# Application Insights analytics in Fabric

The `app_telemetry_ingest.Notebook` item incrementally copies the Application Insights
`requests` table into the existing `app_telemtry_lh_bronze` Lakehouse table named
`Requests`. The existing Direct Lake semantic model can then analyze the copied rows.
The KQL queryset remains the option for querying Application Insights live.

## One-time setup

1. In Application Insights, create a read-only API key with permission to read telemetry.
   Do not use the instrumentation key from the connection string as an API key.
2. Save the API key in Azure Key Vault as `appinsights-query-api-key`.
3. Grant the identity that runs the Fabric notebook permission to get that Key Vault secret.
4. In `app_telemetry_ingest.Notebook/notebook-content.py`, replace
   `REPLACE_WITH_KEY_VAULT_NAME` with the Key Vault name. No key or other credential
   should be committed to Git.
5. Sync the branch into Fabric. Run the notebook once manually and confirm that it
   creates the `Requests` Lakehouse table and completes successfully.
6. Create a schedule on `app_telemetry_ingest_pipeline` for every 15 minutes. Ensure
   pipeline runs do not overlap.

## Load and retention behavior

- The first run loads the latest 24 hours. It does not backfill the previous year.
- Later runs query from the latest stored timestamp minus a two-hour overlap. This
  allows for telemetry ingestion delay; rows are merged by telemetry `id` to avoid
  duplicates.
- Data older than 365 days is deleted from the current Delta table at the end of each
  run. Physical removal of obsolete Delta files is governed by Delta `VACUUM` retention.
- Each query request covers at most six hours to keep API responses bounded. If the
  Application Insights API rejects a query, the notebook fails visibly; review the
  run output and adjust the window or backfill strategy rather than silently dropping
  data.

The copy is near-real-time, not a streaming feed. The API key is a sensitive credential;
restrict its scope, protect the Key Vault, and apply your organization's retention and
privacy policies to telemetry fields such as user IDs and client IP addresses.
