"""Preserve a shared shortcut's device choices while making refresh cleanup explicit."""

from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import plistlib
import re
from urllib.parse import urlparse
from urllib.request import urlopen
from uuid import uuid4


PREFIX = "is.workflow.actions."
RESULT_VARIABLE = "本次续签结果"


def identifier():
    return str(uuid4()).upper()


def action(name, **parameters):
    return {"WFWorkflowActionIdentifier": PREFIX + name,
            "WFWorkflowActionParameters": {"UUID": identifier(), **parameters}}


def output_of(item, content_type=None):
    values = item["WFWorkflowActionParameters"]
    reference = {"Type": "ActionOutput", "OutputUUID": values["UUID"],
                 "OutputName": values.get("CustomOutputName", "结果")}
    if content_type is not None:
        reference["Aggrandizements"] = [{"Type": "WFCoercionVariableAggrandizement",
                                        "CoercionItemClass": content_type}]
    return {"Value": reference, "WFSerializationType": "WFTextTokenAttachment"}


def text_output_of(item):
    reference = output_of(item, "WFStringContentItem")["Value"]
    return {"Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": reference}},
            "WFSerializationType": "WFTextTokenString"}


def result_variable():
    return {"Value": {"Type": "Variable", "VariableName": RESULT_VARIABLE},
            "WFSerializationType": "WFTextTokenAttachment"}


def field(name):
    return action("getvalueforkey", WFDictionaryKey=name, WFGetDictionaryValueType="Value",
                  CustomOutputName=name, WFInput=result_variable())


def remember_result(item):
    dictionary = action("detect.dictionary", WFInput=output_of(item))
    assignment = action("setvariable", WFVariableName=RESULT_VARIABLE, WFInput=output_of(dictionary))
    return [dictionary, assignment]


def condition(item, *, text=None, number=None):
    values = {"WFConditionalActionString": text} if text is not None else {"WFNumberValue": number}
    content_type = "WFStringContentItem" if text is not None else "WFNumberContentItem"
    return action("conditional", GroupingIdentifier=identifier(), WFControlFlowMode=0, WFCondition=4,
                  WFInput={"Type": "Variable", "Variable": output_of(item, content_type)}, **values)


def end_group(start):
    return {"WFWorkflowActionIdentifier": start["WFWorkflowActionIdentifier"],
            "WFWorkflowActionParameters": {
                "GroupingIdentifier": start["WFWorkflowActionParameters"]["GroupingIdentifier"],
                "WFControlFlowMode": 2}}


def original_actions(shortcut):
    items = shortcut["WFWorkflowActions"]
    refresh = [item for item in items if item["WFWorkflowActionIdentifier"].endswith(".RefreshAllIntent")]
    vpn = [item for item in items if item["WFWorkflowActionIdentifier"] == PREFIX + "vpn.set"]
    allowed = {PREFIX + name for name in ("getwifi", "count", "conditional", "wifi.set", "delay", "vpn.set", "notification")}
    if len(refresh) != 1 or not vpn or shortcut.get("WFWorkflowImportQuestions"):
        raise ValueError("Expected one refresh action and an existing VPN configuration without import questions")
    allowed.add(refresh[0]["WFWorkflowActionIdentifier"])
    if any(item["WFWorkflowActionIdentifier"] not in allowed for item in items):
        raise ValueError("This shortcut contains additional actions that need individual review")
    configurations = [item["WFWorkflowActionParameters"]["WFVPN"] for item in vpn]
    if any(value != configurations[0] for value in configurations[1:]):
        raise ValueError("The original shortcut uses multiple VPN configurations")
    descriptor = refresh[0]["WFWorkflowActionParameters"]["AppIntentDescriptor"]
    if refresh[0]["WFWorkflowActionIdentifier"] != descriptor["BundleIdentifier"] + ".RefreshAllIntent":
        raise ValueError("The original refresh action and application descriptor disagree")
    return deepcopy(refresh[0]), deepcopy(configurations[0])


def optimize(shortcut, *, name, minimum_build, checks=18, interval=10):
    if not 1 <= checks <= 36 or not 1 <= interval <= 15:
        raise ValueError("The refresh observation window must be bounded")
    result = deepcopy(shortcut)
    refresh, vpn = original_actions(shortcut)
    first_vpn = next(index for index, item in enumerate(shortcut["WFWorkflowActions"])
                     if item["WFWorkflowActionIdentifier"] == PREFIX + "vpn.set")
    network_preparation = deepcopy(shortcut["WFWorkflowActions"][:first_vpn])
    refresh["WFWorkflowActionParameters"].update(returnErrorsAsResult=True, UUID=identifier(), ShowWhenRun=False)
    descriptor = deepcopy(refresh["WFWorkflowActionParameters"]["AppIntentDescriptor"])
    descriptor["AppIntentIdentifier"] = "GetRefreshResultIntent"
    request = field("requestID")
    query = {"WFWorkflowActionIdentifier": descriptor["BundleIdentifier"] + ".GetRefreshResultIntent",
             "WFWorkflowActionParameters": {"UUID": identifier(), "AppIntentDescriptor": descriptor,
                                             "requestID": text_output_of(request), "ShowWhenRun": False}}
    repeat = action("repeat.count", WFRepeatCount=checks, GroupingIdentifier=identifier(), WFControlFlowMode=0)
    status = field("status")
    pending = condition(status, text="pending")
    disconnect_allowed = field("canDisconnectVPN")
    cleanup = condition(disconnect_allowed, number=1)
    message = field("message")
    explanation = (f"需要三合一 {minimum_build} 或更新版本。连接 VPN 后续签；失败也会返回真实结果。"
                   f"仍在运行时每 {interval} 秒查询本次任务，最多 {checks} 次；确认结束后才断开 VPN。"
                   "若观察时间用完、系统终止或手动停止，请按结果提示检查 VPN。")
    result["WFWorkflowName"] = name
    result["WFWorkflowActions"] = [
        action("comment", WFCommentActionText=explanation), *network_preparation,
        action("vpn.set", WFVPN=deepcopy(vpn), WFVPNOperation="Connect"),
        action("delay", WFDelayTime=2), refresh, *remember_result(refresh),
        repeat, status, pending, action("delay", WFDelayTime=interval), request, query,
        *remember_result(query), end_group(pending), end_group(repeat),
        disconnect_allowed, cleanup,
        action("vpn.set", WFVPN=deepcopy(vpn), WFVPNOperation="Disconnect"), end_group(cleanup),
        message, action("notification", WFNotificationActionBody=text_output_of(message),
                        WFNotificationActionTitle="SideStore 续签结果", WFNotificationActionSound=False),
    ]
    return result


def download_shared(record_id):
    if not re.fullmatch(r"[a-fA-F0-9]{32}", record_id):
        raise ValueError("Expected a public iCloud shortcut record identifier")
    with urlopen("https://www.icloud.com/shortcuts/api/records/" + record_id, timeout=30) as response:
        record = json.load(response)
    url = record["fields"]["shortcut"]["value"]["downloadURL"]
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith((".icloud.com", ".icloud-content.com")):
        raise ValueError("The shared record returned an unexpected download host")
    with urlopen(url, timeout=60) as response:
        data = response.read(4 * 1024 * 1024 + 1)
    if len(data) > 4 * 1024 * 1024:
        raise ValueError("The shared shortcut exceeds the supported size")
    return record["fields"]["name"]["value"], data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", required=True, help="Comma or whitespace separated public iCloud record IDs")
    parser.add_argument("--minimum-build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    records = [value for value in re.split(r"[,\s]+", args.records.strip()) if value]
    if not 1 <= len(records) <= 2 or len(set(records)) != len(records):
        raise ValueError("Provide one or two different shortcut records")
    args.output.mkdir(parents=True, exist_ok=True)
    receipts = []
    for record_id in records:
        name, original = download_shared(record_id)
        filename = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .") + ".shortcut"
        destination = args.output / filename
        if destination.exists():
            raise ValueError("Refusing to overwrite an existing shortcut output")
        updated = optimize(plistlib.loads(original), name=name, minimum_build=args.minimum_build)
        payload = plistlib.dumps(updated, fmt=plistlib.FMT_BINARY, sort_keys=False)
        destination.write_bytes(payload)
        receipts.append({"name": name, "filename": filename, "original_sha256": hashlib.sha256(original).hexdigest(),
                         "unsigned_sha256": hashlib.sha256(payload).hexdigest(), "minimum_build": args.minimum_build})
    (args.output / "receipt.json").write_text(json.dumps(receipts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"prepared": len(receipts), "minimum_build": args.minimum_build}))


if __name__ == "__main__":
    main()
