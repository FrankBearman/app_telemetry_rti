# Application telemetry solution

For what the project does and how data flows, see [docs/OVERVIEW.md](docs/OVERVIEW.md).

The repository is organized into three components so each can evolve toward a
separate deployment:

- [`fabric/`](./fabric/): Microsoft Fabric items for telemetry ingestion,
  Lakehouse storage, querying, and semantic modeling.
- [`azure/`](./azure/): Azure-side resources and configuration, including
  Application Insights and its access setup.
- [`powerapps/`](./powerapps/): demo Power Apps intended to generate telemetry.
- [`dotnetapp/`](./dotnetapp/): standalone .NET demo API that sends telemetry to the same Application Insights resource.

The Azure side is Bicep in `azure/infra/`; the Power Apps solution export is committed in
`powerapps/solutionpackage/`.

When syncing the Fabric component with a Fabric workspace, configure the Git
folder mapping to use `fabric/`. See
[`azure/APP_INSIGHTS_FABRIC_SETUP.md`](./azure/APP_INSIGHTS_FABRIC_SETUP.md)
for the Application Insights ingestion setup.

## Deploying to a customer

Prerequisites: an Azure subscription, a Fabric workspace on a capacity, a Power Platform
environment, and an Azure DevOps project with a service connection (or a local PowerShell
session with `az`, `pac` and Python).

Start with the ordered checklist in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#order-of-operations),
and read its "Identities and secrets" section to understand which service principal does what.
Per-customer settings live in `customers/<code>.json` (copy `customers/_template.json`).
