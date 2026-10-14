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

output appInsightsName string = appInsights.outputs.name
output appInsightsId string = appInsights.outputs.id
output appInsightsAppId string = appInsights.outputs.appId
output appInsightsConnectionString string = appInsights.outputs.connectionString
output keyVaultName string = keyVault.outputs.name
output keyVaultUrl string = keyVault.outputs.uri
