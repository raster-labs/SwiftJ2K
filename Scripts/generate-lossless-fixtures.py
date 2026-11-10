# SPDX-License-Identifier: MIT
"""Deterministic synthetic greyscale fixtures for SwiftJ2K Milestone 2.
Writes PGM (P5, big-endian 16-bit when maxval > 255) plus independent
lossless JPEG 2000 codestreams from OpenJPEG and Kakadu, and a manifest with
SHA-256 values, geometry, precision and the sample digest (SHA-256 of the
little-endian UInt16 sample stream, row-major, no padding).
"""
import hashlib, json, os, struct, subprocess, sys
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
OPJ = "/opt/homebrew/bin/opj_compress"; OPJD = "/opt/homebrew/bin/opj_decompress"
KDU = "/usr/local/bin/kdu_compress"; KDUD = "/usr/local/bin/kdu_expand"

class XorShift32:
    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF or 1
    def next(self):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFF; s ^= s >> 17; s ^= (s << 5) & 0xFFFFFFFF
        self.s = s & 0xFFFFFFFF
        return self.s

def ramp_extremes(w, h, bits):
    mx = (1 << bits) - 1
    return [mx if (x + y) % 2 == 0 else (x + y * w) % (mx + 1) for y in range(h) for x in range(w)]
def alternating(w, h, bits):
    mx = (1 << bits) - 1
    return [mx if (x ^ y) & 1 else 0 for y in range(h) for x in range(w)]
def random_full(w, h, bits, seed):
    r = XorShift32(seed); mx = (1 << bits) - 1
    return [r.next() & mx for _ in range(w * h)]
def gradient_impulses(w, h, bits, seed):
    r = XorShift32(seed); mx = (1 << bits) - 1
    px = []
    for y in range(h):
        for x in range(w):
            v = (x * mx) // max(w - 1, 1)
            v = (v + (y * mx) // max(h - 1, 1)) // 2
            if r.next() % 97 == 0: v = mx if r.next() & 1 else 0
            px.append(v)
    return px
def smooth_noise(w, h, bits, seed):
    import math
    r = XorShift32(seed); mx = (1 << bits) - 1
    px = []
    for y in range(h):
        for x in range(w):
            v = 0.5 + 0.35 * math.sin(x / 11.0) * math.cos(y / 7.0)
            n = (r.next() % 65) - 32
            px.append(max(0, min(mx, int(v * mx) + n)))
    return px

FIXTURES = [
    ("g16_1x1_max",            1,   1, 16, lambda w,h,b: [65535]),
    ("g16_8x8_zero",           8,   8, 16, lambda w,h,b: [0]*64),
    ("g16_8x8_const",          8,   8, 16, lambda w,h,b: [65535]*64),
    ("g12_5x3_ramp_extremes",  5,   3, 12, ramp_extremes),
    ("g16_17x9_alternating",  17,   9, 16, alternating),
    ("g16_64x64_random",      64,  64, 16, lambda w,h,b: random_full(w,h,b,0x2A)),
    ("g12_129x67_gradient",  129,  67, 12, lambda w,h,b: gradient_impulses(w,h,b,0x1234)),
    ("g16_256x256_smooth",   256, 256, 16, lambda w,h,b: smooth_noise(w,h,b,0x99)),
    ("g08_37x23_random",      37,  23,  8, lambda w,h,b: random_full(w,h,b,0x77)),
    ("g10_300x200_gradient", 300, 200, 10, lambda w,h,b: gradient_impulses(w,h,b,0x55)),
]
# Encoder variants: (suffix, tool, args). Defaults: single tile, one layer, no precincts.
VARIANTS = [
    ("opj",       "opj", []),                    # 6 resolutions, 64x64 blocks, LRCP
    ("opj_n1",    "opj", ["-n", "1"]),           # no wavelet levels
    ("opj_b32",   "opj", ["-b", "32,32"]),       # 32x32 code-blocks
    ("opj_n2_b16","opj", ["-n", "2", "-b", "16,16"]),
    ("opj_rpcl",  "opj", ["-p", "RPCL"]),
    ("kdu",       "kdu", []),                    # Kakadu defaults, reversible
    ("kdu_l3",    "kdu", ["Clevels=3", "Cblk={32,32}"]),
]

def write_pgm(path, w, h, bits, px):
    mx = (1 << bits) - 1
    with open(path, "wb") as f:
        f.write(f"P5\n{w} {h}\n{mx}\n".encode())
        if mx <= 255: f.write(bytes(px))
        else: f.write(b"".join(struct.pack(">H", v) for v in px))

def read_pgm(path):
    data = open(path, "rb").read()
    parts = []; i = 0
    while len(parts) < 4:
        while data[i:i+1].isspace(): i += 1
        if data[i:i+1] == b"#":
            while data[i:i+1] not in (b"\n", b""): i += 1
            continue
        j = i
        while not data[j:j+1].isspace(): j += 1
        parts.append(data[i:j]); i = j
    i += 1
    w, h, mx = int(parts[1]), int(parts[2]), int(parts[3])
    body = data[i:]
    if mx <= 255: return w, h, mx, list(body[:w*h])
    return w, h, mx, [v for (v,) in struct.iter_unpack(">H", body[:w*h*2])]

def sha(path): return hashlib.sha256(open(path, "rb").read()).hexdigest()
def sample_digest(px): return hashlib.sha256(b"".join(struct.pack("<H", v) for v in px)).hexdigest()

manifest = {"generator": "generate.py (deterministic; XorShift32 seeds recorded)", "licence": "MIT (synthetic, in-house)",
            "tools": {}, "fixtures": []}
manifest["tools"]["openjpeg"] = "OpenJPEG " + subprocess.run(["brew","list","--versions","openjpeg"], capture_output=True, text=True).stdout.split()[-1] + " (opj_compress/opj_decompress, BSD-2-Clause)"
manifest["tools"]["kakadu"] = [l.strip() for l in subprocess.run([KDU, "-version"], capture_output=True, text=True).stdout.splitlines() if "version" in l][0] + " (kdu_compress/kdu_expand, proprietary; used as a test oracle only)"
for name, w, h, bits, gen in FIXTURES:
    px = gen(w, h, bits)
    assert len(px) == w*h and max(px) < (1 << bits)
    pgm = os.path.join(OUT, name + ".pgm"); write_pgm(pgm, w, h, bits, px)
    entry = dict(name=name, width=w, height=h, meaningfulBits=bits, storageBits=16, sampleType="unsigned",
                 pgm_sha256=sha(pgm), sample_digest_le16=sample_digest(px),
                 minimum=min(px), maximum=max(px), codestreams=[])
    for suffix, tool, args in VARIANTS:
        j2k = os.path.join(OUT, f"{name}.{suffix}.j2k")
        if tool == "opj":
            r = subprocess.run([OPJ, "-i", pgm, "-o", j2k, *args], capture_output=True, text=True)
        else:
            r = subprocess.run([KDU, "-i", pgm, "-o", j2k, "Creversible=yes", "-quiet", *args], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(j2k):
            entry.setdefault("not_produced", []).append(dict(variant=suffix, reason=(r.stdout+r.stderr).strip().splitlines()[0][:120] if (r.stdout+r.stderr).strip() else "no output")); continue
        # Cross-decode with the *other* tool where possible, and with the same tool.
        ok = {}
        for dn, dec in (("opj", OPJD), ("kdu", KDUD)):
            outp = os.path.join(OUT, f"{name}.{suffix}.{dn}.pgm")
            if dec == OPJD: rr = subprocess.run([dec, "-i", j2k, "-o", outp], capture_output=True, text=True)
            else: rr = subprocess.run([dec, "-i", j2k, "-o", outp, "-quiet"], capture_output=True, text=True)
            if rr.returncode == 0 and os.path.exists(outp):
                _, _, _, back = read_pgm(outp); ok[dn] = (back == px); os.remove(outp)
            else: ok[dn] = None
        entry["codestreams"].append(dict(file=os.path.basename(j2k), tool=tool, args=args, sha256=sha(j2k),
                                         bytes=os.path.getsize(j2k), independent_decode_exact=ok))
    manifest["fixtures"].append(entry)

# Valid Part 1 codestreams the Milestone 2 path must reject with unsupportedFeature.
UNSUPPORTED = [
    ("irreversible97", "opj", ["-I", "-n", "3"], "9/7 irreversible wavelet"),
    ("tiled",          "opj", ["-t", "32,32", "-n", "3"], "multiple tiles"),
    ("layers2",        "opj", ["-r", "20,1", "-n", "3"], "two quality layers"),
    ("bypass",         "opj", ["-M", "1", "-n", "3"], "selective arithmetic bypass"),
    ("termall",        "opj", ["-M", "4", "-n", "3"], "termination on each pass"),
    ("segsym",         "opj", ["-M", "32", "-n", "3"], "segmentation symbols"),
    ("precincts",      "opj", ["-c", "[32,32],[32,32],[32,32],[32,32]", "-n", "3"], "explicit precincts (supported)"),
    ("sop_eph",        "opj", ["-SOP", "-EPH", "-n", "3"], "SOP and EPH markers (supported)"),
    ("rpcl",           "opj", ["-p", "RPCL", "-n", "3"], "RPCL progression (supported)"),
    ("cprl",           "opj", ["-p", "CPRL", "-n", "3"], "CPRL progression (supported with one precinct)"),
    ("kdu_ht",         "kdu", ["Cmodes=HT"], "HTJ2K block coder"),
    ("kdu_tileparts",  "kdu", ["ORGtparts=R", "Clevels=3"], "several tile-parts of one tile (supported)"),
    ("kdu_plt",        "kdu", ["ORGgen_plt=yes", "Clevels=3"], "PLT marker segments (supported, skipped)"),
]
name, w, h, bits = "g16_64x64_random", 64, 64, 16
pgm = os.path.join(OUT, name + ".pgm")
_, _, _, px = read_pgm(pgm)
extra = []
for suffix, tool, args, note in UNSUPPORTED:
    j2k = os.path.join(OUT, f"{name}.{suffix}.j2k")
    if tool == "opj":
        r = subprocess.run([OPJ, "-i", pgm, "-o", j2k, *args], capture_output=True, text=True)
    else:
        r = subprocess.run([KDU, "-i", pgm, "-o", j2k, "Creversible=yes", "-quiet", *args], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(j2k):
        extra.append(dict(file=os.path.basename(j2k), note=note, produced=False, reason=(r.stdout+r.stderr).strip()[:160])); continue
    outp = os.path.join(OUT, "tmp.pgm")
    rr = subprocess.run([OPJD, "-i", j2k, "-o", outp], capture_output=True, text=True)
    exact = None
    if rr.returncode == 0 and os.path.exists(outp):
        _, _, _, back = read_pgm(outp); exact = (back == px); os.remove(outp)
    extra.append(dict(file=os.path.basename(j2k), tool=tool, args=args, note=note, produced=True,
                      sha256=sha(j2k), bytes=os.path.getsize(j2k), openjpeg_decode_exact=exact))
manifest["variants_of_g16_64x64_random"] = extra
# RGB fixture (three components) must be rejected too.
rgb = os.path.join(OUT, "rgb8_16x16.ppm")
with open(rgb, "wb") as f:
    f.write(b"P6\n16 16\n255\n" + bytes((x*16) & 255 for y in range(16) for x in range(16) for c in range(3)))
rgbj = os.path.join(OUT, "rgb8_16x16.opj.j2k")
r = subprocess.run([OPJ, "-i", rgb, "-o", rgbj, "-n", "2"], capture_output=True, text=True)
manifest["rgb_fixture"] = dict(file=os.path.basename(rgbj), produced=r.returncode == 0, sha256=sha(rgbj) if r.returncode == 0 else None, note="three components; must be rejected")
os.remove(rgb)

# Milestone 4 syntax coverage: quality layers, code-block styles, tiles and
# origins, precinct-major progressions. All lossless; every file is
# cross-decoded by both tools before admission.
SYNTAX = [
    ("layers3_opj",     "opj", ["-r", "40,20,1", "-n", "4"], "three quality layers, last lossless"),
    ("layers3_kdu",     "kdu", ["Clayers=3", "Clevels=3"], "three quality layers (Kakadu)"),
    ("bypass_opj",      "opj", ["-M", "1", "-n", "4"], "selective arithmetic bypass"),
    ("reset_opj",       "opj", ["-M", "2", "-n", "4"], "context reset on each pass"),
    ("restart_opj",     "opj", ["-M", "4", "-n", "4"], "termination on each pass"),
    ("causal_opj",      "opj", ["-M", "8", "-n", "4"], "vertically causal contexts"),
    ("erterm_opj",      "opj", ["-M", "16", "-n", "4"], "predictable termination"),
    ("segsym_opj",      "opj", ["-M", "32", "-n", "4"], "segmentation symbols"),
    ("allstyles_opj",   "opj", ["-M", "63", "-n", "4"], "all six code-block style bits"),
    ("bypass_restart_kdu", "kdu", ["Cmodes=BYPASS|RESTART", "Clevels=3"], "bypass with restart (Kakadu)"),
    ("allstyles_kdu",   "kdu", ["Cmodes=BYPASS|RESET|RESTART|CAUSAL|ERTERM|SEGMARK", "Clevels=3"], "all style bits (Kakadu)"),
    ("tiles37x29_opj",  "opj", ["-t", "37,29", "-n", "3"], "4x3 tiles of 37x29"),
    ("tiles64_opj",     "opj", ["-t", "64,64", "-n", "4"], "3x2 tiles of 64x64"),
    ("origin_opj",      "opj", ["-d", "3,5", "-n", "4"], "image origin (3,5)"),
    ("origin_tiles_opj","opj", ["-d", "3,5", "-T", "1,2", "-t", "40,30", "-n", "3"], "image origin (3,5), tile origin (1,2), 40x30 tiles"),
    ("tiles_kdu",       "kdu", ["Stiles={29,37}", "Clevels=3"], "tiles 37 wide 29 high (Kakadu)"),
    ("origin_kdu",      "kdu", ["Sorigin={5,3}", "Clevels=3"], "image origin (3,5) (Kakadu)"),
    ("pcrl_precincts_opj", "opj", ["-c", "[32,32],[32,32],[32,32],[32,32]", "-p", "PCRL", "-n", "4"], "PCRL with several precincts"),
    ("cprl_precincts_opj", "opj", ["-c", "[32,32],[32,32],[32,32],[32,32]", "-p", "CPRL", "-n", "4"], "CPRL with several precincts"),
    ("rpcl_precincts_kdu", "kdu", ["Corder=RPCL", "Cprecincts={32,32}", "Clevels=3"], "RPCL with several precincts (Kakadu)"),
    ("everything_opj",  "opj", ["-t", "40,30", "-r", "30,1", "-M", "63", "-c", "[32,32],[32,32],[32,32]", "-p", "PCRL", "-SOP", "-EPH", "-n", "3"], "tiles + layers + styles + precincts + PCRL + SOP/EPH"),
    ("everything_kdu",  "kdu", ["Stiles={30,40}", "Clayers=2", "Cmodes=BYPASS|RESTART|SEGMARK", "Cprecincts={32,32}", "Corder=CPRL", "Cuse_sop=yes", "Cuse_eph=yes", "Clevels=3", "ORGtparts=R"], "tiles + layers + styles + precincts + CPRL + SOP/EPH + tile-parts (Kakadu)"),
]
manifest["syntax_variants"] = []
for base in ["g12_129x67_gradient", "g16_64x64_random"]:
    pgm = os.path.join(OUT, base + ".pgm")
    _, _, _, px = read_pgm(pgm)
    for suffix, tool, args, note in SYNTAX:
        j2k = os.path.join(OUT, f"{base}.syntax.{suffix}.j2k")
        if tool == "opj":
            r = subprocess.run([OPJ, "-i", pgm, "-o", j2k, *args], capture_output=True, text=True)
        else:
            r = subprocess.run([KDU, "-i", pgm, "-o", j2k, "Creversible=yes", "-quiet", *args], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(j2k):
            manifest["syntax_variants"].append(dict(base=base, file=os.path.basename(j2k), note=note, produced=False,
                                                    reason=(r.stdout + r.stderr).strip().splitlines()[0][:160] if (r.stdout + r.stderr).strip() else "no output"))
            continue
        ok = {}
        for dn, dec in (("opj", OPJD), ("kdu", KDUD)):
            outp = os.path.join(OUT, "tmp.pgm")
            cmd = [dec, "-i", j2k, "-o", outp] + (["-quiet"] if dn == "kdu" else [])
            rr = subprocess.run(cmd, capture_output=True, text=True)
            if rr.returncode == 0 and os.path.exists(outp):
                _, _, _, back = read_pgm(outp); ok[dn] = (back == px); os.remove(outp)
            else:
                ok[dn] = None
        if not (ok.get("opj") and ok.get("kdu")):
            os.remove(j2k)
            manifest["syntax_variants"].append(dict(base=base, file=os.path.basename(j2k), note=note, produced=False, reason=f"not cross-decoded exactly: {ok}"))
            continue
        manifest["syntax_variants"].append(dict(base=base, file=os.path.basename(j2k), tool=tool, args=args, note=note, produced=True,
                                                sha256=sha(j2k), bytes=os.path.getsize(j2k), independent_decode_exact=ok))
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
for e in manifest["fixtures"]:
    print(e["name"], f'{e["width"]}x{e["height"]}@{e["meaningfulBits"]}', [ (c["file"].split(".")[1], c["bytes"], c["independent_decode_exact"]) for c in e["codestreams"]])
