"""Deploy the fabric/ items to a customer's Fabric workspace using fabric-cicd.

Usage: python scripts/deploy_fabric.py --customer contoso
First deployment: add --bootstrap to omit shortcuts and reporting items until the
Eventhouse tables have OneLake availability and their first mirrored Delta files.

Authentication uses the Azure CLI login (AzureCliCredential): an `az login` session locally,
or the service connection identity inside the ADO AzureCLI@2 task. That identity must be a
member (Contributor or higher) of the target Fabric workspace, and the tenant must allow
service principals to use Fabric APIs.

The repository's fabric/ folder is copied to out/<customer>/fabric-src and the development
environment's identifiers are rewritten for the customer before publishing. The repository
files themselves are never modified.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from uuid import UUID

import yaml
from azure.identity import AzureCliCredential
from fabric_cicd import FabricWorkspace, append_feature_flag, publish_all_items

# Identifiers baked into the exported development items. Update these if the source items change.
SOURCE_APP_INSIGHTS_APP_ID = "00a8e086-bbec-4f92-a08f-14a05eb151f2"
SOURCE_KEY_VAULT_URL = "https://app-telem-kv.vault.azure.net/"
SOURCE_APP_INSIGHTS_CLUSTER_URI = (
    "https://ade.applicationinsights.io/subscriptions/835c0954-8dd3-4099-8644-daff1323d1ec"
    "/resourcegroups/apv8_telemtry/providers/microsoft.insights/components/apv8appInsights"
)
SOURCE_WORKSPACE_ID = "e40c817a-488d-4c50-b65e-4020fa697795"
SOURCE_LAKEHOUSE_ID = "e8d8f813-dff6-4223-8857-e2ccdf0c2381"
LAKEHOUSE_NAME = "app_telemtry_lh_bronze"
REPORTING_ITEM_TYPES = {"SemanticModel", "Report"}

# Non-secret bindings in the exported, working Eventstream definition.
SOURCE_EVENTHUB_CONNECTION_ID = "a951cee1-43e0-4ec5-8023-cab7a2899113"
SOURCE_EVENTSTREAM_WORKSPACE_ID = "faa9dc33-4f71-4eb4-b815-0f4fd8662646"
SOURCE_KQL_DATABASE_ID = "1c401fb0-7b07-4e12-9c22-be709e106d9f"
EVENTSTREAM_NAME = "app_telemetry_eventstream"
EVENTHOUSE_NAME = "app_telemetry_eventhouse"
KQL_DATABASE_NAME = "app_telemetry_eventhouse"
SHORTCUT_KQL_DATABASE_TOKEN = "__KQL_DATABASE_ID__"

TEXT_SUFFIXES = {".py", ".json", ".pq", ".tmdl", ".kql", ".platform", ".yml", ".yaml", ".txt", ".md"}


def stage_sources(repo: Path, out_dir: Path, replacements: dict[str, str]) -> Path:
    stage = out_dir / "fabric-src"
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(repo / "fabric", stage)

    for path in stage.rglob("*"):
        if not path.is_file() or (path.suffix.lower() not in TEXT_SUFFIXES and path.name != ".platform"):
            continue
        text = path.read_text(encoding="utf-8")
        updated = text
        for old, new in replacements.items():
            updated = updated.replace(old, new)
        if updated != text:
            path.write_text(updated, encoding="utf-8", newline="")
    return stage


def inject_shortcuts(stage: Path, tables: list[str]) -> None:
    """Add OneLake shortcuts from the Lakehouse to the KQL database's OneLake-mirrored tables.

    Written into the staged copy only; the IDs are resolved by parameter.yml at publish time.
    """
    shortcuts = [
        {
            "name": table,
            "path": "Tables/dbo",
            "target": {
                "type": "OneLake",
                "oneLake": {
                    "workspaceId": SOURCE_WORKSPACE_ID,
                    "itemId": SHORTCUT_KQL_DATABASE_TOKEN,
                    "path": f"Tables/{table}",
                },
            },
        }
        for table in tables
    ]
    path = stage / f"{LAKEHOUSE_NAME}.Lakehouse" / "shortcuts.metadata.json"
    path.write_text(json.dumps(shortcuts, indent=2), encoding="utf-8")


def configure_realtime(stage: Path, fabric: dict, azure: dict, *, enabled: bool) -> None:
    if not enabled:
        return
    item_types = fabric["itemTypes"]
    if "KQLDatabase" in item_types:
        setup = (stage / "realtime" / "hotpath_setup.kql").read_text(encoding="utf-8")
        marker = ".execute database script with (ContinueOnErrors = false) <|"
        if setup.count(marker) != 1:
            raise ValueError("hotpath_setup.kql must contain exactly one database-script header.")
        commands = setup.split(marker, 1)[1].strip()
        schema = stage / f"{EVENTHOUSE_NAME}.Eventhouse" / ".children" / f"{KQL_DATABASE_NAME}.KQLDatabase" / "DatabaseSchema.kql"
        schema.write_text(schema.read_text(encoding="utf-8").rstrip() + "\n\n" + commands + "\n", encoding="utf-8")
    if "Eventstream" in item_types:
        if not {"Eventhouse", "KQLDatabase"}.issubset(item_types):
            raise ValueError("Eventstream deployment requires Eventhouse and KQLDatabase in fabric.itemTypes.")
        connection_id = fabric.get("realtime", {}).get("eventHubConnectionId", "")
        try:
            valid_connection = isinstance(connection_id, str) and UUID(connection_id).int != 0
        except ValueError:
            valid_connection = False
        if not valid_connection:
            raise ValueError("fabric.realtime.eventHubConnectionId must be a nonzero connection GUID.")
        consumer_group = azure.get("eventHubConsumerGroup")
        if not consumer_group:
            raise ValueError("Azure outputs must include eventHubConsumerGroup for Eventstream deployment.")
        path = stage / f"{EVENTSTREAM_NAME}.Eventstream" / "eventstream.json"
        topology = json.loads(path.read_text(encoding="utf-8"))
        topology["sources"][0]["properties"]["consumerGroupName"] = consumer_group
        path.write_text(json.dumps(topology, indent=2) + "\n", encoding="utf-8")


def write_parameter_file(
    stage: Path, environment: str, app_insights_app_id: str, realtime: dict, *, publish_shortcuts: bool
) -> None:
    # Workspace and Lakehouse IDs only exist after the items are created, so fabric-cicd resolves
    # them through its dynamic variables at publish time.
    parameters = {
        "find_replace": [
            {
                "find_value": SOURCE_APP_INSIGHTS_APP_ID,
                "replace_value": {environment: app_insights_app_id},
            },
            {
                "find_value": SOURCE_WORKSPACE_ID,
                "replace_value": {environment: "$workspace.$id"},
            },
            {
                "find_value": SOURCE_LAKEHOUSE_ID,
                "replace_value": {environment: f"$items.Lakehouse.{LAKEHOUSE_NAME}.$id"},
            },
        ]
    }
    optional = {
        SOURCE_EVENTHUB_CONNECTION_ID: realtime.get("eventHubConnectionId", ""),
        SOURCE_EVENTSTREAM_WORKSPACE_ID: "$workspace.$id",
        SOURCE_KQL_DATABASE_ID: f"$items.KQLDatabase.{KQL_DATABASE_NAME}.$id",
    }
    for find_value, replace_value in optional.items():
        if find_value and replace_value:
            parameters["find_replace"].append({"find_value": find_value, "replace_value": {environment: replace_value}})
    if publish_shortcuts:
        parameters["find_replace"].append(
            {
                "find_value": SHORTCUT_KQL_DATABASE_TOKEN,
                "replace_value": {environment: f"$items.KQLDatabase.{KQL_DATABASE_NAME}.$id"},
            }
        )
    (stage / "parameter.yml").write_text(yaml.safe_dump(parameters, sort_keys=False), encoding="utf-8")


def publish_workspace(fabric: dict, environment: str, stage: Path, *, bootstrap: bool) -> None:
    item_types = fabric["itemTypes"]
    reporting = [item_type for item_type in item_types if item_type in REPORTING_ITEM_TYPES]
    infrastructure = [item_type for item_type in item_types if item_type not in REPORTING_ITEM_TYPES | {"Eventstream"}]
    credential = AzureCliCredential()
    # Shortcut publication is a post-publish action. Finish that pass before importing models.
    streaming = ["Eventstream"] if "Eventstream" in item_types else []
    # Create the raw table/mapping before a Direct ingestion destination can reference it.
    phases = [infrastructure, streaming] if bootstrap else [infrastructure, streaming, reporting]
    for scope in phases:
        if scope:
            workspace = FabricWorkspace(
                workspace_id=fabric["workspaceId"],
                environment=environment,
                repository_directory=str(stage),
                item_type_in_scope=scope,
                token_credential=credential,
            )
            publish_all_items(workspace)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--customer", required=True)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument(
        "--bootstrap", action="store_true",
        help="Publish infrastructure without shortcuts, semantic models, or reports.",
    )
    args = parser.parse_args()

    repo = Path(args.repo_root)
    out_dir = repo / "out" / args.customer
    config = json.loads((repo / "customers" / f"{args.customer}.json").read_text(encoding="utf-8-sig"))
    azure = json.loads((out_dir / "azure-outputs.json").read_text(encoding="utf-8-sig"))

    fabric = config["fabric"]
    realtime = fabric.get("realtime", {})
    shortcuts = realtime.get("lakehouseShortcuts", {})
    publish_shortcuts = bool(shortcuts.get("enabled")) and not args.bootstrap
    if not args.bootstrap and "SemanticModel" in fabric["itemTypes"]:
        if not publish_shortcuts or "AppRequestsRT" not in shortcuts.get("tables", []):
            raise ValueError(
                "app_telemetry_model requires the AppRequestsRT OneLake shortcut. Enable "
                "fabric.realtime.lakehouseShortcuts and include AppRequestsRT in tables, "
                "or use --bootstrap until hotpath_setup.kql has run and mirroring is ready."
            )
        if "Lakehouse" not in fabric["itemTypes"] or "KQLDatabase" not in fabric["itemTypes"]:
            raise ValueError("Hot-path model deployment requires Lakehouse and KQLDatabase in fabric.itemTypes.")
    key_vault_url = azure["keyVaultUrl"] if azure["keyVaultUrl"].endswith("/") else azure["keyVaultUrl"] + "/"
    cluster_uri = (
        f"https://ade.applicationinsights.io/subscriptions/{azure['subscriptionId']}"
        f"/resourcegroups/{azure['resourceGroup']}/providers/microsoft.insights"
        f"/components/{azure['appInsightsName']}"
    )

    stage = stage_sources(
        repo,
        out_dir,
        {
            SOURCE_KEY_VAULT_URL: key_vault_url,
            SOURCE_APP_INSIGHTS_CLUSTER_URI: cluster_uri,
        },
    )
    realtime_enabled = bool(config.get("azure", {}).get("realtime", {}).get("enabled"))
    if "Eventstream" in fabric["itemTypes"] and not realtime_enabled:
        raise ValueError("Remove Eventstream from fabric.itemTypes when azure.realtime.enabled is false.")
    configure_realtime(stage, fabric, azure, enabled=realtime_enabled)
    if publish_shortcuts:
        inject_shortcuts(stage, shortcuts.get("tables", []))
        append_feature_flag("enable_shortcut_publish")
    write_parameter_file(
        stage, args.customer, azure["appInsightsAppId"], realtime, publish_shortcuts=publish_shortcuts
    )
    if args.bootstrap:
        print("Bootstrap: shortcuts, semantic models, and reports are explicitly excluded.")
    publish_workspace(fabric, args.customer, stage, bootstrap=args.bootstrap)
    print(f"Fabric items published to workspace {fabric['workspaceId']}.")


if __name__ == "__main__":
    main()
