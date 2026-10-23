// Fabric connector injection and the Event Hub private endpoint use separate subnets.
param namePrefix string
param location string
param addressPrefix string
param connectorSubnetPrefix string
param privateEndpointSubnetPrefix string
param eventHubNamespaceId string
param workspaceIdentityPrincipalId string

var connectorSubnetName = 'streaming-connectors'
var privateEndpointSubnetName = 'private-endpoints'
var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

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
          delegations: [
            {
              name: 'messaging-connectors'
              properties: {
                serviceName: 'Microsoft.MessagingConnectors'
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

resource networkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, workspaceIdentityPrincipalId, networkContributorRoleId)
  scope: vnet
  properties: {
    principalId: workspaceIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleId
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
