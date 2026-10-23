# Fabric

This component contains the Microsoft Fabric items for the telemetry solution:
the ingestion notebook and pipeline, Lakehouse, dataflows, Eventhouse and KQL
artifacts, and Direct Lake semantic model.

The Fabric artifacts are grouped directly under this directory. Configure
Fabric workspace Git integration to sync this folder.

Notes:

- `scripts/deploy_fabric.py` rewrites the hardcoded dev workspace/lakehouse IDs on a staged copy at deploy time; keep customer values out of these source items.
- The Lakehouse is named `app_telemtry_lh_bronze` (sic). Do not rename it; references depend on it.
- The notebook reads `appinsights-query-api-key` from Key Vault at run time. See [azure/APP_INSIGHTS_FABRIC_SETUP.md](../azure/APP_INSIGHTS_FABRIC_SETUP.md) for permissions, scheduling and load behaviour.
- `dataflow_weather_flow` materializes 24-hour weather-flow start/end traces into the `weather_flow_runs` Lakehouse table. It and the notebook pipeline are alternate batch paths, not dependencies of hot-path reporting.
- `app_telemetry_model` reads the `dbo.AppRequestsRT` OneLake shortcut, backed by the Eventhouse's mirrored Delta files. Its model table remains named `Requests`; only fields present in the hot-path schema are exposed. Bootstrap new workspaces with `Deploy-Fabric.ps1 -Bootstrap`, initialize streaming and mirroring, then deploy normally.
- `realtime/hotpath_setup.kql` is not a Fabric item. It is a KQL script you run against the Eventhouse database to create the real-time (zero-ETL) hot-path tables, update policies and OneLake mirroring. See [docs/REALTIME_HOTPATH.md](../docs/REALTIME_HOTPATH.md).