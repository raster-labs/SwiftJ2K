#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate this standalone Milestone 1 package with the pinned Xcode toolchain."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

# Contract 0.5.0: Swift 6.2 is the manifest minimum and 6.4 the qualified
# primary toolchain, so both are accepted here. Pinning one exact build string
# made this script unrunnable on every machine but the one that produced the
# original evidence, and pinning a preview Xcode made it unrunnable in CI at
# all. The exact toolchain identity is still recorded in the report below; it
# is evidence, not an admission gate.
ACCEPTED_SWIFT = (
    re.compile(r"Apple Swift version 6\.2(\.\d+)?\b"),
    re.compile(r"Apple Swift version 6\.4(\.\d+)?\b"),
)
DEFAULT_CHECKS = "debug,release,consumer,repetition,sbom"
CHECKS = {"debug", "release", "consumer", "repetition", "sbom", "asan", "tsan"}
REPETITION_FILTER = r"(?i)(cancell|writer|lease|retain|concurrent|publication)"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New evidence directory; never reuse an earlier run")
    parser.add_argument("--checks", default=DEFAULT_CHECKS, help="Comma-separated debug,release,consumer,repetition,sbom,asan,tsan; or all")
    parser.add_argument("--sanitizers", action="store_true", help="Add separate AddressSanitizer and ThreadSanitizer runs")
    parser.add_argument("--jobs", type=int, default=2, help="Build workers per command (1..32; default 2)")
    parser.add_argument("--repetitions", type=int, default=5, help="Fixed repetitions for selected lifetime/cancellation cases (2..50)")
    parser.add_argument("--disable-package-sandbox", action="store_true", help="Explicit nested SwiftPM sandbox workaround; does not change the host sandbox")
    parser.add_argument("--timeout", type=int, default=600, help="Maximum seconds per command")
    args = parser.parse_args()
    selected = CHECKS.copy() if args.checks == "all" else set(args.checks.split(","))
    if args.sanitizers:
        selected.update({"asan", "tsan"})
    if not selected or not selected <= CHECKS or not 2 <= args.repetitions <= 50 or args.timeout < 1 or not 1 <= args.jobs <= 32:
        parser.error("Use recognised nonempty checks, 2..50 repetitions, 1..32 jobs and a positive timeout")
    repo = Path(__file__).resolve().parent.parent
    manifest = (repo / "Package.swift").read_text()
    match = re.search(r'name:\s*"(SwiftJ2K|SwiftJLS|SwiftJXL|SwiftJLI)"', manifest)
    if not match:
        parser.error("Expected a standalone successor package")
    name = match.group(1)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or repo / ".build" / "swift64-evidence" / f"{stamp}-{os.getpid()}").resolve()
    if output.exists():
        parser.error("Output already exists; use a new directory to preserve previous evidence")
    output.mkdir(parents=True)
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = env.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    env["CLANG_MODULE_CACHE_PATH"] = str(output / "clang-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "swift-cache")
    report = {"package": name, "repository": str(repo), "started_utc": stamp,
              "developer_dir": env["DEVELOPER_DIR"], "build_engine": "swiftbuild",
              "accepted_swift": [pattern.pattern for pattern in ACCEPTED_SWIFT],
              "selected_checks": sorted(selected), "not_run_checks": sorted(CHECKS - selected),
              "package_sandbox_disabled": args.disable_package_sandbox, "build_jobs": args.jobs,
              "commands": [], "test_runs": [], "sboms": [], "open_gates": [], "status": "running"}

    def save() -> None:
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label: str, argv: list[str], cwd: Path = repo) -> str:
        log = output / f"{label}.log"
        print(f"{name}: {label}", flush=True)
        started = time.monotonic()
        entry = {"label": label, "argv": argv, "cwd": str(cwd), "log": log.name}
        report["commands"].append(entry)
        try:
            result = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, timeout=args.timeout)
            text = result.stdout
            entry["exit_code"] = result.returncode
        except subprocess.TimeoutExpired as error:
            text = error.stdout or ""
            if isinstance(text, bytes):
                text = text.decode(errors="replace")
            entry["exit_code"] = None
            entry["timed_out"] = True
        log.write_text(text)
        entry["seconds"] = round(time.monotonic() - started, 3)
        save()
        if entry.get("timed_out") or entry["exit_code"] != 0:
            raise RuntimeError(f"{label} failed; see {log}")
        return text

    def swift(verb: str, scratch: str, package: Path = repo) -> list[str]:
        command = ["xcrun", "swift", verb, "--package-path", str(package),
                   "--scratch-path", str(output / "build" / scratch),
                   "--cache-path", str(output / "cache"), "--config-path", str(output / "config"),
                   "--security-path", str(output / "security"), "--build-system", "swiftbuild", "--jobs", str(args.jobs)]
        if args.disable_package_sandbox:
            command.append("--disable-sandbox")
        return command

    # Do not silently exclude future XCTest tests to work around an environment failure.
    xctest = any(re.search(r"\bimport\s+XCTest\b|:\s*XCTestCase\b", p.read_text())
                 for p in (repo / "Tests").rglob("*.swift"))
    frameworks = ["--enable-swift-testing", "--enable-xctest" if xctest else "--disable-xctest"]
    report["xctest_detected"] = xctest
    inventory: dict[str, list[str]] = {}

    def discover(label: str, config: str, extra: list[str]) -> list[str]:
        text = run(label + "-discovery", swift("test", label) + ["-c", config] + extra + ["list"] + frameworks)
        pattern = re.compile(rf"^{name}[A-Za-z0-9_]*Tests\..+\)$")
        names = [line.strip() for line in text.splitlines() if pattern.match(line.strip())]
        if not names:
            raise RuntimeError(f"{label}: zero discovered tests")
        inventory[label] = names
        report.setdefault("test_inventory", {})[label] = names
        save()
        return names

    def test(label: str, config: str, extra: list[str], repeat: bool = False) -> None:
        names = inventory[label]
        if repeat:
            names = [item for item in names if re.search(REPETITION_FILTER, item)]
            if not names:
                raise RuntimeError("Repetition filter selected zero discovered tests")
        xml = output / f"{label}-tests.xml"
        resolved_xml = xml
        argv = swift("test", label) + ["-c", config] + extra + frameworks + ["--skip-build", "--xunit-output", str(xml)]
        repetitions = args.repetitions if repeat else 1
        if repeat:
            argv += ["--filter", REPETITION_FILTER, "--maximum-repetitions", str(repetitions)]
        # No repeat-until-pass option: every failure remains a failure.
        try:
            text = run(label + "-tests", argv)
        finally:
            if not resolved_xml.exists():
                candidate = xml.with_name(xml.stem + "-swift-testing.xml")
                if candidate.exists():
                    resolved_xml = candidate
            if resolved_xml.exists():
                document = ET.parse(resolved_xml)
                cases = document.findall(".//testcase")
                counts = {"executed_declarations": len(cases),
                          "failed_declarations": sum(c.find("failure") is not None or c.find("error") is not None for c in cases),
                          "skipped_declarations": sum(c.find("skipped") is not None for c in cases)}
                counts["passed_declarations"] = counts["executed_declarations"] - counts["failed_declarations"] - counts["skipped_declarations"]
                report["test_runs"].append({"label": label, "discovered_declarations": len(names),
                    "repetitions": repetitions, "xml": resolved_xml.name, **counts})
                save()
        if not resolved_xml.exists() or counts["executed_declarations"] == 0:
            raise RuntimeError(f"{label}: no executed tests in xUnit evidence")
        if counts["executed_declarations"] != len(names):
            raise RuntimeError(f"{label}: discovered/executed declaration counts differ")
        if counts["failed_declarations"] or counts["skipped_declarations"]:
            raise RuntimeError(f"{label}: failed or skipped cases require disposition")
        # xUnit collapses parameterised cases/repetitions. Logs retain actual case starts.
        passed_cases = 0
        for line in text.splitlines():
            if re.search(r"\bTest (?!run\b|case\b).+ passed after", line):
                parameterised = re.search(r"with (\d+) test cases passed", line)
                passed_cases += int(parameterised.group(1)) if parameterised else 1
        record = report["test_runs"][-1]
        record["swift_testing_passed_case_executions"] = passed_cases * repetitions
        record["parameterised_case_start_events"] = len(re.findall(r"\bTest case passing .* started", text))
        record["repetition_start_events"] = len(re.findall(r"started \(repetition \d+\)", text))
        record["count_note"] = "xUnit counts declarations; passing Swift Testing case executions include argument cases and fixed repetitions. Raw logs retain every event. XCTest counts remain separate."
        save()

    try:
        actual_swift = run("swift-version", ["xcrun", "swift", "--version"])
        # Xcode is recorded when present. It is not required: the Linux gates and
        # a swift.org toolchain on macOS have no xcodebuild, and demanding one
        # would fail those runs for a reason unrelated to what is being checked.
        try:
            actual_xcode = run("xcode-version", ["xcrun", "xcodebuild", "-version"])
        except Exception:
            actual_xcode = "unavailable"
        if not any(pattern.search(actual_swift) for pattern in ACCEPTED_SWIFT):
            raise RuntimeError(
                "Swift 6.2 or 6.4 is required by contract 0.5.0 PLAT-01; found: "
                + actual_swift.strip().splitlines()[0]
            )
        report["toolchain_swift"] = actual_swift.strip()
        report["toolchain_xcode"] = actual_xcode.strip()
        report["source_commit"] = run("source-commit", ["git", "rev-parse", "HEAD"]).strip()
        report["working_tree"] = run("working-tree", ["git", "status", "--short"])
        report["manifest_sha256"] = hashlib.sha256(manifest.encode()).hexdigest()
        source_files = [repo / "Package.swift"]
        for folder in ("Sources", "Tests", "Scripts"):
            source_files.extend(p for p in (repo / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
        report["source_files_sha256"] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source_files)}
        resolved = repo / "Package.resolved"
        report["package_resolved_sha256"] = hashlib.sha256(resolved.read_bytes()).hexdigest() if resolved.exists() else None
        for verb in ("build", "test"):
            run(f"swift-{verb}-help", swift(verb, "help") + ["--help"])
        # Swift 6.2's `swift package` rejects a help flag placed after other
        # options and only accepts the bare form; 6.4 accepts both. Contract
        # 0.5.0 PLAT-01 admits both compilers, so the bare form is recorded.
        run("swift-package-help", ["xcrun", "swift", "package", "-help"])
        if "sbom" in selected:
            run("swift-sbom-help", swift("package", "help") + ["generate-sbom", "--help"])
        run("target-info", ["xcrun", "swiftc", "-print-target-info"])
        for config in ("debug", "release"):
            if config in selected:
                # Each invocation owns a fresh output tree. The second build reuses exactly that tree.
                command = swift("build", config) + ["-c", config]
                run(config + "-clean-build", command)
                run(config + "-incremental-build", command)
                discover(config, config, [])
                test(config, config, [])
        if "consumer" in selected:
            consumer = output / "consumer"
            (consumer / "Sources/Consumer").mkdir(parents=True)
            package_path = json.dumps(str(repo))
            (consumer / "Package.swift").write_text(
                '// swift-tools-version: 6.2\nimport PackageDescription\n'
                'let package = Package(name: "FreshConsumer", platforms: [.macOS(.v26)],\n'
                f' dependencies: [.package(path: {package_path})],\n'
                f' targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "{name}", package: "{name}")])],\n'
                ' swiftLanguageModes: [.v6])\n')
            (consumer / "Sources/Consumer/main.swift").write_text(
                f'import {name}\n'
                'let d = try ImageDescriptor.greyscale16(width: 3, height: 1, meaningfulBits: 16, rowBytes: 8)\n'
                'let image = try ImageDestination.allocate(descriptor: d).writeUInt16 { x, _ in [UInt16(0), 65535, 4095][x] }\n'
                'guard try image.sampleUInt16(x: 1, y: 0) == 65535 else { throw CodecError(.internalFailure, "Sample mismatch") }\n'
                'let encoder = try Encoder(), decoder = try Decoder()\n'
                'guard encoder.capabilities.canEncode, decoder.capabilities.canDecode else { throw CodecError(.internalFailure, "Scalar lossless coverage is not advertised") }\n'
                'let encoded = try await encoder.encode(image)\n'
                'let decoded = try await decoder.decode(encoded.data)\n'
                'for x in 0..<3 where try decoded.image.sampleUInt16(x: x, y: 0) != image.sampleUInt16(x: x, y: 0) { throw CodecError(.internalFailure, "Round trip changed a sample") }\n'
                'print("Fresh independent consumer passed; \\(encoded.data.count)-byte codestream round-tripped")\n')
            run("fresh-local-consumer", swift("run", "consumer", consumer) + ["Consumer"])
            report["open_gates"].append("Fresh URL-based consumer resolution is separate from this local consumer check")
        if "repetition" in selected:
            discover("repetition", "debug", [])
            test("repetition", "debug", [], repeat=True)
        for label, sanitizer in (("asan", "address"), ("tsan", "thread")):
            if label in selected:
                extra = ["--sanitize", sanitizer]
                discover(label, "debug", extra)
                test(label, "debug", extra)
        if "sbom" in selected:
            for spec in ("spdx", "cyclonedx"):
                destination = output / "sboms" / spec
                text = run("sbom-" + spec, swift("build", "sbom") + ["-c", "release", "--product", name,
                    "--sbom-spec", spec, "--sbom-output-dir", str(destination), "--sbom-filter", "all"])
                files = sorted(destination.glob("*.json"))
                if not files:
                    raise RuntimeError(f"No {spec} build-associated SBOM emitted")
                for path in files:
                    json.loads(path.read_text())
                    report["sboms"].append({"path": str(path.relative_to(output)),
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "build_associated": True})
                if "skipping SBOM validation" in text:
                    report["open_gates"].append(f"{spec}: installed SwiftPM schema bundle unavailable; SBOM emitted but schema validation skipped")
                save()
        report["status"] = "passed_requested_checks"
        print(f"Evidence: {output / 'report.json'}", flush=True)
        return 0
    except (RuntimeError, OSError, ValueError, ET.ParseError) as error:
        report["status"] = "failed"
        report["failure"] = str(error)
        print(str(error), file=sys.stderr)
        return 1
    finally:
        report["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        save()


if __name__ == "__main__":
    sys.exit(main())
