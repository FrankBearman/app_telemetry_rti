// Continuous Log Analytics data export rule that streams workspace-based Application
// Insights tables to a single Event Hub. Deploy at the workspace's resource group scope.

param workspaceName string

param ruleName string = 'apptelem-realtime-export'

@description('Resource ID of the Event Hubs namespace (same region as the workspace).')
param eventHubNamespaceId string

@description('Hub that receives every exported table. Records carry a Type column per table.')
param eventHubName string

@description('Workspace table names (Analytics plan). App Insights tables use the App* names.')
param tableNames array

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource dataExport 'Microsoft.OperationalInsights/workspaces/dataExports@2020-08-01' = {
  parent: workspace
  name: ruleName
  properties: {
    destination: {
      resourceId: eventHubNamespaceId
      metaData: {
        eventHubName: eventHubName
      }
    }
    tableNames: tableNames
    enable: true
  }
}

output id string = dataExport.id
