# Repository Guidelines

## Build and test

There is no repository-level build, lint, or automated test suite. From the repository root, use Python's syntax compiler to check edits to the exported notebook source:

```powershell
python -m py_compile "fabric/app_telemetry_ingest.Notebook/notebook-content.py"
```

This checks syntax only; the notebook depends on Fabric-provided `spark` and `notebookutils` and cannot be run as a normal local Python script. For an end-to-end check, run `fabric/app_telemetry_ingest.Notebook` in the Fabric workspace and inspect the notebook run output. There are no individual tests to select.

For the demo API, check with `dotnet build dotnetapp/DemoApi`. It is standalone (no Power Platform dependency) and is not part of the deployment tooling. For deployment scripts, check PowerShell syntax by parsing (`[System.Management.Automation.Language.Parser]::ParseFile`) and Bicep with `bicep build azure/infra/main.bicep`; neither deployment path has been run end to end.

## Architecture

- Deployment tooling lives alongside the components: `scripts/` (`Deploy-Azure.ps1`, `Deploy-Fabric.ps1` + `deploy_fabric.py`, `Deploy-PowerPlatform.ps1`, `Deploy-All.ps1`), `customers/` (`_template.json`; real per-customer JSON is gitignored), `azure/infra/` (Bicep, create-or-reference App Insights, Log Analytics, Key Vault) and `azure-pipelines.yml` (ADO). `deploy_fabric.py` rewrites the hardcoded dev IDs in `fabric/` on a staged copy at deploy time, so do not make source items depend on customer values. See [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md).
- The repository is divided into `fabric/`, `azure/`, and `powerapps/` components. Microsoft Fabric items are grouped under `fabric/`; their `.platform` metadata identifies item types and logical IDs. Treat those IDs, workspace/lakehouse bindings, and cross-item references as deployment configuration; keep references aligned when changing or adding items. Configure Fabric Git integration to sync the `fabric/` folder.
- The ingestion pipeline in `fabric/app_telemetry_ingest_pipeline.DataPipeline` runs `fabric/app_telemetry_ingest.Notebook`. The notebook queries the Application Insights `requests` API in bounded UTC windows, reads its API key from Azure Key Vault at runtime, and incrementally merges rows by telemetry `id` into the existing `Requests` Delta table in `app_telemtry_lh_bronze`. It uses an event-time watermark with an overlap for late arrivals and applies logical retention.
- The notebook also flattens selected fields from `customDimensions` into `RequestsCustomDimensions`, joined to `Requests` by `id`. `fabric/dataflow_requests_customdim.Dataflow/mashup.pq` defines the corresponding selected fields; update the extraction and destination schema together when that selection changes.
- `fabric/app_telemetry_model.SemanticModel` uses the Lakehouse through Direct Lake. `fabric/app_telemetry_requests.KQLQueryset` and the Eventhouse/KQL database artifacts provide a separate live-query path; they are not the notebook's incremental Lakehouse load.
- `.vscode/mcp.json` configures the hosted FabricIQ MCP server for Fabric/semantic-model analysis. Authenticate with an Azure CLI Fabric access token when VS Code prompts; tokens expire, so generate a fresh one when required. Never put the token in this file.
- See [APP_INSIGHTS_FABRIC_SETUP.md](../azure/APP_INSIGHTS_FABRIC_SETUP.md) for Key Vault permissions, Fabric sync and scheduling, load-window/retention behavior, and query examples.

## Repository-specific conventions

- `fabric/app_telemetry_ingest.Notebook/notebook-content.py` is exported Fabric notebook source, not a standalone application module. Preserve its Fabric cell/metadata markers and keep changes compatible with the Synapse PySpark runtime.
- Keep the explicit `request_schema`, generated KQL projection, API response column order, and Lakehouse table columns in sync. For custom dimensions, keep the notebook's parsed fields and Delta table schema aligned with the dataflow's selected fields.
- Ingestion is designed to be idempotent: telemetry rows are deduplicated and merged by `id`; custom-dimension rows are also merged by `id`. Preserve the UTC watermark, bounded API query windows, and overlap behavior when changing incremental loading.
- API/query failures should remain visible in the Fabric run rather than silently dropping a time window. The notebook retries transient HTTP failures only.
- Never put the Application Insights API key in notebook source or pipeline parameters. Retrieve it from Key Vault at runtime; setup and identity requirements are documented in the setup guide.
