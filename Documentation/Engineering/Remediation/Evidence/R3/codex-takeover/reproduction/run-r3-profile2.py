#!/usr/bin/env python3
"""Profile only the two child processes this invocation creates. Never builds."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import platform
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def stop_owned(child):
    # Popen handles only our unreaped direct child. No pgrep, killall, or groups.
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=2)


def dependency_identity(root):
    files = [root / "Package.swift"] + sorted((root / "Sources").rglob("*.swift"))
    hashes = {str(p.relative_to(root)): sha(p) for p in files}
    aggregate = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return {"path": str(root), "source_file_count": len(hashes),
            "source_manifest_sha256": aggregate, "source_hashes": hashes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-bin", type=Path, required=True)
    parser.add_argument("--candidate-bin", type=Path, required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    work = Path(__file__).resolve().parent
    receipt_path = work / "r3-profile2-harness-source.json"
    receipt = json.loads(receipt_path.read_text())
    original = work / "r3-benchmark-harness" / "Bench.swift"
    if sha(original) != receipt["original_benchmark_sha256"]:
        raise RuntimeError("Measured harness source changed since profile preparation")
    bins = {"baseline": args.baseline_bin.resolve(), "candidate": args.candidate_bin.resolve()}
    inputs = args.inputs.resolve()
    for name in ["odd8.raw", "odd8.ht.j2k"]:
        if not (inputs / name).is_file():
            raise RuntimeError("Missing common input " + name)
    identities = {}
    for variant, binary in bins.items():
        entry = receipt["packages"][variant]
        package = Path(entry["path"])
        if binary.name != "r3-profile2" or not binary.is_relative_to(Path(entry["scratch_path"])):
            raise RuntimeError("Binary must come from the separate " + variant + " profile build")
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError("Profile binary does not exist or is not executable: " + str(binary))
        if sha(package / "Package.swift") != entry["manifest_sha256"] or sha(package / "Sources/Profile/Bench.swift") != entry["harness_sha256"]:
            raise RuntimeError("Profile package changed; review and refresh its preparation receipt first")
        identities[variant] = {
            "path": str(binary), "sha256": sha(binary), "size": binary.stat().st_size,
            "mtime_ns": binary.stat().st_mtime_ns, "package": entry,
            "dependency": dependency_identity(Path(entry["dependency"]))}
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    metadata = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "Bounded R3 CPU profile diagnostic; not acceptance timing or R4 qualification",
        "platform": platform.platform(), "receipt_sha256": sha(receipt_path),
        "runner_sha256": sha(Path(__file__).resolve()),
        "binaries": identities,
        "input_hashes": {name: sha(inputs / name) for name in ["odd8.raw", "odd8.ht.j2k"]},
        "case": "odd8", "operation": "transcode-to-ebcot", "warmups": 5,
        "requested_iterations": 10000, "profile_loop_duration_cap_seconds": 45,
        "sample_seconds": 5, "sample_interval_ms": 1, "process_timeout_seconds": 60,
        "environment": {k: os.environ[k] for k in ["DEVELOPER_DIR", "SDKROOT"] if k in os.environ},
        "runs": []}
    metadata_path = output / "metadata.json"
    write_json(metadata_path, metadata)
    try:
        for variant, binary in bins.items():
            ready = output / (variant + ".ready.json")
            start = output / (variant + ".start")
            sample_file = output / (variant + ".sample.txt")
            argv = [str(binary), "profile", str(inputs), "odd8", "transcode-to-ebcot", "10000", str(ready), str(start)]
            record = {"variant": variant, "argv": argv, "binary_sha256_before": sha(binary)}
            metadata["runs"].append(record)
            child = sampler = None
            began = time.monotonic()
            deadline = began + 60
            try:
                with (output / (variant + ".stdout")).open("wb") as stdout, (output / (variant + ".stderr")).open("wb") as stderr:
                    child = subprocess.Popen(argv, stdout=stdout, stderr=stderr)
                    record["pid"] = child.pid
                    write_json(metadata_path, metadata)
                    ready_deadline = min(deadline, time.monotonic() + 10)
                    while not ready.exists():
                        if child.poll() is not None:
                            raise RuntimeError(variant + " exited before readiness; inspect logs")
                        if time.monotonic() >= ready_deadline:
                            raise TimeoutError(variant + " readiness timeout")
                        time.sleep(0.01)
                    handshake = json.loads(ready.read_text())
                    if handshake["pid"] != child.pid or child.poll() is not None:
                        raise RuntimeError("Readiness does not identify the live child we own")
                    record["readiness"] = handshake
                    sample_argv = ["/usr/bin/sample", str(child.pid), "5", "1", "-file", str(sample_file)]
                    record["sample_argv"] = sample_argv
                    with (output / (variant + ".sample.stdout")).open("wb") as sout, (output / (variant + ".sample.stderr")).open("wb") as serr:
                        sampler = subprocess.Popen(sample_argv, stdout=sout, stderr=serr)
                        record["sampler_pid"] = sampler.pid
                        # The sampler is launched before releasing the warmed codec loop.
                        with start.open("x") as signal:
                            signal.write("start\n")
                        write_json(metadata_path, metadata)
                        sampler.wait(timeout=min(15, max(0.001, deadline - time.monotonic())))
                        record["sample_exit_code"] = sampler.returncode
                        if sampler.returncode != 0:
                            raise RuntimeError(variant + " sample failed; inspect sampler logs")
                    child.wait(timeout=max(0.001, deadline - time.monotonic()))
                    record["exit_code"] = child.returncode
                    if child.returncode != 0:
                        raise RuntimeError(variant + " profile loop failed; inspect logs")
                result = json.loads((output / (variant + ".stdout")).read_text().splitlines()[-1])
                if result["pid"] != child.pid or not result["final_sample_exact"] or result["actual_iterations"] <= 0:
                    raise RuntimeError(variant + " invalid profile result")
                if result["profile_loop_seconds"] < 5 or not sample_file.is_file() or sample_file.stat().st_size == 0:
                    raise RuntimeError(variant + " profile did not cover a complete five-second busy window")
                record["result"] = result
                record["sample_sha256"] = sha(sample_file)
                record["binary_sha256_after"] = sha(binary)
                if record["binary_sha256_after"] != record["binary_sha256_before"]:
                    raise RuntimeError(variant + " binary changed during profiling")
                record["completed"] = True
                print(variant + " profile complete: " + str(result["actual_iterations"]) + " operations", flush=True)
            finally:
                stop_owned(sampler)
                stop_owned(child)
                record["process_wall_seconds"] = time.monotonic() - began
                write_json(metadata_path, metadata)
        metadata["completed"] = True
    except BaseException as error:
        metadata["completed"] = False
        metadata["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        metadata["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_json(metadata_path, metadata)


if __name__ == "__main__":
    main()
