"""Exercise cleanup and bounded observation in the generated Shortcuts control flow."""

from copy import deepcopy
import json
from pathlib import Path
import plistlib
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_refresh_shortcuts as builder


def fixture():
    vpn = {"identifier": "device-specific-vpn", "title": "LocalDevVPN"}
    descriptor = {"BundleIdentifier": "example.host.personal", "TeamIdentifier": "PERSONAL",
                  "Name": "LiveContainer", "AppIntentIdentifier": "RefreshAllIntent"}
    refresh = {"WFWorkflowActionIdentifier": "example.host.personal.RefreshAllIntent",
               "WFWorkflowActionParameters": {"AppIntentDescriptor": descriptor, "UUID": "old-refresh"}}
    return {"WFWorkflowIcon": {"WFWorkflowIconStartColor": 123}, "WFWorkflowTypes": ["WatchKit"],
            "WFWorkflowImportQuestions": [], "WFWorkflowTriggers": [],
            "WFWorkflowActions": [builder.action("vpn.set", WFVPN=vpn, WFVPNOperation="Connect"),
                                  refresh, builder.action("notification", WFNotificationActionBody="Always success"),
                                  builder.action("vpn.set", WFVPN=vpn, WFVPNOperation="Disconnect")]}


def outcome(status):
    return {"schemaVersion": 1, "requestID": "one-request", "status": status,
            "succeeded": status == "success", "canDisconnectVPN": status in ("success", "failed"),
            "message": {"success": "Renewed", "failed": "Signing failed", "pending": "Still running; keep VPN",
                        "unknown": "Result unavailable; keep VPN"}[status]}


class WorkflowExecution:
    """Interpret the subset of built-in control actions emitted into the plist."""

    def __init__(self, shortcut, results):
        self.items = shortcut["WFWorkflowActions"]
        self.results = iter(results)
        self.outputs, self.variables, self.loops = {}, {}, {}
        self.events = []
        self.delay = 0
        self.groups = {}
        for index, item in enumerate(self.items):
            values = item["WFWorkflowActionParameters"]
            group = values.get("GroupingIdentifier")
            if group:
                self.groups.setdefault(group, {})[values["WFControlFlowMode"]] = index

    def value(self, token):
        if not isinstance(token, dict):
            return token
        if "Variable" in token:
            return self.value(token["Variable"])
        data = token["Value"]
        if token.get("WFSerializationType") == "WFTextTokenString":
            reference = data["attachmentsByRange"]["{0, 1}"]
            return str(self.value({"Value": reference}))
        if data["Type"] == "ActionOutput":
            return self.outputs[data["OutputUUID"]]
        return self.variables[data["VariableName"]]

    def control(self, index, name, values):
        group, mode = values["GroupingIdentifier"], values["WFControlFlowMode"]
        if name == "conditional" and mode == 0:
            expected = values.get("WFConditionalActionString", values.get("WFNumberValue"))
            return index + 1 if self.value(values["WFInput"]) == expected else self.groups[group][2] + 1
        if name == "repeat.count" and mode == 0:
            self.loops[group] = values["WFRepeatCount"]
        if name == "repeat.count" and mode == 2:
            self.loops[group] -= 1
            if self.loops[group]:
                return self.groups[group][0] + 1
        return index + 1

    def execute(self, name, values):
        if name.endswith(".RefreshAllIntent"):
            self.events.append("refresh")
            self.outputs[values["UUID"]] = json.dumps(next(self.results))
        elif name.endswith(".GetRefreshResultIntent"):
            self.events.append(("query", self.value(values["requestID"])))
            self.outputs[values["UUID"]] = json.dumps(next(self.results))
        elif name == "detect.dictionary":
            self.outputs[values["UUID"]] = json.loads(self.value(values["WFInput"]))
        elif name == "setvariable":
            self.variables[values["WFVariableName"]] = self.value(values["WFInput"])
        elif name == "getvalueforkey":
            self.outputs[values["UUID"]] = self.value(values["WFInput"])[values["WFDictionaryKey"]]
        elif name == "vpn.set":
            self.events.append(values["WFVPNOperation"])
        elif name == "notification":
            self.events.append(("notification", self.value(values["WFNotificationActionBody"])))
        elif name == "delay":
            self.delay += values["WFDelayTime"]
        elif name != "comment":
            raise AssertionError("Unexpected generated action: " + name)

    def run(self):
        index = 0
        while index < len(self.items):
            item = self.items[index]
            name = item["WFWorkflowActionIdentifier"].removeprefix(builder.PREFIX)
            values = item["WFWorkflowActionParameters"]
            if "WFControlFlowMode" in values:
                index = self.control(index, name, values)
                continue
            self.execute(name, values)
            index += 1
        return self


class RefreshShortcutFileTests(unittest.TestCase):
    def prepared(self):
        return builder.optimize(fixture(), name="Phone", minimum_build="test")

    def test_roundtrip_preserves_device_application_vpn_and_metadata(self):
        original = fixture()
        snapshot = deepcopy(original)
        result = builder.optimize(original, name="Phone", minimum_build="test")
        encoded = plistlib.dumps(result, fmt=plistlib.FMT_BINARY)
        self.assertEqual(plistlib.loads(encoded), result)
        self.assertEqual(original, snapshot)
        for key in ("WFWorkflowIcon", "WFWorkflowTypes", "WFWorkflowTriggers"):
            self.assertEqual(result[key], original[key])
        actions = result["WFWorkflowActions"]
        vpns = [item["WFWorkflowActionParameters"]["WFVPN"] for item in actions
                if item["WFWorkflowActionIdentifier"] == builder.PREFIX + "vpn.set"]
        self.assertEqual(vpns, [original["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["WFVPN"]] * 2)
        refresh = next(item for item in actions if item["WFWorkflowActionIdentifier"].endswith(".RefreshAllIntent"))
        self.assertEqual(refresh["WFWorkflowActionParameters"]["AppIntentDescriptor"],
                         original["WFWorkflowActions"][1]["WFWorkflowActionParameters"]["AppIntentDescriptor"])
        self.assertTrue(refresh["WFWorkflowActionParameters"]["returnErrorsAsResult"])

    def test_failed_refresh_disconnects_before_showing_actual_error(self):
        run = WorkflowExecution(self.prepared(), [outcome("failed")]).run()
        self.assertEqual(run.events, ["Connect", "refresh", "Disconnect", ("notification", "Signing failed")])
        self.assertEqual(run.delay, 2)

    def test_success_disconnects_before_notification(self):
        run = WorkflowExecution(self.prepared(), [outcome("success")]).run()
        self.assertEqual(run.events, ["Connect", "refresh", "Disconnect", ("notification", "Renewed")])

    def test_pending_queries_same_request_then_cleans_up_late_failure(self):
        results = [outcome("pending"), outcome("pending"), outcome("failed")]
        run = WorkflowExecution(self.prepared(), results).run()
        self.assertEqual(run.events, ["Connect", "refresh", ("query", "one-request"), ("query", "one-request"),
                                     "Disconnect", ("notification", "Signing failed")])
        self.assertEqual(run.delay, 22)

    def test_observation_is_bounded_and_never_refreshes_twice(self):
        run = WorkflowExecution(self.prepared(), [outcome("pending")] * 19).run()
        self.assertEqual(run.delay, 182)
        self.assertEqual(run.events.count("refresh"), 1)
        self.assertEqual(run.events.count(("query", "one-request")), 18)
        self.assertNotIn("Disconnect", run.events)
        self.assertEqual(run.events[-1], ("notification", "Still running; keep VPN"))

    def test_missing_final_receipt_does_not_disconnect(self):
        run = WorkflowExecution(self.prepared(), [outcome("pending"), outcome("unknown")]).run()
        self.assertNotIn("Disconnect", run.events)
        self.assertEqual(run.events[-1], ("notification", "Result unavailable; keep VPN"))

    def test_existing_conditional_wifi_recovery_is_preserved(self):
        original = fixture()
        query = builder.action("getwifi", WFWiFiDetail="Network Name")
        count = builder.action("count", Input=builder.output_of(query))
        condition = builder.condition(count, number=1)
        otherwise = deepcopy(condition)
        otherwise["WFWorkflowActionParameters"]["WFControlFlowMode"] = 1
        prefix = [query, count, condition, otherwise, builder.action("wifi.set", OnValue=0),
                  builder.action("delay", WFDelayTime=3), builder.action("wifi.set", OnValue=1),
                  builder.action("delay", WFDelayTime=5), builder.end_group(condition)]
        original["WFWorkflowActions"] = prefix + original["WFWorkflowActions"]
        prepared = builder.optimize(original, name="Phone", minimum_build="test")
        self.assertEqual(prepared["WFWorkflowActions"][1:10], prefix)

    def test_unrecognized_actions_are_not_silently_removed(self):
        original = fixture()
        original["WFWorkflowActions"].append(builder.action("sendmessage"))
        with self.assertRaisesRegex(ValueError, "individual review"):
            builder.optimize(original, name="Phone", minimum_build="test")

    def test_import_parameters_match_independently_compiled_shortcuts_schema(self):
        fixture_path = Path(__file__).parent / "fixtures/shortcut_parameter_schema.json"
        schema = json.loads(fixture_path.read_text(encoding="utf-8"))["parameters"]
        actions = self.prepared()["WFWorkflowActions"]
        conditions = [item["WFWorkflowActionParameters"] for item in actions
                      if item["WFWorkflowActionIdentifier"] == builder.PREFIX + "conditional"
                      and item["WFWorkflowActionParameters"]["WFControlFlowMode"] == 0]
        for parameters, key in zip(conditions, ("text_condition", "number_condition")):
            selected = {name: parameters[name] for name in schema[key]}
            self.assertEqual(normalize_references(selected), schema[key])
            self.assertNotIn("WFTextValue", parameters)
        query = next(item["WFWorkflowActionParameters"] for item in actions
                     if item["WFWorkflowActionIdentifier"].endswith(".GetRefreshResultIntent"))
        notification = actions[-1]["WFWorkflowActionParameters"]
        self.assertEqual(normalize_references(query["requestID"]), schema["text_reference"])
        self.assertEqual(normalize_references(notification["WFNotificationActionBody"]), schema["text_reference"])
        self.assertEqual(query["requestID"]["Value"]["string"], "\ufffc")
        self.assertEqual(query["requestID"]["Value"]["attachmentsByRange"]["{0, 1}"]["OutputName"], "requestID")


def normalize_references(value):
    if isinstance(value, list):
        return [normalize_references(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize_references(item) for key, item in value.items()
                if key not in ("OutputName", "OutputUUID")}
    return value


if __name__ == "__main__":
    unittest.main()
