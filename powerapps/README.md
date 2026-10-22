# Power Apps

`solutionpackage/` holds the exported `apptelemppsol` Dataverse solution zip (unmanaged) and is the source of truth. [`scripts/Deploy-PowerPlatform.ps1`](../scripts/Deploy-PowerPlatform.ps1) deploys it (see [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md)).

## How deployment works

1. The script picks the newest `apptelemppsol*.zip` in `solutionpackage/`.
2. It copies it to `out/<customer>/` and patches the Application Insights key in the canvas app's `Properties.json`.
3. It runs `pac solution import`. Use `-PackOnly` to prepare the patched zip without importing.

## Updating the solution

Export the solution from Power Platform (unmanaged for dev/test, managed for production), put the zip in `solutionpackage/` and remove the older zip. Managed vs unmanaged is fixed at export time and cannot be switched in place; delete the solution in the environment first.

## Connection references

Set real connection IDs in `customers/<customer>.json` for:

- Dataverse: `crf6e_sharedcommondataserviceforapps_d81c3`
- MSN Weather: `new_sharedmsnweather_956a6`

`REPLACE_*` placeholders are skipped with a warning.

## Telemetry

The canvas app's `Trace()` events land in the Application Insights `traces` table; the Fabric ingest currently reads `requests`. Never commit a real key or connection string.
