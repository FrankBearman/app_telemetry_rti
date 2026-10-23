@description('Name of the Log Analytics workspace to create (ignored when using an existing Application Insights).')
param workspaceName string

@description('Name of the Application Insights resource (created, or looked up when create is false).')
param name string

@description('True to create the workspace and Application Insights; false to reference an existing Application Insights.')
param create bool

param location string
param retentionInDays int

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (create) {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

resource appInsightsNew 'Microsoft.Insights/components@2020-02-02' = if (create) {
  name: name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics!.id
    RetentionInDays: retentionInDays
    IngestionMode: 'LogAnalytics'
  }
}

resource appInsightsExisting 'Microsoft.Insights/components@2020-02-02' existing = if (!create) {
  name: name
}

output id string = create ? appInsightsNew!.id : appInsightsExisting!.id
output name string = name
output appId string = create ? appInsightsNew!.properties.AppId : appInsightsExisting!.properties.AppId
output connectionString string = create ? appInsightsNew!.properties.ConnectionString : appInsightsExisting!.properties.ConnectionString
output workspaceId string = create ? logAnalytics!.id : appInsightsExisting!.properties.WorkspaceResourceId
