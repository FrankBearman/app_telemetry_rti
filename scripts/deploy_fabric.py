"""Deploy the fabric/ items to a customer's Fabric workspace using fabric-cicd.

Usage: python scripts/deploy_fabric.py --customer contoso

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

import yaml
from azure.identity import AzureCliCredential
from fabric_cicd import FabricWorkspace, publish_all_items

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


def write_parameter_file(stage: Path, environment: str) -> None:
    # Workspace and Lakehouse IDs only exist after the items are created, so fabric-cicd resolves
    # them through its dynamic variables at publish time.
    parameters = {
        "find_replace": [
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
    (stage / "parameter.yml").write_text(yaml.safe_dump(parameters, sort_keys=False), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--customer", required=True)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    args = parser.parse_args()

    repo = Path(args.repo_root)
    out_dir = repo / "out" / args.customer
    config = json.loads((repo / "customers" / f"{args.customer}.json").read_text(encoding="utf-8-sig"))
    azure = json.loads((out_dir / "azure-outputs.json").read_text(encoding="utf-8-sig"))

    fabric = config["fabric"]
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
            SOURCE_APP_INSIGHTS_APP_ID: azure["appInsightsAppId"],
            SOURCE_KEY_VAULT_URL: key_vault_url,
            SOURCE_APP_INSIGHTS_CLUSTER_URI: cluster_uri,
        },
    )
    write_parameter_file(stage, args.customer)

    workspace = FabricWorkspace(
        workspace_id=fabric["workspaceId"],
        environment=args.customer,
        repository_directory=str(stage),
        item_type_in_scope=fabric["itemTypes"],
        token_credential=AzureCliCredential(),
    )
    publish_all_items(workspace)
    print(f"Fabric items published to workspace {fabric['workspaceId']}.")


if __name__ == "__main__":
    main()
