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
    [switch]$WhatIf,
    # Skip deploying; just rewrite azure-outputs.json from the customer's existing deployment.
    [switch]$OutputsOnly
)

$ErrorActionPreference = 'Stop'
$cfg = & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer -RepoRoot $RepoRoot
$outDir = Join-Path $RepoRoot "out\$Customer"
New-Item -ItemType Directory $outDir -Force | Out-Null

az account set --subscription $cfg.subscriptionId
if ($LASTEXITCODE) { throw 'az account set failed.' }

if ($OutputsOnly) {
    $raw = az deployment group show --resource-group $cfg.resourceGroup --name "apptelem-$($cfg.customerCode)" --query properties.outputs --output json
    if ($LASTEXITCODE) { throw 'Could not read existing deployment outputs. Run the Azure deployment first.' }
    $o = $raw | ConvertFrom-Json
    [ordered]@{
        appInsightsName             = $o.appInsightsName.value
        appInsightsId               = $o.appInsightsId.value
        appInsightsAppId            = $o.appInsightsAppId.value
        appInsightsConnectionString = $o.appInsightsConnectionString.value
        keyVaultName                = $o.keyVaultName.value
        keyVaultUrl                 = $o.keyVaultUrl.value
        logAnalyticsWorkspaceId     = $o.logAnalyticsWorkspaceId.value
        eventHubNamespaceName       = $o.eventHubNamespaceName.value
        eventHubName                = $o.eventHubName.value
        eventHubConsumerGroup       = $o.eventHubConsumerGroup.value
        eventHubListenRuleName      = $o.eventHubListenRuleName.value
        streamingVirtualNetworkLocation = $o.streamingVirtualNetworkLocation.value
        streamingVirtualNetworkId   = $o.streamingVirtualNetworkId.value
        streamingVirtualNetworkName = $o.streamingVirtualNetworkName.value
        streamingConnectorSubnetId  = $o.streamingConnectorSubnetId.value
        streamingConnectorSubnetName = $o.streamingConnectorSubnetName.value
        eventHubPrivateEndpointId   = $o.eventHubPrivateEndpointId.value
        resourceGroup               = $cfg.resourceGroup
        subscriptionId              = $cfg.subscriptionId
    } | ConvertTo-Json | Set-Content (Join-Path $outDir 'azure-outputs.json') -Encoding utf8
    Write-Host "Wrote outputs from existing deployment to $outDir\azure-outputs.json"
    return
}

$groupExists = az group exists --name $cfg.resourceGroup --output tsv
if ($LASTEXITCODE) { throw 'Could not check whether the resource group exists.' }
if ($groupExists -eq 'false') {
    az group create --name $cfg.resourceGroup --location $cfg.location --tags solution=app-telemetry customer=$($cfg.customerCode) --output none
    if ($LASTEXITCODE) { throw 'Resource group creation failed.' }
} elseif ($groupExists -ne 'true') {
    throw "Unexpected resource group existence response: '$groupExists'."
}

$a = $cfg.azure
$rt = $a.realtime
$rtEnabled = [bool]($rt -and $rt.enabled)
$network = $rt.privateNetworking
$privateNetworkingEnabled = [bool]($rtEnabled -and $network -and $network.enabled)
$rtSku = 'Standard'; $rtCapacity = 1; $rtTables = @('AppRequests', 'AppTraces', 'AppExceptions')
$rtConsumerGroup = 'fabric-eventstream'; $rtLawId = ''
if ($rt) {
    if ($rt.eventHubSku) { $rtSku = [string]$rt.eventHubSku }
    if ($rt.eventHubCapacity) { $rtCapacity = [int]$rt.eventHubCapacity }
    if ($rt.exportTables) { $rtTables = @($rt.exportTables) }
    if ($rt.consumerGroupName) { $rtConsumerGroup = [string]$rt.consumerGroupName }
    if ($rt.existingLogAnalyticsWorkspaceId) { $rtLawId = [string]$rt.existingLogAnalyticsWorkspaceId }
}
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
        enableRealtime            = @{ value = $rtEnabled }
        eventHubSku               = @{ value = $rtSku }
        eventHubCapacity          = @{ value = $rtCapacity }
        exportTables              = @{ value = @($rtTables) }
        consumerGroupName         = @{ value = $rtConsumerGroup }
        existingLogAnalyticsWorkspaceId = @{ value = $rtLawId }
        enableStreamingPrivateNetworking = @{ value = $privateNetworkingEnabled }
        streamingNetworkLocation = @{ value = [string]$network.location }
        streamingNetworkAddressPrefix = @{ value = $(if ($privateNetworkingEnabled) { [string]$network.addressPrefix } else { '10.50.0.0/24' }) }
        streamingConnectorSubnetPrefix = @{ value = $(if ($privateNetworkingEnabled) { [string]$network.connectorSubnetPrefix } else { '10.50.0.0/27' }) }
        streamingPrivateEndpointSubnetPrefix = @{ value = $(if ($privateNetworkingEnabled) { [string]$network.privateEndpointSubnetPrefix } else { '10.50.0.32/27' }) }
    }
}
$paramFile = Join-Path $outDir 'azure.parameters.json'
$parameters | ConvertTo-Json -Depth 6 | Set-Content $paramFile -Encoding utf8

$template = Join-Path $RepoRoot 'azure\infra\main.bicep'
$deployment = "apptelem-$($cfg.customerCode)"

if ($WhatIf) {
    az deployment group what-if --resource-group $cfg.resourceGroup --name $deployment --template-file $template --parameters "@$paramFile"
    if ($LASTEXITCODE) { throw 'Azure deployment what-if failed.' }
    return
}

if ($privateNetworkingEnabled) {
    $registrationState = az provider show --namespace Microsoft.MessagingConnectors --query registrationState --output tsv
    if ($LASTEXITCODE) { throw 'Could not read Microsoft.MessagingConnectors registration state.' }
    if ($registrationState -ne 'Registered') {
        az provider register --namespace Microsoft.MessagingConnectors --wait --output none
        if ($LASTEXITCODE) { throw 'Microsoft.MessagingConnectors registration failed. Subscription-level registration permission is required.' }
    }
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
    logAnalyticsWorkspaceId     = $o.logAnalyticsWorkspaceId.value
    eventHubNamespaceName       = $o.eventHubNamespaceName.value
    eventHubName                = $o.eventHubName.value
    eventHubConsumerGroup       = $o.eventHubConsumerGroup.value
    eventHubListenRuleName      = $o.eventHubListenRuleName.value
    streamingVirtualNetworkLocation = $o.streamingVirtualNetworkLocation.value
    streamingVirtualNetworkId   = $o.streamingVirtualNetworkId.value
    streamingVirtualNetworkName = $o.streamingVirtualNetworkName.value
    streamingConnectorSubnetId  = $o.streamingConnectorSubnetId.value
    streamingConnectorSubnetName = $o.streamingConnectorSubnetName.value
    eventHubPrivateEndpointId   = $o.eventHubPrivateEndpointId.value
    resourceGroup               = $cfg.resourceGroup
    subscriptionId              = $cfg.subscriptionId
}
$result | ConvertTo-Json | Set-Content (Join-Path $outDir 'azure-outputs.json') -Encoding utf8
Write-Host "Azure deployment complete. Key Vault: $($result.keyVaultUrl)  App Insights: $($result.appInsightsName)"
if ($rtEnabled) {
    Write-Host "Real-time export enabled. Event Hub: $($result.eventHubNamespaceName)/$($result.eventHubName) (consumer group '$($result.eventHubConsumerGroup)', listen rule '$($result.eventHubListenRuleName)'). See docs/REALTIME_HOTPATH.md."
}
if ($privateNetworkingEnabled) {
    Write-Host "Private consumer networking: $($result.streamingVirtualNetworkName) in $($result.streamingVirtualNetworkLocation), subnet '$($result.streamingConnectorSubnetName)'. Create the Fabric streaming VNet gateway and bind the Event Hubs (Extended features) connection. See docs/REALTIME_HOTPATH.md."
}
