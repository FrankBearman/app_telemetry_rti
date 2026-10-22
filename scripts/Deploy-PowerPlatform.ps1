#Requires -Version 5.1
<#
.SYNOPSIS
  Packs powerapps/ (classic `pac solution unpack` format) into a managed (default) or unmanaged (powerPlatform.managed = false) solution and imports it
  into the customer's Power Platform environment.

  Needs the Power Platform CLI (pac) on PATH and a service principal registered as an application
  user in the target environment.   The client secret is read at run time from the customer's Key Vault
    (secret 'pp-client-secret', or powerPlatform.clientSecretName; needs an az login) or, if set, the
    PP_CLIENT_SECRET environment variable - never from the customer file.

  The Application Insights connection string produced by Deploy-Azure.ps1 is written into the
  Canvas app before packing, so the app reports to the customer's own resource.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$PackOnly
)

$ErrorActionPreference = 'Stop'
$cfg = & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer -RepoRoot $RepoRoot
$pp = $cfg.powerPlatform
$outDir = Join-Path $RepoRoot "out\$Customer"
$azureOut = Join-Path $outDir 'azure-outputs.json'
if (-not (Test-Path $azureOut)) { throw "Run Deploy-Azure.ps1 first; missing $azureOut" }
$azure = Get-Content $azureOut -Raw | ConvertFrom-Json

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) { throw 'Power Platform CLI (pac) was not found on PATH.' }

# Stage a copy so the repository source is never modified.
$stage = Join-Path $outDir 'powerapps-src'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item (Join-Path $RepoRoot 'powerapps') $stage -Recurse

$connectionString = $azure.appInsightsConnectionString
if ($connectionString -notmatch 'InstrumentationKey=([0-9a-fA-F-]{36})') { throw 'Unexpected Application Insights connection string format.' }
$instrumentationKey = $Matches[1]

# The Canvas app ships as a packed .msapp: unpack, patch the two App Insights files, repack in place.
$patched = 0
Get-ChildItem (Join-Path $stage 'CanvasApps') -Filter *.msapp -ErrorAction SilentlyContinue | ForEach-Object {
    $msapp = $_.FullName
    $src = Join-Path $outDir "canvas-src-$($_.BaseName)"
    if (Test-Path $src) { Remove-Item $src -Recurse -Force }
    pac canvas unpack --msapp $msapp --sources $src | Out-Null
    if ($LASTEXITCODE) { throw "pac canvas unpack failed for $msapp." }
    $keyFile = Join-Path $src 'AppInsightsKey.json'
    $manifest = Join-Path $src 'CanvasManifest.json'
    if ((Test-Path $keyFile) -and (Test-Path $manifest)) {
        $k = Get-Content $keyFile -Raw
        $k = [regex]::Replace($k, '("InstrumentationKey"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + '"' + $instrumentationKey + '"' })
        Set-Content $keyFile $k -Encoding utf8 -NoNewline
        $m = Get-Content $manifest -Raw
        $m = [regex]::Replace($m, '("ConnectionString"\s*:\s*)"[^"]*"', { param($x) $x.Groups[1].Value + (ConvertTo-Json $connectionString) })
        Set-Content $manifest $m -Encoding utf8 -NoNewline
        $newMsapp = "$msapp.new"
        $packOut = pac canvas pack --sources $src --msapp $newMsapp 2>&1
        if ($LASTEXITCODE) { $packOut | Out-Host; throw "pac canvas pack failed for $msapp." }
        Move-Item $newMsapp $msapp -Force
        $patched++
    }
    Remove-Item $src -Recurse -Force
}
Write-Host "Patched Application Insights settings in $patched Canvas app(s)."
# powerPlatform.managed defaults to true; Dataverse cannot update a solution across modes.
$managed = $true
if ($null -ne $pp.managed) { $managed = [bool]$pp.managed }
$packageType = if ($managed) { 'Managed' } else { 'Unmanaged' }
Write-Host "Packing as $packageType solution."
$zip = Join-Path $outDir "$($pp.solutionName)_$($packageType.ToLower()).zip"
pac solution pack --folder $stage --zipfile $zip --packagetype $packageType
if ($LASTEXITCODE) { throw 'pac solution pack failed.' }
if ($PackOnly) { Write-Host "Packed: $zip"; return }

$settings = [ordered]@{
    EnvironmentVariables = @($pp.environmentVariables | ForEach-Object { [ordered]@{ SchemaName = $_.schemaName; Value = $_.value } })
    ConnectionReferences = @($pp.connectionReferences | Where-Object {
        if (-not $_.connectionId -or $_.connectionId -like 'REPLACE_*') {
            Write-Warning "Skipping connection reference $($_.logicalName): no real connectionId set."
            $false
        } else { $true }
    } | ForEach-Object { [ordered]@{ LogicalName = $_.logicalName; ConnectionId = $_.connectionId; ConnectorId = $_.connectorId } })
}
$settingsFile = Join-Path $outDir 'deployment-settings.json'
$settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Encoding utf8

$secret = $env:PP_CLIENT_SECRET
if (-not $secret -or $secret -match '^\$\(') {
    $secretName = if ($pp.clientSecretName) { $pp.clientSecretName } else { 'pp-client-secret' }
    Write-Host "Reading secret '$secretName' from Key Vault $($azure.keyVaultName)."
    $secret = az keyvault secret show --vault-name $azure.keyVaultName --name $secretName --query value -o tsv
    if ($LASTEXITCODE -or -not $secret) { throw "Could not read Key Vault secret '$secretName' from $($azure.keyVaultName). Create it and grant the deploy service connection 'Key Vault Secrets User'." }
}
Write-Host "##vso[task.setsecret]$secret"
Write-Host "Authenticating as app $($pp.applicationId); secret length $($secret.Length) chars."
pac auth create --name "apptelem-$Customer" --applicationId $pp.applicationId --clientSecret $secret --tenant $cfg.tenantId --environment $pp.environmentUrl
if ($LASTEXITCODE) { throw 'pac auth create failed.' }

pac solution import --path $zip --settings-file $settingsFile --publish-changes --force-overwrite --async --max-async-wait-time 60
if ($LASTEXITCODE) {
    # pac only reports "An unexpected error occurred"; the detail is in the Dataverse import job.
    try {
        $envUrl = $pp.environmentUrl.TrimEnd('/')
        $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body @{
            grant_type = 'client_credentials'; client_id = $pp.applicationId; client_secret = $secret; scope = "$envUrl/.default" }
        $job = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $($tok.access_token)" } `
            -Uri "$envUrl/api/data/v9.2/importjobs?`$orderby=createdon desc&`$top=1&`$select=data,solutionname,progress").value[0]
        Write-Host "--- Dataverse import job ($($job.solutionname), progress $($job.progress)) ---"
        $xml = [xml]$job.data
        $xml.SelectNodes("//*[@result='failure' or @errorcode]") | ForEach-Object {
            Write-Host "$($_.LocalName) $($_.name) $($_.id): $($_.errorcode) $($_.errortext)"
        }
    } catch { Write-Warning "Could not fetch import job details: $_" }
    throw 'pac solution import failed.'
}
Write-Host "Imported $($pp.solutionName) into $($pp.environmentUrl)"
