#!/usr/bin/env python3
"""Inventory only: build/list the requested sanitizer, verify an exact two-way partition.
This script does not execute tests. The subsequent workflow commands execute both sets.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

JPIP = r"^SwiftJ2KJPIPTests[./]"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def inventory(label, argv, directory):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    (directory / f"{label}.stdout").write_bytes(result.stdout)
    (directory / f"{label}.stderr").write_bytes(result.stderr)
    receipt = {"command": argv, "exit_code": result.returncode,
               "stdout_sha256": sha(result.stdout), "stderr_sha256": sha(result.stderr)}
    (directory / f"{label}.command-result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if result.returncode:
        sys.stderr.buffer.write(result.stderr)
        raise RuntimeError(f"{label} inventory failed: exit {result.returncode}")
    # Build progress/diagnostics belong to stderr. Fail instead of silently dropping
    # any unrecognised stdout line or accepting a truncated/deprecation-spliced ID.
    lines = result.stdout.decode("utf-8").splitlines()
    ids = [line for line in lines if line]
    if not ids or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*[./]\S+", line) for line in ids):
        raise RuntimeError(f"{label}: empty or unrecognised inventory stdout; inspect the raw files")
    if len(ids) != len(set(ids)):
        raise RuntimeError(f"{label}: duplicate declaration identity; inspect framework naming before proceeding")
    return set(ids), receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitizer", choices=["address", "thread"], required=True)
    parser.add_argument("--scratch-path", required=True)
    parser.add_argument("--reference-scratch-path", default=".build")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift-option", action="append", default=[],
                        help="Additional common SwiftPM option; repeat with --swift-option=VALUE")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    common = args.swift_option
    reference, ref_receipt = inventory("reference", ["swift", "test", "list", "--skip-build",
        "--scratch-path", args.reference_scratch_path, *common], args.output)
    sanitized, san_receipt = inventory("sanitized", ["swift", "test", "list", "--scratch-path",
        args.scratch_path, "--sanitize", args.sanitizer, *common], args.output)
    if reference != sanitized:
        delta = {"missing_from_sanitizer": sorted(reference - sanitized),
                 "extra_in_sanitizer": sorted(sanitized - reference)}
        (args.output / "inventory-mismatch.json").write_text(json.dumps(delta, indent=2) + "\n")
        raise RuntimeError("Ordinary/sanitized inventories differ; no omitted declaration is permitted")
    jpip = {name for name in sanitized if re.search(JPIP, name)}
    complement = sanitized - jpip
    if not jpip or not complement or jpip & complement or jpip | complement != sanitized:
        raise RuntimeError("Partition empty, overlapping or incomplete")
    for name, values in [("all", sanitized), ("jpip", jpip), ("complement", complement)]:
        (args.output / f"{name}.ids").write_text("\n".join(sorted(values)) + "\n")
    report = {"sanitizer": args.sanitizer, "reference": ref_receipt, "sanitized": san_receipt,
              "selection_regex": JPIP, "jpip_arguments": ["--filter", JPIP],
              "complement_arguments": ["--skip", JPIP],
              "counts": {"all_declarations": len(sanitized), "jpip_declarations": len(jpip),
                         "complement_declarations": len(complement)},
              "equal_to_ordinary": True, "disjoint": True, "union_equals_full": True,
              "scope": "Discovered declarations; parameterised cases must also finish in the actual test runs."}
    (args.output / "inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    # Make the exact captured inventory inspectable in hosted step logs as well as
    # the raw .stdout/.stderr files; no output filtering can hide a failed command.
    print("BEGIN EXACT SANITIZED INVENTORY STDOUT")
    sys.stdout.flush()
    sys.stdout.buffer.write((args.output / "sanitized.stdout").read_bytes())
    sys.stdout.flush()
    print("END EXACT SANITIZED INVENTORY STDOUT")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, RuntimeError) as exc:
        print(f"Sanitizer inventory verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
