[StagingDefinition = [Kind = "FastCopy"]]
section Section1;
[DataDestinations = {[Definition = [Kind = "Reference", QueryName = "Requests_DataDestination", IsNewTarget = true], Settings = [Kind = "Manual", AllowCreation = true, ColumnSettings = [Mappings = {[SourceColumnName = "timestamp", DestinationColumnName = "timestamp"], [SourceColumnName = "id", DestinationColumnName = "id"], [SourceColumnName = "source", DestinationColumnName = "source"], [SourceColumnName = "name", DestinationColumnName = "name"], [SourceColumnName = "url", DestinationColumnName = "url"], [SourceColumnName = "success", DestinationColumnName = "success"], [SourceColumnName = "resultCode", DestinationColumnName = "resultCode"], [SourceColumnName = "duration", DestinationColumnName = "duration"], [SourceColumnName = "performanceBucket", DestinationColumnName = "performanceBucket"], [SourceColumnName = "itemType", DestinationColumnName = "itemType"], [SourceColumnName = "customDimensions", DestinationColumnName = "customDimensions"], [SourceColumnName = "customMeasurements", DestinationColumnName = "customMeasurements"], [SourceColumnName = "operation_Name", DestinationColumnName = "operation_Name"], [SourceColumnName = "operation_Id", DestinationColumnName = "operation_Id"], [SourceColumnName = "operation_ParentId", DestinationColumnName = "operation_ParentId"], [SourceColumnName = "operation_SyntheticSource", DestinationColumnName = "operation_SyntheticSource"], [SourceColumnName = "session_Id", DestinationColumnName = "session_Id"], [SourceColumnName = "user_Id", DestinationColumnName = "user_Id"], [SourceColumnName = "user_AuthenticatedId", DestinationColumnName = "user_AuthenticatedId"], [SourceColumnName = "user_AccountId", DestinationColumnName = "user_AccountId"], [SourceColumnName = "application_Version", DestinationColumnName = "application_Version"], [SourceColumnName = "client_Type", DestinationColumnName = "client_Type"], [SourceColumnName = "client_Model", DestinationColumnName = "client_Model"], [SourceColumnName = "client_OS", DestinationColumnName = "client_OS"], [SourceColumnName = "client_IP", DestinationColumnName = "client_IP"], [SourceColumnName = "client_City", DestinationColumnName = "client_City"], [SourceColumnName = "client_StateOrProvince", DestinationColumnName = "client_StateOrProvince"], [SourceColumnName = "client_CountryOrRegion", DestinationColumnName = "client_CountryOrRegion"], [SourceColumnName = "client_Browser", DestinationColumnName = "client_Browser"], [SourceColumnName = "cloud_RoleName", DestinationColumnName = "cloud_RoleName"], [SourceColumnName = "cloud_RoleInstance", DestinationColumnName = "cloud_RoleInstance"], [SourceColumnName = "links", DestinationColumnName = "links"], [SourceColumnName = "appId", DestinationColumnName = "appId"], [SourceColumnName = "appName", DestinationColumnName = "appName"], [SourceColumnName = "iKey", DestinationColumnName = "iKey"], [SourceColumnName = "sdkVersion", DestinationColumnName = "sdkVersion"], [SourceColumnName = "itemId", DestinationColumnName = "itemId"], [SourceColumnName = "itemCount", DestinationColumnName = "itemCount"], [SourceColumnName = "_ResourceId", DestinationColumnName = "_ResourceId"]}], DynamicSchema = false, UpdateMethod = [Kind = "Replace"], TypeSettings = [Kind = "Table"]]]}]
shared Requests = /* The exported Power Query Formula Language can be used with Power BI Desktop. */
let AnalyticsQuery =
let Source = Json.Document(Web.Contents("https://api.applicationinsights.io/v1/apps/" & application_id & "/query", 
[Query=[#"query"=
"requests
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
  #"Changed column type" = Table.TransformColumnTypes(AnalyticsQuery, {{"timestamp", type datetime}})
in #"Changed column type";
shared application_id = "cf6c9bff-c723-4116-900a-947ddf8d9dca" meta [IsParameterQuery = true, IsParameterQueryRequired = false, Type = type text] //cf6c9bff-c723-4116-900a-947ddf8d9dca//"00a8e086-bbec-4f92-a08f-14a05eb151f2"
;
shared Requests_DataDestination = let
  Pattern = Lakehouse.Contents([CreateNavigationProperties = false, EnableFolding = false, HierarchicalNavigation = true, EnableVorder = true, OutputMetadataRefresh = true]),
  Navigation_1 = Pattern{[workspaceId = "e40c817a-488d-4c50-b65e-4020fa697795"]}[Data],
  Navigation_2 = Navigation_1{[lakehouseId = "e8d8f813-dff6-4223-8857-e2ccdf0c2381"]}[Data],
  Navigation_3 = Navigation_2{[Id = "dbo", ItemKind = "Schema"]}[Data],
  TableNavigation = Navigation_3{[Id = "requests_dataflow", ItemKind = "Table"]}?[Data]?
in
  TableNavigation;
