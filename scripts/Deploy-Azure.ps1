#Requires -Version 5.1
<#
.SYNOPSIS
  Deploys the Azure foundation (Application Insights, Log Analytics, Key Vault) for a customer
  and writes the deployment outputs to out/<Customer>/azure-outputs.json.

  Requires an authenticated Azure CLI (az login, or the ADO AzureCLI@2 task) with Contributor
  on the target subscription/resource group (plus User Access Administrator to assign roles).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$cfg = & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer -RepoRoot $RepoRoot
$outDir = Join-Path $RepoRoot "out\$Customer"
New-Item -ItemType Directory $outDir -Force | Out-Null

az account set --subscription $cfg.subscriptionId
if ($LASTEXITCODE) { throw 'az account set failed.' }

az group create --name $cfg.resourceGroup --location $cfg.location --tags solution=app-telemetry customer=$($cfg.customerCode) --output none
if ($LASTEXITCODE) { throw 'Resource group creation failed.' }

$a = $cfg.azure
$parameters = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        namePrefix                = @{ value = $a.namePrefix }
        location                  = @{ value = $cfg.location }
        retentionInDays           = @{ value = [int]$a.retentionInDays }
        enablePurgeProtection     = @{ value = [bool]$a.enablePurgeProtection }
        useExistingAppInsights    = @{ value = [bool]$a.useExistingAppInsights }
        existingAppInsightsName   = @{ value = [string]$a.existingAppInsightsName }
        useExistingKeyVault       = @{ value = [bool]$a.useExistingKeyVault }
        existingKeyVaultName      = @{ value = [string]$a.existingKeyVaultName }
        secretReaderPrincipalIds  = @{ value = @($a.secretReaderPrincipalIds) }
        secretOfficerPrincipalIds = @{ value = @($a.secretOfficerPrincipalIds) }
    }
}
$paramFile = Join-Path $outDir 'azure.parameters.json'
$parameters | ConvertTo-Json -Depth 6 | Set-Content $paramFile -Encoding utf8

$template = Join-Path $RepoRoot 'azure\infra\main.bicep'
$deployment = "apptelem-$($cfg.customerCode)"

if ($WhatIf) {
    az deployment group what-if --resource-group $cfg.resourceGroup --name $deployment --template-file $template --parameters "@$paramFile"
    return
}

$raw = az deployment group create --resource-group $cfg.resourceGroup --name $deployment `
    --template-file $template --parameters "@$paramFile" --query properties.outputs --output json
if ($LASTEXITCODE) { throw 'Azure deployment failed.' }

$o = $raw | ConvertFrom-Json
$result = [ordered]@{
    appInsightsName             = $o.appInsightsName.value
    appInsightsId               = $o.appInsightsId.value
    appInsightsAppId            = $o.appInsightsAppId.value
    appInsightsConnectionString = $o.appInsightsConnectionString.value
    keyVaultName                = $o.keyVaultName.value
    keyVaultUrl                 = $o.keyVaultUrl.value
    resourceGroup               = $cfg.resourceGroup
    subscriptionId              = $cfg.subscriptionId
}
$result | ConvertTo-Json | Set-Content (Join-Path $outDir 'azure-outputs.json') -Encoding utf8
Write-Host "Azure deployment complete. Key Vault: $($result.keyVaultUrl)  App Insights: $($result.appInsightsName)"
