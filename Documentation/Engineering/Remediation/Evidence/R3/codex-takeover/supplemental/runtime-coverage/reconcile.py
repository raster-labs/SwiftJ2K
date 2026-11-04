#!/usr/bin/env python3
"""Reconcile immutable ordinary and two-part sanitizer runtime receipts.

Read-only with respect to source/native receipts; writes --output only. This is
deliberately strict about the observed Apple Swift 6.4 report formats. Unknown,
ambiguous, truncated or interleaved events are gaps, never silently dropped.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

SANITIZER_REPORT = re.compile(r"WARNING: ThreadSanitizer|ERROR: (AddressSanitizer|LeakSanitizer)|SUMMARY: (ThreadSanitizer|AddressSanitizer)|runtime error:")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def ids(path):
    values = Path(path).read_text().splitlines()
    require(values and all(values), f"Empty inventory/ID: {path}")
    require(len(values) == len(set(values)), f"Duplicate inventory ID: {path}")
    return set(values)


def signature(identity):
    # SwiftPM uses Module.Suite/function for members, Module.function for free
    # functions. Preserve inventory identities; only extract the display part.
    if "/" in identity:
        return identity.split("/", 1)[1]
    module, separator, function = identity.partition(".")
    require(bool(module and separator and function), f"Unknown inventory identity: {identity}")
    return function


def xml_identity(classname, name, inventory):
    candidates = {classname + "/" + name, classname + "." + name} & inventory
    require(len(candidates) == 1, f"XML identity missing/ambiguous in inventory: {classname}, {name}")
    return candidates.pop()


def display_map(source, inventory):
    """Bind simple literal @Test names to canonical, unique function IDs.

    This limited text reader does not claim to parse arbitrary Swift. Only a
    first-argument JSON-compatible ordinary string literal is accepted. Every
    mapped name must resolve uniquely and exactly match runtime events.
    """
    swift = {v for v in inventory if v.endswith(")")}
    result = {v: signature(v) for v in swift}
    provenance = []
    for path in sorted((source / "Tests").rglob("*.swift")):
        data = path.read_text()
        module = path.relative_to(source / "Tests").parts[0]
        for match in re.finditer(r'@Test\s*\(\s*("(?:[^"\\]|\\.)*")', data):
            literal = match.group(1)
            require(not literal.startswith('""'), f"Unsupported multiline title: {path}")
            try:
                title = json.loads(literal)
            except ValueError as exc:
                raise ValueError(f"Unsupported Swift title escape at {path}: {literal}") from exc
            following = data[match.end():]
            function = re.search(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", following)
            require(function is not None, f"No function after title: {path}")
            require("@Test" not in following[:function.start()], f"Ambiguous title owner: {path}")
            base = function.group(1)
            candidates = [v for v in swift if v.startswith(module + ".")
                          and signature(v).split("(", 1)[0] == base]
            require(len(candidates) == 1, f"Title has ambiguous/missing ID: {path}: {base}")
            identity = candidates[0]
            result[identity] = '"' + title + '"'
            provenance.append({"id": identity, "display": result[identity],
                "source": str(path), "line": data[:match.start()].count("\n") + 1,
                "source_sha256": sha(path), "literal": literal})
    require(len(set(result.values())) == len(result), "Duplicate Swift Testing display names")
    return result, provenance


def logical_log_records(path):
    """Join only a started parameter event through its own terminal marker.

    Literal tabs/newlines can occur in argument descriptions. Retain them exactly.
    A different framework event or diagnostic ends the incomplete record as a gap;
    it must never be swallowed as an argument continuation.
    """
    pending, first = [], None
    terminal = re.compile(r" to .+ started\.$", re.S)
    interruption = re.compile(r"[◇✔✘↷] (?:Test|Suite) |(?:^|\n)(?:warning:|error:|Test Case ')")
    for number, line in enumerate(path.read_bytes().decode("utf-8").split("\n"), 1):
        if pending:
            if interruption.search(line):
                yield first, "\n".join(pending)
                pending, first = [], None
            else:
                pending.append(line)
                if terminal.search("\n".join(pending)):
                    yield first, "\n".join(pending)
                    pending, first = [], None
                continue
        if "◇ Test case passing " in line and not terminal.search(line):
            pending, first = [line], number
        else:
            yield number, line
    if pending:
        yield first, "\n".join(pending)


def parse_log(path, display_to_id, strict=True):
    xstarts, xends, swstarts, swends = Counter(), {}, Counter(), {}
    cases = defaultdict(Counter)
    known_or_skipped = []
    unknown = []
    warnings = []
    known_issues = []
    failed_events = []
    def resolve_display(display, number, line):
        if display not in display_to_id:
            unknown.append({"line": number, "text": line, "unresolved_display": display})
            return None
        return display_to_id[display]
    for number, line in logical_log_records(path):
        if SANITIZER_REPORT.search(line):
            warnings.append({"line": number, "text": line})
        if re.search(r"known issue|[Ss][Kk][Ii][Pp]|[Uu][Nn][Ee][Xx][Ee][Cc][Uu][Tt][Ee][Dd]", line):
            known_or_skipped.append({"line": number, "text": line})
        if re.search(r"recorded (?:a|an) known issue|with \d+ known issues?", line):
            known_issues.append({"line": number, "text": line})
        event = re.search(r"Test Case '-\[([^ ]+) ([^]]+)\]' (started|passed|failed|skipped)(?:\.| \([^\n]*\))\.?$", line)
        if event:
            key = event[1] + "/" + event[2]
            if event[3] == "started":
                xstarts[key] += 1
            else:
                require(key not in xends, f"Repeated XCTest completion: {key}")
                xends[key] = event[3]
            continue
        if "Test Case '" in line and re.search(r" (started|passed|failed|skipped)", line):
            unknown.append({"line": number, "text": line})
            continue
        # Prefix diagnostics may precede a complete Unicode event. Extracting the
        # intact suffix is safe; a diagnostic inserted inside it fails matching.
        event = re.search(r"◇ Test case passing (\d+) arguments? ", line)
        if event:
            endings = [(display, key, " to " + display + " started.")
                       for display, key in display_to_id.items()
                       if line.endswith(" to " + display + " started.")]
            if len(endings) != 1:
                unknown.append({"line": number, "text": line,
                                "problem": "Parameter terminal display missing or ambiguous"})
            else:
                _, key, suffix = endings[0]
                argument_text = line[event.end():-len(suffix)]
                cases[key][f"{event[1]} arguments {argument_text}"] += 1
            continue
        event = re.search(r"◇ Test (.*) started\.$", line)
        if event and event[1] != "run":
            display = event[1]
            key = resolve_display(display, number, line)
            if key is not None:
                swstarts[key] += 1
            continue
        event = re.search(r"✔ Test (.*?) (?:with (\d+) test cases? )?passed after [0-9.]+ seconds\.$", line)
        if event:
            display = event[1]
            if display.startswith("run with "):
                continue
            key = resolve_display(display, number, line)
            if key is None:
                continue
            require(key not in swends, f"Repeated Swift Testing completion: {key}")
            swends[key] = {"status": "passed", "parameter_count": int(event[2]) if event[2] else None}
            continue
        event = re.search(r"↷ Test (.*?) skipped(?:[.:] (.*))?\.?$", line)
        if event:
            display = event[1]
            key = resolve_display(display, number, line)
            if key is None:
                continue
            require(key not in swends, f"Repeated Swift Testing completion/skip: {key}")
            swends[key] = {"status": "skipped", "reason": event[2], "parameter_count": None}
            continue
        event = re.search(r"✘ Test (.*?) failed after [0-9.]+ seconds(?: with \d+ issues?)?\.$", line)
        if event:
            display = event[1]
            if display.startswith("run with "):
                continue
            key = resolve_display(display, number, line)
            if key is None:
                continue
            require(key not in swends, f"Repeated Swift Testing failure: {key}")
            swends[key] = {"status": "failed", "parameter_count": None}
            failed_events.append({"line": number, "text": line})
            continue
        if re.search(r"✘ Test .* recorded an issue ", line):
            failed_events.append({"line": number, "text": line})
            continue
        if re.search(r"[◇✔✘↷] Test ", line) and not re.search(r"[◇✔✘↷] Test run ", line):
            unknown.append({"line": number, "text": line})
    issues = []
    def check(ok, message):
        if not ok:
            issues.append(message)
    check(not warnings, f"Sanitizer warnings in {path}: {warnings}")
    check(not known_issues, f"Known-issue records require explicit manual disposition, not an automatic pass: {path}: {known_issues}")
    check(not failed_events, f"Failed Swift Testing events in {path}: {failed_events}")
    check(not unknown, f"Unresolved/interleaved runtime events in {path}: {unknown}")
    check(set(xstarts) == set(xends), f"XCTest starts/completions differ in {path}")
    check(all(n == 1 for n in xstarts.values()), f"Duplicate XCTest starts in {path}")
    check(all(v in ("passed", "skipped") for v in xends.values()), f"Failed XCTest in {path}")
    for key, status in swends.items():
        count = swstarts[key]
        check(count == 1 if status["status"] in ("passed", "failed") else count in (0, 1), f"Swift Testing start count for {key}: {count}")
        case_count = sum(cases[key].values())
        if status["parameter_count"] is not None:
            check(case_count == status["parameter_count"], f"Parameter case count differs for {key}: {case_count} starts/{status['parameter_count']} completed")
        else:
            check(case_count == 0, f"Parameter starts without aggregate case completion: {key}")
    check(set(swstarts) <= set(swends), f"Swift Testing started without completion in {path}")
    check(set(cases) <= set(swends), f"Parameter case has no declaration completion in {path}")
    if strict:
        require(not issues, "\n".join(issues))
    return {"xctest": xends, "swift_testing": swends,
            "parameter_cases": {k: dict(sorted(v.items())) for k, v in cases.items() if v},
            "known_or_skipped_log_lines": known_or_skipped,
            "diagnostic_gaps": issues}


def xml_ids(paths, inventory, strict=True):
    found = {}
    for path in paths:
        require(path.is_file(), f"Missing Swift Testing XML: {path}")
        root = ET.parse(path).getroot()
        for case in root.iter("testcase"):
            key = xml_identity(case.attrib.get("classname", ""), case.attrib.get("name", ""), inventory)
            require(key not in found, f"Duplicate XML declaration: {key}")
            failures = list(case.iter("failure")) + list(case.iter("error"))
            if strict:
                require(not failures, f"XML failed declaration: {key}")
            skipped = list(case.iter("skipped"))
            found[key] = {"status": "failed" if failures else ("skipped" if skipped else "passed"),
                "skip_records": [{"attributes": n.attrib, "text": "".join(n.itertext())} for n in skipped]}
    return found


def parse_run(spec, inventory, displays):
    directory = Path(spec["directory"]).resolve()
    expected = inventory if spec.get("expected_ids") is None else ids(spec["expected_ids"])
    require(expected <= inventory, f"Selected IDs outside ordinary inventory: {directory}")
    result = json.loads((directory / "result.json").read_text())
    require(result["exit_code"] == 0 and not result["changed_inputs"], f"Failed/changed source run: {directory}")
    require(result["log_sha256"] == sha(directory / "native.log"), f"Native log hash mismatch: {directory}")
    before = json.loads((directory / "source-before.json").read_text())
    after = json.loads((directory / "source-after.json").read_text())
    require(before == after, f"Source changed: {directory}")
    event_log = directory / "native.log"
    stream_files = []
    if "native_streams" in result:
        require(result.get("capture_complete") is True and result.get("capture_threads_joined") is True
                and result.get("capture_errors") == [] and result.get("wrapper_exit_code") == 0,
                f"Incomplete stream capture: {directory}")
        require(set(result["native_streams"]) == {"stdout", "stderr"}, f"Missing/unexpected captured streams: {directory}")
        for kind in ("stdout", "stderr"):
            record = result["native_streams"][kind]
            path = directory / ("native." + kind)
            require(sha(path) == record["sha256"] and path.stat().st_size == record["bytes"],
                    f"Raw {kind} hash/length mismatch: {directory}")
            require(not SANITIZER_REPORT.search(path.read_bytes().decode("utf-8")),
                    f"Sanitizer report in {path}")
            stream_files.append(path)
        event_log = directory / "native.stdout"
    log = parse_log(event_log, {v: k for k, v in displays.items()})
    xml_paths = [Path(v).resolve() for v in spec.get("swift_testing_xml", [str(directory / "report-swift-testing.xml")])]
    xml = xml_ids(xml_paths, inventory)
    require(set(log["swift_testing"]) == set(xml), f"Swift Testing log/XML ID mismatch: {directory}: log-only={sorted(set(log['swift_testing'])-set(xml))}, XML-only={sorted(set(xml)-set(log['swift_testing']))}")
    require(set(log["xctest"]).isdisjoint(xml), f"Framework ID overlap: {directory}")
    actual = set(log["xctest"]) | set(xml)
    require(actual == expected, f"Execution/inventory mismatch {directory}: missing={sorted(expected-actual)}, extra={sorted(actual-expected)}")
    for key in xml:
        require(xml[key]["status"] == log["swift_testing"][key]["status"], f"XML/log status mismatch: {key}")
    statuses = {**log["xctest"], **{k: v["status"] for k, v in xml.items()}}
    return {"label": spec["label"], "directory": str(directory), "source": before,
        "expected_ids": sorted(expected), "statuses": statuses, "swift_xml": xml,
        "runtime": log, "event_stream": str(event_log),
        "files": {str(p): sha(p) for p in [directory / "command.json", directory / "result.json", directory / "native.log", directory / "source-before.json", directory / "source-after.json", *xml_paths, *stream_files]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    require(not args.output.exists(), "Refusing to overwrite an existing proof")
    spec = json.loads(args.spec.read_text())
    inventory = ids(spec["inventory"])
    source = Path(spec["source"]).resolve()
    displays, title_receipts = display_map(source, inventory)
    ordinary = parse_run(spec["ordinary"], inventory, displays)
    require(set(ordinary["expected_ids"]) == inventory, "Ordinary run is not the full inventory")
    partitions = [parse_run(v, inventory, displays) for v in spec["partitions"]]
    require(len(partitions) == 2, "Exactly two sanitizer partitions are required")
    seen = set()
    statuses, cases, completions = {}, {}, {}
    for run in partitions:
        require(run["source"] == ordinary["source"], f"Different source manifest: {run['label']}")
        require(seen.isdisjoint(run["expected_ids"]), f"Partition overlap: {run['label']}")
        seen.update(run["expected_ids"])
        statuses.update(run["statuses"])
        cases.update(run["runtime"]["parameter_cases"])
        completions.update(run["runtime"]["swift_testing"])
    require(seen == inventory, "Partition union is not the full inventory")
    require(statuses == ordinary["statuses"], "Ordinary/sanitized statuses differ; inspect newly skipped/unexecuted declarations")
    require(cases == ordinary["runtime"]["parameter_cases"], "Ordinary/sanitized parameter argument multisets differ")
    # Compare status/count, not skip reason text (which may include environment paths).
    shape = lambda values: {k: (v["status"], v["parameter_count"]) for k, v in values.items()}
    require(shape(completions) == shape(ordinary["runtime"]["swift_testing"]), "Ordinary/sanitized declaration completion counts differ")
    for relative, digest in ordinary["source"].items():
        if relative.startswith("Tests/"):
            require(sha(source / relative) == digest, f"Display-map source mismatch: {relative}")
    for run in [ordinary, *partitions]:
        del run["source"]
    report = {"state": "COMPLETE_PARTITIONED_RUNTIME_COVERAGE", "spec_sha256": sha(args.spec),
        "helper_sha256": sha(Path(__file__)), "inventory_sha256": sha(Path(spec["inventory"])),
        "source_manifest_sha256": ordinary["files"][str(Path(ordinary["directory"]) / "source-before.json")],
        "declared_tests": len(inventory), "parameter_declarations": len(cases),
        "parameter_argument_starts": sum(sum(v.values()) for v in cases.values()),
        "unexecuted_declarations": sorted(k for k, v in statuses.items() if v == "skipped"),
        "boundaries": ["Coverage reconciliation does not confer R3 acceptance or independent peer qualification.",
            "Skipped declarations remain unexecuted even when the runner exits successfully.",
            "Case-level proof uses exact argument-start multisets plus each parameter declaration's matching successful aggregate case count; the installed reporter does not emit per-argument completion IDs.",
            "This is partitioned sanitizer coverage, not concurrent cross-target sanitizer execution.",
            "Simple source title binding is format-specific and fails on unsupported or ambiguous names; source hashes and bindings are retained for review.",
            "Known-issue/skip text is retained for separate review; no such text is silently promoted to external-oracle success."],
        "display_bindings": displays, "title_source_receipts": title_receipts,
        "ordinary": ordinary, "partitions": partitions}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: report[k] for k in ("state", "declared_tests", "parameter_declarations", "parameter_argument_starts", "unexecuted_declarations")}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, KeyError, ET.ParseError) as exc:
        print(f"Runtime coverage NOT ESTABLISHED: {exc}", file=sys.stderr)
        raise SystemExit(1)
