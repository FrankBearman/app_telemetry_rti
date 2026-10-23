import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import yaml

import deploy_fabric as deploy


class RealtimeDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parent.parent
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stage = deploy.stage_sources(self.repo, Path(self.temp.name), {})
        self.fabric = {
            "workspaceId": "11111111-2222-3333-4444-555555555555",
            "itemTypes": ["Eventhouse", "KQLDatabase", "Eventstream", "Lakehouse", "SemanticModel"],
            "realtime": {"eventHubConnectionId": "22222222-3333-4444-5555-666666666666"},
        }
        self.azure = {"eventHubConsumerGroup": "customer-consumer"}

    def test_stages_schema_and_preserves_source(self):
        relative = Path(
            "app_telemetry_eventhouse.Eventhouse",
            ".children",
            "app_telemetry_eventhouse.KQLDatabase",
            "DatabaseSchema.kql",
        )
        original = (self.repo / "fabric" / relative).read_text(encoding="utf-8")
        deploy.configure_realtime(self.stage, self.fabric, self.azure, enabled=True)
        schema = (self.stage / relative).read_text(encoding="utf-8")
        self.assertTrue(schema.startswith(original.rstrip()))
        self.assertNotIn(".execute database script", schema)
        self.assertIn('ingestion json mapping "RawAppTelemetryMapping"', schema)
        for table in ("AppRequestsRT", "AppTracesRT", "AppExceptionsRT"):
            self.assertIn(f".alter table {table} policy update", schema)
            self.assertIn(f".alter-merge table {table} policy mirroring", schema)
        self.assertEqual(original, (self.repo / "fabric" / relative).read_text(encoding="utf-8"))
        topology = json.loads((self.stage / f"{deploy.EVENTSTREAM_NAME}.Eventstream" / "eventstream.json").read_text())
        self.assertEqual(topology["sources"][0]["properties"]["consumerGroupName"], "customer-consumer")
        self.assertEqual(topology["sources"][0]["type"], "AzureEventHubExtended")
        self.assertEqual(topology["sources"][0]["properties"]["startPosition"], "Latest")
        self.assertEqual(topology["destinations"][0]["properties"]["mappingRuleName"], "RawAppTelemetryMapping")
        self.assertEqual(topology["destinations"][0]["properties"]["dataIngestionMode"], "DirectIngestion")

    def test_all_environment_bindings_are_parameterized(self):
        deploy.write_parameter_file(
            self.stage, "test", "app-id", self.fabric["realtime"], publish_shortcuts=True
        )
        parameters = yaml.safe_load((self.stage / "parameter.yml").read_text())
        replacements = {
            entry["find_value"]: entry["replace_value"]["test"]
            for entry in parameters["find_replace"]
        }
        self.assertEqual(replacements[deploy.SOURCE_EVENTHUB_CONNECTION_ID], self.fabric["realtime"]["eventHubConnectionId"])
        self.assertEqual(replacements[deploy.SOURCE_EVENTSTREAM_WORKSPACE_ID], "$workspace.$id")
        self.assertEqual(replacements[deploy.SOURCE_WORKSPACE_ID], "$workspace.$id")
        self.assertEqual(
            replacements[deploy.SOURCE_KQL_DATABASE_ID],
            "$items.KQLDatabase.app_telemetry_eventhouse.$id",
        )
        self.assertEqual(replacements[deploy.SHORTCUT_KQL_DATABASE_TOKEN], replacements[deploy.SOURCE_KQL_DATABASE_ID])

    def test_disabled_realtime_does_not_change_schema(self):
        deploy.configure_realtime(self.stage, self.fabric, {}, enabled=False)
        schema = next(self.stage.glob("*.Eventhouse/.children/*.KQLDatabase/DatabaseSchema.kql")).read_text()
        self.assertNotIn("RawAppTelemetry", schema)

    def test_missing_outputs_or_dependency_fail_before_publication(self):
        with self.assertRaisesRegex(ValueError, "eventHubConsumerGroup"):
            deploy.configure_realtime(self.stage, self.fabric, {}, enabled=True)
        self.fabric["itemTypes"].remove("KQLDatabase")
        with self.assertRaisesRegex(ValueError, "requires Eventhouse and KQLDatabase"):
            deploy.configure_realtime(self.stage, self.fabric, self.azure, enabled=True)

    def test_invalid_connection_fails(self):
        for connection in ("not-a-guid", "", None, "00000000-0000-0000-0000-000000000000"):
            with self.subTest(connection=connection):
                self.fabric["realtime"]["eventHubConnectionId"] = connection
                with self.assertRaisesRegex(ValueError, "nonzero connection GUID"):
                    deploy.configure_realtime(self.stage, self.fabric, self.azure, enabled=True)

    def test_library_resolves_streaming_phase_database_and_workspace_ids(self):
        deploy.configure_realtime(self.stage, self.fabric, self.azure, enabled=True)
        deploy.write_parameter_file(
            self.stage, "test", "app-id", self.fabric["realtime"], publish_shortcuts=False
        )
        workspace = object.__new__(deploy.FabricWorkspace)
        workspace.environment = "test"
        workspace.workspace_id = self.fabric["workspaceId"]
        workspace.repository_directory = self.stage
        workspace.item_type_in_scope = ["Eventstream"]
        workspace.bulk_publish_enabled = False
        workspace._api_root_url = "https://api.fabric.microsoft.com"
        workspace.repository_items = {}
        database_id = "33333333-4444-5555-6666-777777777777"
        workspace.contains_param_item_vars = True
        workspace.endpoint = Mock()
        workspace.endpoint.invoke.return_value = {
            "body": {"value": [{
                "type": "KQLDatabase",
                "displayName": deploy.KQL_DATABASE_NAME,
                "description": "",
                "id": database_id,
            }]}
        }
        workspace.environment_parameter = yaml.safe_load((self.stage / "parameter.yml").read_text())
        path = self.stage / f"{deploy.EVENTSTREAM_NAME}.Eventstream" / "eventstream.json"
        result = workspace._replace_parameters(
            SimpleNamespace(contents=path.read_text(), file_path=path),
            SimpleNamespace(type="Eventstream", name=deploy.EVENTSTREAM_NAME),
        )
        topology = json.loads(result)
        self.assertEqual(topology["destinations"][0]["properties"]["itemId"], database_id)
        self.assertEqual(topology["destinations"][0]["properties"]["workspaceId"], self.fabric["workspaceId"])
        self.assertEqual(
            topology["sources"][0]["properties"]["dataConnectionId"],
            self.fabric["realtime"]["eventHubConnectionId"],
        )

    def test_publish_order_and_bootstrap_exclusions(self):
        for bootstrap in (False, True):
            with self.subTest(bootstrap=bootstrap), patch.object(deploy, "AzureCliCredential"), patch.object(
                deploy, "FabricWorkspace"
            ) as workspace, patch.object(deploy, "publish_all_items"):
                deploy.publish_workspace(self.fabric, "test", self.stage, bootstrap=bootstrap)
                scopes = [call.kwargs["item_type_in_scope"] for call in workspace.call_args_list]
                self.assertEqual(scopes[0], ["Eventhouse", "KQLDatabase", "Lakehouse"])
                self.assertEqual(scopes[1], ["Eventstream"])
                self.assertEqual(scopes[2:], [] if bootstrap else [["SemanticModel"]])


if __name__ == "__main__":
    unittest.main()
