# Application telemetry solution

The repository is organized into three components so each can evolve toward a
separate deployment:

- [`fabric/`](./fabric/): Microsoft Fabric items for telemetry ingestion,
  Lakehouse storage, querying, and semantic modeling.
- [`azure/`](./azure/): Azure-side resources and configuration, including
  Application Insights and its access setup.
- [`powerapps/`](./powerapps/): demo Power Apps intended to generate telemetry.

The existing Fabric artifacts and Application Insights setup guide have been
grouped into their corresponding component folders. The Azure resource
configuration and Power Apps demos are not populated yet.

When syncing the Fabric component with a Fabric workspace, configure the Git
folder mapping to use `fabric/`. See
[`azure/APP_INSIGHTS_FABRIC_SETUP.md`](./azure/APP_INSIGHTS_FABRIC_SETUP.md)
for the current Application Insights ingestion setup.

## Deployment

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for per-customer, manual and Azure DevOps deployment (scripts/, customers/, zure-pipelines.yml).

