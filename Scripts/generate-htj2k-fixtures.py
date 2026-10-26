#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the HTJ2K (ISO/IEC 15444-15) fixture set from the same deterministic synthetic
images as generate-lossless-fixtures.py, encoded by two independent Part 15 encoders
(OpenJPH ojph_compress, Kakadu kdu_compress Cmodes=HT) and cross-decoded by three
independent decoders (ojph_expand, kdu_expand, opj_decompress). Every codestream is
an *output* of a reference encoder run on in-house synthetic samples; the manifest
records per-decoder sample exactness so a variant that only one oracle can read
(Kakadu's HT/legacy mixed mode) is recorded as such and never claimed as triangulated.

Usage: generate-htj2k-fixtures.py [OUTPUT_DIR]   (default: Tests/SwiftJ2KTests/Fixtures/HTJ2K)
"""
import hashlib, json, os, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "Tests", "SwiftJ2KTests", "Fixtures", "HTJ2K")
OJPH = "/opt/homebrew/bin/ojph_compress"; OJPHD = "/opt/homebrew/bin/ojph_expand"
KDU = "/usr/local/bin/kdu_compress"; KDUD = "/usr/local/bin/kdu_expand"
OPJD = "/opt/homebrew/bin/opj_decompress"

# Reuse the image generators, PGM helpers and FIXTURES table of the Part 1 generator without
# running its module-level encoding loop: execute its source up to the manifest construction.
source = open(os.path.join(HERE, "generate-lossless-fixtures.py")).read()
namespace = {"__name__": "lossless_fixture_definitions", "__file__": os.path.join(HERE, "generate-lossless-fixtures.py"), "sys": sys}
exec(compile(source[:source.index("\nmanifest = ")], "generate-lossless-fixtures.py", "exec"), namespace)
FIXTURES, write_pgm, read_pgm, sha, sample_digest = (namespace[k] for k in ("FIXTURES", "write_pgm", "read_pgm", "sha", "sample_digest"))

# (suffix, tool, arguments, description). OpenJPH default: 5 decompositions, 64x64 blocks, RPCL, HT only.
VARIANTS = [
    ("ojph",          "ojph", [],                                        "OpenJPH defaults: HT only, 5 levels, 64x64, RPCL"),
    ("ojph_n1",       "ojph", ["-num_decomps", "1"],                     "one decomposition level"),
    # ("ojph_n0", -num_decomps 0) is excluded: OpenJPH 0.30.1 encodes 16-bit samples of value 0 as 32768 at zero
    # decomposition levels (all three decoders agree with each other and disagree with the source on five of the ten
    # images), an encoder defect recorded in MILESTONE6.md rather than a fixture.
    ("ojph_b32",      "ojph", ["-block_size", "{32,32}"],                "32x32 code-blocks"),
    ("ojph_b16_n2",   "ojph", ["-block_size", "{16,16}", "-num_decomps", "2"], "16x16 code-blocks, two levels"),
    ("ojph_lrcp",     "ojph", ["-prog_order", "LRCP"],                   "LRCP progression"),
    ("kdu_ht",        "kdu",  ["Cmodes=HT"],                             "Kakadu HT only, defaults"),
    ("kdu_ht_l3",     "kdu",  ["Cmodes=HT", "Clevels=3", "Cblk={32,32}"], "Kakadu HT, three levels, 32x32 blocks"),
    ("kdu_ht_tiles",  "kdu",  ["Cmodes=HT", "Stiles={32,32}"],            "Kakadu HT, 32x32 tiles"),
    ("kdu_ht_layers", "kdu",  ["Cmodes=HT", "Clayers=3"],                 "Kakadu HT, three quality layers: HT code-blocks with several HT sets (7 passes); OpenJPH decodes one layer only and OpenJPEG at most 3 HT passes, so Kakadu is the only oracle"),
    ("kdu_ht_layers_lrcp", "kdu", ["Cmodes=HT", "Clayers=3", "Corder=LRCP"], "Kakadu HT, three layers, LRCP"),
    ("kdu_ht_precincts", "kdu", ["Cmodes=HT", "Cprecincts={32,32}", "Corder=RPCL", "Cuse_sop=yes", "Cuse_eph=yes"], "Kakadu HT, precincts, RPCL, SOP/EPH"),
    ("kdu_htmix",     "kdu",  ["Cmodes=HT|HTMIX"],                       "Kakadu HT with legacy blocks permitted (mixed); Kakadu-only oracle"),
]

def run(argv):
    return subprocess.run(argv, capture_output=True, text=True)

def decode_exact(codestream, px, w, h, bits):
    """Decode with each independent decoder; return {tool: True/False/None(error)}."""
    results = {}
    for tool, decoder in (("openjph", OJPHD), ("kakadu", KDUD), ("openjpeg", OPJD)):
        out = codestream + f".{tool}.pgm"
        if decoder == KDUD:
            r = run([decoder, "-i", codestream, "-o", out, "-quiet"])
        else:
            r = run([decoder, "-i", codestream, "-o", out])
        if r.returncode != 0 or not os.path.exists(out):
            results[tool] = None
        else:
            try:
                dw, dh, dmax, back = read_pgm(out)
                results[tool] = (dw, dh) == (w, h) and back == px
            except Exception:
                results[tool] = None
        if os.path.exists(out):
            os.remove(out)
    return results

os.makedirs(OUT, exist_ok=True)
manifest = {"generator": "generate-htj2k-fixtures.py (deterministic; same images and seeds as the Part 1 set)",
            "licence": "Apache-2.0 (synthetic, in-house)", "standard": "ISO/IEC 15444-15 (HTJ2K)", "tools": {}, "fixtures": []}
manifest["tools"]["openjph"] = "OpenJPH " + run(["brew", "list", "--versions", "openjph"]).stdout.split()[-1] + " (ojph_compress/ojph_expand, BSD-2-Clause)"
manifest["tools"]["kakadu"] = [l.strip() for l in run([KDU, "-version"]).stdout.splitlines() if "version" in l][0] + " (kdu_compress/kdu_expand, proprietary; test oracle only)"
manifest["tools"]["openjpeg"] = "OpenJPEG " + run(["brew", "list", "--versions", "openjpeg"]).stdout.split()[-1] + " (opj_decompress, BSD-2-Clause; Part 15 decode oracle)"

for name, w, h, bits, gen in FIXTURES:
    px = gen(w, h, bits)
    assert len(px) == w * h and max(px) < (1 << bits)
    pgm = os.path.join(OUT, name + ".pgm"); write_pgm(pgm, w, h, bits, px)
    entry = dict(name=name, width=w, height=h, meaningfulBits=bits, storageBits=16, sampleType="unsigned",
                 pgm_sha256=sha(pgm), sample_digest_le16=sample_digest(px), minimum=min(px), maximum=max(px), codestreams=[])
    for suffix, tool, args, description in VARIANTS:
        ext = "j2c" if tool == "ojph" else "j2k"
        codestream = os.path.join(OUT, f"{name}.{suffix}.{ext}")
        if tool == "ojph":
            r = run([OJPH, "-i", pgm, "-o", codestream, "-reversible", "true", *args])
        else:
            r = run([KDU, "-i", pgm, "-o", codestream, "Creversible=yes", "-quiet", *args])
        if r.returncode != 0 or not os.path.exists(codestream) or os.path.getsize(codestream) == 0:
            entry["codestreams"].append(dict(file=os.path.basename(codestream), tool=tool, arguments=args, description=description,
                                             produced=False, encoder_message=(r.stderr or r.stdout).strip()[:300]))
            if os.path.exists(codestream):
                os.remove(codestream)
            continue
        exact = decode_exact(codestream, px, w, h, bits)
        entry["codestreams"].append(dict(file=os.path.basename(codestream), tool=tool, arguments=args, description=description,
                                         produced=True, bytes=os.path.getsize(codestream), sha256=sha(codestream),
                                         independent_decode_exact=exact,
                                         triangulated=all(v is True for v in exact.values())))
    os.remove(pgm)
    manifest["fixtures"].append(entry)
    print(name, f"{w}x{h}@{bits}", [(c["file"].split(".")[1], c.get("bytes"), "".join("T" if v else ("x" if v is None else "F") for v in c.get("independent_decode_exact", {}).values())) for c in entry["codestreams"]])

with open(os.path.join(OUT, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1, sort_keys=True)
produced = sum(1 for e in manifest["fixtures"] for c in e["codestreams"] if c["produced"])
triangulated = sum(1 for e in manifest["fixtures"] for c in e["codestreams"] if c.get("triangulated"))
print(f"{produced} codestreams written, {triangulated} triangulated by all three decoders; manifest.json written to {OUT}")
