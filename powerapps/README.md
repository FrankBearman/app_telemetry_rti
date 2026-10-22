# Power Apps

Dataverse solution source (`apptelemppsol`) synced from Power Platform Git integration. Deployed to client tenants by [`scripts/Deploy-PowerPlatform.ps1`](../scripts/Deploy-PowerPlatform.ps1) (see [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md)).

## Contents

| Folder | What it holds |
|--------|---------------|
| `canvasapps/crf6e_apptelemcanvappweather_c88cd` | Canvas app with a button that calls the weather flow and emits `Trace()` telemetry |
| `entities/crf6e_apptelemweather` | Dataverse weather table |
| `appmodules/`, `appmodulesitemaps/` | Model-driven app `crf6e_apptelemppmodapp` |
| `connectionreferences/` | Dataverse connection reference (bound per customer at deploy time) |
| `solutions/`, `publishers/` | Solution and publisher metadata |

The weather flow (`ap-telem-pp-flow-weather`) is Power Apps-triggered, fetches today's forecast for London and writes a row to the weather table. Its definition is not currently in this folder; confirm it is included in the solution and synced to Git before relying on a deployment, and note that its connections (e.g. MSN Weather) need customer connection IDs.

## Application Insights tracing

The Canvas app's Application Insights connection string is set on the app object in Power Apps Studio (save and publish afterwards). `Trace()` events are only sent when the published app runs, not in Studio preview. Never commit a real connection string or key.

The button's `OnSelect` in `Src/Screen1.pa.yaml` emits three events, all carrying the same `clientRunId` (a GUID per invocation) and `flowName`:

| Event | When |
|-------|------|
| `weather-flow.started` | Before the flow is called |
| `weather-flow.succeeded` | Flow call returned without error |
| `weather-flow.failed` | `IfError` caught a failure (severity Error) |

`clientRunId` correlates the start and end events when querying Application Insights; the flow takes no inputs so the id is not passed into it. Keep personal or sensitive data out of trace custom properties.

Edit the Canvas app in Power Apps Studio rather than the YAML where possible (the YAML is generated and only suited to review and minor edits).
