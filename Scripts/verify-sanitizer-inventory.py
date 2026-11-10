#!/usr/bin/env python3
"""Verify compiled test declaration inventory against the checked-in R3/12.2.0
scope ledger (full 1,385 macOS declarations across SwiftJ2KTests, SwiftJ2K3DTests,
and SwiftJ2KJPIPTests; 0 held declarations; exact JPIP/complement sanitizer
partition), and reconcile executed XCTest + Swift Testing outputs and
parameterised case logs after test execution completes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


DEFAULT_LEDGER = Path("Documentation/Engineering/Remediation/R3_HELD_VALIDATION_LEDGER.json")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inventory(label: str, argv: list[str], directory: Path) -> tuple[set[str], dict]:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    (directory / f"{label}.stdout").write_bytes(result.stdout)
    (directory / f"{label}.stderr").write_bytes(result.stderr)
    receipt = {
        "command": argv,
        "exit_code": result.returncode,
        "stdout_sha256": sha(result.stdout),
        "stderr_sha256": sha(result.stderr),
    }
    (directory / f"{label}.command-result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if result.returncode:
        sys.stderr.buffer.write(result.stderr)
        raise RuntimeError(f"{label} inventory failed: exit {result.returncode}")
    lines = result.stdout.decode("utf-8").splitlines()
    ids = [line for line in lines if line]
    if not ids or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*[./]\S+", line) for line in ids):
        raise RuntimeError(f"{label}: empty or unrecognised inventory stdout; inspect the raw files")
    if len(ids) != len(set(ids)):
        raise RuntimeError(f"{label}: duplicate declaration identity; inspect framework naming before proceeding")
    return set(ids), receipt


def load_and_validate_ledger(ledger_path: Path) -> tuple[dict, str]:
    raw = ledger_path.read_bytes()
    ledger_sha = sha(raw)
    ledger = json.loads(raw.decode("utf-8"))
    if ledger.get("schema") != "swiftj2k-r3-owner-scope-ledger-v2":
        raise RuntimeError(f"Unexpected ledger schema in {ledger_path}: {ledger.get('schema')!r}")
    if ledger.get("held_ids_all") != [] or ledger.get("counts", {}).get("held_declarations_total") != 0:
        raise RuntimeError(f"Expected 0 held declarations in {ledger_path}")
    return ledger, ledger_sha


def canonical_xml_id(classname: str, name: str) -> str:
    if "." in classname:
        return f"{classname}/{name}"
    return f"{classname}.{name}"


def verify_executed_run(
    sanitizer: str,
    ledger: dict,
    ledger_sha: str,
    output_dir: Path,
    xml_paths: list[Path],
    log_paths: list[Path],
) -> None:
    if not xml_paths:
        raise RuntimeError("At least one --verify-executed-xml path is required")
    if not log_paths:
        raise RuntimeError("At least one --verify-executed-log path is required for XCTest and parameterised reconciliation")

    resolved_xml_records: list[dict[str, str]] = []
    st_observed_ids: list[str] = []
    st_passed_ids: list[str] = []
    st_skipped_ids: list[str] = []
    st_failed_ids: list[str] = []

    for xml_arg in xml_paths:
        candidates: list[Path] = []
        if xml_arg.name.endswith(".xml") and not xml_arg.name.endswith("-swift-testing.xml"):
            st_cand = xml_arg.with_name(xml_arg.stem + "-swift-testing.xml")
            if st_cand.exists():
                candidates.append(st_cand)
            if xml_arg.exists():
                candidates.append(xml_arg)
        elif xml_arg.exists():
            candidates.append(xml_arg)
        if not candidates:
            raise RuntimeError(f"Executed XML not found for {xml_arg}")
        for resolved_xml in candidates:
            xml_bytes = resolved_xml.read_bytes()
            resolved_xml_records.append({"path": str(resolved_xml), "sha256": sha(xml_bytes)})
            root = ET.fromstring(xml_bytes.decode("utf-8"))
            for tc in root.findall(".//testcase"):
                cn = tc.attrib.get("classname", "")
                nm = tc.attrib.get("name", "")
                if not cn or not nm:
                    raise RuntimeError(f"Malformed testcase element in {resolved_xml}: {tc.attrib}")
                cid = canonical_xml_id(cn, nm)
                st_observed_ids.append(cid)
                if tc.find("failure") is not None or tc.find("error") is not None:
                    st_failed_ids.append(cid)
                elif tc.find("skipped") is not None:
                    st_skipped_ids.append(cid)
                else:
                    st_passed_ids.append(cid)

    if len(st_observed_ids) != len(set(st_observed_ids)):
        raise RuntimeError("Duplicate Swift Testing / XML testcase execution detected across XML inputs")

    xct_started_ids: list[str] = []
    xct_passed_ids: list[str] = []
    xct_skipped_ids: list[str] = []
    xct_failed_ids: list[str] = []
    xct_nonzero_failure_summaries: list[str] = []
    sanitizer_banners: list[str] = []
    log_records: list[dict[str, str]] = []

    selected_expected = set(ledger["selected_macos_ids"])
    held_expected = set(ledger["held_ids_all"])
    oracle_expected = set(ledger["five_ordinary_external_oracle_skips"])

    param_expected: dict[str, int] = {
        **ledger["selected_parameterised_case_counts_common"],
        **ledger["macos_only_parameterised_case_counts"],
    }
    oracle_param_expected: dict[str, int] = ledger["oracle_parameterised_case_counts_when_installed"]
    stdout_label_map: dict[str, str] = dict(ledger.get("parameterised_stdout_labels", {}))

    short_to_full: dict[str, str] = dict(stdout_label_map)
    for cid in selected_expected:
        short = cid.split("/")[-1] if "/" in cid else cid.split(".", 1)[1]
        short_to_full[short] = cid

    param_observed: dict[str, int] = {}

    for log_path in log_paths:
        if not log_path.exists():
            raise RuntimeError(f"Executed test log not found at {log_path}")
        raw_log = log_path.read_bytes()
        log_records.append({"path": str(log_path), "sha256": sha(raw_log)})
        log_text = raw_log.decode("utf-8", errors="replace")

        for raw in re.findall(r"Test Case '-\[([^\]]+)\]' started\.", log_text):
            cls, meth = raw.split(" ", 1)
            xct_started_ids.append(f"{cls}/{meth}")
        for raw in re.findall(r"Test Case '-\[([^\]]+)\]' passed \([0-9.]+ seconds\)\.", log_text):
            cls, meth = raw.split(" ", 1)
            xct_passed_ids.append(f"{cls}/{meth}")
        for raw in re.findall(r"Test Case '-\[([^\]]+)\]' skipped", log_text):
            cls, meth = raw.split(" ", 1)
            xct_skipped_ids.append(f"{cls}/{meth}")
        for raw in re.findall(r"Test Case '-\[([^\]]+)\]' failed", log_text):
            cls, meth = raw.split(" ", 1)
            xct_failed_ids.append(f"{cls}/{meth}")

        for m in re.finditer(r"Executed (\d+) tests?, with (\d+) failures?", log_text):
            if int(m.group(2)) != 0:
                xct_nonzero_failure_summaries.append(m.group(0))

        for line in log_text.splitlines():
            if (
                "ERROR: AddressSanitizer:" in line
                or "ERROR: LeakSanitizer:" in line
                or "WARNING: ThreadSanitizer:" in line
            ):
                sanitizer_banners.append(line.strip())

        for label, count_str in re.findall(r'Test ("[^"]+"|[^\s]+) with (\d+) test cases? passed', log_text):
            if label in short_to_full:
                param_observed[short_to_full[label]] = int(count_str)

    # On Linux, XCTest cases may also appear in XML; deduplicate only if identical IDs appear in both XCTest stdout and XCTest XML,
    # while still catching duplicate XCTest runs across separate log invocations.
    if len(xct_started_ids) != len(set(xct_started_ids)):
        raise RuntimeError("Duplicate XCTest execution detected across test logs")

    xct_terminal = set(xct_passed_ids) | set(xct_skipped_ids) | set(xct_failed_ids)
    xct_unterminated = sorted(set(xct_started_ids) - xct_terminal)

    observed_set = set(st_observed_ids) | set(xct_started_ids)
    passed_set = set(st_passed_ids) | set(xct_passed_ids)
    skipped_set = set(st_skipped_ids) | set(xct_skipped_ids)
    failed_set = set(st_failed_ids) | set(xct_failed_ids)
    framework_overlap = sorted(set(st_observed_ids) & set(xct_started_ids))

    missing_selected = sorted(selected_expected - observed_set)
    extra_observed = sorted(observed_set - selected_expected)
    held_executed = sorted(observed_set & held_expected)
    unexpected_skips = sorted(skipped_set - oracle_expected)

    param_mismatches: dict[str, dict] = {}
    for cid, exp_count in sorted(param_expected.items()):
        obs_count = param_observed.get(cid)
        if obs_count != exp_count:
            param_mismatches[cid] = {"expected_cases": exp_count, "observed_cases": obs_count}
    for cid, exp_count in sorted(oracle_param_expected.items()):
        if cid in passed_set:
            obs_count = param_observed.get(cid)
            if obs_count != exp_count:
                param_mismatches[cid] = {"expected_cases": exp_count, "observed_cases": obs_count}

    reconciliation = {
        "schema": "swiftj2k-r3-macos-execution-reconciliation-v2",
        "sanitizer": sanitizer,
        "ledger_sha256": ledger_sha,
        "xml_files": resolved_xml_records,
        "log_files": log_records,
        "counts": {
            "expected_selected_declarations": len(selected_expected),
            "observed_declarations": len(observed_set),
            "observed_xctest_declarations": len(set(xct_started_ids)),
            "observed_swift_testing_declarations": len(set(st_observed_ids)),
            "passed_declarations": len(passed_set),
            "skipped_oracle_declarations": len(skipped_set),
            "failed_declarations": len(failed_set),
            "unterminated_xctest_declarations": len(xct_unterminated),
            "held_declarations_executed": len(held_executed),
            "parameterised_non_oracle_declarations_verified": len(param_expected) - sum(
                1 for k in param_mismatches if k in param_expected
            ),
            "parameterised_non_oracle_total_cases_expected": sum(param_expected.values()),
            "parameterised_non_oracle_total_cases_observed": sum(
                param_observed.get(k, 0) for k in param_expected
            ),
        },
        "skipped_oracle_ids": sorted(skipped_set),
        "missing_selected_ids": missing_selected,
        "extra_observed_ids": extra_observed,
        "framework_overlap_ids": framework_overlap,
        "unterminated_xctest_ids": xct_unterminated,
        "held_executed_ids": held_executed,
        "unexpected_skipped_ids": unexpected_skips,
        "failed_ids": sorted(failed_set),
        "xct_nonzero_failure_summaries": xct_nonzero_failure_summaries,
        "sanitizer_banners": sanitizer_banners,
        "parameterised_case_mismatches": param_mismatches,
        "exact_selected_match": (
            not missing_selected
            and not extra_observed
            and not framework_overlap
            and not xct_unterminated
            and not held_executed
            and not unexpected_skips
            and not failed_set
            and not xct_nonzero_failure_summaries
            and not sanitizer_banners
            and not param_mismatches
        ),
    }
    (output_dir / "execution-reconciliation.json").write_text(json.dumps(reconciliation, indent=2) + "\n")
    print(json.dumps(reconciliation, indent=2))
    if not reconciliation["exact_selected_match"]:
        raise RuntimeError(
            f"Execution reconciliation failed for {sanitizer}: "
            f"missing={len(missing_selected)}, extra={len(extra_observed)}, "
            f"unterminated_xct={len(xct_unterminated)}, held_executed={len(held_executed)}, "
            f"unexpected_skips={len(unexpected_skips)}, failed={len(failed_set)}, "
            f"sanitizer_banners={len(sanitizer_banners)}, param_mismatches={len(param_mismatches)}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitizer", choices=["ordinary", "address", "thread"], required=True)
    parser.add_argument("--scratch-path", required=True)
    parser.add_argument("--reference-scratch-path", default=".build")
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-executed-xml", type=Path, action="append", default=[])
    parser.add_argument("--verify-executed-log", type=Path, action="append", default=[])
    parser.add_argument(
        "--swift-option",
        action="append",
        default=[],
        help="Additional common SwiftPM option; repeat with --swift-option=VALUE",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    ledger, ledger_sha = load_and_validate_ledger(args.ledger)

    if args.verify_executed_xml:
        verify_executed_run(
            args.sanitizer,
            ledger,
            ledger_sha,
            args.output,
            args.verify_executed_xml,
            args.verify_executed_log,
        )
        return

    common = args.swift_option
    reference, ref_receipt = inventory(
        "reference",
        ["swift", "test", "list", "--skip-build", "--scratch-path", args.reference_scratch_path, *common],
        args.output,
    )
    if args.sanitizer == "ordinary":
        sanitized, san_receipt = inventory(
            "sanitized",
            ["swift", "test", "list", "--skip-build", "--scratch-path", args.scratch_path, *common],
            args.output,
        )
    else:
        sanitized, san_receipt = inventory(
            "sanitized",
            ["swift", "test", "list", "--scratch-path", args.scratch_path, "--sanitize", args.sanitizer, *common],
            args.output,
        )

    if reference != sanitized:
        delta = {
            "missing_from_sanitizer": sorted(reference - sanitized),
            "extra_in_sanitizer": sorted(sanitized - reference),
        }
        (args.output / "inventory-mismatch.json").write_text(json.dumps(delta, indent=2) + "\n")
        raise RuntimeError("Ordinary/sanitized inventories differ; no omitted declaration is permitted")

    selected_ledger = set(ledger["selected_macos_ids"])
    held_ledger = set(ledger["held_ids_all"])
    inapplicable_ios = set(ledger["inapplicable_macos_only_cli_process_declarations_on_ios"]["all"])
    ios_only = set(ledger["ios_only_declarations"]["all"])
    selected_ios = set(ledger["selected_ios_simulator_ids"])
    oracle_skips = set(ledger["five_ordinary_external_oracle_skips"])

    jpip_re = ledger["selection_arguments"]["macos_swift_test"]["sanitizer_jpip_filter_regex"]
    comp_skip_re = ledger["selection_arguments"]["macos_swift_test"]["sanitizer_complement_skip_regex"]
    jpip_part = {name for name in sanitized if re.search(jpip_re, name)}
    comp_part = {name for name in sanitized if not re.search(comp_skip_re, name)}

    if (
        not selected_ledger
        or held_ledger
        or selected_ledger != sanitized
        or not jpip_part
        or not comp_part
        or (jpip_part & comp_part)
        or (jpip_part | comp_part) != sanitized
        or not (inapplicable_ios <= selected_ledger)
        or (ios_only & selected_ledger)
        or ((selected_ledger - inapplicable_ios) | ios_only) != selected_ios
        or not (oracle_skips <= selected_ios)
    ):
        mismatch = {
            "missing_from_ledger": sorted(sanitized - selected_ledger),
            "extra_in_ledger": sorted(selected_ledger - sanitized),
            "held_ids": sorted(held_ledger),
            "partition_overlap": sorted(jpip_part & comp_part),
            "partition_missing": sorted(sanitized - (jpip_part | comp_part)),
        }
        (args.output / "inventory-mismatch.json").write_text(json.dumps(mismatch, indent=2) + "\n")
        raise RuntimeError("Ledger or JPIP/complement partition mismatch against discovered inventory")

    for name, values in [
        ("all", sanitized),
        ("selected", selected_ledger),
        ("held", held_ledger),
        ("jpip", jpip_part),
        ("complement", comp_part),
        ("inapplicable-ios", inapplicable_ios),
        ("ios-only", ios_only),
        ("oracle-skips", oracle_skips),
    ]:
        (args.output / f"{name}.ids").write_text(("\n".join(sorted(values)) + "\n") if values else "")

    report = {
        "schema": "swiftj2k-r3-owner-scope-inventory-v2",
        "sanitizer": args.sanitizer,
        "ledger_path": str(args.ledger),
        "ledger_sha256": ledger_sha,
        "authority": ledger["authority"],
        "reference": ref_receipt,
        "sanitized": san_receipt,
        "selection_arguments": ledger["selection_arguments"]["macos_swift_test"],
        "counts": {
            "all_declarations": len(sanitized),
            "selected_macos_declarations": len(selected_ledger),
            "jpip_partition_declarations": len(jpip_part),
            "complement_partition_declarations": len(comp_part),
            "held_declarations": len(held_ledger),
            "inapplicable_ios_declarations_total": len(inapplicable_ios),
            "ios_only_declarations_total": len(ios_only),
            "selected_ios_simulator_declarations": len(selected_ios),
            "ordinary_external_oracle_skips": len(oracle_skips),
            "direct_external_interoperability_holds": len(ledger["five_direct_external_interoperability_holds"]),
        },
        "equal_to_ordinary": True,
        "zero_held_declarations": True,
        "disjoint_jpip_and_complement": True,
        "union_equals_full_discovered": True,
        "scope": (
            "12.2.0 un-held full R3 scope (7 Nov 2026): executes all 1,385 discovered macOS declarations "
            "across SwiftJ2KTests, SwiftJ2K3DTests, and SwiftJ2KJPIPTests (and all 1,375 compiled iOS Simulator "
            "declarations) with 0 held declarations."
        ),
    }
    (args.output / "inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print("BEGIN EXACT SANITIZED INVENTORY STDOUT")
    sys.stdout.flush()
    sys.stdout.buffer.write((args.output / "sanitized.stdout").read_bytes())
    sys.stdout.flush()
    print("END EXACT SANITIZED INVENTORY STDOUT")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, RuntimeError, ET.ParseError) as exc:
        print(f"Sanitizer inventory verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
