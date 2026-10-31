#!/usr/bin/env python3
"""Reconstruct swiftj2k-ci-evidence-v1 from one complete timestamped job log.

No network, Git, native runner or repository writes. All records and bytes are
validated before a fresh directory under this takeover's work/ is created.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys

WORK = Path(__file__).resolve().parent.parent
FORMAT = "swiftj2k-ci-evidence-v1"
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
CHARS_PER_CHUNK = 4096
INVENTORY_NAMES = ["reference.stdout", "reference.stderr", "reference.command-result.json",
                   "sanitized.stdout", "sanitized.stderr", "sanitized.command-result.json",
                   "inventory.json", "all.ids", "jpip.ids", "complement.ids"]
REQUIRED = {f"{mode}/{name}" for mode in ("address", "thread") for name in INVENTORY_NAMES}
OPTIONAL = {f"{mode}/inventory-mismatch.json" for mode in ("address", "thread")}
XML_GROUPS = [["ordinary/full.xml", "ordinary/full-swift-testing.xml"]]
for _mode in ("address", "thread"):
    for _part in ("jpip", "complement"):
        XML_GROUPS.append([f"{_mode}/{_part}.xml", f"{_mode}/{_part}-swift-testing.xml"])
ALLOWED = sorted(REQUIRED | OPTIONAL | {p for group in XML_GROUPS for p in group})
IDENTITY_KEYS = {"GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB",
                 "GITHUB_EVENT_NAME", "GITHUB_REF", "GITHUB_SHA", "EVIDENCE_PR_HEAD",
                 "EVIDENCE_PR_BASE", "EVIDENCE_ORDINARY", "EVIDENCE_ASAN", "EVIDENCE_TSAN"}
OUTCOME_KEYS = ("EVIDENCE_ORDINARY", "EVIDENCE_ASAN", "EVIDENCE_TSAN")
SCOPE = "Retention only; missing framework reports are not zero tests; reconcile runtime declarations and parameter cases separately"
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z) (.*)$")
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def loads(text):
    def reject_constant(value):
        raise ValueError(f"Non-JSON numeric constant: {value}")
    return json.loads(text, object_pairs_hook=no_duplicate_keys, parse_constant=reject_constant)


def exact_keys(record, fields):
    expected = {"format", "kind", *fields}
    require(set(record) == expected, f"Unexpected/missing {record.get('kind')} record fields: {sorted(set(record) ^ expected)}")


def integer(value, lower, upper, label):
    require(type(value) is int and lower <= value <= upper, f"Invalid {label}: {value!r}")


def path_check(value):
    require(isinstance(value, str), "Record path is not a string")
    path = PurePosixPath(value)
    require(not path.is_absolute() and ".." not in path.parts and "\\" not in value
            and path.as_posix() == value and value in ALLOWED, f"Path outside fixed allowlist: {value!r}")
    return value


def validate_expected(expected):
    require(isinstance(expected, dict) and set(expected) == {"identity", "checkout_head", "checkout_tree"},
            "Expected identity file must contain exactly identity, checkout_head, checkout_tree")
    identity = expected["identity"]
    require(isinstance(identity, dict) and set(identity) == IDENTITY_KEYS, "Expected identity keys differ from emitter")
    require(all(isinstance(v, str) and not any(ord(c) < 32 for c in v) for v in identity.values()),
            "Expected identity values must be plain strings")
    for key in IDENTITY_KEYS - {"EVIDENCE_PR_HEAD", "EVIDENCE_PR_BASE"}:
        require(bool(identity[key]), f"Missing expected {key}")
    require(re.fullmatch(r"[^/\s]+/[^/\s]+", identity["GITHUB_REPOSITORY"]), "Invalid repository identity")
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        require(re.fullmatch(r"[1-9][0-9]*", identity[key]), f"Invalid {key}")
    for key in OUTCOME_KEYS:
        require(identity[key] in {"success", "failure", "cancelled", "skipped"}, f"Unknown step outcome: {key}")
    for key in ("checkout_head", "checkout_tree"):
        require(isinstance(expected[key], str) and HEX40.fullmatch(expected[key]), f"Invalid expected {key}")
    require(HEX40.fullmatch(identity["GITHUB_SHA"]) and identity["GITHUB_SHA"] == expected["checkout_head"],
            "Expected workflow SHA and checkout HEAD must be the same tested commit")
    if identity["GITHUB_EVENT_NAME"] == "pull_request":
        require(re.fullmatch(r"refs/pull/[1-9][0-9]*/merge", identity["GITHUB_REF"]), "PR must identify its synthetic merge ref")
        for key in ("EVIDENCE_PR_HEAD", "EVIDENCE_PR_BASE"):
            require(HEX40.fullmatch(identity[key]), f"Missing/invalid PR identity: {key}")
    else:
        for key in ("EVIDENCE_PR_HEAD", "EVIDENCE_PR_BASE"):
            require(identity[key] == "" or HEX40.fullmatch(identity[key]), f"Invalid optional PR identity: {key}")


def records_from_log(data):
    text = data.decode("utf-8")
    records = []
    for line_number, line in enumerate(text.split("\n"), 1):
        if line.endswith("\r"):
            line = line[:-1]  # Log framing only; JSON strings retain escaped CR bytes.
        match = STAMP.fullmatch(line)
        payload = match[2] if match else line
        if not payload.startswith("{"):
            continue
        try:
            record = loads(payload)
        except (ValueError, json.JSONDecodeError) as exc:
            if FORMAT in payload:
                raise ValueError(f"Malformed evidence JSON at log line {line_number}: {exc}") from exc
            continue
        if not isinstance(record, dict) or record.get("format") != FORMAT:
            continue
        require(match is not None, f"Evidence record lacks runner timestamp at line {line_number}")
        records.append((record, {"line": line_number, "timestamp": match[1]}))
    require(records, "No timestamped evidence records found")
    return records


def validate_log(data, expected):
    validate_expected(expected)
    records = records_from_log(data)
    require(sum(r.get("kind") == "begin" for r, _ in records) == 1, "Require exactly one begin record")
    require(sum(r.get("kind") == "end" for r, _ in records) == 1, "Require exactly one end record")
    begin, begin_location = records[0]
    end, end_location = records[-1]
    require(begin.get("kind") == "begin" and end.get("kind") == "end", "Evidence must start with begin and finish with end")
    exact_keys(begin, {"identity", "checkout_head", "checkout_tree", "tracked_tree_clean", "max_file_bytes", "max_total_bytes"})
    require(begin["identity"] == expected["identity"], "Run/repository/attempt/ref/PR/step identity mismatch")
    require(begin["checkout_head"] == expected["checkout_head"] and begin["checkout_tree"] == expected["checkout_tree"],
            "Tested checkout head/tree mismatch")
    require(begin["tracked_tree_clean"] is True, "Tracked checkout drift was recorded")
    require(type(begin["max_file_bytes"]) is int and begin["max_file_bytes"] == MAX_FILE
            and type(begin["max_total_bytes"]) is int and begin["max_total_bytes"] == MAX_TOTAL,
            "Emitter byte ceilings differ from reviewed format")
    files, missing, receipts = {}, [], {}
    cursor, total = 1, 0
    for relative in ALLOWED:
        require(cursor < len(records) - 1, f"Truncated path sequence before {relative}")
        record, location = records[cursor]
        cursor += 1
        kind = record.get("kind")
        require(kind in {"file", "missing"}, f"Unexpected record {kind!r} before {relative}; file/identity errors are not recoverable evidence")
        require(path_check(record.get("path")) == relative, f"Duplicate, missing or unordered path record: expected {relative}, got {record.get('path')}")
        if kind == "missing":
            exact_keys(record, {"path"})
            missing.append(relative)
            receipts[relative] = {"status": "missing", **location}
            continue
        exact_keys(record, {"path", "sha256", "bytes", "encoding", "chunks"})
        require(record["encoding"] == "utf-8", f"Unsupported encoding: {relative}")
        require(isinstance(record["sha256"], str) and HEX64.fullmatch(record["sha256"]), f"Invalid/masked hash: {relative}")
        integer(record["bytes"], 0, MAX_FILE, "file byte count")
        integer(record["chunks"], 0, (MAX_FILE + CHARS_PER_CHUNK - 1) // CHARS_PER_CHUNK, "chunk count")
        require((record["bytes"] == 0) == (record["chunks"] == 0), f"Empty file/chunk mismatch: {relative}")
        require(total + record["bytes"] <= MAX_TOTAL, "Total evidence ceiling exceeded")
        chunks, byte_count = [], 0
        for index in range(record["chunks"]):
            require(cursor < len(records) - 1, f"Truncated chunks: {relative}/{index}")
            chunk, chunk_location = records[cursor]
            cursor += 1
            require(chunk.get("kind") == "chunk", f"Missing/interleaved chunk: {relative}/{index}")
            exact_keys(chunk, {"path", "index", "content_utf8"})
            require(path_check(chunk["path"]) == relative and type(chunk["index"]) is int and chunk["index"] == index,
                    f"Duplicate, missing, unordered or misbound chunk: {relative}/{index}")
            content = chunk["content_utf8"]
            require(isinstance(content, str), f"Non-string chunk: {relative}/{index}")
            require(0 < len(content) <= CHARS_PER_CHUNK and (index == record["chunks"] - 1 or len(content) == CHARS_PER_CHUNK),
                    f"Invalid Unicode-character chunk boundary: {relative}/{index}")
            encoded = content.encode("utf-8")  # Reject lone surrogate/code-point corruption.
            byte_count += len(encoded)
            require(byte_count <= record["bytes"], f"Chunk bytes exceed declaration: {relative}")
            chunks.append(encoded)
        content = b"".join(chunks)
        require(len(content) == record["bytes"] and digest(content) == record["sha256"],
                f"Exact bytes/SHA mismatch (truncation, masking or modification): {relative}")
        files[relative] = content
        total += len(content)
        receipts[relative] = {"status": "retained", "bytes": len(content), "sha256": digest(content),
                              "chunks": record["chunks"], **location}
    require(cursor == len(records) - 1, "Unexpected records after the complete allowlisted path sequence")
    exact_keys(end, {"files", "bytes", "problems", "retention_complete", "scope"})
    integer(end["files"], 0, len(ALLOWED), "footer file count")
    integer(end["bytes"], 0, MAX_TOTAL, "footer byte count")
    require(end["files"] == len(files) and end["bytes"] == total, "Footer counts differ from recovered data")
    require(type(end["problems"]) is list and end["problems"] == [] and end["retention_complete"] is True,
            "Emitter recorded retention problems or incomplete evidence")
    require(end["scope"] == SCOPE, "Unknown retention scope/version")
    require(REQUIRED <= set(files), f"Missing required inventory evidence: {sorted(REQUIRED - set(files))}")
    for group in XML_GROUPS:
        require(any(path in files for path in group), f"No report retained for invocation: {group[0]}")
    summary = {"state": "RECONSTRUCTED_RETENTION_EVIDENCE_ONLY", "format": FORMAT,
               "identity": begin["identity"], "checkout_head": begin["checkout_head"],
               "checkout_tree": begin["checkout_tree"], "tracked_tree_clean": True,
               "test_steps_successful": all(begin["identity"][k] == "success" for k in OUTCOME_KEYS),
               "begin": begin_location, "end": end_location, "record_count": len(records),
               "files": receipts, "retained_files": len(files), "retained_bytes": total,
               "explicitly_missing_paths": missing,
               "boundaries": [SCOPE, "Expected identity must come from independently retrieved exact-run metadata; copying it from this log does not independently bind the run.",
                   "PR head/base and tested synthetic merge HEAD/tree are distinct identities.",
                   "Reconstruction does not prove all declarations/cases executed, sanitizer success, external-oracle availability or R3 acceptance.",
                   "Hosted source/compiler/environment is distinct from local native receipts; no local receipt is fabricated."]}
    return files, summary


def fresh_work_directory(output):
    raw = Path(output)
    require(".." not in raw.parts, "Output may not traverse parent directories")
    absolute = raw if raw.is_absolute() else Path.cwd() / raw
    require(absolute != WORK and absolute.is_relative_to(WORK), "Output must be a fresh subdirectory of this takeover's work/")
    require(not absolute.exists() and not absolute.is_symlink(), "Output directory already exists")
    require(absolute.parent.is_dir(), "Output parent must already exist")
    for ancestor in [absolute.parent, *absolute.parent.parents]:
        require(not ancestor.is_symlink(), f"Symlinked output ancestor refused: {ancestor}")
    return absolute


def reconstruct(log_path, expected_path, output):
    destination = fresh_work_directory(output)
    data = Path(log_path).read_bytes()
    expectation_bytes = Path(expected_path).read_bytes()
    expected = loads(expectation_bytes.decode("utf-8"))
    files, summary = validate_log(data, expected)
    # All input validation occurs before any output mutation.
    destination.mkdir(mode=0o700)
    for relative, content in files.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as handle:
            handle.write(content)
        require(digest(path.read_bytes()) == digest(content), f"Recovered file verification failed: {relative}")
    summary.update({"input_log": str(Path(log_path).resolve()), "input_log_sha256": digest(data),
                    "expected_identity_file": str(Path(expected_path).resolve()), "expected_identity_sha256": digest(expectation_bytes),
                    "reconstructor_sha256": digest(Path(__file__).read_bytes())})
    with (destination / "reconstruction.json").open("x") as handle:
        json.dump(summary, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--expected", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = reconstruct(args.log, args.expected, args.output)
    print(json.dumps({k: result[k] for k in ("state", "retained_files", "retained_bytes", "test_steps_successful")}, indent=2))
    print("Recovered directory:", args.output.resolve())


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as exc:
        print(f"Hosted evidence reconstruction FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
