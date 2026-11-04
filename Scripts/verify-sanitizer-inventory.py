#!/usr/bin/env python3
"""Verify compiled test declaration inventory against the checked-in R3 owner scope
ledger (selected core vs held JPIP/3D vs iOS-inapplicable vs ordinary external-oracle
skips), and optionally reconcile executed Swift Testing XML and parameterised case
logs after a test run completes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Optional
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
    if ledger.get("schema") != "swiftj2k-r3-owner-scope-ledger-v1":
        raise RuntimeError(f"Unexpected ledger schema in {ledger_path}")
    return ledger, ledger_sha


def verify_executed_run(
    sanitizer: str,
    ledger: dict,
    ledger_sha: str,
    output_dir: Path,
    xml_path: Path,
    log_path: Optional[Path],
) -> None:
    candidates = [xml_path]
    if xml_path.name.endswith(".xml") and not xml_path.name.endswith("-swift-testing.xml"):
        candidates.insert(0, xml_path.with_name(xml_path.stem + "-swift-testing.xml"))
    resolved_xml = next((p for p in candidates if p.exists()), None)
    if resolved_xml is None:
        raise RuntimeError(f"Executed Swift Testing XML not found at {xml_path}")

    xml_bytes = resolved_xml.read_bytes()
    root = ET.fromstring(xml_bytes.decode("utf-8"))
    testcases = root.findall(".//testcase")

    observed_ids: list[str] = []
    passed_ids: list[str] = []
    skipped_ids: list[str] = []
    failed_ids: list[str] = []

    for tc in testcases:
        cn = tc.attrib.get("classname", "")
        nm = tc.attrib.get("name", "")
        if not cn or not nm:
            raise RuntimeError(f"Malformed testcase element in {resolved_xml}: {tc.attrib}")
        cid = f"{cn}.{nm}" if cn == "SwiftJ2KTests" else f"{cn}/{nm}"
        observed_ids.append(cid)
        if tc.find("failure") is not None or tc.find("error") is not None:
            failed_ids.append(cid)
        elif tc.find("skipped") is not None:
            skipped_ids.append(cid)
        else:
            passed_ids.append(cid)

    if len(observed_ids) != len(set(observed_ids)):
        raise RuntimeError(f"Duplicate testcase execution in {resolved_xml}")

    selected_expected = set(ledger["selected_macos_core_ids"])
    held_expected = set(ledger["held_ids_all"])
    oracle_expected = set(ledger["five_ordinary_external_oracle_skips"])
    observed_set = set(observed_ids)

    missing_selected = sorted(selected_expected - observed_set)
    extra_observed = sorted(observed_set - selected_expected)
    held_executed = sorted(observed_set & held_expected)
    unexpected_skips = sorted(set(skipped_ids) - oracle_expected)

    param_expected: dict[str, int] = ledger["selected_parameterised_case_counts"]
    oracle_param_expected: dict[str, int] = ledger["oracle_parameterised_case_counts_when_installed"]
    param_observed: dict[str, int] = {}
    param_mismatches: dict[str, dict] = {}

    if log_path is not None:
        if not log_path.exists():
            raise RuntimeError(f"Executed test log not found at {log_path}")
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        short_to_full = {}
        for cid in selected_expected:
            short = cid.split("/")[-1] if "/" in cid else cid.split(".", 1)[1]
            short_to_full[short] = cid
        for short_name, count_str in re.findall(r"Test ([^\s]+) with (\d+) test cases? passed", log_text):
            if short_name in short_to_full:
                param_observed[short_to_full[short_name]] = int(count_str)
        for cid, exp_count in sorted(param_expected.items()):
            obs_count = param_observed.get(cid)
            if obs_count != exp_count:
                param_mismatches[cid] = {"expected_cases": exp_count, "observed_cases": obs_count}
        for cid, exp_count in sorted(oracle_param_expected.items()):
            if cid in passed_ids:
                obs_count = param_observed.get(cid)
                if obs_count != exp_count:
                    param_mismatches[cid] = {"expected_cases": exp_count, "observed_cases": obs_count}

    reconciliation = {
        "schema": "swiftj2k-r3-macos-execution-reconciliation-v1",
        "sanitizer": sanitizer,
        "ledger_sha256": ledger_sha,
        "xml_path": str(resolved_xml),
        "xml_sha256": sha(xml_bytes),
        "log_path": str(log_path) if log_path else None,
        "log_sha256": sha(log_path.read_bytes()) if (log_path and log_path.exists()) else None,
        "counts": {
            "expected_selected_declarations": len(selected_expected),
            "observed_declarations": len(observed_set),
            "passed_declarations": len(passed_ids),
            "skipped_oracle_declarations": len(skipped_ids),
            "failed_declarations": len(failed_ids),
            "held_declarations_executed": len(held_executed),
            "parameterised_non_oracle_declarations_verified": len(param_expected) - len(param_mismatches),
            "parameterised_non_oracle_total_cases_expected": sum(param_expected.values()),
            "parameterised_non_oracle_total_cases_observed": sum(
                param_observed.get(k, 0) for k in param_expected
            ),
        },
        "skipped_oracle_ids": sorted(skipped_ids),
        "missing_selected_ids": missing_selected,
        "extra_observed_ids": extra_observed,
        "held_executed_ids": held_executed,
        "unexpected_skipped_ids": unexpected_skips,
        "failed_ids": sorted(failed_ids),
        "parameterised_case_mismatches": param_mismatches,
        "exact_selected_match": (
            not missing_selected
            and not extra_observed
            and not held_executed
            and not unexpected_skips
            and not failed_ids
            and not param_mismatches
        ),
    }
    (output_dir / "execution-reconciliation.json").write_text(json.dumps(reconciliation, indent=2) + "\n")
    print(json.dumps(reconciliation, indent=2))
    if not reconciliation["exact_selected_match"]:
        raise RuntimeError(
            f"Execution reconciliation failed for {sanitizer}: "
            f"missing={len(missing_selected)}, extra={len(extra_observed)}, "
            f"held_executed={len(held_executed)}, unexpected_skips={len(unexpected_skips)}, "
            f"failed={len(failed_ids)}, param_mismatches={len(param_mismatches)}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitizer", choices=["ordinary", "address", "thread"], required=True)
    parser.add_argument("--scratch-path", required=True)
    parser.add_argument("--reference-scratch-path", default=".build")
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-executed-xml", type=Path, default=None)
    parser.add_argument("--verify-executed-log", type=Path, default=None)
    parser.add_argument(
        "--swift-option",
        action="append",
        default=[],
        help="Additional common SwiftPM option; repeat with --swift-option=VALUE",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    ledger, ledger_sha = load_and_validate_ledger(args.ledger)

    if args.verify_executed_xml is not None:
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

    selected_ledger = set(ledger["selected_macos_core_ids"])
    held_ledger = set(ledger["held_ids_all"])
    inapplicable_ios = set(ledger["inapplicable_macos_only_cli_process_declarations_on_ios"]["all"])
    inapplicable_ios_selected = set(
        ledger["inapplicable_macos_only_cli_process_declarations_on_ios"]["in_selected_macos_core"]
    )
    inapplicable_ios_held = set(
        ledger["inapplicable_macos_only_cli_process_declarations_on_ios"]["in_held_cross_target"]
    )
    selected_ios = set(ledger["selected_ios_simulator_core_ids"])
    oracle_skips = set(ledger["five_ordinary_external_oracle_skips"])

    filter_re = ledger["selection_arguments"]["macos_swift_test"]["filter_regex"]
    skip_re = ledger["selection_arguments"]["macos_swift_test"]["skip_regex"]
    selected_by_regex = {name for name in sanitized if re.search(filter_re, name) and not re.search(skip_re, name)}
    held_by_regex = sanitized - selected_by_regex

    if (
        not selected_ledger
        or not held_ledger
        or (selected_ledger & held_ledger)
        or (selected_ledger | held_ledger) != sanitized
        or selected_by_regex != selected_ledger
        or held_by_regex != held_ledger
        or (inapplicable_ios_selected | inapplicable_ios_held) != inapplicable_ios
        or not (inapplicable_ios_selected <= selected_ledger)
        or not (inapplicable_ios_held <= held_ledger)
        or (selected_ledger - inapplicable_ios_selected) != selected_ios
        or not (oracle_skips <= selected_ios)
        or (oracle_skips & held_ledger)
    ):
        mismatch = {
            "missing_from_ledger_union": sorted(sanitized - (selected_ledger | held_ledger)),
            "extra_in_ledger_union": sorted((selected_ledger | held_ledger) - sanitized),
            "selected_held_overlap": sorted(selected_ledger & held_ledger),
            "regex_vs_ledger_selected_diff": sorted(selected_by_regex ^ selected_ledger),
            "regex_vs_ledger_held_diff": sorted(held_by_regex ^ held_ledger),
        }
        (args.output / "inventory-mismatch.json").write_text(json.dumps(mismatch, indent=2) + "\n")
        raise RuntimeError("Owner-scope ledger/regex partition mismatch against discovered inventory")

    for name, values in [
        ("all", sanitized),
        ("selected", selected_ledger),
        ("held", held_ledger),
        ("inapplicable-ios", inapplicable_ios),
        ("oracle-skips", oracle_skips),
    ]:
        (args.output / f"{name}.ids").write_text("\n".join(sorted(values)) + "\n")

    report = {
        "schema": "swiftj2k-r3-owner-scope-inventory-v1",
        "sanitizer": args.sanitizer,
        "ledger_path": str(args.ledger),
        "ledger_sha256": ledger_sha,
        "authority": ledger["authority"],
        "reference": ref_receipt,
        "sanitized": san_receipt,
        "selection_arguments": ledger["selection_arguments"]["macos_swift_test"],
        "counts": {
            "all_declarations": len(sanitized),
            "selected_macos_core_declarations": len(selected_ledger),
            "held_declarations": len(held_ledger),
            "held_swiftj2k3d_declarations": len(ledger["held_target_ids"]["SwiftJ2K3DTests"]),
            "held_swiftj2kjpip_declarations": len(ledger["held_target_ids"]["SwiftJ2KJPIPTests"]),
            "held_cross_target_swiftj2k_declarations": len(ledger["held_cross_target_ids"]),
            "inapplicable_ios_declarations_total": len(inapplicable_ios),
            "inapplicable_ios_in_selected_core": len(inapplicable_ios_selected),
            "inapplicable_ios_in_held_cross_target": len(inapplicable_ios_held),
            "selected_ios_simulator_core_declarations": len(selected_ios),
            "ordinary_external_oracle_skips": len(oracle_skips),
            "direct_external_interoperability_holds": len(ledger["five_direct_external_interoperability_holds"]),
        },
        "equal_to_ordinary": True,
        "disjoint_selected_and_held": True,
        "union_equals_full_discovered": True,
        "regex_matches_explicit_ledger": True,
        "scope": (
            "Owner-revised R3 scope (3 Nov 2026): executes only selected non-held SwiftJ2KTests "
            "core/2D-CLI declarations; holds SwiftJ2K3DTests, SwiftJ2KJPIPTests, and 8 cross-target "
            "JPIP/3D declarations in SwiftJ2KTests as ON_HOLD_BY_OWNER / DEFERRED_TO_FUTURE_RELEASE."
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
