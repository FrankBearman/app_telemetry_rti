#Requires -Version 5.1
<#
.SYNOPSIS
  Packs powerapps/ (Dataverse Git-integration YAML format) into a managed solution and imports it
  into the customer's Power Platform environment.

  Needs the Power Platform CLI (pac) on PATH and a service principal registered as an application
  user in the target environment. The client secret is read from the PP_CLIENT_SECRET environment
  variable (a secret variable in ADO) - never from the customer file.

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

$patched = 0
Get-ChildItem (Join-Path $stage 'canvasapps') -Recurse -Filter Properties.json -ErrorAction SilentlyContinue | ForEach-Object {
    $text = Get-Content $_.FullName -Raw
    if ($text -match '"ConnectionString"\s*:') {
        $text = [regex]::Replace($text, '("ConnectionString"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + (ConvertTo-Json $connectionString) })
        $text = [regex]::Replace($text, '("InstrumentationKey"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + '"' + $instrumentationKey + '"' })
        Set-Content $_.FullName $text -Encoding utf8 -NoNewline
        $patched++
    }
}
Write-Host "Patched Application Insights settings in $patched Canvas app file(s)."

$zip = Join-Path $outDir "$($pp.solutionName)_managed.zip"
pac solution pack --folder $stage --zipfile $zip --packagetype Managed
if ($LASTEXITCODE) { throw 'pac solution pack failed.' }
if ($PackOnly) { Write-Host "Packed: $zip"; return }

$settings = [ordered]@{
    EnvironmentVariables = @($pp.environmentVariables | ForEach-Object { [ordered]@{ SchemaName = $_.schemaName; Value = $_.value } })
    ConnectionReferences = @($pp.connectionReferences | ForEach-Object { [ordered]@{ LogicalName = $_.logicalName; ConnectionId = $_.connectionId; ConnectorId = $_.connectorId } })
}
$settingsFile = Join-Path $outDir 'deployment-settings.json'
$settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Encoding utf8

if (-not $env:PP_CLIENT_SECRET) { throw 'Set the PP_CLIENT_SECRET environment variable.' }
if ($env:PP_CLIENT_SECRET -match '^\$\(') { throw 'PP_CLIENT_SECRET was not resolved by Azure DevOps (still a macro). Add a secret variable named exactly PP_CLIENT_SECRET to the variable group and authorize the pipeline to use it.' }
Write-Host "Authenticating as app $($pp.applicationId); secret length $($env:PP_CLIENT_SECRET.Length) chars."
pac auth create --name "apptelem-$Customer" --applicationId $pp.applicationId --clientSecret $env:PP_CLIENT_SECRET --tenant $cfg.tenantId --environment $pp.environmentUrl
if ($LASTEXITCODE) { throw 'pac auth create failed.' }

pac solution import --path $zip --settings-file $settingsFile --publish-changes --force-overwrite --async --max-async-wait-time 60
if ($LASTEXITCODE) { throw 'pac solution import failed.' }
Write-Host "Imported $($pp.solutionName) into $($pp.environmentUrl)"
