#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate bounded independent zero-DWT HT fixtures with installed Kakadu.

No production library invokes this tool. Use a new output directory; retained
fixtures are never overwritten. See the R3 fixture README for evidence limits.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def samples(path):
    data = path.read_bytes()
    position = 0
    tokens = []
    while len(tokens) < 4:
        while data[position] in b" \r\n\t":
            position += 1
        if data[position] == 35:
            position = data.index(b"\n", position) + 1
            continue
        end = position
        while data[end] not in b" \r\n\t":
            end += 1
        tokens.append(data[position:end])
        position = end
    if tokens[0] != b"P5":
        raise ValueError("Expected binary PGM")
    position += 2 if data[position:position + 2] == b"\r\n" else 1
    width, height, maximum = map(int, tokens[1:])
    payload = data[position:]
    if len(payload) != width * height * (1 if maximum < 256 else 2):
        raise ValueError("PGM sample length mismatch")
    return width, height, maximum, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["planar", "refinement"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tools", type=Path, help="Directory containing Kakadu executables")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    inputs = root / "Tests/SwiftJ2KTests/Fixtures/Lossless"
    names = ["kdu_compress", "kdu_expand"] + (["kdu_transcode"] if args.kind == "refinement" else [])
    tools = {}
    for name in names:
        found = str(args.tools / name) if args.tools else shutil.which(name)
        if not found:
            raise RuntimeError("Missing independent tool: " + name)
        tools[name] = Path(found).resolve()
    records = []

    def run(record, command):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        log = args.output / (record["name"] + "." + str(len(record["steps"])) + ".log")
        log.write_bytes(result.stdout)
        record["steps"].append({"command": command, "exit_code": result.returncode, "log_sha256": sha(log)})
        if result.returncode:
            raise RuntimeError("Independent tool failed; see " + str(log))

    if args.kind == "planar":
        for name in ["g12_5x3_ramp_extremes", "g16_17x9_alternating", "g08_37x23_random"]:
            source = inputs / (name + ".pgm")
            output = args.output / (name + ".kdu_ht_n0_layers_lrcp.j2k")
            decoded = args.output / (name + ".decoded.pgm")
            record = {"name": name, "source_sha256": sha(source), "steps": []}
            run(record, [str(tools["kdu_compress"]), "-i", str(source), "-o", str(output),
                "Creversible=yes", "Cmodes=HT", "Clevels=0", "Clayers=3", "Corder=LRCP", "-num_threads", "0", "-quiet"])
            run(record, [str(tools["kdu_expand"]), "-i", str(output), "-o", str(decoded), "-num_threads", "0", "-precise", "-quiet"])
            record.update(codestream_sha256=sha(output), decoded_sha256=sha(decoded), exact_samples=samples(source) == samples(decoded))
            if not record["exact_samples"]:
                raise RuntimeError("Independent lossless sample mismatch")
            records.append(record)
    else:
        source = inputs / "g16_64x64_random.pgm"
        for rate in [4, 8, 12]:
            name = "rate" + str(rate)
            part1 = args.output / (name + ".part1.j2k")
            ht = args.output / (name + ".ht.j2k")
            record = {"name": name, "source_sha256": sha(source), "steps": []}
            run(record, [str(tools["kdu_compress"]), "-i", str(source), "-o", str(part1),
                "Creversible=yes", "Cmodes=0", "Clevels=0", "Clayers=1", "Cblk={8,8}", "-rate", str(rate), "-num_threads", "0", "-quiet"])
            run(record, [str(tools["kdu_transcode"]), "-i", str(part1), "-o", str(ht), "Cmodes=HT", "-quiet"])
            decoded = []
            for kind, codestream in [("part1", part1), ("ht", ht)]:
                path = args.output / (name + "." + kind + ".pgm")
                run(record, [str(tools["kdu_expand"]), "-i", str(codestream), "-o", str(path), "-num_threads", "0", "-precise", "-quiet"])
                decoded.append(path)
            record["files"] = {p.name: sha(p) for p in [part1, ht] + decoded}
            record["independent_part1_ht_decodes_equal"] = samples(decoded[0]) == samples(decoded[1])
            if not record["independent_part1_ht_decodes_equal"]:
                raise RuntimeError("Independent transcode sample mismatch")
            records.append(record)
    manifest = {"kind": args.kind, "input_license": "Apache-2.0 synthetic fixtures",
        "tools": {name: {"path": str(path), "sha256": sha(path)} for name, path in tools.items()},
        "records": records, "scope": "Independent 2D HT evidence only; inspect actual segments before claiming refinement. No direct Part10+15 peer or MULTIHT qualification."}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
