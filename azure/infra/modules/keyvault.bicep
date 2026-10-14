@description('Name of the Key Vault (created, or looked up when create is false). Max 24 characters.')
@maxLength(24)
param name string

@description('True to create the vault; false to reference an existing vault that uses Azure RBAC.')
param create bool

param location string

@description('Principals (object IDs) granted "Key Vault Secrets User".')
param secretReaderPrincipalIds array

@description('Principals (object IDs) granted "Key Vault Secrets Officer".')
param secretOfficerPrincipalIds array

param enablePurgeProtection bool

var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2d791ab8'

resource keyVaultNew 'Microsoft.KeyVault/vaults@2023-07-01' = if (create) {
  name: name
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: enablePurgeProtection ? true : null
  }
}

resource keyVaultExisting 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!create) {
  name: name
}

resource readersNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in secretReaderPrincipalIds: if (create) {
    name: guid(name, principalId, secretsUserRoleId)
    scope: keyVaultNew
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
      principalId: principalId
    }
  }
]

resource readersExisting 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in secretReaderPrincipalIds: if (!create) {
    name: guid(name, principalId, secretsUserRoleId)
    scope: keyVaultExisting
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
      principalId: principalId
    }
  }
]

resource officersNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in secretOfficerPrincipalIds: if (create) {
    name: guid(name, principalId, secretsOfficerRoleId)
    scope: keyVaultNew
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
      principalId: principalId
    }
  }
]

resource officersExisting 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in secretOfficerPrincipalIds: if (!create) {
    name: guid(name, principalId, secretsOfficerRoleId)
    scope: keyVaultExisting
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
      principalId: principalId
    }
  }
]

output name string = name
output uri string = create ? keyVaultNew!.properties.vaultUri : keyVaultExisting!.properties.vaultUri
