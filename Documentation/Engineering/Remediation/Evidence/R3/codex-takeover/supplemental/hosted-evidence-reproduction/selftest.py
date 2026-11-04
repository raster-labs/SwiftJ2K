#!/usr/bin/env python3
"""Pure synthetic reconstruction tests. No CI, Git, network or native execution."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile

HERE = Path(__file__).resolve().parent
loader = importlib.util.spec_from_file_location("hosted_reconstruct", HERE / "reconstruct.py")
m = importlib.util.module_from_spec(loader)
loader.loader.exec_module(m)

expected = {"identity": {
    "GITHUB_REPOSITORY": "synthetic-owner/synthetic-repository", "GITHUB_RUN_ID": "12345",
    "GITHUB_RUN_ATTEMPT": "2", "GITHUB_JOB": "macos", "GITHUB_EVENT_NAME": "pull_request",
    "GITHUB_REF": "refs/pull/42/merge", "GITHUB_SHA": "1" * 40,
    "EVIDENCE_PR_HEAD": "2" * 40, "EVIDENCE_PR_BASE": "3" * 40,
    "EVIDENCE_ORDINARY": "success", "EVIDENCE_ASAN": "success", "EVIDENCE_TSAN": "success"},
    "checkout_head": "1" * 40, "checkout_tree": "4" * 40}
files = {path: ("synthetic report: " + path + "\n").encode() for path in m.REQUIRED}
for group in m.XML_GROUPS:
    files[group[1]] = b'<testsuites><testsuite name="synthetic"/></testsuites>\n'
files["address/reference.stderr"] = b""
files["address/reference.stdout"] = ('quotes " backslash \\ CR\r LF\n TAB\t NUL\0 snowman \u2603 emoji \U0001f600\n' + '\U0001f600' * 4097).encode("utf-8")


def record(kind, **values):
    return {"format": m.FORMAT, "kind": kind, **values}


def make_records():
    records = [record("begin", **expected, tracked_tree_clean=True,
                      max_file_bytes=m.MAX_FILE, max_total_bytes=m.MAX_TOTAL)]
    for path in m.ALLOWED:
        if path not in files:
            records.append(record("missing", path=path))
            continue
        data = files[path]
        text = data.decode("utf-8")
        chunks = [text[i:i + 4096] for i in range(0, len(text), 4096)]
        records.append(record("file", path=path, bytes=len(data), sha256=m.digest(data), encoding="utf-8", chunks=len(chunks)))
        records.extend(record("chunk", path=path, index=i, content_utf8=content) for i, content in enumerate(chunks))
    records.append(record("end", files=len(files), bytes=sum(map(len, files.values())), problems=[],
                          retention_complete=True, scope=m.SCOPE))
    return records


def wire(records):
    return ("2026-10-31T00:00:00.0000000Z command echo ignored\n"
            "2026-10-31T00:00:00.0000000Z {\"format\":\"unrelated-format\",\"value\":1}\n" +
            "".join("2026-10-31T00:00:01.1234567Z " + json.dumps(r, ensure_ascii=True, separators=(",", ":")) + "\n"
                    for r in records)).encode("utf-8")


base = make_records()
recovered, summary = m.validate_log(wire(base), expected)
assert recovered == files and summary["retained_files"] == 25 and len(summary["explicitly_missing_paths"]) == 7
assert len(m.ALLOWED) == 32 and summary["test_steps_successful"]
checks = [{"name": "exact roundtrip: empty/control/Unicode/multiple chunks/all 32 paths", "result": "passed"}]


def rejects(name, mutate=None, expectation=None, raw=None):
    trial = copy.deepcopy(base)
    if mutate:
        mutate(trial)
    try:
        m.validate_log(raw if raw is not None else wire(trial), expectation or expected)
    except (ValueError, UnicodeError, TypeError, KeyError) as exc:
        checks.append({"name": name, "result": "rejected as required", "reason": str(exc)})
    else:
        raise AssertionError("Bad evidence accepted: " + name)


first_file = next(i for i, r in enumerate(base) if r["kind"] == "file")
first_chunk = next(i for i, r in enumerate(base) if r["kind"] == "chunk")
multi_file = next(i for i, r in enumerate(base) if r["kind"] == "file" and r["chunks"] > 1)
missing_xml = next(i for i, r in enumerate(base) if r["kind"] == "missing" and r["path"] == "ordinary/full.xml")
rejects("missing begin", lambda r: r.pop(0))
rejects("duplicate begin", lambda r: r.insert(1, copy.deepcopy(r[0])))
rejects("missing end/truncated log", lambda r: r.pop())
rejects("duplicate end/combined attempts", lambda r: r.append(copy.deepcopy(r[-1])))
rejects("run attempt mismatch", lambda r: r[0]["identity"].update(GITHUB_RUN_ATTEMPT="3"))
rejects("PR head mismatch", lambda r: r[0]["identity"].update(EVIDENCE_PR_HEAD="f" * 40))
rejects("merge tree mismatch", lambda r: r[0].update(checkout_tree="e" * 40))
rejects("step outcome mismatch", lambda r: r[0]["identity"].update(EVIDENCE_TSAN="failure"))
rejects("tracked tree dirty", lambda r: r[0].update(tracked_tree_clean=False))
rejects("path traversal", lambda r: r[first_file].update(path="../outside"))
rejects("absolute path", lambda r: r[first_file].update(path="/tmp/outside"))
rejects("unknown allowlist path", lambda r: r[first_file].update(path="address/secret.txt"))
rejects("duplicate file", lambda r: r.insert(first_file + 1, copy.deepcopy(r[first_file])))
rejects("missing path record", lambda r: r.pop(missing_xml))
rejects("duplicate chunk", lambda r: r.insert(first_chunk + 1, copy.deepcopy(r[first_chunk])))
rejects("unordered chunk index", lambda r: r[multi_file + 1].update(index=1))
rejects("wrong chunk owner", lambda r: r[first_chunk].update(path="thread/all.ids"))
rejects("missing chunk", lambda r: r.pop(first_chunk))
rejects("masked content", lambda r: r[first_chunk].update(content_utf8="***"))
rejects("masked file hash", lambda r: r[first_file].update(sha256="***"))
rejects("wrong UTF8 byte count", lambda r: r[first_file].update(bytes=r[first_file]["bytes"] + 1))
rejects("lone surrogate/invalid UTF8", lambda r: r[first_chunk].update(content_utf8="\ud800"))
rejects("non-final short chunk", lambda r: r[multi_file + 1].update(content_utf8="x"))
rejects("boolean chunk index", lambda r: r[first_chunk].update(index=False))
rejects("footer file mismatch", lambda r: r[-1].update(files=24))
rejects("footer byte mismatch", lambda r: r[-1].update(bytes=r[-1]["bytes"] + 1))
rejects("retention problem", lambda r: r[-1].update(problems=["synthetic error"]))
rejects("incomplete footer", lambda r: r[-1].update(retention_complete=False))
rejects("unknown record field", lambda r: r[-1].update(ignored="not allowed"))
rejects("declared file ceiling", lambda r: r[first_file].update(bytes=m.MAX_FILE + 1))
rejects("changed emitter ceiling", lambda r: r[0].update(max_total_bytes=m.MAX_TOTAL + 1))
rejects("missing timestamp", raw=wire(base).replace(b'2026-10-31T00:00:01.1234567Z {"format"', b'{"format"', 1))
rejects("malformed matching JSON", raw=wire(base) + b'2026-10-31T00:00:02Z {"format":"swiftj2k-ci-evidence-v1",\n')
rejects("duplicate JSON key", raw=wire(base).replace(b'"kind":"begin"', b'"kind":"begin","kind":"begin"', 1))

def remove_retained_path(records, path):
    index = next(i for i, r in enumerate(records) if r["kind"] == "file" and r["path"] == path)
    removed = records[index]
    del records[index:index + 1 + removed["chunks"]]
    records.insert(index, record("missing", path=path))
    records[-1]["files"] -= 1
    records[-1]["bytes"] -= removed["bytes"]

rejects("required inventory missing despite consistent footer", lambda r: remove_retained_path(r, "address/all.ids"))
rejects("entire invocation XML group missing despite consistent footer", lambda r: remove_retained_path(r, "ordinary/full-swift-testing.xml"))

# A reported failing test outcome may still be reconstructed when independently
# expected; this must remain retention-only and explicitly not successful tests.
failed_records = copy.deepcopy(base)
failed_expected = copy.deepcopy(expected)
failed_records[0]["identity"]["EVIDENCE_TSAN"] = "failure"
failed_expected["identity"]["EVIDENCE_TSAN"] = "failure"
_, failed_summary = m.validate_log(wire(failed_records), failed_expected)
assert failed_summary["test_steps_successful"] is False
checks.append({"name": "matching failed step retained without success claim", "result": "passed"})

with tempfile.TemporaryDirectory(prefix="synthetic-selftest-", dir=HERE) as temporary:
    directory = Path(temporary)
    log_path, expected_path = directory / "synthetic.log", directory / "expected.json"
    log_path.write_bytes(wire(base)); expected_path.write_text(json.dumps(expected))
    output = directory / "recovered"
    saved = m.reconstruct(log_path, expected_path, output)
    assert all((output / path).read_bytes() == content for path, content in files.items())
    assert (output / "reconstruction.json").is_file()
    checks.append({"name": "fresh work directory exact file-byte writes", "result": "passed"})
    try:
        m.reconstruct(log_path, expected_path, output)
    except ValueError:
        checks.append({"name": "existing output refused", "result": "rejected as required"})
    else:
        raise AssertionError("Existing output accepted")
    for invalid in (m.WORK, Path("/private/tmp/hosted-evidence-not-authorized-output")):
        try:
            m.fresh_work_directory(invalid)
        except ValueError:
            checks.append({"name": "output boundary " + str(invalid), "result": "rejected as required"})
        else:
            raise AssertionError("Output boundary escaped")
    link = directory / "linked"
    link.symlink_to(directory, target_is_directory=True)
    try:
        m.fresh_work_directory(link / "recovered2")
    except ValueError:
        checks.append({"name": "symlinked output ancestor refused", "result": "rejected as required"})
    else:
        raise AssertionError("Symlinked output accepted")

report = {"state": "PURE_SYNTHETIC_SELFTEST_ONLY", "checks": checks, "count": len(checks),
          "reconstructor_sha256": m.digest((HERE / "reconstruct.py").read_bytes()),
          "selftest_sha256": m.digest(Path(__file__).read_bytes()),
          "boundary": "No actual hosted log, GitHub metadata, Swift/native runner or repository was accessed. Synthetic temporary outputs were removed. This does not qualify hosted evidence."}
(HERE / "selftest-result.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"Passed {len(checks)} synthetic reconstruction/error checks; no hosted evidence accepted.")
