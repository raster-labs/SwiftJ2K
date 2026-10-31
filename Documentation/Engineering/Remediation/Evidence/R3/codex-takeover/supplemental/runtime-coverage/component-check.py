#!/usr/bin/env python3
"""Non-native parser checks over preserved receipts; never acceptance evidence."""
import importlib.util
import json
from pathlib import Path
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
WORK = HERE.parent
loader = importlib.util.spec_from_file_location("runtime_coverage", HERE / "reconcile.py")
m = importlib.util.module_from_spec(loader)
loader.loader.exec_module(m)
inventory_path = WORK / "sanitizer-inventory-06/thread/all.ids"
inventory = m.ids(inventory_path)
report = {"state": "PARSER_COMPONENT_CHECKS_ONLY", "helper_sha256": m.sha(HERE / "reconcile.py"),
          "inventory06_sha256": m.sha(inventory_path), "runs": []}

for version, label in [("06", "candidate-handoff-tsan-06"),
                       ("07", "candidate-full-07"),
                       ("08", "candidate-focused-08")]:
    directory = WORK / "validation" / label
    xml_path = directory / "report-swift-testing.xml"
    log_path = directory / "native.log"
    # Later native inventories do not yet exist. For parser format checks only,
    # extend the real06 inventory by new declarations explicitly present in XML.
    # This cannot establish discovery completeness, and is never used by main().
    added = []
    for case in ET.parse(xml_path).getroot().iter("testcase"):
        class_name, name = case.attrib["classname"], case.attrib["name"]
        candidates = {class_name + "/" + name, class_name + "." + name} & inventory
        if not candidates:
            identity = class_name + ("/" if "." in class_name else ".") + name
            inventory.add(identity)
            added.append(identity)
    displays, titles = m.display_map(WORK / ("candidate-snapshot-" + version), inventory)
    reverse = {v: k for k, v in displays.items()}
    log = m.parse_log(log_path, reverse, strict=False)
    xml = m.xml_ids([xml_path], inventory, strict=False)
    strict_log_rejected = False
    try:
        m.parse_log(log_path, reverse)
    except ValueError:
        strict_log_rejected = True
    strict_xml_rejected = False
    try:
        m.xml_ids([xml_path], inventory)
    except ValueError:
        strict_xml_rejected = True
    row = {"label": label, "native_exit_code": json.loads((directory / "result.json").read_text())["exit_code"],
           "derived_component_inventory_count": len(inventory), "added_from_xml_for_format_checks_only": sorted(added),
           "custom_title_bindings": len(titles), "xctest_declarations": len(log["xctest"]),
           "swift_log_completions": len(log["swift_testing"]), "swift_xml_declarations": len(xml),
           "strict_log_rejected": strict_log_rejected, "strict_xml_rejected": strict_xml_rejected,
           "diagnostic_gaps": log["diagnostic_gaps"],
           "files": {str(p): m.sha(p) for p in (xml_path, log_path, directory / "result.json")}}
    assert len(titles) == 130
    if version == "06":
        assert not strict_log_rejected and not strict_xml_rejected
        assert set(log["swift_testing"]) == set(xml) and len(xml) == 4
        assert sum(sum(v.values()) for v in log["parameter_cases"].values()) == 5
        assert m.xml_identity("SwiftJ2KTests", "independentHTDecodersReadSuccessorHTJ2KCodestreams(name:)", inventory) == "SwiftJ2KTests.independentHTDecodersReadSuccessorHTJ2KCodestreams(name:)"
        assert m.signature("SwiftJ2KTests.independentHTDecodersReadSuccessorHTJ2KCodestreams(name:)") == "independentHTDecodersReadSuccessorHTJ2KCodestreams(name:)"
    elif version == "07":
        assert row["native_exit_code"] == 1 and strict_log_rejected and strict_xml_rejected
        assert len(log["xctest"]) == 1034 and len(xml) == 300
        assert sum(v["status"] == "failed" for v in xml.values()) == 1
        assert any("secowarning:" in v for v in log["diagnostic_gaps"])
        assert set(xml) - set(log["swift_testing"]) == {"SwiftJ2KTests.independentOraclesVerifyTranscodedOutputsInBothDirections(name:)"}
    else:
        assert row["native_exit_code"] == 0 and strict_log_rejected and not strict_xml_rejected
        assert len(xml) == 6 and len(log["swift_testing"]) == 6
        key = "SwiftJ2KTests.CodexR3CLIHostTests/onceVerificationUsesTheAcceptedBindAddress(host:)"
        expected = {'1 arguments host → ""', '1 arguments host → " 127.0.0.1 "',
                    '1 arguments host → " * "', '1 arguments host → " 0.0.0.0 "',
                    '1 arguments host → " \t\n "'}
        assert set(log["parameter_cases"][key]) == expected
        assert all(v == 1 for v in log["parameter_cases"][key].values())
        assert log["swift_testing"][key]["parameter_count"] == 5
        assert any("OutputsIwarning:" in v for v in log["diagnostic_gaps"])
        assert any("3 starts/4 completed" in v for v in log["diagnostic_gaps"])
        row["literal_multiline_host_cases"] = log["parameter_cases"][key]
    report["runs"].append(row)

report["boundaries"] = [
    "No native code, test binary, build or test runner was executed.",
    "Derived07/08 component inventories extend real06 with XML identities only for parser checks; they do not prove discovery completeness or final runtime coverage.",
    "Failed07 is rejected. Successful focused08 has an unresolved warning-spliced parameter start and is rejected by strict log reconciliation.",
    "Only literal multiline argument records are joined; no native receipt is altered or repaired.",
    "No R3 acceptance or independent peer gate is closed."]
destination = HERE / "component-check-result.json"
destination.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print("Parser component checks passed; diagnostic gaps preserved:", destination)
