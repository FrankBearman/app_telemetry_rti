#Requires -Version 5.1
<#
.SYNOPSIS
  Takes the exported solution zip powerapps\solutionpackage\<solutionName>*.zip, patches the Application Insights
  settings inside the nested Canvas app (.msapp), and imports it into the customer's Power Platform
  environment. Managed/unmanaged is whatever the zip was exported as.

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

# Work on a copy of the exported solution zip so the repository file is never modified.
$pkgDir = Join-Path $RepoRoot 'powerapps\solutionpackage'
$found = Get-ChildItem $pkgDir -Filter "$($pp.solutionName)*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $found) { throw "No $($pp.solutionName)*.zip found in $pkgDir. Export the solution from dev and commit it there." }
$source = $found.FullName
Write-Host "Using solution package $source"
$zip = Join-Path $outDir "$($pp.solutionName)_import.zip"
New-Item -ItemType Directory -Force $outDir | Out-Null
Copy-Item $source $zip -Force

$connectionString = $azure.appInsightsConnectionString
if ($connectionString -notmatch 'InstrumentationKey=([0-9a-fA-F-]{36})') { throw 'Unexpected Application Insights connection string format.' }
$instrumentationKey = $Matches[1]

function Update-Properties([string]$text) {
    $text = [regex]::Replace($text, '("ConnectionString"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + (ConvertTo-Json $connectionString) })
    [regex]::Replace($text, '("InstrumentationKey"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + '"' + $instrumentationKey + '"' })
}

# Patch Properties.json inside each nested .msapp in place; entry names are left untouched.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$utf8 = New-Object System.Text.UTF8Encoding($false)
$patched = 0
$solZip = [IO.Compression.ZipFile]::Open($zip, 'Update')
try {
    foreach ($appEntry in @($solZip.Entries | Where-Object { $_.FullName -match '(?i)^canvasapps/.+\.msapp$' })) {
        $ms = New-Object IO.MemoryStream
        $s = $appEntry.Open(); $s.CopyTo($ms); $s.Dispose()
        $app = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Update, $true)
        $props = $app.GetEntry('Properties.json')
        if ($props) {
            $r = New-Object IO.StreamReader($props.Open(), $utf8); $text = $r.ReadToEnd(); $r.Dispose()
            if ($text -match '"ConnectionString"\s*:') {
                $new = Update-Properties $text
                $props.Delete()
                $e = $app.CreateEntry('Properties.json')
                $w = New-Object IO.StreamWriter($e.Open(), $utf8); $w.Write($new); $w.Dispose()
                $patched++
            } else {
                Write-Warning "Skipped $($appEntry.FullName): Properties.json has no ConnectionString, so it was not patched."
            }
        } else {
            Write-Warning "Skipped $($appEntry.FullName): no Properties.json found."
        }
        $app.Dispose()
        $name = $appEntry.FullName
        $appEntry.Delete()
        $out = $solZip.CreateEntry($name).Open()
        $ms.Position = 0; $ms.CopyTo($out); $out.Dispose(); $ms.Dispose()
    }
} finally { $solZip.Dispose() }
if (-not $patched) { throw "No canvas app Properties.json with a ConnectionString was found in $source." }
Write-Host "Patched Application Insights settings in $patched Canvas app(s)."
if ($PackOnly) { Write-Host "Prepared: $zip"; return }

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
