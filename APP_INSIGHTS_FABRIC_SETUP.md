# Application Insights analytics in Fabric

The `app_telemetry_ingest.Notebook` item incrementally copies the Application Insights
`requests` table into the existing `app_telemtry_lh_bronze` Lakehouse table named
`Requests`. It also creates/updates `RequestsCustomDimensions`, a flattened table
containing the custom-dimension fields selected by the existing custom-dimensions
dataflow. Join it to `Requests` on `id`. The existing Direct Lake semantic model can
then analyze the copied rows. The KQL queryset remains the option for querying
Application Insights live.

## One-time setup

1. In Application Insights, create a read-only API key with permission to read telemetry.
   Do not use the instrumentation key from the connection string as an API key.
2. Create or select an Azure Key Vault. Add a secret named
   `appinsights-query-api-key` and use the read-only API key as its value.
3. Grant the identity used to run the Fabric notebook permission to read/get that
   specific secret. For Key Vault RBAC, assign **Key Vault Secrets User** at the
   narrowest practical scope; for access-policy vaults, grant **Get** on secrets.
4. In `app_telemetry_ingest.Notebook/notebook-content.py`, replace
   `REPLACE_WITH_KEY_VAULT_NAME` in `KEY_VAULT_URL` with the vault name, keeping the
   full URL form `https://<vault-name>.vault.azure.net/`. Fabric's
   `notebookutils.credentials.getSecret` expects the full vault URL, not just its name.
   Never commit the API key or other credentials to Git.
5. Sync the branch into Fabric. Run the notebook once manually and confirm that it
   creates the `Requests` Lakehouse table and completes successfully.
6. Create a schedule on `app_telemetry_ingest_pipeline` for every 15 minutes. Ensure
   pipeline runs do not overlap.

The notebook reads the Key Vault secret under the identity used for its run. Test
secret access by running it manually first, then configure the pipeline's Notebook
activity authentication to use an identity that has the same Key Vault permission.

The pipeline references the notebook by its Fabric Git logical ID and uses the
all-zero workspace ID so Fabric resolves the notebook in the workspace containing the
pipeline.

## Load and retention behavior

- The first run loads the latest 24 hours. It does not backfill the previous year.
- If the existing `Requests` table predates this ingestion and has no `timestamp`
  column, the notebook adds it. Existing rows receive null timestamps; only newly
  ingested/re-read rows have event timestamps.
- Later runs query from the latest stored timestamp minus a two-hour overlap. This
  allows for telemetry ingestion delay; rows are merged by telemetry `id` to avoid
  duplicates.
- Data older than 365 days is deleted from the current Delta table at the end of each
  run. Physical removal of obsolete Delta files is governed by Delta `VACUUM` retention.
- `RequestsCustomDimensions` includes the top-level organization/resource/environment
  fields, the selected `Data` fields, and selected nested `tags` fields from
  `dataflow_requests_customdim`. Missing custom-dimension values remain null. It is
  keyed by the same request `id` as `Requests`.

Example SQL Analytics Endpoint join:

```sql
SELECT
    r.timestamp,
    r.name,
    r.success,
    d.organizationId,
    d.environmentId,
    d.TaskName,
    d.FlowDisplayName,
    d.RunId,
    d.tags_environmentName,
    d.tags_state
FROM dbo.Requests AS r
LEFT JOIN dbo.RequestsCustomDimensions AS d
    ON r.id = d.id;
```
- Each query request covers at most six hours to keep API responses bounded. If the
  Application Insights API rejects a query, the notebook fails visibly; review the
  run output and adjust the window or backfill strategy rather than silently dropping
  data.

The copy is near-real-time, not a streaming feed. The API key is a sensitive credential;
restrict its scope, protect the Key Vault, and apply your organization's retention and
privacy policies to telemetry fields such as user IDs and client IP addresses.
