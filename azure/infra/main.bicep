// Azure foundation for the app telemetry solution, deployable to any customer tenant.
// Creates (or references existing) Application Insights + Log Analytics and Key Vault.
// Normally invoked by scripts/Deploy-Azure.ps1, which builds the parameters from
// customers/<customer>.json.
targetScope = 'resourceGroup'

@description('Short lowercase prefix for new resource names, e.g. "apptelemcon".')
@minLength(3)
@maxLength(12)
param namePrefix string

param location string = resourceGroup().location

@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Reference an existing Application Insights instead of creating one.')
param useExistingAppInsights bool = false
param existingAppInsightsName string = ''

@description('Reference an existing (RBAC-enabled) Key Vault instead of creating one.')
param useExistingKeyVault bool = false
param existingKeyVaultName string = ''

param secretReaderPrincipalIds array = []
param secretOfficerPrincipalIds array = []
param enablePurgeProtection bool = true

@description('Real-time hot path: Log Analytics data export -> Event Hub -> Fabric Eventstream -> Eventhouse.')
param enableRealtime bool = false

@allowed([
  'Standard'
  'Premium'
])
param eventHubSku string = 'Standard'

@minValue(1)
@maxValue(20)
param eventHubCapacity int = 1

@description('Workspace tables to export (workspace schema names, Analytics plan only).')
param exportTables array = [
  'AppRequests'
  'AppTraces'
  'AppExceptions'
  'AppDependencies'
]

param consumerGroupName string = 'fabric-eventstream'

@description('Required with enableRealtime + useExistingAppInsights: resource ID of the Log Analytics workspace behind the existing Application Insights. It must be in the same region as "location".')
param existingLogAnalyticsWorkspaceId string = ''

param enableStreamingPrivateNetworking bool = false
@description('Region of the Fabric Eventstream/capacity, which can differ from the Event Hub/Log Analytics region.')
param streamingNetworkLocation string = ''
param streamingNetworkAddressPrefix string = '10.50.0.0/24'
param streamingConnectorSubnetPrefix string = '10.50.0.0/27'
param streamingPrivateEndpointSubnetPrefix string = '10.50.0.32/27'
@description('Service-principal object ID of the Fabric workspace identity, not its client/application ID.')
param fabricWorkspaceIdentityPrincipalId string = ''

var suffix = uniqueString(resourceGroup().id)
var appInsightsName = useExistingAppInsights ? existingAppInsightsName : '${namePrefix}-appi'
var keyVaultName = useExistingKeyVault ? existingKeyVaultName : take('${namePrefix}-kv-${suffix}', 24)

module appInsights 'modules/appinsights.bicep' = {
  name: 'appinsights'
  params: {
    name: appInsightsName
    workspaceName: '${namePrefix}-law'
    create: !useExistingAppInsights
    location: location
    retentionInDays: retentionInDays
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    create: !useExistingKeyVault
    location: location
    secretReaderPrincipalIds: secretReaderPrincipalIds
    secretOfficerPrincipalIds: secretOfficerPrincipalIds
    enablePurgeProtection: enablePurgeProtection
  }
}

// The export rule lives on the workspace, which for an existing App Insights may be in
// another resource group/subscription, so the scope is derived from a deploy-time value.
var newWorkspaceId = resourceId('Microsoft.OperationalInsights/workspaces', '${namePrefix}-law')
var exportWorkspaceId = useExistingAppInsights && !empty(existingLogAnalyticsWorkspaceId) ? existingLogAnalyticsWorkspaceId : newWorkspaceId
var exportWorkspaceParts = split(exportWorkspaceId, '/')

module eventHub 'modules/eventhub.bicep' = if (enableRealtime) {
  name: 'eventhub'
  params: {
    namespaceName: take('${namePrefix}-ehns-${suffix}', 50)
    location: location
    sku: eventHubSku
    capacity: eventHubCapacity
    consumerGroupName: consumerGroupName
    enablePrivateNetworking: enableStreamingPrivateNetworking
  }
}

module streamingNetwork 'modules/streamingnetwork.bicep' = if (enableRealtime && enableStreamingPrivateNetworking) {
  name: 'streamingnetwork'
  params: {
    namePrefix: namePrefix
    location: streamingNetworkLocation
    addressPrefix: streamingNetworkAddressPrefix
    connectorSubnetPrefix: streamingConnectorSubnetPrefix
    privateEndpointSubnetPrefix: streamingPrivateEndpointSubnetPrefix
    eventHubNamespaceId: eventHub!.outputs.namespaceId
    workspaceIdentityPrincipalId: fabricWorkspaceIdentityPrincipalId
  }
}

module dataExport 'modules/dataexport.bicep' = if (enableRealtime) {
  name: 'dataexport'
  scope: resourceGroup(exportWorkspaceParts[2], exportWorkspaceParts[4])
  params: {
    workspaceName: exportWorkspaceParts[8]
    eventHubNamespaceId: eventHub!.outputs.namespaceId
    eventHubName: eventHub!.outputs.eventHubName
    tableNames: exportTables
  }
  dependsOn: [
    appInsights
    streamingNetwork
  ]
}

output appInsightsName string = appInsights.outputs.name
output appInsightsId string = appInsights.outputs.id
output appInsightsAppId string = appInsights.outputs.appId
output appInsightsConnectionString string = appInsights.outputs.connectionString
output keyVaultName string = keyVault.outputs.name
output keyVaultUrl string = keyVault.outputs.uri
output logAnalyticsWorkspaceId string = appInsights.outputs.workspaceId
output eventHubNamespaceName string = enableRealtime ? eventHub!.outputs.namespaceName : ''
output eventHubName string = enableRealtime ? eventHub!.outputs.eventHubName : ''
output eventHubConsumerGroup string = enableRealtime ? eventHub!.outputs.consumerGroupName : ''
output eventHubListenRuleName string = enableRealtime ? eventHub!.outputs.listenRuleName : ''
output streamingVirtualNetworkLocation string = enableRealtime && enableStreamingPrivateNetworking ? streamingNetworkLocation : ''
output streamingVirtualNetworkId string = enableRealtime && enableStreamingPrivateNetworking ? streamingNetwork!.outputs.virtualNetworkId : ''
output streamingVirtualNetworkName string = enableRealtime && enableStreamingPrivateNetworking ? streamingNetwork!.outputs.virtualNetworkName : ''
output streamingConnectorSubnetId string = enableRealtime && enableStreamingPrivateNetworking ? streamingNetwork!.outputs.connectorSubnetId : ''
output streamingConnectorSubnetName string = enableRealtime && enableStreamingPrivateNetworking ? streamingNetwork!.outputs.connectorSubnetName : ''
output eventHubPrivateEndpointId string = enableRealtime && enableStreamingPrivateNetworking ? streamingNetwork!.outputs.privateEndpointId : ''
