#!/usr/bin/env python3
"""Package completed SwiftJ2K R3 receipts. Never runs native tools or git.

Run only under the coordinator's existing exclusive claim with source writers stopped.
The source identity excludes documentation, including this package, to avoid self-reference.
Existing receipt paths are immutable: a conflicting byte sequence aborts publication.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import zipfile

SCHEMA = "swiftj2k-r3-evidence-package-v1"
EVIDENCE_REL = Path("Documentation/Engineering/Remediation/Evidence/R3/codex-takeover")
REQUIRED_RUN_FILES = ("command.json", "result.json", "native.log", "source-before.json", "source-after.json")
SOURCE_DIRS = ("Sources", "Tests", "Scripts")
EXCLUDED_DIRS = {".git", ".build", "__pycache__", "node_modules", ".cache"}
EXTERNAL_GATES = [
    ("combined-part10-part15", "Direct independent combined Part 10+15 profile"),
    ("native-3d-jpip", "Independent native 3D JPIP peer"),
    ("exact-websocket-extension", "Independent peer for the exact repository WebSocket extension"),
    ("direct-full38-part2", "Direct full38 Part 2-marker synthesis/output peer"),
    ("multiple-active-ht-sets", "Multiple transmitted nonempty HT sets in independent peer/fixture"),
]
README = """# Codex R3 takeover evidence — NOT ACCEPTED

This directory preserves source-scoped evidence; it grants no engineering acceptance,
waiver, merge permission or R4 activation. STATUS.md is the canonical owner/queue record.

Read generated-index.json for original paths, repository-relative packaged paths,
SHA-256 identities, completed command/results, review scopes, excluded incomplete work
and the separately captured current Sources/Tests/Scripts/Package.swift identity.
Validation includes failed runs. A completed process or focused pass is not full R3
qualification. Missing/skipped/unavailable external gates are not successful tests.

Before/after source manifests are stored once per SHA-256 under manifests/. Their bytes
are unmodified, including any historical generated-cache entries; the index records the
original run roles. The current implementation-only identity deliberately excludes
Documentation and package contents, so generated evidence never hashes itself. It is
not a Git tree or proof that earlier runs qualified this later candidate.

All five direct external gates remain UNEXECUTED / UNWAIVED in external-gates.json:
combined Part10+15; native 3D JPIP; the exact repository WebSocket extension; direct
full38 Part2 output; and multiple transmitted nonempty HT sets. Shared-core refinement,
Part1/15 limb adapters, independently written synthesis, 2D peers, diagnostic decoder
patches and scripted loopback tests retain their narrower scope.

The packager copies exact receipt bytes and never invokes a compiler, test, codec,
server, network service or Git. Completed runs require result.json plus all receipt
files and a matching recorded native-log hash. Incomplete runs and incomplete review
pairs are excluded and listed. Benchmark/profile families are included only when their
own validation run is complete. No executables, build trees or generated source trees
are copied. Existing historical files are left intact.

XML reports beside completed validation receipts are copied without interpreting a
missing XCTest report as zero tests. Numbered sanitizer inventories are included only
when their owning validation command has finished; raw stdout/stderr, IDs and JSON
remain exact. Final sanitizer proof/decision receipts are separate from declaration
inventories and never change this package's NOT_ACCEPTED state or external gates.

Packaged receipt paths are immutable. A conflicting existing receipt causes a visible
error; the operator must reconcile it explicitly. Repeated runs update only the generated
index, first preserving the prior index under index-history/<sha256>.json. New source
identities use content-addressed paths. Missing or changed prior receipt objects abort
rather than silently dropping evidence. Run only with source writers stopped and the
coordinator's existing exclusive claim held; this tool does not acquire that claim.
"""


def canonical(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def stable_read(path):
    """Read a regular non-symlink file without allowing an observed concurrent change."""
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError(f"Refusing non-regular file: {path}")
    data = path.read_bytes()
    after = path.lstat()
    fields = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if fields(before) != fields(after) or len(data) != after.st_size:
        raise RuntimeError(f"File changed while reading: {path}")
    return data, stat.S_IMODE(after.st_mode)


def regular_files(directory):
    """Walk only the explicitly selected directory, with no symlink traversal."""
    if directory.is_symlink():
        raise RuntimeError(f"Refusing symlink directory: {directory}")
    for current, dirs, names in os.walk(directory, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS)
        for d in dirs:
            if (Path(current) / d).is_symlink():
                raise RuntimeError(f"Refusing symlink directory: {Path(current) / d}")
        for name in sorted(names):
            if name != ".DS_Store":
                yield Path(current) / name


def implementation_identity(repository):
    paths = [repository / "Package.swift"]
    for name in SOURCE_DIRS:
        directory = repository / name
        if not directory.is_dir():
            raise RuntimeError(f"Missing source scope: {directory}")
        paths.extend(regular_files(directory))
    files = {}
    for path in sorted(paths):
        data, mode = stable_read(path)
        files[path.relative_to(repository).as_posix()] = {
            "sha256": digest(data), "bytes": len(data), "mode": f"{mode:04o}"
        }
    return {
        "schema": "swiftj2k-r3-implementation-identity-v1",
        "scope": ["Package.swift", "Sources/**", "Tests/**", "Scripts/**"],
        "excluded": ["Documentation/**", ".git/**", "build/cache directories", ".DS_Store"],
        "source_root": str(repository),
        "scope_sha256": digest(canonical(files)),
        "file_count": len(files),
        "files": files,
        "meaning": "Current file contents and modes; not a Git tree, native result or acceptance.",
    }


class Collector:
    def __init__(self, repository, destination):
        self.repository = repository
        self.destination = destination
        self.payloads = {}
        self.records = []
        self.original_hashes = {}
        self.excluded = []

    def add_bytes(self, relative, data, category, original=None, original_mode=None):
        relative = Path(relative)
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"Unsafe destination: {relative}")
        key = relative.as_posix()
        old = self.payloads.get(key)
        if old is not None and old != data:
            raise RuntimeError(f"Conflicting package payloads: {key}")
        self.payloads[key] = data
        target = self.destination / relative
        record = {
            "category": category,
            "original_location": str(original) if original else None,
            "repository_relative_location": target.relative_to(self.repository).as_posix(),
            "sha256": digest(data), "bytes": len(data),
        }
        if original_mode is not None:
            record["original_mode"] = f"{original_mode:04o}"
        self.records.append(record)
        return record

    def add(self, original, relative, category, deduplicate_manifest=False):
        data, mode = stable_read(original)
        key = str(original)
        h = digest(data)
        if key in self.original_hashes and self.original_hashes[key] != h:
            raise RuntimeError(f"Source receipt changed during collection: {original}")
        self.original_hashes[key] = h
        if deduplicate_manifest:
            relative = Path("manifests") / f"{h}.json"
        return self.add_bytes(relative, data, category, original, mode)

    def excluded_item(self, path, reason):
        self.excluded.append({"original_location": str(path), "reason": reason})


def collect_runs(work, package):
    complete = {}
    directory = work / "validation"
    for run in sorted(directory.iterdir()):
        if not run.is_dir() or run.is_symlink():
            continue
        missing = [name for name in REQUIRED_RUN_FILES if not (run / name).is_file()]
        if missing:
            package.excluded_item(run, "Incomplete validation receipt: " + ", ".join(missing))
            continue
        result_bytes, _ = stable_read(run / "result.json")
        try:
            result = json.loads(result_bytes)
        except ValueError:
            package.excluded_item(run, "Incomplete/malformed result.json")
            continue
        if not result.get("finished_at") or not isinstance(result.get("exit_code"), int):
            package.excluded_item(run, "No completed process identity in result.json")
            continue
        raw_log, _ = stable_read(run / "native.log")
        if result.get("log_sha256") != digest(raw_log):
            raise RuntimeError(f"Completed run log differs from result receipt: {run}")
        command_bytes, _ = stable_read(run / "command.json")
        command = json.loads(command_bytes)
        refs = {}
        for name in REQUIRED_RUN_FILES:
            refs[name] = package.add(
                run / name, Path("validation") / run.name / name, "validation",
                deduplicate_manifest=name in {"source-before.json", "source-after.json"},
            )
        # Legacy runs have only native.log. New wrappers bind both raw streams
        # explicitly; preserve incomplete capture as failed evidence, never a pass.
        stream_receipts = result.get("native_streams", {})
        capture_required = bool(command.get("output_capture")) or bool(stream_receipts)
        for stream in ("stdout", "stderr"):
            name = "native." + stream
            path = run / name
            if not path.is_file():
                if capture_required:
                    raise RuntimeError(f"Recorded raw stream missing: {path}")
                continue
            data, _ = stable_read(path)
            recorded = stream_receipts.get(stream)
            if recorded is not None:
                if recorded.get("sha256") != digest(data) or recorded.get("bytes") != len(data):
                    raise RuntimeError(f"Raw stream differs from its result receipt: {path}")
                if Path(recorded.get("path", "")).resolve() != path.resolve():
                    raise RuntimeError(f"Raw stream path differs from its result receipt: {path}")
            elif capture_required:
                raise RuntimeError(f"New raw stream lacks result metadata: {path}")
            refs[name] = package.add(path, Path("validation") / run.name / name, "validation-raw-stream")
        # Both XCTest and Swift Testing may emit XML, with different filenames.
        # Preserve every XML under this completed run, including failed-run reports.
        # Do not fabricate a missing report or parse/rewrite historical report bytes.
        for report in regular_files(run):
            if report.suffix.lower() == ".xml":
                relative = report.relative_to(run)
                refs[relative.as_posix()] = package.add(
                    report, Path("validation") / run.name / relative, "validation-xml"
                )
        complete[run.name] = {
            "original_directory": str(run), "source_root": command.get("cwd"),
            "command": command.get("command"), "exit_code": result["exit_code"],
            "finished_at": result["finished_at"],
            "changed_inputs": result.get("changed_inputs"),
            "capture_complete": result.get("capture_complete"),
            "capture_errors": result.get("capture_errors"),
            "wrapper_exit_code": result.get("wrapper_exit_code"),
            "qualification": "Receipt only; failures and changed inputs retained; no acceptance inferred.",
            "files": refs,
        }
    return complete


def completed_output_directories(complete):
    """Resolve recorded --output paths without executing the recorded command."""
    outputs = {}
    for name, run in complete.items():
        command = run.get("command") or []
        source_root = run.get("source_root")
        if not isinstance(source_root, str):
            continue
        for index, argument in enumerate(command):
            output = None
            if argument == "--output" and index + 1 < len(command):
                output = command[index + 1]
            elif isinstance(argument, str) and argument.startswith("--output="):
                output = argument.partition("=")[2]
            if isinstance(output, str) and output:
                path = Path(output)
                if not path.is_absolute():
                    path = Path(source_root) / path
                outputs.setdefault(path.resolve(), []).append(name)
    return outputs


def collect_cli_repair_coverage_evidence(work, package, complete):
    """Preserve the inspected CLI/probe/repair/coverage files, not source trees."""
    groups = []
    outputs = completed_output_directories(complete)

    def add_group(label, paths, category, scope, owners=(), manifest_names=()):
        missing = [path.name for path in paths if not path.is_file()]
        if missing:
            package.excluded_item(work / label, "Supplemental evidence incomplete: " + ", ".join(missing))
            return
        refs = [package.add(path, Path("supplemental") / label / path.name, category,
                            deduplicate_manifest=path.name in manifest_names) for path in paths]
        groups.append({"label": label, "files": refs,
                       "completed_validation_runs": list(owners), "scope": scope})

    cli_directory = work / "cli-integration-08"
    cli_owners = outputs.get(cli_directory.resolve(), [])
    if "candidate-cli-08" in cli_owners:
        add_group("cli-integration-08", [cli_directory / "report.json"], "cli-integration-report",
                  "Exact CLI harness report from the completed command's --output directory; failed results remain evidence.",
                  owners=("candidate-cli-08",))
    elif cli_directory.exists():
        package.excluded_item(cli_directory, "No completed candidate-cli-08 command owns this --output directory")

    # This diagnostic used a positional output path, not --output. Verify the
    # actual recorded invocation of the preserved probe before attaching files.
    diagnostic = complete.get("cli-host-before-07")
    if diagnostic:
        command = diagnostic.get("command") or []
        cwd = Path(diagnostic.get("source_root") or work)
        if (len(command) == 4 and (cwd / command[1]).resolve() == (work / "cli-host-probe.py").resolve()
                and (cwd / command[3]).resolve() == (work / "cli-host-before-07").resolve()):
            add_group("cli-host-before-07", [work / "cli-host-before-07" / name
                                            for name in ("stdout.txt", "stderr.txt")],
                      "cli-failed-diagnostic", "Original failing child output, bound to its completed owner receipt; no successful qualification inferred.",
                      owners=("cli-host-before-07",))
        else:
            raise RuntimeError("cli-host-before-07 diagnostic output does not match its recorded owner command")
    elif (work / "cli-host-before-07").exists():
        package.excluded_item(work / "cli-host-before-07", "Diagnostic owner receipt incomplete")

    for script, owner in (("cli-host-probe.py", "cli-host-before-07"),
                          ("stream-capture-probe.py", "stream-capture-probe-08")):
        if owner in complete:
            add_group(Path(script).stem, [work / script], "diagnostic-reproduction-helper",
                      "Helper source preserved for the named completed diagnostic; never executed by this packager.", owners=(owner,))
    if "stream-capture-probe-08" in complete:
        verification = work / "stream-capture-verification-08.json"
        if verification.is_file():
            data, _ = stable_read(verification)
            receipt = json.loads(data)
            if (work / receipt.get("probe", "")).resolve() != (work / "validation/stream-capture-probe-08").resolve():
                raise RuntimeError("Stream-capture verification names a different owner receipt")
            add_group("stream-capture-verification-08", [verification], "stream-capture-verification",
                      "Exact recorded verification of the completed Python stream probe, not native qualification.", owners=("stream-capture-probe-08",))

    repair_groups = {
        "root-cli-host-repair-08": ("root-cli-host-repair-08.txt", "root-cli-host-repair-08-source.json"),
        "oracle-harness-08": ("oracle-harness-report-08.txt", "oracle-harness-source-08.json",
                              "oracle-harness-before-08.json", "oracle-harness-delta-08.patch"),
        "jpip-worker-handoff-06": ("jpip-worker-handoff-report.txt", "jpip-worker-handoff-source-06.json"),
        "jpip-http-scan-07": ("jpip-http-scan-report.txt", "jpip-http-scan-source-07.json"),
        "r3-cli-harness-repair": ("r3-cli-harness-repair-report.txt", "r3-cli-harness-repair-source.json"),
    }
    for label, names in repair_groups.items():
        add_group(label, [work / name for name in names], "implementation-repair-report",
                  "Implementation report and original source/delta identities; not an independent approval or current native pass.",
                  manifest_names=("oracle-harness-before-08.json",))

    coverage = work / "runtime-coverage"
    add_group("runtime-coverage", [coverage / name for name in
              ("reconcile.py", "report.txt", "component-check.py", "component-check-result.json",
               "full08-component-check.json", "ordinary08-authoritative-check.json",
               "thread-final-08.json", "address-final-08.json")],
              "runtime-coverage-component-evidence",
              "Current helper and preserved parser component checks, including rejected/failed inputs; not final runtime coverage proof.")
    example = coverage / "spec-example.json"
    if example.is_file():
        add_group("runtime-coverage-example", [example], "runtime-coverage-example",
                  "Example input only; not an executed proof or completed validation receipt.")
    hosted = work / "hosted-evidence"
    add_group("hosted-evidence-reproduction", [hosted / name for name in
              ("reconstruct.py", "report.txt", "selftest.py", "selftest-result.json",
               "source-reference.json", "expected-template.json")],
              "hosted-evidence-reproduction",
              "Reconstruction helper and synthetic format checks only; template placeholders are not real hosted results or acceptance.")
    return groups


def collect_sanitizer_evidence(work, package, complete):
    outputs = completed_output_directories(complete)
    inventories = []
    for directory in sorted(work.glob("sanitizer-inventory-*")):
        if not directory.is_dir() or not re.fullmatch(r"sanitizer-inventory-\d+", directory.name):
            continue
        groups = {}
        for path in regular_files(directory):
            if path.suffix.lower() not in {".stdout", ".stderr", ".ids", ".json"}:
                continue
            owners = sorted({name for output, names in outputs.items()
                             if output.is_relative_to(directory.resolve())
                             and path.resolve().is_relative_to(output)
                             for name in names})
            if not owners:
                package.excluded_item(path, "Sanitizer inventory owner has no completed validation receipt")
                continue
            ref = package.add(path, Path("sanitizers/inventories") / directory.name
                              / path.relative_to(directory), "sanitizer-inventory")
            groups.setdefault(tuple(owners), []).append(ref)
        for owners, files in sorted(groups.items()):
            inventories.append({"original_directory": str(directory),
                                "completed_validation_runs": list(owners),
                                "files": files,
                                "scope": "Raw discovery/proof inputs; failed owning runs retained; no execution pass inferred."})

    # Only explicit final records enter this collection. A complete failed decision
    # is evidence too; a declaration inventory is never treated as execution proof.
    patterns = ("sanitizer-execution-proof*.json", "r3-sanitizer-execution-proof*.json",
                "sanitizer-decision*.json", "r3-sanitizer-decision*.json")
    candidates = {path for pattern in patterns for path in work.glob(pattern)}
    proofs = []
    nonfinal = {"draft", "proposed", "pending", "running", "partial", "active", "awaiting"}
    terminal = {"complete", "completed", "final", "pass", "passed", "fail", "failed",
                "accepted", "rejected", "qualified", "unqualified"}
    for path in sorted(candidates):
        raw, _ = stable_read(path)
        try:
            record = json.loads(raw)
        except ValueError:
            package.excluded_item(path, "Sanitizer proof/decision JSON is not yet complete")
            continue
        if not isinstance(record, dict):
            package.excluded_item(path, "Sanitizer proof/decision has no completion record")
            continue
        status_text = " ".join(str(record.get(key, "")) for key in ("status", "state", "decision"))
        name_tokens = set(re.split(r"[^a-z0-9]+", path.stem.lower()))
        status_tokens = set(re.split(r"[^a-z0-9]+", status_text.lower()))
        complete_marker = (record.get("completed_at") or record.get("finished_at")
                           or record.get("final") is True or record.get("completed") is True
                           or bool(status_tokens & terminal))
        if (name_tokens | status_tokens) & nonfinal or not complete_marker:
            package.excluded_item(path, "Sanitizer proof/decision is draft, pending or lacks explicit completion")
            continue
        files = [package.add(path, Path("sanitizers/decisions") / path.name, "sanitizer-proof-decision")]
        for suffix in (".txt", ".md"):
            companion = path.with_suffix(suffix)
            if companion.is_file():
                files.append(package.add(companion, Path("sanitizers/decisions") / companion.name,
                                         "sanitizer-proof-decision"))
        proofs.append({"original_location": str(path), "files": files,
                       "scope": "Explicit completed receipt; decision content preserved, not inferred or elevated."})
    return {"inventories": inventories, "proofs_and_decisions": proofs}


def collect_reviews(work, package):
    paired = set()
    reports = set(work.glob("independent-*-review*.txt")) | set(work.glob("independent-*-diagnosis-*.txt"))
    for report in sorted(reports):
        source = report.with_name(report.stem + "-source.json")
        if not source.is_file():
            package.excluded_item(report, "Review source manifest not yet available")
            continue
        raw, _ = stable_read(report)
        manifest, _ = stable_read(source)
        details = json.loads(manifest)
        if not raw.strip():
            package.excluded_item(report, "Review report empty/incomplete")
            continue
        expected = details.get("report_sha256")
        if expected is not None and expected != digest(raw):
            raise RuntimeError(f"Review report differs from its manifest: {report}")
        paired.add(source.name)
        supporting = [p for p in sorted(work.glob(report.stem + "-*.json")) if p != source]
        for item in [report, source, *supporting]:
            package.add(item, Path("reviews") / item.name, "independent-review")
    for source in sorted(work.glob("independent-*-review*-source.json")):
        if source.name not in paired:
            package.excluded_item(source, "No complete paired review report")


def text_family(directory, prefix, package, category, suffixes):
    for item in sorted(directory.iterdir()):
        if item.is_file() and item.suffix in suffixes:
            package.add(item, Path(prefix) / item.name, category)


def archive_benchmark_output(directory, prefix, package):
    """Retain every original output byte without thousands of PR file entries."""
    members = []
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(directory.iterdir()):
            if not path.is_file() or path.suffix not in {".stdout", ".stderr"}:
                continue
            data, mode = stable_read(path)
            package.original_hashes[str(path)] = digest(data)
            entry = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = mode << 16
            archive.writestr(entry, data)
            members.append({"name": path.name, "original_location": str(path),
                            "sha256": digest(data), "bytes": len(data), "mode": f"{mode:04o}"})
    package.add_bytes(Path(prefix) / "raw-output.zip", buffer.getvalue(), "benchmark-raw-output-archive")
    package.add_bytes(Path(prefix) / "raw-output-members.json", canonical(members), "benchmark-raw-output-index")


def collect_families(work, package, complete):
    for number in range(2, 6):
        family = work / f"r3-benchmark-results-{number:02d}"
        run = f"perf-comparison-{number:02d}"
        if not family.exists():
            continue
        required = [family / name for name in ("metadata.json", "samples.jsonl", "summary.json")]
        if run not in complete or not all(p.is_file() for p in required):
            package.excluded_item(family, "Benchmark run/metadata/samples/summary incomplete")
            continue
        text_family(family, Path("benchmarks") / family.name, package, "benchmark",
                    {".json", ".jsonl"})
        archive_benchmark_output(family, Path("benchmarks") / family.name, package)
    for number in (1, 2):
        family = work / f"r3-profile-results-{number:02d}"
        run = f"profile-comparison-{number:02d}"
        if not family.exists():
            continue
        if run not in complete:
            package.excluded_item(family, "Profile comparison has no completed validation result")
            continue
        text_family(family, Path("profiles") / family.name, package, "profile",
                    {".json", ".txt", ".stdout", ".stderr"})
    fixture_families = {
        "planar-ht-fixtures-01": "planar-ht-generation-01",
        "ht-refinement-candidates-01": "ht-refinement-generation-01",
        "portable-planar-fixtures-01": "portable-fixtures-planar-01",
        "portable-refinement-fixtures-01": "portable-fixtures-refinement-01",
    }
    for name, run in fixture_families.items():
        family = work / name
        if not family.exists():
            continue
        if run not in complete:
            package.excluded_item(family, "Fixture generation has no completed validation receipt")
            continue
        text_family(family, Path("fixtures") / name, package, "fixture-generation",
                    {".json", ".txt", ".log"})
    for name in ("part2-peer-01", "part2-limbs-01"):
        family = work / name
        if not family.exists() or name not in complete:
            continue
        for item in regular_files(family):
            if item.suffix in {".json", ".txt", ".log"}:
                package.add(item, Path("peers") / name / item.relative_to(family), "peer-diagnostic")


def verify_existing_package(repository, destination):
    index = destination / "generated-index.json"
    if not index.exists():
        return None
    raw, _ = stable_read(index)
    old = json.loads(raw)
    if old.get("schema") != SCHEMA:
        raise RuntimeError(f"Refusing to replace unknown index format: {index}")
    for item in old.get("artifacts", []):
        rel = Path(item["repository_relative_location"])
        if rel.is_absolute() or ".." in rel.parts:
            raise RuntimeError("Unsafe path in previous generated index")
        path = repository / rel
        if not path.resolve().is_relative_to(destination.resolve()):
            raise RuntimeError(f"Previous index points outside evidence destination: {path}")
        data, _ = stable_read(path)
        if digest(data) != item["sha256"]:
            raise RuntimeError(f"Existing receipt was changed; refusing silent overwrite: {path}")
    return raw


def immutable_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    for parent in [path.parent, *path.parents]:
        if parent.is_symlink():
            raise RuntimeError(f"Refusing destination symlink: {parent}")
    if path.exists():
        existing, _ = stable_read(path)
        if existing != data:
            raise RuntimeError(f"Existing receipt differs; refusing overwrite: {path}")
        return
    # Exclusive create prevents replacement of another concurrent writer's file.
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--repository", type=Path, help="Default: WORKSPACE/work/SwiftJ2K")
    parser.add_argument("--candidate-label", default="uncommitted-current-source", help="Descriptive only; never asserted as a Git identity")
    parser.add_argument("--dry-run", action="store_true", help="Read/verify and report proposed package; write nothing")
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    repository = (args.repository or workspace / "work" / "SwiftJ2K").resolve()
    if not repository.is_relative_to(workspace):
        raise RuntimeError("Repository must be the isolated checkout beneath this workspace")
    work = workspace / "work"
    destination = repository / EVIDENCE_REL
    identity_before = implementation_identity(repository)
    previous = verify_existing_package(repository, destination)
    package = Collector(repository, destination)
    complete = collect_runs(work, package)
    sanitizer_evidence = collect_sanitizer_evidence(work, package, complete)
    supplemental_evidence = collect_cli_repair_coverage_evidence(work, package, complete)
    collect_reviews(work, package)
    collect_families(work, package, complete)
    for case in ("odd8", "medium16"):
        for suffix in (".raw", ".ebcot.j2k", ".ht.j2k"):
            path = work / "r3-benchmark-inputs" / (case + suffix)
            if path.is_file():
                package.add(path, Path("benchmarks/inputs") / path.name, "synthetic-benchmark-input")
    # Preserve the actual reproducibility helpers behind recorded commands.
    for name in ("run-validation.py", "snapshot-candidate.py", "run-r3-benchmark.py",
                 "run-r3-profile.py", "run-r3-profile2.py", "build-r3-profiles.py",
                 "build-r3-profile2s.py", "independent-part2-peer.py",
                 "generate-ht-refinement.py", "common-contract-check-01.json", "candidate05-cli-binding.json",
                 "final-implementation-identity-08.json", "performance-core-identity-08.json",
                 "ci-workflow-application-08.json", "root-implementation-report.txt",
                 "independent-final-native-check-08.py", "independent-final-native-check-08-summary.json"):
        path = work / name
        if path.is_file():
            package.add(path, Path("reproduction") / name, "reproduction-helper")
    for path in sorted((work / "validation-wrapper-versions").glob("*.py")):
        package.add(path, Path("reproduction/validation-wrapper-versions") / path.name, "historical-validation-wrapper")
    for pattern in ("r3-*-harness-source.json", "r3-performance-decision*.json",
                    "r3-performance-stage-label-change.json"):
        for path in sorted(work.glob(pattern)):
            package.add(path, Path("reproduction") / path.name, "reproduction-receipt")
    for name in ("r3-benchmark-harness", "r3-benchmark-baseline", "r3-benchmark-candidate",
                 "r3-benchmark-candidate03", "r3-profile-baseline", "r3-profile-candidate",
                 "r3-profile2-baseline", "r3-profile2-candidate"):
        directory = work / name
        if directory.is_dir():
            for path in regular_files(directory):
                if path.suffix == ".swift":
                    package.add(path, Path("reproduction") / name / path.relative_to(directory), "reproduction-source")
    peer_options = workspace / "outputs" / "SwiftJ2K-R3-Peer-Options.txt"
    if peer_options.is_file():
        package.add(peer_options, "peers/SwiftJ2K-R3-Peer-Options.txt", "peer-options-research")
    else:
        package.excluded_item(peer_options, "Peer-options report unavailable")
    for pattern in ("*external*gate*.json", "*external*gate*.txt", "*oracle*gate*.json"):
        for path in sorted(work.glob(pattern)):
            if path.is_file():
                package.add(path, Path("peers") / path.name, "external-gate-receipt")
    # Link frozen-candidate identities without copying any snapshot/source tree.
    for path in sorted(work.glob("candidate-snapshot-*-source.json")):
        package.add(path, "unused", "frozen-candidate-manifest", deduplicate_manifest=True)
        provenance = path.with_name(path.name.replace("-source.json", "-provenance.json"))
        if provenance.is_file():
            package.add(provenance, Path("provenance") / provenance.name, "snapshot-provenance")
    package.add(Path(__file__).resolve(), "packaging/package-r3-evidence.py", "packaging-script")
    identity_bytes = canonical(identity_before)
    identity_ref = package.add_bytes(
        Path("source-identities") / f"{digest(identity_bytes)}.json", identity_bytes, "current-implementation-identity"
    )
    package.add_bytes("README.generated.md", README.encode(), "generated-explanation")
    gate_data = {
        "state": "NOT_ACCEPTED", "scope": "R3 mandatory external qualification",
        "gates": [{"id": key, "description": description, "state": "UNEXECUTED", "waived": False}
                  for key, description in EXTERNAL_GATES],
        "boundary": "Narrower diagnostics and research do not satisfy these gates. Reconcile explicitly if formal evidence later changes a state.",
    }
    package.add_bytes("external-gates.json", canonical(gate_data), "generated-external-gate-register")
    # Do not publish a package assembled while any captured receipt/source changed.
    for original, expected in package.original_hashes.items():
        data, _ = stable_read(Path(original))
        if digest(data) != expected:
            raise RuntimeError(f"Receipt changed after collection: {original}")
    if implementation_identity(repository) != identity_before:
        raise RuntimeError("Implementation source changed while packaging; no generated index will be published")
    if previous is not None and stable_read(destination / "generated-index.json")[0] != previous:
        raise RuntimeError("Generated index changed concurrently; abort")
    # Preflight every collision before writing any receipt.
    for relative, data in package.payloads.items():
        path = destination / relative
        if path.exists() and stable_read(path)[0] != data:
            raise RuntimeError(f"Conflicting existing receipt; reconcile explicitly: {path}")
    prior_artifacts = json.loads(previous).get("artifacts", []) if previous else []
    current_locations = {r["repository_relative_location"] for r in package.records}
    retained_prior = [dict(r, retained_from_prior_index=True) for r in prior_artifacts
                      if r["repository_relative_location"] not in current_locations]
    index = {
        "schema": SCHEMA, "generated_at": utc_now(), "state": "NOT_ACCEPTED",
        "candidate_label": args.candidate_label, "workspace": str(workspace),
        "repository": str(repository), "destination": EVIDENCE_REL.as_posix(),
        "previous_index_sha256": digest(previous) if previous else None,
        "current_source_identity": identity_ref, "current_scope_sha256": identity_before["scope_sha256"],
        "current_identity_is_git_tree": False,
        "validation_runs": complete,
        "sanitizer_evidence": sanitizer_evidence,
        "cli_repair_coverage_evidence": supplemental_evidence,
        "artifacts": package.records + retained_prior,
        "excluded_incomplete": package.excluded,
        "external_gates": gate_data,
        "notes": ["Exact copied bytes; source manifests deduplicated by SHA256.",
                  "Artifact original paths are provenance; repository-relative paths provide review access.",
                  "Current source identity excludes documentation and does not retroactively qualify prior runs.",
                  "No native execution, git command, acceptance or waiver is performed by packaging."],
    }
    new_index = canonical(index)
    summary = {"completed_runs": len(complete), "artifact_roles": len(package.records),
               "unique_payloads": len(package.payloads), "payload_bytes": sum(map(len, package.payloads.values())),
               "excluded_incomplete": package.excluded, "source_scope_sha256": identity_before["scope_sha256"],
               "destination": str(destination), "dry_run": args.dry_run}
    summary["sanitizer_artifact_counts"] = {
        category: sum(record["category"] == category for record in package.records)
        for category in ("validation-xml", "validation-raw-stream", "sanitizer-inventory", "sanitizer-proof-decision")
    }
    summary["cli_repair_coverage_groups"] = {group["label"]: len(group["files"])
                                             for group in supplemental_evidence}
    if args.dry_run:
        print(json.dumps(summary, indent=2))
        return
    destination.mkdir(parents=True, exist_ok=True)
    lock = destination / ".package-r3-evidence.lock"
    try:
        lock.mkdir()
    except FileExistsError as exc:
        raise RuntimeError(f"Another packaging operation or unresolved lock exists: {lock}") from exc
    temporary = None
    try:
        # This local writer lock is not the coordinator's audit claim.
        actual = stable_read(destination / "generated-index.json")[0] if (destination / "generated-index.json").exists() else None
        if actual != previous:
            raise RuntimeError("Generated index changed before publication")
        for relative, data in package.payloads.items():
            immutable_write(destination / relative, data)
        if implementation_identity(repository) != identity_before:
            raise RuntimeError("Implementation source changed before index publication; immutable copied receipts retained, index unchanged")
        if previous is not None:
            immutable_write(destination / "index-history" / f"{digest(previous)}.json", previous)
        fd, name = tempfile.mkstemp(prefix=".generated-index-", suffix=".tmp", dir=destination)
        temporary = Path(name)
        with os.fdopen(fd, "wb") as stream:
            stream.write(new_index)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination / "generated-index.json")
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        lock.rmdir()
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        print(f"Evidence packaging stopped: {exc}", file=sys.stderr)
        raise SystemExit(1)
