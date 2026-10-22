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
