[StagingDefinition = [Kind = "FastCopy"]]
section Section1;
[DataDestinations = {[Definition = [Kind = "Reference", QueryName = "weather_flow_runs_DataDestination", IsNewTarget = true], Settings = [Kind = "Manual", AllowCreation = true, ColumnSettings = [Mappings = {[SourceColumnName = "clientRunId", DestinationColumnName = "clientRunId"], [SourceColumnName = "durationMs", DestinationColumnName = "durationMs"], [SourceColumnName = "severityLevel", DestinationColumnName = "severityLevel"], [SourceColumnName = "startTime", DestinationColumnName = "startTime"], [SourceColumnName = "endTime", DestinationColumnName = "endTime"], [SourceColumnName = "appid", DestinationColumnName = "appid"], [SourceColumnName = "appName", DestinationColumnName = "appName"]}], DynamicSchema = false, UpdateMethod = [Kind = "Replace"], TypeSettings = [Kind = "Table"]]]}]
shared weather_flow_runs = /* Flow run durations from Application Insights traces. */
let
    QueryText =
"let startedView =
traces
| extend clientRunId = tostring(customDimensions[""clientRunId""]), appName = tostring(customDimensions[""ms-appName""]), appid = tostring(customDimensions[""ms-appId""])
| where timestamp > ago(24h)
| where message has ""started""
| where message has ""weather-flow""
| project timestamp, message, severityLevel, clientRunId, startTime = timestamp, appName, appid;
let endedView =
traces
| extend clientRunId = tostring(customDimensions[""clientRunId""]), appName = tostring(customDimensions[""ms-appName""]), appid = tostring(customDimensions[""ms-appId""])
| where timestamp > ago(24h)
| where message has ""ended""
| where message has ""weather-flow""
| project timestamp, message, severityLevel, clientRunId, endTime = timestamp, appName, appid;
startedView
| join kind=leftouter endedView on clientRunId
| extend durationMs = datetime_diff(""millisecond"", endTime, startTime)
| project clientRunId, durationMs, severityLevel, startTime, endTime, appid, appName",
    Source = Json.Document(
        Web.Contents(
            "https://api.applicationinsights.io/v1/apps/" & application_id & "/query",
            [
                Query = [
                    #"query" = QueryText,
                    #"x-ms-app" = "AAPBI",
                    timespan = "P1D",
                    prefer = "ai.response-thinning=true"
                ],
                Timeout = #duration(0, 0, 4, 0)
            ]
        )
    ),
    DataTable = Source[tables]{0},
    ColumnNames = List.Transform(DataTable[columns], each _[name]),
    Rows = Table.FromRows(DataTable[rows], ColumnNames),
    Typed = Table.TransformColumnTypes(
        Rows,
        {
            {"clientRunId", type text},
            {"durationMs", Int64.Type},
            {"severityLevel", Int32.Type},
            {"startTime", type datetime},
            {"endTime", type datetime},
            {"appid", type text},
            {"appName", type text}
        }
    )
in
    Typed;
shared application_id = "00a8e086-bbec-4f92-a08f-14a05eb151f2" meta [IsParameterQuery = true, IsParameterQueryRequired = false, Type = type text]
;
shared weather_flow_runs_DataDestination = let
  Pattern = Lakehouse.Contents([CreateNavigationProperties = false, EnableFolding = false, HierarchicalNavigation = true, EnableVorder = true, OutputMetadataRefresh = true]),
  Navigation_1 = Pattern{[workspaceId = "e40c817a-488d-4c50-b65e-4020fa697795"]}[Data],
  Navigation_2 = Navigation_1{[lakehouseId = "e8d8f813-dff6-4223-8857-e2ccdf0c2381"]}[Data],
  Navigation_3 = Navigation_2{[Id = "dbo", ItemKind = "Schema"]}[Data],
  TableNavigation = Navigation_3{[Id = "weather_flow_runs", ItemKind = "Table"]}?[Data]?
in
  TableNavigation;
