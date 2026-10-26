#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Controlled release benchmark of the swiftj2k-cli CLI against reference tools
(PERFORMANCE.md PERF-02): cold command-line invocations, 5 warm-ups and 20
interleaved timed iterations per case, medians, p95, spread and pixels/s, plus
HTJ2K encode/decode and native coefficient transcode vs decode+encode sample
baseline with structured memory/workspace telemetry.

Usage: benchmark-lossless.py --binary /abs/release/swiftj2k-cli --output /new/dir

Cases are the repository's synthetic fixtures. Each codec is invoked as a
fresh process, so process start-up is part of every figure; results describe
this host and configuration only and are not a release gate on their own.
"""
import argparse, json, os, platform, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "Tests/SwiftJ2KTests/Fixtures/Lossless"
HT_FIXTURES = REPO / "Tests/SwiftJ2KTests/Fixtures/HTJ2K"
WARMUPS, ITERATIONS = 5, 20
CASES = ["g16_64x64_random", "g12_129x67_gradient", "g16_256x256_smooth", "g10_300x200_gradient"]

def timed(argv, env=None):
    start = time.perf_counter()
    r = subprocess.run(argv, capture_output=True, env=env)
    elapsed = time.perf_counter() - start
    if r.returncode != 0:
        raise RuntimeError(f"{argv[0]} exited {r.returncode}: {r.stderr.decode(errors='replace')[:200]}")
    return elapsed

def timed_sequence(argvs, env=None):
    start = time.perf_counter()
    for argv in argvs:
        r = subprocess.run(argv, capture_output=True, env=env)
        if r.returncode != 0:
            raise RuntimeError(f"{argv[0]} exited {r.returncode}: {r.stderr.decode(errors='replace')[:200]}")
    return time.perf_counter() - start

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    tools = {
        "swiftj2k-cli": {"encode": [str(binary), "encode", "-i", "{nrrd}", "-o", "{out}", "--overwrite", "--precision", "{bits}"],
                         "decode": [str(binary), "decode", "-i", "{j2k}", "-o", "{out}", "--overwrite"]},
    }
    opj_c, opj_d = shutil.which("opj_compress"), shutil.which("opj_decompress")
    if opj_c and opj_d:
        tools["openjpeg"] = {"encode": [opj_c, "-i", "{pgm}", "-o", "{out}"], "decode": [opj_d, "-i", "{j2k}", "-o", "{out}"]}
    kdu_c, kdu_d = shutil.which("kdu_compress") or "/usr/local/bin/kdu_compress", shutil.which("kdu_expand") or "/usr/local/bin/kdu_expand"
    if os.access(kdu_c, os.X_OK) and os.access(kdu_d, os.X_OK):
        tools["kakadu"] = {"encode": [kdu_c, "-i", "{pgm}", "-o", "{out}", "Creversible=yes", "-quiet"],
                           "decode": [kdu_d, "-i", "{j2k}", "-o", "{out}", "-quiet"]}
    ht_tools = {
        "swiftj2k-cli": {"encode": [str(binary), "encode", "-i", "{nrrd}", "-o", "{out}", "--output-format", "htj2k", "--overwrite", "--precision", "{bits}"],
                         "decode": [str(binary), "decode", "-i", "{htj2k}", "-o", "{out}", "--overwrite"]},
    }
    ojph_c, ojph_d = shutil.which("ojph_compress") or "/opt/homebrew/bin/ojph_compress", shutil.which("ojph_expand") or "/opt/homebrew/bin/ojph_expand"
    if os.access(ojph_c, os.X_OK) and os.access(ojph_d, os.X_OK):
        ht_tools["openjph"] = {"encode": [ojph_c, "-i", "{pgm}", "-o", "{out}", "-reversible", "true"],
                               "decode": [ojph_d, "-i", "{htj2k}", "-o", "{out}"]}
    if os.access(kdu_c, os.X_OK) and os.access(kdu_d, os.X_OK):
        ht_tools["kakadu-ht"] = {"encode": [kdu_c, "-i", "{pgm}", "-o", "{out}", "Creversible=yes", "Cmodes=HT", "-quiet"],
                                 "decode": [kdu_d, "-i", "{htj2k}", "-o", "{out}", "-quiet"]}
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    entries = {e["name"]: e for e in manifest["fixtures"]}
    host = {"machine": platform.machine(), "system": platform.system(), "release": platform.release(),
            "binary_sha256": __import__("hashlib").sha256(binary.read_bytes()).hexdigest(),
            "tools": {name: spec["encode"][0] for name, spec in {**tools, **ht_tools}.items()}, "warmups": WARMUPS, "iterations": ITERATIONS}
    results = []
    ht_results = []
    transcode_results = []
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        for name in CASES:
            entry = entries[name]
            pixels = entry["width"] * entry["height"]
            pgm = FIXTURES / f"{name}.pgm"
            j2k = FIXTURES / entry["codestreams"][0]["file"]
            htj2k = HT_FIXTURES / f"{name}.ojph.j2c"
            nrrd = temp / f"{name}.nrrd"
            subprocess.run([str(binary), "decode", "-i", str(j2k), "-o", str(nrrd)], check=True, capture_output=True)
            for direction in ("encode", "decode"):
                samples = {tool: [] for tool in tools}
                def argv(tool):
                    ext = ".j2k" if direction == "encode" else (".nrrd" if tool == "swiftj2k-cli" else ".pgm")
                    return [a.format(nrrd=nrrd, pgm=pgm, j2k=j2k, out=temp / f"{tool}-{direction}-{name}{ext}", bits=entry["meaningfulBits"]) for a in tools[tool][direction]]
                for _ in range(WARMUPS):
                    for tool in tools: timed(argv(tool))
                for i in range(ITERATIONS):
                    order = list(tools) if i % 2 == 0 else list(reversed(list(tools)))
                    for tool in order: samples[tool].append(timed(argv(tool)))
                row = {"case": name, "direction": direction, "width": entry["width"], "height": entry["height"],
                       "meaningfulBits": entry["meaningfulBits"], "codestreamBytes": j2k.stat().st_size, "tools": {}}
                for tool, values in samples.items():
                    ordered = sorted(values)
                    median = statistics.median(values)
                    row["tools"][tool] = {"median_ms": median * 1000, "p95_ms": ordered[int(0.95 * (len(ordered) - 1))] * 1000,
                                          "min_ms": ordered[0] * 1000, "max_ms": ordered[-1] * 1000,
                                          "megapixels_per_s": pixels / median / 1e6, "samples_ms": [v * 1000 for v in values]}
                results.append(row)
                print(f"{name:24s} {direction:6s} " + "  ".join(f"{tool} {row['tools'][tool]['median_ms']:7.1f} ms" for tool in tools), flush=True)

            # HTJ2K encode / decode benchmark
            for direction in ("encode", "decode"):
                samples = {tool: [] for tool in ht_tools}
                def ht_argv(tool):
                    ext = ".j2c" if direction == "encode" else (".nrrd" if tool == "swiftj2k-cli" else ".pgm")
                    return [a.format(nrrd=nrrd, pgm=pgm, htj2k=htj2k, out=temp / f"{tool}-ht-{direction}-{name}{ext}", bits=entry["meaningfulBits"]) for a in ht_tools[tool][direction]]
                for _ in range(WARMUPS):
                    for tool in ht_tools: timed(ht_argv(tool))
                for i in range(ITERATIONS):
                    order = list(ht_tools) if i % 2 == 0 else list(reversed(list(ht_tools)))
                    for tool in order: samples[tool].append(timed(ht_argv(tool)))
                row = {"case": name, "direction": f"ht-{direction}", "width": entry["width"], "height": entry["height"],
                       "meaningfulBits": entry["meaningfulBits"], "codestreamBytes": htj2k.stat().st_size, "tools": {}}
                for tool, values in samples.items():
                    ordered = sorted(values)
                    median = statistics.median(values)
                    row["tools"][tool] = {"median_ms": median * 1000, "p95_ms": ordered[int(0.95 * (len(ordered) - 1))] * 1000,
                                          "min_ms": ordered[0] * 1000, "max_ms": ordered[-1] * 1000,
                                          "megapixels_per_s": pixels / median / 1e6, "samples_ms": [v * 1000 for v in values]}
                ht_results.append(row)
                print(f"{name:24s} ht-{direction:6s} " + "  ".join(f"{tool} {row['tools'][tool]['median_ms']:7.1f} ms" for tool in ht_tools), flush=True)

            # Native coefficient transcode vs 2-step decode+encode sample baseline
            for tdir, src_file, out_fmt, out_ext in (
                ("j2k-to-htj2k", j2k, "htj2k", ".j2c"),
                ("htj2k-to-j2k", htj2k, "j2k", ".j2k"),
            ):
                coeff_cmd = [str(binary), "transcode", "-i", str(src_file), "-o", str(temp / f"coeff-{tdir}-{name}{out_ext}"), "--output-format", out_fmt, "--overwrite", "--json"]
                mid_nrrd = temp / f"sample-mid-{tdir}-{name}.nrrd"
                sample_cmds = [
                    [str(binary), "decode", "-i", str(src_file), "-o", str(mid_nrrd), "--overwrite", "--json"],
                    [str(binary), "encode", "-i", str(mid_nrrd), "-o", str(temp / f"sample-{tdir}-{name}{out_ext}"), "--output-format", out_fmt, "--overwrite", "--json"],
                ]
                for _ in range(WARMUPS):
                    timed(coeff_cmd); timed_sequence(sample_cmds)
                coeff_samples, sample_samples = [], []
                for i in range(ITERATIONS):
                    if i % 2 == 0:
                        coeff_samples.append(timed(coeff_cmd))
                        sample_samples.append(timed_sequence(sample_cmds))
                    else:
                        sample_samples.append(timed_sequence(sample_cmds))
                        coeff_samples.append(timed(coeff_cmd))
                coeff_r = json.loads(subprocess.run(coeff_cmd, check=True, capture_output=True).stderr.decode())
                dec_r = json.loads(subprocess.run(sample_cmds[0], check=True, capture_output=True).stderr.decode())
                enc_r = json.loads(subprocess.run(sample_cmds[1], check=True, capture_output=True).stderr.decode())
                c_ord, s_ord = sorted(coeff_samples), sorted(sample_samples)
                c_med, s_med = statistics.median(coeff_samples), statistics.median(sample_samples)
                trow = {
                    "case": name, "direction": tdir, "width": entry["width"], "height": entry["height"],
                    "meaningfulBits": entry["meaningfulBits"], "inputBytes": src_file.stat().st_size,
                    "coefficientPath": {
                        "median_ms": c_med * 1000, "p95_ms": c_ord[int(0.95 * (len(c_ord) - 1))] * 1000,
                        "min_ms": c_ord[0] * 1000, "max_ms": c_ord[-1] * 1000,
                        "in_process_elapsed_ms": coeff_r["elapsedSeconds"] * 1000,
                        "peak_workspace_bytes": coeff_r["peakWorkspaceBytes"],
                        "pixel_allocations": coeff_r["pixelAllocations"],
                        "copy_events": coeff_r["copyEvents"],
                        "output_bytes": coeff_r["outputBytes"],
                        "samples_ms": [v * 1000 for v in coeff_samples],
                    },
                    "sampleDecodeEncodeBaseline": {
                        "median_ms": s_med * 1000, "p95_ms": s_ord[int(0.95 * (len(s_ord) - 1))] * 1000,
                        "min_ms": s_ord[0] * 1000, "max_ms": s_ord[-1] * 1000,
                        "in_process_elapsed_ms": (dec_r["elapsedSeconds"] + enc_r["elapsedSeconds"]) * 1000,
                        "decode_peak_workspace_bytes": dec_r["peakWorkspaceBytes"],
                        "encode_peak_workspace_bytes": enc_r["peakWorkspaceBytes"],
                        "decode_pixel_allocations": dec_r["pixelAllocations"],
                        "samples_ms": [v * 1000 for v in sample_samples],
                    },
                }
                transcode_results.append(trow)
                print(f"{name:24s} {tdir:14s} coeff {c_med*1000:7.1f} ms (in-proc {coeff_r['elapsedSeconds']*1000:5.2f} ms, ws {coeff_r['peakWorkspaceBytes']} B, 0 px alloc)  sample {s_med*1000:7.1f} ms (in-proc {(dec_r['elapsedSeconds']+enc_r['elapsedSeconds'])*1000:5.2f} ms)", flush=True)
    # In-memory shared-sample baseline (Decoder.decode(into:) + Encoder.encode) vs in-memory Transcoder.transcode
    in_memory_transcode = None
    consumer_dir = REPO / "Examples/Consumer"
    if consumer_dir.is_dir():
        subprocess.run(["swift", "build", "--build-system", "native", "-c", "release", "--package-path", str(consumer_dir)], check=True, capture_output=True)
        consumer_bin = consumer_dir / ".build/out/Products/Release/Consumer"
        if not consumer_bin.exists():
            consumer_bin = consumer_dir / ".build/release/Consumer"
        in_mem_run = subprocess.run([str(consumer_bin), "--benchmark-in-memory", str(REPO)], check=True, capture_output=True)
        in_memory_transcode = json.loads(in_mem_run.stdout.decode())
        for row in in_memory_transcode.get("cases", []):
            cm = row["inMemoryCoefficientPath"]["median_ms"]
            sm = row["inMemorySharedSampleBaseline"]["median_ms"]
            cws = row["inMemoryCoefficientPath"]["peak_workspace_bytes"]
            sws = row["inMemorySharedSampleBaseline"]["peak_workspace_bytes"]
            spx = row["inMemorySharedSampleBaseline"]["peak_pixel_bytes"]
            print(f"{row['case']:24s} in-mem {row['direction']:14s} coeff {cm:6.2f} ms (ws {cws} B, px 0 B)  shared-sample {sm:6.2f} ms (ws {sws} B, px {spx} B)", flush=True)

    (out / "results.json").write_text(json.dumps({
        "host": host,
        "method": "cold CLI invocations + in-process shared-sample vs coefficient transcode benchmark, 5 warm-ups then 20 interleaved timed iterations per case; medians and p95s reported",
        "results": results,
        "htj2k_results": ht_results,
        "transcode_results": transcode_results,
        "in_memory_transcode": in_memory_transcode,
    }, indent=2) + "\n")
    print(f"written {out / 'results.json'}")

if __name__ == "__main__":
    sys.exit(main())
