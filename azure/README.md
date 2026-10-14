# Azure

Azure foundation for the solution. Each resource is created, or referenced if it already exists, based on the customer config.

| Path | Purpose |
|------|---------|
| [`infra/main.bicep`](./infra/main.bicep) | Creates or references Log Analytics, workspace-based Application Insights and an RBAC Key Vault; optional Key Vault role assignments |
| [`infra/modules/`](./infra/modules) | `appinsights.bicep`, `keyvault.bicep` |
| [`APP_INSIGHTS_FABRIC_SETUP.md`](./APP_INSIGHTS_FABRIC_SETUP.md) | Fabric ingestion setup guide (API key secret, notebook, schedule) |

Parameters come from `customers/<code>.json` (the `azure` section); there is no parameter file in this folder.

## Deploy

```powershell
./scripts/Deploy-Azure.ps1 -Customer <code> [-WhatIf]
```

Outputs (App Insights app ID, connection string, Key Vault URL) are written to `out/<code>/azure-outputs.json` and consumed by the Fabric and Power Platform scripts. See [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md) for the full flow, including Azure DevOps.

## After deployment

1. Grant the Fabric identity secret read via `secretReaderPrincipalIds`, then add the `appinsights-query-api-key` secret (see the setup guide). The key is a credential and is not provisioned by the template.
2. Configure Dataverse telemetry export to Application Insights in the Power Platform admin center.
