// Fabric connector injection and the Event Hub private endpoint use separate subnets.
param namePrefix string
param location string
param addressPrefix string
param connectorSubnetPrefix string
param privateEndpointSubnetPrefix string
param eventHubNamespaceId string

var connectorSubnetName = 'streaming-connectors'
var privateEndpointSubnetName = 'private-endpoints'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-streaming-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: connectorSubnetName
        properties: {
          addressPrefix: connectorSubnetPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.EventHub'
            }
          ]
          delegations: [
            {
              name: 'messaging-connectors'
              properties: {
                serviceName: 'Microsoft.MessagingConnectors/connectors'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: last(split(eventHubNamespaceId, '/'))
}

// Selected-networks mode requires a real allow rule even with trusted services enabled.
resource networkRules 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = {
  parent: eventHubNamespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Enabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
    ipRules: []
    virtualNetworkRules: [
      {
        subnet: {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, connectorSubnetName)
        }
        ignoreMissingVnetServiceEndpoint: false
      }
    ]
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.servicebus.windows.net'
  location: 'global'
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: '${namePrefix}-streaming-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${namePrefix}-eventhub-pe'
  location: location
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointSubnetName)
    }
    privateLinkServiceConnections: [
      {
        name: 'eventhub'
        properties: {
          privateLinkServiceId: eventHubNamespaceId
          groupIds: [
            'namespace'
          ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'eventhub'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

output virtualNetworkId string = vnet.id
output virtualNetworkName string = vnet.name
output connectorSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, connectorSubnetName)
output connectorSubnetName string = connectorSubnetName
output privateEndpointId string = privateEndpoint.id
