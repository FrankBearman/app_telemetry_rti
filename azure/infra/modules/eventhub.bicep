// Event Hubs namespace + hub that receives the Log Analytics continuous data export
// (real-time hot path). Fabric Eventstream reads it through a dedicated consumer group
// using a listen-only SAS rule. No keys are emitted as outputs.

@description('Event Hubs namespace name (globally unique, 6-50 chars).')
param namespaceName string

@description('Must be the same region as the Log Analytics workspace being exported.')
param location string

@description('Data export requires Standard or above.')
@allowed([
  'Standard'
  'Premium'
])
param sku string = 'Standard'

@minValue(1)
@maxValue(20)
param capacity int = 1

param eventHubName string = 'appinsights-export'

@minValue(1)
@maxValue(32)
param partitionCount int = 4

@minValue(1)
@maxValue(7)
param messageRetentionInDays int = 1

param consumerGroupName string = 'fabric-eventstream'

param listenRuleName string = 'fabric-listen'

resource namespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  sku: {
    name: sku
    tier: sku
    capacity: capacity
  }
  properties: {
    minimumTlsVersion: '1.2'
    // Log Analytics data export authenticates with the trusted-service identity, not SAS.
    disableLocalAuth: false
  }
}

resource hub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: namespace
  name: eventHubName
  properties: {
    partitionCount: partitionCount
    messageRetentionInDays: messageRetentionInDays
  }
}

resource consumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: hub
  name: consumerGroupName
}

resource listenRule 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: hub
  name: listenRuleName
  properties: {
    rights: [
      'Listen'
    ]
  }
}

output namespaceName string = namespace.name
output namespaceId string = namespace.id
output eventHubName string = hub.name
output consumerGroupName string = consumerGroup.name
output listenRuleName string = listenRule.name
