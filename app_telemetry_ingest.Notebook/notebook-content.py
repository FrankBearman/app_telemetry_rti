# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "e8d8f813-dff6-4223-8857-e2ccdf0c2381",
# META       "default_lakehouse_name": "app_telemtry_lh_bronze",
# META       "default_lakehouse_workspace_id": "e40c817a-488d-4c50-b65e-4020fa697795",
# META       "known_lakehouses": [
# META         {
# META           "id": "e8d8f813-dff6-4223-8857-e2ccdf0c2381"
# META         }
# META       ]
# META     }
# META   }
# META }

# CELL ********************

from datetime import datetime, timedelta, timezone
import json
import time

import requests
from delta.tables import DeltaTable
from pyspark.sql import functions as F
from pyspark.sql import types as T
from pyspark.sql.window import Window


APP_INSIGHTS_APP_ID = "00a8e086-bbec-4f92-a08f-14a05eb151f2"
KEY_VAULT_NAME = "REPLACE_WITH_KEY_VAULT_NAME"
API_KEY_SECRET_NAME = "appinsights-query-api-key"
TABLE_NAME = "Requests"
INITIAL_LOOKBACK_HOURS = 24
OVERLAP_MINUTES = 120
RETENTION_DAYS = 365
QUERY_WINDOW_HOURS = 6

if KEY_VAULT_NAME == "REPLACE_WITH_KEY_VAULT_NAME":
    raise ValueError("Set KEY_VAULT_NAME to the Key Vault containing the App Insights API key.")

api_key = notebookutils.credentials.getSecret(KEY_VAULT_NAME, API_KEY_SECRET_NAME)
if not api_key:
    raise RuntimeError(f"Key Vault secret '{API_KEY_SECRET_NAME}' is empty.")


request_schema = T.StructType([
    T.StructField("timestamp", T.TimestampType(), True),
    T.StructField("id", T.StringType(), True),
    T.StructField("source", T.StringType(), True),
    T.StructField("name", T.StringType(), True),
    T.StructField("url", T.StringType(), True),
    T.StructField("success", T.StringType(), True),
    T.StructField("resultCode", T.StringType(), True),
    T.StructField("duration", T.DoubleType(), True),
    T.StructField("performanceBucket", T.StringType(), True),
    T.StructField("itemType", T.StringType(), True),
    T.StructField("customDimensions", T.StringType(), True),
    T.StructField("customMeasurements", T.StringType(), True),
    T.StructField("operation_Name", T.StringType(), True),
    T.StructField("operation_Id", T.StringType(), True),
    T.StructField("operation_ParentId", T.StringType(), True),
    T.StructField("operation_SyntheticSource", T.StringType(), True),
    T.StructField("session_Id", T.StringType(), True),
    T.StructField("user_Id", T.StringType(), True),
    T.StructField("user_AuthenticatedId", T.StringType(), True),
    T.StructField("user_AccountId", T.StringType(), True),
    T.StructField("application_Version", T.StringType(), True),
    T.StructField("client_Type", T.StringType(), True),
    T.StructField("client_Model", T.StringType(), True),
    T.StructField("client_OS", T.StringType(), True),
    T.StructField("client_IP", T.StringType(), True),
    T.StructField("client_City", T.StringType(), True),
    T.StructField("client_StateOrProvince", T.StringType(), True),
    T.StructField("client_CountryOrRegion", T.StringType(), True),
    T.StructField("client_Browser", T.StringType(), True),
    T.StructField("cloud_RoleName", T.StringType(), True),
    T.StructField("cloud_RoleInstance", T.StringType(), True),
    T.StructField("links", T.StringType(), True),
    T.StructField("appId", T.StringType(), True),
    T.StructField("appName", T.StringType(), True),
    T.StructField("iKey", T.StringType(), True),
    T.StructField("sdkVersion", T.StringType(), True),
    T.StructField("itemId", T.StringType(), True),
    T.StructField("itemCount", T.LongType(), True),
    T.StructField("_ResourceId", T.StringType(), True),
])

projection = []
for field in request_schema.fields:
    if field.name == "duration":
        projection.append("duration=todouble(duration)")
    elif field.name == "itemCount":
        projection.append("itemCount=tolong(itemCount)")
    elif field.dataType == T.StringType():
        projection.append(f"{field.name}=tostring({field.name})")
    else:
        projection.append(field.name)
projection_sql = ",\n    ".join(projection)


def query_window(start_utc, end_utc):
    start_literal = start_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end_literal = end_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"""
requests
| where timestamp >= datetime({start_literal}) and timestamp < datetime({end_literal})
| project
    {projection_sql}
"""


def parse_cell(value, data_type):
    if value is None:
        return None
    if data_type == T.TimestampType():
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc).replace(tzinfo=None)
    if data_type == T.StringType():
        if isinstance(value, (dict, list)):
            return json.dumps(value, separators=(",", ":"), ensure_ascii=False)
        if isinstance(value, bool):
            return str(value).lower()
        return str(value)
    if data_type == T.DoubleType():
        return float(value)
    if data_type == T.LongType():
        return int(value)
    raise TypeError(f"Unsupported Spark type for Application Insights column: {data_type}")


def read_requests(start_utc, end_utc):
    response = requests.get(
        f"https://api.applicationinsights.io/v1/apps/{APP_INSIGHTS_APP_ID}/query",
        headers={"x-api-key": api_key, "Content-Type": "application/json"},
        params={"query": query_window(start_utc, end_utc)},
        timeout=120,
    )
    response.raise_for_status()
    payload = response.json()
    if payload.get("error"):
        raise RuntimeError(f"Application Insights query returned an error: {payload['error']}")
    tables = payload.get("tables", [])
    if not tables:
        raise RuntimeError("Application Insights query response did not contain a result table.")

    result = tables[0]
    column_names = [column["name"] for column in result["columns"]]
    expected_names = [field.name for field in request_schema.fields]
    if column_names != expected_names:
        raise RuntimeError(
            "Application Insights returned an unexpected requests schema. "
            f"Expected {expected_names}; received {column_names}."
        )

    data_types = [field.dataType for field in request_schema.fields]
    rows = [
        tuple(parse_cell(value, data_type) for value, data_type in zip(row, data_types))
        for row in result.get("rows", [])
    ]
    return rows


table_exists = spark.catalog.tableExists(TABLE_NAME)
now_utc = datetime.now(timezone.utc).replace(second=0, microsecond=0)
if table_exists:
    latest_timestamp = (
        spark.table(TABLE_NAME)
        .select(F.max("timestamp").alias("latest"))
        .first()["latest"]
    )
    if latest_timestamp is None:
        start_utc = now_utc - timedelta(hours=INITIAL_LOOKBACK_HOURS)
    else:
        start_utc = latest_timestamp.replace(tzinfo=timezone.utc) - timedelta(
            minutes=OVERLAP_MINUTES
        )
else:
    start_utc = now_utc - timedelta(hours=INITIAL_LOOKBACK_HOURS)

if start_utc >= now_utc:
    raise RuntimeError("The ingestion start time is not earlier than the current query time.")

all_rows = []
window_start = start_utc
window_size = timedelta(hours=QUERY_WINDOW_HOURS)
while window_start < now_utc:
    window_end = min(window_start + window_size, now_utc)
    attempt = 0
    while True:
        try:
            all_rows.extend(read_requests(window_start, window_end))
            break
        except requests.RequestException as error:
            status_code = error.response.status_code if error.response is not None else None
            if status_code is not None and status_code not in (429, 500, 502, 503, 504):
                raise
            attempt += 1
            if attempt >= 4:
                raise RuntimeError(
                    f"Application Insights request failed for "
                    f"{window_start.isoformat()} through {window_end.isoformat()}: {error}"
                ) from error
            time.sleep(min(2 ** attempt, 30))
    window_start = window_end

if all_rows:
    batch = spark.createDataFrame(all_rows, schema=request_schema)
    if batch.filter(F.col("id").isNull()).limit(1).count():
        raise RuntimeError("Application Insights returned a request without an id; refusing to write it.")

    latest_per_id = Window.partitionBy("id").orderBy(F.col("timestamp").desc())
    batch = (
        batch.withColumn("_row_number", F.row_number().over(latest_per_id))
        .filter(F.col("_row_number") == 1)
        .drop("_row_number")
    )

    if table_exists:
        target = DeltaTable.forName(spark, TABLE_NAME)
        (
            target.alias("target")
            .merge(batch.alias("source"), "target.id = source.id")
            .whenMatchedUpdateAll()
            .whenNotMatchedInsertAll()
            .execute()
        )
    else:
        batch.write.format("delta").mode("overwrite").saveAsTable(TABLE_NAME)

cutoff = (now_utc - timedelta(days=RETENTION_DAYS)).replace(tzinfo=None)
if spark.catalog.tableExists(TABLE_NAME):
    DeltaTable.forName(spark, TABLE_NAME).delete(F.col("timestamp") < F.lit(cutoff))

print(
    f"Application Insights ingestion finished. "
    f"Rows returned: {len(all_rows)}; window start: {start_utc.isoformat()}."
)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
