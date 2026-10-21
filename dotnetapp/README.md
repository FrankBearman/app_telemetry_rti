# dotnetapp

A minimal ASP.NET Core API that demonstrates .NET telemetry flowing into the Application Insights resource used by this solution. It has no dependency on the Power Platform solution.

Inbound calls are auto-tracked as `requests`, so they are picked up by the existing Fabric ingest without pipeline changes.

## Endpoints

| Path | Behaviour |
|---|---|
| `/` | App info and whether telemetry is enabled |
| `/weather` | Random temperature (200) |
| `/slow` | Random 0.5-2.5 s delay (200) |
| `/error` | Throws, giving a 500 and an `exceptions` row |

Send an `X-Demo-Run-Id` header to have it recorded as `customDimensions.clientRunId` on the request.

## Run locally

Prerequisite: [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```powershell
cd dotnetapp\DemoApi

# Optional: send telemetry to App Insights (do not commit this value)
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = '<connection string>'

dotnet run
```

In a second terminal:

```powershell
.\dotnetapp\scripts\generate-traffic.ps1 -Count 20
```

If script execution is blocked by your PowerShell execution policy, run the script with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\dotnetapp\scripts\generate-traffic.ps1 -Count 20
```

Without the connection string the app still runs but sends nothing.

## Check it in App Insights

Telemetry takes 1-3 minutes to appear (Live Metrics is faster).

```kusto
requests
| where cloud_RoleName == "demo-dotnet-api"
| project timestamp, name, resultCode, duration, success, runId = tostring(customDimensions.clientRunId)
| order by timestamp desc
```

`cloud_RoleName` comes from `OTEL_SERVICE_NAME` (set in `launchSettings.json`).
