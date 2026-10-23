targetScope = 'resourceGroup'

@description('Existing streaming VNet in this resource group. Deploy main.bicep first.')
@minLength(1)
param virtualNetworkName string

@description('Fabric workspace identity service-principal object ID, not its application ID.')
@minLength(36)
@maxLength(36)
param workspacePrincipalId string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

@description('Reuse the name of an existing identical VNet assignment to avoid RoleAssignmentExists.')
param roleAssignmentName string = ''

// AVM role-assignment modules target RG/subscription scopes; this grant must be VNet-only.
resource streamingAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: empty(roleAssignmentName) ? guid(vnet.id, workspacePrincipalId, networkContributorRoleId) : roleAssignmentName
  scope: vnet
  properties: {
    principalId: workspacePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleId
  }
}

output roleAssignmentId string = streamingAccess.id
