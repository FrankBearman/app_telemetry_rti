[StagingDefinition = [Kind = "FastCopy"]]
section Section1;
[DataDestinations = {[Definition = [Kind = "Reference", QueryName = "requests_custom_dim_DataDestination", IsNewTarget = true], Settings = [Kind = "Automatic", TypeSettings = [Kind = "Table"]]]}]
shared requests_custom_dim = // dataflow_requests_custom_dim
/* The exported Power Query Formula Language can be used with Power BI Desktop. */

let AnalyticsQuery =
let Source = Json.Document(Web.Contents("https://api.applicationinsights.io/v1/apps/00a8e086-bbec-4f92-a08f-14a05eb151f2/query", 
[Query=[#"query"="requests
|take 10

",#"x-ms-app"="AAPBI",#"timespan"="P1D",#"prefer"="ai.response-thinning=true"],Timeout=#duration(0,0,4,0)])),
TypeMap = #table(
{ "AnalyticsTypes", "Type" }, 
{ 
{ "string",   Text.Type },
{ "int",      Int32.Type },
{ "long",     Int64.Type },
{ "real",     Double.Type },
{ "timespan", Duration.Type },
{ "datetime", DateTimeZone.Type },
{ "bool",     Logical.Type },
{ "guid",     Text.Type },
{ "dynamic",  Text.Type }
}),
DataTable = Source[tables]{0},
Columns = Table.FromRecords(DataTable[columns]),
ColumnsWithType = Table.Join(Columns, {"type"}, TypeMap , {"AnalyticsTypes"}),
Rows = Table.FromRows(DataTable[rows], Columns[name]), 
Table = Table.TransformColumnTypes(Rows, Table.ToList(ColumnsWithType, (c) => { c{0}, c{3}}))
in
Table,
  #"Removed other columns" = Table.SelectColumns(AnalyticsQuery, {"id", "customDimensions"}),
  #"Parsed JSON" = Table.TransformColumns(#"Removed other columns", {{"customDimensions", each Json.Document(_), type any}}),
  #"Expanded customDimensions" = Table.ExpandRecordColumn(#"Parsed JSON", "customDimensions", {"Data", "organizationId", "resourceId", "environmentId", "signalCategory", "resourceProvider"}, {"Data", "organizationId", "resourceId", "environmentId", "signalCategory", "resourceProvider"}),
  #"Changed column type 1" = Table.TransformColumnTypes(#"Expanded customDimensions", {{"Data", type text}, {"organizationId", type text}, {"resourceId", type text}, {"environmentId", type text}, {"signalCategory", type text}, {"resourceProvider", type text}}),
  #"Parsed JSON 1" = Table.TransformColumns(#"Changed column type 1", {{"Data", each Json.Document(_), type any}}),
  #"Expanded Data" = Table.ExpandRecordColumn(#"Parsed JSON 1", "Data", {"TaskName", "FlowDisplayName", "RunId", "OriginRunId", "code", "tags", "flowSequenceId", "error"}, {"TaskName", "FlowDisplayName", "RunId", "OriginRunId", "code", "tags", "flowSequenceId", "error"}),
  #"Expanded tags" = Table.ExpandRecordColumn(#"Expanded Data", "tags", {"flowDisplayName", "licenseContextConfigName", "environmentName", "logicAppName", "environmentWorkflowId", "xrmWorkflowId", "environmentFlowSuspensionReason", "sharingType", "state", "createdTime", "lastModifiedTime", "createdBy", "triggerType", "createdByUserId"}, {"flowDisplayName.1", "licenseContextConfigName", "environmentName", "logicAppName", "environmentWorkflowId", "xrmWorkflowId", "environmentFlowSuspensionReason", "sharingType", "state", "createdTime", "lastModifiedTime", "createdBy", "triggerType", "createdByUserId"}),
  #"Changed column type" = Table.TransformColumnTypes(#"Expanded tags", {{"FlowDisplayName", type text}, {"TaskName", type text}, {"RunId", type text}, {"OriginRunId", type text}, {"environmentName", type text}, {"logicAppName", type text}, {"environmentWorkflowId", type text}, {"state", type text}, {"createdTime", type datetime}})
in #"Changed column type";
shared requests_custom_dim_DataDestination = let
  Pattern = Lakehouse.Contents([CreateNavigationProperties = false, EnableFolding = false, HierarchicalNavigation = true, EnableVorder = true, OutputMetadataRefresh = true]),
  Navigation_1 = Pattern{[workspaceId = "."]}[Data],
  Navigation_2 = Navigation_1{[lakehouseName = "app_telemtry_lh_bronze"]}[Data],
  Navigation_3 = Navigation_2{[Id = "dbo", ItemKind = "Schema"]}[Data],
  TableNavigation = Navigation_3{[Id = "requests_custom_dim", ItemKind = "Table"]}?[Data]?
in
  TableNavigation;
