#Requires -Version 5.1
<#
.SYNOPSIS
  Administrator-only bootstrap: grants the Fabric workspace identity Network Contributor
  on the existing streaming VNet. Not invoked by Deploy-All or the normal ADO pipeline.
  Run Azure deployment and Ensure-FabricWorkspaceIdentity.ps1 first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$cfg = & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer -RepoRoot $RepoRoot
if (-not $cfg.azure.realtime.enabled -or -not $cfg.azure.realtime.privateNetworking.enabled) {
    throw 'Streaming access bootstrap requires realtime private networking to be enabled.'
}
$raw = az account show --subscription $cfg.subscriptionId --output json
if ($LASTEXITCODE) { throw 'Could not read the Azure account. Sign in to the customer tenant as an administrator.' }
$account = $raw | ConvertFrom-Json
if ($account.tenantId -ne $cfg.tenantId -or $account.id -ne $cfg.subscriptionId) {
    throw 'The Azure authentication context does not match the configured customer tenant and subscription.'
}
$identity = & "$PSScriptRoot\Ensure-FabricWorkspaceIdentity.ps1" -Customer $Customer -RepoRoot $RepoRoot -ReadOnly
$vnetName = "$($cfg.azure.namePrefix)-streaming-vnet"
$vnetId = "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.resourceGroup)/providers/Microsoft.Network/virtualNetworks/$vnetName"
$roleId = "/subscriptions/$($cfg.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
$raw = az role assignment list --subscription $cfg.subscriptionId --scope $vnetId --fill-principal-name false --output json
if ($LASTEXITCODE) { throw 'Could not read the VNet role assignments. Administrator role-assignment read access is required.' }
$existing = @($raw | ConvertFrom-Json | Where-Object {
    $_.scope -eq $vnetId -and $_.principalId -eq $identity.servicePrincipalId -and $_.roleDefinitionId -eq $roleId
})
if ($existing.Count -gt 1) { throw 'Multiple identical VNet role assignments exist; resolve them before deploying the bootstrap.' }
$parameters = @("virtualNetworkName=$vnetName", "workspacePrincipalId=$($identity.servicePrincipalId)")
if ($existing.Count -eq 1) {
    $parameters += "roleAssignmentName=$($existing[0].name)"
    Write-Host "Reusing existing VNet role assignment $($existing[0].name)."
}
$template = Join-Path $RepoRoot 'azure\infra\streaming-access.bicep'
$operation = 'create'
if ($WhatIf) { $operation = 'what-if' }
az deployment group $operation --subscription $cfg.subscriptionId --resource-group $cfg.resourceGroup `
    --name "apptelem-$Customer-streaming-access" --template-file $template --parameters @parameters
if ($LASTEXITCODE) { throw 'Streaming access bootstrap failed. This separate deployment requires roleAssignments/write on the VNet.' }
