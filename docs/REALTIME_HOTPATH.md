# Real-time hot path (Eventhouse, zero-ETL)

This guide adds a streaming path next to the existing batch path (notebook + pipeline).
Application Insights telemetry flows into a Fabric Eventhouse within seconds. There you can query it with KQL, raise Data Activator alerts, and mirror it to OneLake as Delta Parquet for Direct Lake reporting.

This path uses **no Spark notebooks, Data Factory pipelines, or ADLS Gen2 shortcuts**. Every hop is managed streaming or a Fabric-native policy.

```mermaid
flowchart LR
  AI[App Insights<br/>workspace-based] --> LA[Log Analytics<br/>AppRequests/AppTraces/AppExceptions]
  LA -- Data Export rule<br/>apptelem-realtime-export --> EH[Event Hub<br/>appinsights-export]
  EH -- consumer group<br/>fabric-eventstream --> ES[Fabric Eventstream]
  ES -- direct ingestion<br/>RawAppTelemetryMapping --> RAW[(RawAppTelemetry)]
  RAW -- update policies --> T[(AppRequestsRT<br/>AppTracesRT<br/>AppExceptionsRT)]
  T --> KQL[KQL queryset<br/>sub-second queries]
  T --> DA[Data Activator alerts]
  T -- OneLake availability<br/>mirroring policy --> OL[(OneLake Delta Parquet)]
  OL -- OneLake shortcut --> DL[Direct Lake semantic model / Power BI]
```

## Files

| File | Purpose |
|---|---|
| [`azure/infra/modules/eventhub.bicep`](../azure/infra/modules/eventhub.bicep) | Event Hub namespace, hub `appinsights-export`, consumer group, Listen-only SAS rule `fabric-listen` |
| [`azure/infra/modules/dataexport.bicep`](../azure/infra/modules/dataexport.bicep) | Log Analytics data export rule `apptelem-realtime-export` → Event Hub |
| [`azure/infra/main.bicep`](../azure/infra/main.bicep) | Deploys both modules when `enableRealtime = true` |
| [`customers/_template.json`](../customers/_template.json) | `azure.realtime` config block |
| [`fabric/realtime/hotpath_setup.kql`](../fabric/realtime/hotpath_setup.kql) | Idempotent KQL: raw table, JSON mapping, typed tables, update policies, retention/caching, `WeatherFlowRuns()`, mirroring |

## Prerequisites

- **Workspace-based** Application Insights. Classic resources can't export.
- An Event Hub in the **same region** as the Log Analytics workspace, on the **Standard** SKU or higher. Basic is not supported.
- At most 10 export rules per workspace. Basic and Auxiliary log tables cannot be exported.
- A Fabric capacity with the Eventhouse `app_telemetry_eventhouse` deployed (it is part of the normal Fabric deploy).
- Rights to create Eventstream and Activator items in the Fabric workspace.
- For private Event Hub consumption, complete Step 1a before creating the Eventstream connection. The supported source is **Azure Event Hubs (Extended features mode)**; do not use the basic connector for the streaming VNet gateway.

## Step 1: Deploy the Azure resources

In `customers/<name>.json`, enable the realtime block:

```json
"realtime": {
  "enabled": true,
  "eventHubSku": "Standard",
  "eventHubCapacity": 1,
  "exportTables": ["AppRequests", "AppTraces", "AppExceptions"],
  "consumerGroup": "fabric-eventstream",
  "existingLogAnalyticsWorkspaceId": ""
}
```

If `useExistingAppInsights` is true, set `existingLogAnalyticsWorkspaceId` to the full resource ID of the workspace behind the App Insights resource. The config loader rejects the file if this is blank.

```powershell
./scripts/Deploy-Azure.ps1 -Customer <name>
```

The script returns `eventHubNamespaceName`, `eventHubName`, `eventHubConsumerGroup`, and `eventHubListenRuleName`. It does **not** output any secrets.

Verify that the export is running:

```powershell
az monitor log-analytics workspace data-export show `
  --resource-group <rg> --workspace-name <law> --name apptelem-realtime-export
```

Generate some traffic, for example with the demo API or a Power App run. Then confirm that **Incoming Messages** rises on the Event Hub's **Metrics** blade. Export latency is usually under a minute.

> The export sends batches as `{"records":[{...},{...}]}`. Each record uses the
> Log Analytics schema (`TimeGenerated`, `Type`, `Properties`, `OperationId`, ...),
> not the classic App Insights API schema (`timestamp`, `customDimensions`).

## Step 1a: Private Event Hub connectivity and streaming VNet gateway

The gateway is required for the private-network consumer path, not for the original
public-endpoint connector. The Azure deployment provisions its network prerequisites;
the gateway itself and the credential-bearing Fabric connection are created in Fabric.

1. Ensure `fabric.workspaceId` identifies an existing, capacity-assigned workspace.
   Deployment reads its workspace identity or provisions one if missing, using
   `Ensure-FabricWorkspaceIdentity.ps1`. The deploying identity must be Workspace
   Admin to provision it. The helper waits for completion and records the
   application and service-principal IDs in `out/<customer>/fabric-identity.json`.
   It does not create the workspace. Azure deployment also calls the helper
   before assigning VNet permissions, so no manual principal-ID copying is needed.
2. Configure `azure.realtime.privateNetworking`:

   ```json
   "privateNetworking": {
     "enabled": true,
     "location": "centralus",
     "addressPrefix": "10.50.0.0/24",
     "connectorSubnetPrefix": "10.50.0.0/27",
     "privateEndpointSubnetPrefix": "10.50.0.32/27"
   }
   ```

   `privateNetworking.location` must match the Fabric Eventstream/capacity region.
   Contoso keeps its existing Azure telemetry resources in **UK South**
   (`location: uksouth`) within `rg-apptelem-contoso`. Only the gateway VNet and
   private endpoint use **Central US**, matching the Fabric capacity. The private
   endpoint targets the existing UK South Event Hub across regions; account for
   cross-region latency and transfer charges. Existing resource names and telemetry
   endpoints are retained. The deployment script reuses the existing group without
   changing its metadata location. Do not change the top-level region to move
   existing resources: same-name resources cannot be recreated in another region.
   Choose nonoverlapping ranges for your organization's network. The config loader
   also checks subnet containment, disjointness, a /27-or-larger connector subnet,
   and avoidance of Fabric's reserved `10.240.0.0/16` and `10.224.0.0/12`.
3. Run the Azure deployment again. The deploying identity needs resource creation,
   role-assignment permission, and subscription provider-registration permission
   if `Microsoft.MessagingConnectors` is not already registered. The script checks
   and registers that provider before deployment; `-WhatIf` and `-OutputsOnly`
   do not register it. `-WhatIf` reads but does not provision the Fabric identity;
   provision a missing identity with the helper first. `-OutputsOnly` skips
   identity provisioning entirely.

   This provisions:
   - A VNet with an otherwise empty `streaming-connectors` subnet delegated to
     `Microsoft.MessagingConnectors`.
   - A separate `private-endpoints` subnet and Event Hub namespace private endpoint.
   - The `privatelink.servicebus.windows.net` private DNS zone, VNet link and
     endpoint DNS zone group. Continue using the namespace's normal
     `<namespace>.servicebus.windows.net` hostname.
   - **Network Contributor**, scoped to this VNet, for the Fabric workspace identity.
   - Event Hub network rules with **default deny** and the **trusted Microsoft
     services exception enabled**. General public client traffic is denied, but
     Azure Monitor data export can still deliver events.
     Azure requires at least one allowed IP or VNet rule in selected-networks mode.
     The connector subnet has a `Microsoft.EventHub` service endpoint and is the
     only allowed subnet; there are no allowed public IP rules. Its firewall rule
     is applied after subnet creation, before deploying the data export rule.
     Private DNS still routes the configured Fabric connection through Private
     Link. The subnet allow rule additionally permits authenticated service-endpoint
     access from that subnet; this is not a private-link-only namespace.

   **This is not an all-private producer path:** Log Analytics data export needs
   the trusted-service exception on the public endpoint. Do not set public network
   access to `Disabled` for this design. The Fabric consumer uses Private Link.
   If you later set `privateNetworking.enabled = false`, deployment restores the
   Event Hub's public allow rules; incremental deployment does not delete the
   previously created network resources or role assignment.
4. In Fabric **Manage connections and gateways -> Streaming virtual network data
   gateways -> New**, choose the subscription, resource group, VNet and
   `streaming-connectors` subnet. Use the `streamingVirtualNetwork*` and
   `streamingConnectorSubnet*` values in `out/<customer>/azure-outputs.json`.
   Save the gateway, for example as `apptelem-contoso-streaming`.
5. Grant the person creating the connection **Connection Creator** or **Admin**
   on the gateway. This Fabric permission is separate from the workspace
   identity's Azure Network Contributor role.
6. In the Eventstream source wizard choose **Azure Event Hubs (Extended features
   mode)**. Create a connection with the gateway marked **[Streaming VNET]** and
   choose the resulting **[vNet]** connection. Use the Event Hub settings and
   Listen-only credentials from Step 3 below. Gateway connection testing is not
   supported by this flow; **Skip test connection** is expected. Publish the
   Eventstream and verify actual ingestion, rather than treating a saved
   connection as proof that it works.

Deployment does **not** create a Fabric gateway, a Fabric connection, or an
Eventstream definition that is absent from Git. After creating and publishing
the Eventstream, sync it to Git and configure its promotion as described below.

References: [Streaming VNet gateway creation](https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/create-manage-streaming-virtual-network-data-gateways),
[streaming connector private networking prerequisites](https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/streaming-connector-private-network-support-guide),
and [Log Analytics export destination networking](https://learn.microsoft.com/azure/azure-monitor/logs/logs-data-export#event-hubs).

## Step 2: Create the KQL objects

Open a KQL queryset on the Eventhouse database. Paste [`hotpath_setup.kql`](../fabric/realtime/hotpath_setup.kql) and run it. It is idempotent and creates the following objects:

- `RawAppTelemetry(records: dynamic)` plus the JSON mapping `RawAppTelemetryMapping` (`$.records`). Raw data is retained for 1 day.
- Typed tables `AppRequestsRT`, `AppTracesRT`, and `AppExceptionsRT`. Update policies (`mv-expand records`, filtered by `Type`) fill them on ingestion. They have a 30-day hot cache.
- `WeatherFlowRuns(lookback=24h)`, the streaming equivalent of the weather-flow Dataflow KQL.
- A mirroring policy (OneLake availability) on the three typed tables. See Step 5.

If the queryset rejects `.execute database script`, run the commands inside the `<|` block one at a time, in order.

## Step 3: Create the Eventstream

In the Fabric workspace, select **New item → Eventstream**, for example `app_telemetry_es`.

1. **Source → Azure Event Hubs** (use **Extended features mode** and the streaming VNet gateway from Step 1a for private connectivity). Create a new connection with these settings:
   - Namespace: `eventHubNamespaceName` from Step 1. Event Hub: `appinsights-export`.
   - Authentication: Shared Access Key, using the rule `fabric-listen`. Copy the key from **Azure portal → Event Hub → Shared access policies**.
   - Consumer group: `fabric-eventstream`. Data format: **JSON**.
2. **Destination → Eventhouse**:
   - Ingestion mode: **Direct ingestion**. Workspace and database: `app_telemetry_eventhouse`.
   - Table: existing `RawAppTelemetry`. Data format: JSON. Mapping: existing `RawAppTelemetryMapping`.
3. **Publish**.

### Deploying the Eventstream from ADO

Build the Eventstream once in the **dev** workspace, then let `Deploy-Fabric.ps1` promote it:

1. Create the Eventstream in dev as described above, then commit it to Git through Fabric Git integration. This produces `fabric/<name>.Eventstream/` with `eventstream.json`.
2. In `scripts/deploy_fabric.py`, set these constants from that `eventstream.json`:
   - `SOURCE_EVENTHUB_CONNECTION_ID`
   - `SOURCE_EVENTHOUSE_ID`
   - `SOURCE_KQL_DATABASE_ID`
   
   At deploy time these values are replaced: the connection ID with the customer value, and the Eventhouse and KQL database IDs with `$items.Eventhouse/KQLDatabase.<name>.$id`.
3. In the **target** tenant, create a Fabric cloud connection of type Azure Event Hubs (Shared Access Key, rule `fabric-listen`). Put its ID in `fabric.realtime.eventHubConnectionId` in the customer JSON. Connections hold credentials, so they cannot be created from Git.
4. Keep `"Eventstream"` in `fabric.itemTypes`. `Get-CustomerConfig.ps1` refuses to deploy an Eventstream without a valid connection ID.

Activator rules are still created manually (Step 4).

Use direct ingestion with the KQL mapping, not Eventstream's "event processing before ingestion". This keeps all the nested-JSON shaping in update policies inside the database, so there is one source of truth and nothing to re-map in the UI.

Verify:

```kusto
RawAppTelemetry | count
AppRequestsRT | where TimeGenerated > ago(10m) | take 10
```

## Step 4: Query and alert

Example sub-second queries:

```kusto
AppRequestsRT
| where TimeGenerated > ago(15m)
| summarize requests = count(), failures = countif(Success == false),
            p95ms = percentile(DurationMs, 95) by bin(TimeGenerated, 1m), Name

WeatherFlowRuns(1h)
| where isnull(endTime) or durationMs > 60000
```

**Data Activator** (Activator item): use the queryset or Eventstream as the source.

- *Failed requests*: in the queryset, run `AppRequestsRT | where TimeGenerated > ago(5m) | summarize failures = countif(Success == false)`. Choose **Set alert** and set the condition to `failures > 0`. Use Email or Teams as the action.
- *Long or never-ended weather-flow runs*: run `WeatherFlowRuns(1h) | where isnull(endTime) and startTime < ago(10m) or durationMs > 60000`. Alert when the row count is greater than 0, with an object per `clientRunId`.

Set the alert check frequency (for example 1–5 min). Each check is a KQL query against the Eventhouse.

## Step 5: Enable OneLake availability

You can enable it either way:

- **UI**: open the KQL database and turn on **OneLake availability**. This applies to new tables. To cover existing tables, toggle it per table.
- **KQL**: the setup script already runs this command:

  ```kusto
  .alter-merge table AppRequestsRT policy mirroring dataformat=parquet
      with (IsEnabled=true, TargetLatencyInMinutes=5)
  ```

Monitor:

```kusto
.show table AppRequestsRT policy mirroring
.show table AppRequestsRT operations mirroring-status
```

Caveats:

- **No backfill**: only data ingested *after* you enable mirroring is written to OneLake. Enable it before you rely on the reports.
- **Latency vs. file size**: without `TargetLatencyInMinutes`, files can take up to about 3 hours (or about 200–256 MB) to appear. A low target latency produces more, smaller files.
- **Schema changes are restricted** while mirroring is on. Disable mirroring, alter the table, and re-enable it.
- The raw table is not mirrored on purpose. It holds only 1 day of data and is not report-friendly.

## Step 6: Direct Lake reporting

1. Create OneLake shortcuts in the Lakehouse `app_telemtry_lh_bronze` that point to the three `*RT` tables. These are internal OneLake shortcuts, **not** ADLS Gen2 shortcuts. They are zero-copy, and they read the mirrored Delta files, so OneLake availability (Step 5) is required. You can create them either way:
   - **Automated (ADO)**: set `fabric.realtime.lakehouseShortcuts.enabled = true`, and include `AppRequestsRT` in `tables`. `deploy_fabric.py` writes `shortcuts.metadata.json` into the *staged* Lakehouse copy under `Tables/dbo`, matching the schema-enabled Lakehouse and model. The target KQL database is resolved through `$items.KQLDatabase.app_telemetry_eventhouse.$id`. Shortcut publication failures stop deployment; they are not ignored. The source `shortcuts.metadata.json` stays `[]`.
   - **Manual**: in the Lakehouse, select **Tables → New shortcut → Microsoft OneLake**, then pick the KQL database and the tables.

   The target tables and their mirrored Delta files must already exist, so the first deployment takes two passes:
   1. Run ADO with **fabricBootstrap = true**, or run `Deploy-Fabric.ps1 -Customer <name> -Bootstrap` (for `Deploy-All.ps1`, use `-FabricBootstrap`). This explicitly omits shortcuts, semantic models, and reports, regardless of the shortcut setting. It publishes infrastructure only; it does not run notebooks or pipelines.
   2. Run `hotpath_setup.kql`, configure/publish the Eventstream, and generate telemetry. Wait for mirroring and verify that `AppRequestsRT` appears in the KQL database's OneLake view with Delta files. An empty Lakehouse or a provisioned SQL endpoint alone is not sufficient.
   3. Set `fabric.realtime.lakehouseShortcuts.enabled = true` with `AppRequestsRT` in `tables`, then rerun ADO with **fabricBootstrap = false** (or omit `-Bootstrap`). The script finishes the infrastructure/shortcut pass before publishing semantic models and reports. The deploying identity needs access to the KQL database's OneLake data as well as the Lakehouse.

   Shortcuts show data only after the first mirrored files are written, which can take up to `TargetLatencyInMinutes`.
2. The checked-in `app_telemetry_model` now reads `dbo.AppRequestsRT` through the Lakehouse shortcut, **not** the notebook's `Requests` table. Its model table is still named `Requests`, and supported report-facing column names and lineage tags are retained:

   | Model column | Hot-path source column |
   |---|---|
   | `timestamp`, `id`, `name`, `url` | `TimeGenerated`, `Id`, `Name`, `Url` |
   | `success`, `resultCode`, `duration` | `Success` (boolean), `ResultCode`, `DurationMs` (milliseconds) |
   | `customDimensions` | `Properties` (mirrored dynamic value as a string) |
   | `operation_Name`, `operation_Id` | `OperationName`, `OperationId` |
   | `cloud_RoleName`, `client_CountryOrRegion` | `AppRoleName`, `ClientCountryOrRegion` |
   | `itemCount`, `_ResourceId` | `ItemCount`, `_ResourceId` |

   Legacy-only columns such as `source`, `performanceBucket`, `customMeasurements`, session/user IDs, and other client fields are removed rather than fabricated. Existing reports using those columns, or expecting string-valued `success`, need updating. Add traces/exception model tables separately when required; the current model reports requests only.

Direct Lake reads the mirrored Delta files directly, so no import refresh or ETL step is needed.

## Cost and operations notes

- **Event Hub**: Standard SKU, 1 throughput unit (TU) = 1 MB/s or 1,000 events/s ingress. Raise `eventHubCapacity` or enable auto-inflate for bursts.
- **Log Analytics data export** is billed per GB exported.
- **Eventhouse**: the capacity cost is driven by always-on compute. Keep the raw-table retention short, which is already set to 1 day.
- To add more tables (for example `AppDependencies`), add them to `exportTables`. Then add a typed table, expand function, and update policy in `hotpath_setup.kql`, and enable mirroring on the new table.
- The batch ingestion artifacts (notebook + pipeline -> Lakehouse `Requests`) are unchanged and optional. The checked-in semantic model no longer depends on them; do not run them to bootstrap this hot path.

## Not yet verified

These configs have not been run end to end. In particular, check the following:

- That the queryset accepts `.execute database script`.
- That the export-record column names (for example `DurationMs`, `Success`, `Properties`) match your workspace. Inspect them with `RawAppTelemetry | take 1`.
- That Eventstream's direct-ingestion mode accepts the existing mapping.
- The end-to-end Eventstream deployment, shortcut resolution and model import in the target tenant. Bootstrap creates the KQL database before the reporting deployment.
- That `dbo.AppRequestsRT` resolves through the generated OneLake shortcut and exposes the mirrored Delta schema to Direct Lake. Inspect the Lakehouse shortcut and model after the first reporting deployment.
