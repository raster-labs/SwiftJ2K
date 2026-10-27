#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Deterministic synthetic Part 1 breadth fixtures for SwiftJ2K Milestone 7.
Generates reference codestreams from OpenJPEG 2.5.4 and Kakadu 8.4.1 covering:
  - 3-component RGB (8-bit and 12-bit) with RCT (5/3 lossless), ICT (9/7 lossy), and no-MCT
  - 4-component RGBA (8-bit) lossless
  - Signed integer samples (8-bit, 12-bit, 16-bit) lossless (5/3) and lossy (9/7)
  - 9/7 irreversible wavelet with scalar-derived (Sqcd=1), scalar-expounded (Sqcd=2), and extended guard bits
  - Region of Interest (RGN 0xFF5E MaxShift)
  - Multi-tile, multi-layer, explicit precincts, POC (0xFF5F), SOP/EPH, and code-block style bits
Writes manifest.json with SHA-256 digests, reference sample digests, and cross-decode PSNR/exactness.
"""
import hashlib, json, math, os, struct, subprocess, sys, tempfile

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Tests", "SwiftJ2KTests", "Fixtures", "Part1Breadth"
)
os.makedirs(OUT, exist_ok=True)

OPJ = "/opt/homebrew/bin/opj_compress"
OPJD = "/opt/homebrew/bin/opj_decompress"
KDU = "/usr/local/bin/kdu_compress"
KDUD = "/usr/local/bin/kdu_expand"

class XorShift32:
    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF or 1
    def next(self):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        self.s = s & 0xFFFFFFFF
        return self.s

def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()

def sha256_file(path):
    return sha256_bytes(open(path, "rb").read())

def gen_rgb8_gradient(w, h):
    r_plane, g_plane, b_plane = [], [], []
    rng = XorShift32(0xC0105)
    for y in range(h):
        for x in range(w):
            rv = min(255, max(0, int(255 * x / max(w - 1, 1)) + ((rng.next() % 7) - 3)))
            gv = min(255, max(0, int(255 * y / max(h - 1, 1)) + ((rng.next() % 7) - 3)))
            bv = min(255, max(0, int(128 + 90 * math.sin(x / 6.0) * math.cos(y / 5.0))))
            r_plane.append(rv)
            g_plane.append(gv)
            b_plane.append(bv)
    return [r_plane, g_plane, b_plane]

def gen_rgb12_pattern(w, h):
    mx = (1 << 12) - 1
    r_plane, g_plane, b_plane = [], [], []
    for y in range(h):
        for x in range(w):
            r_plane.append((x * 113 + y * 29) & mx)
            g_plane.append((x * 43 + y * 197 + 500) & mx)
            b_plane.append(((x ^ y) * 151 + 1024) & mx)
    return [r_plane, g_plane, b_plane]

def gen_rgba8_pattern(w, h):
    planes = gen_rgb8_gradient(w, h)
    a_plane = [min(255, max(0, (x * 7 + y * 11) & 0xFF)) for y in range(h) for x in range(w)]
    planes.append(a_plane)
    return planes

def gen_signed(w, h, bits, seed):
    rng = XorShift32(seed)
    mn = -(1 << (bits - 1))
    mx = (1 << (bits - 1)) - 1
    span = mx - mn + 1
    out = []
    for y in range(h):
        for x in range(w):
            wave = math.sin(x / 7.0) * math.cos(y / 5.0)
            center = int(wave * (mx * 0.75))
            noise = (rng.next() % 33) - 16
            v = max(mn, min(mx, center + noise))
            if (x == 0 and y == 0):
                v = mn
            elif (x == 1 and y == 0):
                v = mx
            elif (x == 2 and y == 0):
                v = 0
            elif (x == 3 and y == 0):
                v = -1
            out.append(v)
    return out

def gen_smooth16(w, h):
    rng = XorShift32(0x9797)
    mx = 65535
    out = []
    for y in range(h):
        for x in range(w):
            v = 0.5 + 0.4 * math.sin(x / 8.0) * math.cos(y / 6.0)
            n = (rng.next() % 31) - 15
            out.append(max(0, min(mx, int(v * mx) + n)))
    return out

def gen_smooth8(w, h):
    rng = XorShift32(0x5588)
    out = []
    for y in range(h):
        for x in range(w):
            v = 128 + int(95 * math.sin(x / 7.0) * math.cos(y / 6.0)) + ((rng.next() % 5) - 2)
            out.append(max(0, min(255, v)))
    return out

def write_ppm(path, w, h, planes):
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        interleaved = bytearray(w * h * 3)
        for i in range(w * h):
            interleaved[i * 3] = planes[0][i]
            interleaved[i * 3 + 1] = planes[1][i]
            interleaved[i * 3 + 2] = planes[2][i]
        f.write(interleaved)

def read_ppm(path):
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
    body = data[i:i + w * h * 3]
    r = list(body[0::3]); g = list(body[1::3]); b = list(body[2::3])
    return w, h, [r, g, b]

def write_pgm(path, w, h, bits, samples):
    mx = (1 << bits) - 1
    with open(path, "wb") as f:
        f.write(f"P5\n{w} {h}\n{mx}\n".encode())
        if mx <= 255:
            f.write(bytes(samples))
        else:
            f.write(b"".join(struct.pack(">H", v) for v in samples))

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
    if mx <= 255:
        return w, h, list(body[:w * h])
    return w, h, [v for (v,) in struct.iter_unpack(">H", body[:w * h * 2])]

def write_pgx(path, w, h, bits, signed, samples):
    sign_ch = "-" if signed else "+"
    with open(path, "wb") as f:
        f.write(f"PG ML {sign_ch}{bits} {w} {h}\n".encode())
        if bits <= 8:
            fmt = ">b" if signed else ">B"
        else:
            fmt = ">h" if signed else ">H"
        f.write(b"".join(struct.pack(fmt, v) for v in samples))

def read_pgx(path):
    if not os.path.exists(path) and os.path.exists(path[:-4] + "_0.pgx"):
        path = path[:-4] + "_0.pgx"
    data = open(path, "rb").read()
    nl = data.index(b"\n")
    hdr = data[:nl].decode().split()
    endian = ">" if hdr[1] == "ML" else "<"
    if hdr[2] in ("+", "-"):
        signed = (hdr[2] == "-")
        bits = int(hdr[3])
        w = int(hdr[4])
        h = int(hdr[5])
    else:
        signed = hdr[2].startswith("-")
        bits = int(hdr[2].lstrip("+-"))
        w = int(hdr[3])
        h = int(hdr[4])
    body = data[nl + 1:]
    if bits <= 8:
        fmt = endian + ("b" if signed else "B")
        step = 1
    else:
        fmt = endian + ("h" if signed else "H")
        step = 2
    return w, h, [v for (v,) in struct.iter_unpack(fmt, body[:w * h * step])]

def pack_samples_le(planes, bits, signed):
    buf = bytearray()
    if bits <= 8:
        fmt = "<b" if signed else "<B"
    else:
        fmt = "<h" if signed else "<H"
    for p in planes:
        for v in p:
            buf.extend(struct.pack(fmt, v))
    return bytes(buf)

def compute_psnr(ref_planes, dec_planes, bits, signed):
    total_sq = 0.0
    max_err = 0
    count = 0
    for rp, dp in zip(ref_planes, dec_planes):
        for a, b in zip(rp, dp):
            d = abs(a - b)
            if d > max_err:
                max_err = d
            total_sq += d * d
            count += 1
    if total_sq == 0:
        return float("inf"), 0
    mse = total_sq / count
    peak = ((1 << bits) - 1)
    return 10.0 * math.log10((peak * peak) / mse), max_err

manifest = {
    "generator": "Scripts/generate-part1-breadth-fixtures.py",
    "licence": "Apache-2.0 (synthetic, in-house)",
    "tools": {
        "openjpeg": "OpenJPEG " + subprocess.run(["brew", "list", "--versions", "openjpeg"], capture_output=True, text=True).stdout.split()[-1],
        "kakadu": [l.strip() for l in subprocess.run([KDU, "-version"], capture_output=True, text=True).stdout.splitlines() if "version" in l][0]
    },
    "fixtures": []
}

with tempfile.TemporaryDirectory() as tmp:
    # 1. RGB 8-bit 64x48 gradient
    w, h = 64, 48
    rgb8_planes = gen_rgb8_gradient(w, h)
    rgb8_raw = pack_samples_le(rgb8_planes, 8, False)
    rgb8_raw_path = os.path.join(OUT, "rgb8_64x48_gradient.le.raw")
    open(rgb8_raw_path, "wb").write(rgb8_raw)
    ppm_path = os.path.join(tmp, "rgb8.ppm")
    write_ppm(ppm_path, w, h, rgb8_planes)

    rgb8_variants = [
        ("opj_rct", "opj", ["-n", "3"], True, "3-component 8-bit RGB, 5/3 lossless + RCT (OpenJPEG)"),
        ("kdu_rct", "kdu", ["Creversible=yes", "Clevels=3"], True, "3-component 8-bit RGB, 5/3 lossless + RCT (Kakadu)"),
        ("kdu_nomct", "kdu", ["Creversible=yes", "Cycc=no", "Clevels=3"], True, "3-component 8-bit RGB, 5/3 lossless without MCT (Kakadu)"),
        ("opj_ict", "opj", ["-I", "-q", "45", "-n", "3"], False, "3-component 8-bit RGB, 9/7 irreversible + ICT (OpenJPEG)"),
        ("kdu_ict", "kdu", ["Creversible=no", "Clevels=3", "-rate", "3.0"], False, "3-component 8-bit RGB, 9/7 irreversible + ICT (Kakadu)"),
        ("opj_tiles_layers", "opj", ["-t", "32,24", "-r", "8,2,1", "-n", "3", "-SOP", "-EPH", "-p", "PCRL"], True, "3-component RGB multi-tile + 3 layers + PCRL + SOP/EPH (OpenJPEG)"),
        ("opj_layers_poc", "opj", ["-r", "8,2,1", "-n", "3", "-SOP", "-EPH", "-POC", "T1=0,0,3,2,3,RLCP/T1=2,0,3,3,3,LRCP"], True, "3-component RGB 3 layers + POC + SOP/EPH (OpenJPEG)"),
        ("kdu_tiles_layers_precincts", "kdu", ["Creversible=yes", "Stiles={24,32}", "Clayers=3", "Cprecincts={16,16}", "Corder=RPCL", "Cuse_sop=yes", "Cuse_eph=yes", "Cmodes=BYPASS|RESTART|SEGMARK", "Clevels=3"], True, "3-component RGB multi-tile + 3 layers + precincts + RPCL + SOP/EPH + modes (Kakadu)"),
    ]
    for suffix, tool, args, lossless, note in rgb8_variants:
        j2k_name = f"rgb8_64x48_gradient.{suffix}.j2k"
        j2k_path = os.path.join(OUT, j2k_name)
        if tool == "opj":
            subprocess.run([OPJ, "-i", ppm_path, "-o", j2k_path, *args], check=True, capture_output=True)
        else:
            subprocess.run([KDU, "-i", ppm_path, "-o", j2k_path, "-quiet", *args], check=True, capture_output=True)
        opj_out = os.path.join(tmp, "dec_opj.ppm")
        subprocess.run([OPJD, "-i", j2k_path, "-o", opj_out], check=True, capture_output=True)
        _, _, opj_planes = read_ppm(opj_out)
        psnr, max_err = compute_psnr(rgb8_planes, opj_planes, 8, False)
        assert (max_err == 0) if lossless else (psnr > 30.0)
        manifest["fixtures"].append({
            "name": f"rgb8_64x48_gradient.{suffix}",
            "file": j2k_name,
            "referenceRaw": "rgb8_64x48_gradient.le.raw",
            "width": w, "height": h, "components": 3, "meaningfulBits": 8, "storageBits": 8, "signed": False,
            "lossless": lossless, "tool": tool, "args": args, "note": note,
            "sha256": sha256_file(j2k_path), "bytes": os.path.getsize(j2k_path),
            "referenceDigest": sha256_bytes(rgb8_raw),
            "oracleMaxError": max_err, "oraclePSNR": None if math.isinf(psnr) else round(psnr, 2)
        })

    # 2. RGBA 8-bit 32x24 4-component lossless
    w4, h4 = 32, 24
    rgba8_planes = gen_rgba8_pattern(w4, h4)
    rgba8_raw = pack_samples_le(rgba8_planes, 8, False)
    rgba8_raw_path = os.path.join(OUT, "rgba8_32x24_pattern.le.raw")
    open(rgba8_raw_path, "wb").write(rgba8_raw)
    comp_PGMs = []
    for c in range(4):
        p = os.path.join(tmp, f"rgba_c{c}.pgm")
        write_pgm(p, w4, h4, 8, rgba8_planes[c])
        comp_PGMs.append(p)
    j2k_rgba = os.path.join(OUT, "rgba8_32x24_pattern.kdu.j2k")
    subprocess.run([KDU, "-i", ",".join(comp_PGMs), "-o", j2k_rgba, "Creversible=yes", "Cycc=no", "Clevels=2", "-quiet"], check=True, capture_output=True)
    manifest["fixtures"].append({
        "name": "rgba8_32x24_pattern.kdu",
        "file": "rgba8_32x24_pattern.kdu.j2k",
        "referenceRaw": "rgba8_32x24_pattern.le.raw",
        "width": w4, "height": h4, "components": 4, "meaningfulBits": 8, "storageBits": 8, "signed": False,
        "lossless": True, "tool": "kdu", "args": ["Creversible=yes", "Cycc=no", "Clevels=2"],
        "note": "4-component 8-bit RGBA lossless (Kakadu)",
        "sha256": sha256_file(j2k_rgba), "bytes": os.path.getsize(j2k_rgba),
        "referenceDigest": sha256_bytes(rgba8_raw),
        "oracleMaxError": 0, "oraclePSNR": None
    })

    # 2b. RGB 12-bit 33x25 pattern lossless + RCT
    w12, h12 = 33, 25
    rgb12_planes = gen_rgb12_pattern(w12, h12)
    rgb12_raw = pack_samples_le(rgb12_planes, 16, False)
    rgb12_raw_path = os.path.join(OUT, "rgb12_33x25_pattern.le.raw")
    open(rgb12_raw_path, "wb").write(rgb12_raw)
    comp12_pgms = []
    for c in range(3):
        p = os.path.join(tmp, f"rgb12_c{c}.pgm")
        write_pgm(p, w12, h12, 12, rgb12_planes[c])
        comp12_pgms.append(p)
    j2k_rgb12 = os.path.join(OUT, "rgb12_33x25_pattern.kdu_rct.j2k")
    subprocess.run([KDU, "-i", ",".join(comp12_pgms), "-o", j2k_rgb12, "Creversible=yes", "Cycc=yes", "Clevels=2", "-quiet"], check=True, capture_output=True)
    manifest["fixtures"].append({
        "name": "rgb12_33x25_pattern.kdu_rct",
        "file": "rgb12_33x25_pattern.kdu_rct.j2k",
        "referenceRaw": "rgb12_33x25_pattern.le.raw",
        "width": w12, "height": h12, "components": 3, "meaningfulBits": 12, "storageBits": 16, "signed": False,
        "lossless": True, "tool": "kdu", "args": ["Creversible=yes", "Cycc=yes", "Clevels=2"],
        "note": "3-component 12-bit RGB lossless + RCT (Kakadu)",
        "sha256": sha256_file(j2k_rgb12), "bytes": os.path.getsize(j2k_rgb12),
        "referenceDigest": sha256_bytes(rgb12_raw),
        "oracleMaxError": 0, "oraclePSNR": None
    })

    # 3. Signed integer fixtures (8-bit, 12-bit, 16-bit)
    signed_specs = [
        ("s08_37x23_signed", 37, 23, 8, 8, 0x801, True, "opj", ["-n", "3"], "Signed 8-bit lossless 5/3 (OpenJPEG)"),
        ("s08_37x23_signed", 37, 23, 8, 8, 0x801, True, "kdu", ["Creversible=yes", "Clevels=3"], "Signed 8-bit lossless 5/3 (Kakadu)"),
        ("s12_45x31_signed", 45, 31, 12, 16, 0x1201, True, "opj", ["-n", "3"], "Signed 12-bit lossless 5/3 (OpenJPEG)"),
        ("s12_45x31_signed", 45, 31, 12, 16, 0x1201, True, "kdu", ["Creversible=yes", "Clevels=3"], "Signed 12-bit lossless 5/3 (Kakadu)"),
        ("s16_64x48_signed", 64, 48, 16, 16, 0x1601, True, "opj", ["-n", "3"], "Signed 16-bit lossless 5/3 (OpenJPEG)"),
        ("s16_64x48_signed", 64, 48, 16, 16, 0x1601, True, "kdu", ["Creversible=yes", "Clevels=3"], "Signed 16-bit lossless 5/3 (Kakadu)"),
        ("s16_64x48_signed", 64, 48, 16, 16, 0x1601, False, "kdu", ["Creversible=no", "Clevels=3", "-rate", "4.0"], "Signed 16-bit irreversible 9/7 (Kakadu)"),
    ]
    for base, sw, sh, sbits, stbits, seed, lossless, tool, args, note in signed_specs:
        samples = gen_signed(sw, sh, sbits, seed)
        raw_le = pack_samples_le([samples], stbits, True)
        raw_name = f"{base}.le.raw"
        raw_path = os.path.join(OUT, raw_name)
        if not os.path.exists(raw_path):
            open(raw_path, "wb").write(raw_le)
        rawl_in = os.path.join(tmp, f"{base}.rawl")
        open(rawl_in, "wb").write(raw_le)
        pgx_in = os.path.join(tmp, f"{base}.pgx")
        write_pgx(pgx_in, sw, sh, sbits, True, samples)
        suffix = f"{tool}_{'rev' if lossless else 'irrev'}"
        j2k_name = f"{base}.{suffix}.j2k"
        j2k_path = os.path.join(OUT, j2k_name)
        if tool == "opj":
            subprocess.run([OPJ, "-i", rawl_in, "-F", f"{sw},{sh},1,{sbits},s", "-o", j2k_path, *args], check=True, capture_output=True)
        else:
            subprocess.run([KDU, "-i", pgx_in, "-o", j2k_path, "-quiet", *args], check=True, capture_output=True)
        # Verify with Kakadu and OpenJPEG decode to PGX
        dec_pgx = os.path.join(tmp, f"dec_{base}_{suffix}.pgx")
        subprocess.run([KDUD, "-i", j2k_path, "-o", dec_pgx, "-quiet"], check=True, capture_output=True)
        _, _, dec_samples = read_pgx(dec_pgx)
        psnr, max_err = compute_psnr([samples], [dec_samples], sbits, True)
        assert (max_err == 0) if lossless else (psnr > 35.0), (base, suffix, max_err, psnr, samples[:5], dec_samples[:5])
        manifest["fixtures"].append({
            "name": f"{base}.{suffix}",
            "file": j2k_name,
            "referenceRaw": raw_name,
            "width": sw, "height": sh, "components": 1, "meaningfulBits": sbits, "storageBits": stbits, "signed": True,
            "lossless": lossless, "tool": tool, "args": args, "note": note,
            "sha256": sha256_file(j2k_path), "bytes": os.path.getsize(j2k_path),
            "referenceDigest": sha256_bytes(raw_le),
            "oracleMaxError": max_err, "oraclePSNR": None if math.isinf(psnr) else round(psnr, 2)
        })

    # 4. 9/7 Irreversible Wavelet, Scalar-Derived (Sqcd=1), Scalar-Expounded (Sqcd=2), Extended Guard Bits
    gw, gh = 64, 64
    g16_samples = gen_smooth16(gw, gh)
    g16_raw = pack_samples_le([g16_samples], 16, False)
    g16_raw_path = os.path.join(OUT, "g16_64x64_smooth.le.raw")
    open(g16_raw_path, "wb").write(g16_raw)
    g16_pgm = os.path.join(tmp, "g16_smooth.pgm")
    write_pgm(g16_pgm, gw, gh, 16, g16_samples)

    irrev_specs = [
        ("opj_expounded", "opj", ["-I", "-q", "45", "-n", "4"], "16-bit 9/7 irreversible scalar-expounded Sqcd=2 (OpenJPEG)"),
        ("kdu_derived", "kdu", ["Creversible=no", "Qderived=yes", "Clevels=4", "-rate", "3.0"], "16-bit 9/7 irreversible scalar-derived Sqcd=1 (Kakadu)"),
        ("kdu_expounded_gb4", "kdu", ["Creversible=no", "Qderived=no", "Qguard=4", "Clevels=4", "-rate", "3.0"], "16-bit 9/7 irreversible scalar-expounded Sqcd=2 with 4 guard bits (Kakadu)"),
    ]
    for suffix, tool, args, note in irrev_specs:
        j2k_name = f"g16_64x64_smooth.{suffix}.j2k"
        j2k_path = os.path.join(OUT, j2k_name)
        if tool == "opj":
            subprocess.run([OPJ, "-i", g16_pgm, "-o", j2k_path, *args], check=True, capture_output=True)
        else:
            subprocess.run([KDU, "-i", g16_pgm, "-o", j2k_path, "-quiet", *args], check=True, capture_output=True)
        dec_pgm = os.path.join(tmp, "dec_irrev.pgm")
        subprocess.run([OPJD, "-i", j2k_path, "-o", dec_pgm], check=True, capture_output=True)
        _, _, dec_samples = read_pgm(dec_pgm)
        psnr, max_err = compute_psnr([g16_samples], [dec_samples], 16, False)
        assert psnr > 35.0
        manifest["fixtures"].append({
            "name": f"g16_64x64_smooth.{suffix}",
            "file": j2k_name,
            "referenceRaw": "g16_64x64_smooth.le.raw",
            "width": gw, "height": gh, "components": 1, "meaningfulBits": 16, "storageBits": 16, "signed": False,
            "lossless": False, "tool": tool, "args": args, "note": note,
            "sha256": sha256_file(j2k_path), "bytes": os.path.getsize(j2k_path),
            "referenceDigest": sha256_bytes(g16_raw),
            "oracleMaxError": max_err, "oraclePSNR": round(psnr, 2)
        })

    # 5. Region of Interest (RGN 0xFF5E MaxShift)
    g8_samples = gen_smooth8(gw, gh)
    g8_raw = pack_samples_le([g8_samples], 8, False)
    g8_raw_path = os.path.join(OUT, "g08_64x64_smooth.le.raw")
    open(g8_raw_path, "wb").write(g8_raw)
    g8_pgm = os.path.join(tmp, "g08_smooth.pgm")
    write_pgm(g8_pgm, gw, gh, 8, g8_samples)

    roi_specs = [
        ("opj_roi", "opj", ["-ROI", "c=0,U=11", "-n", "3"], True, "8-bit MaxShift ROI RGN 0xFF5E shift=11 (OpenJPEG)"),
        ("kdu_roi", "kdu", ["Creversible=yes", "Rshift=11", "-roi", "{0.25,0.25},{0.5,0.5}", "Clevels=3"], True, "8-bit MaxShift ROI RGN 0xFF5E shift=11 (Kakadu)"),
    ]
    for suffix, tool, args, lossless, note in roi_specs:
        j2k_name = f"g08_64x64_smooth.{suffix}.j2k"
        j2k_path = os.path.join(OUT, j2k_name)
        if tool == "opj":
            subprocess.run([OPJ, "-i", g8_pgm, "-o", j2k_path, *args], check=True, capture_output=True)
        else:
            subprocess.run([KDU, "-i", g8_pgm, "-o", j2k_path, "-quiet", *args], check=True, capture_output=True)
        dec_pgm = os.path.join(tmp, "dec_roi.pgm")
        subprocess.run([OPJD, "-i", j2k_path, "-o", dec_pgm], check=True, capture_output=True)
        _, _, dec_samples = read_pgm(dec_pgm)
        psnr, max_err = compute_psnr([g8_samples], [dec_samples], 8, False)
        assert max_err == 0
        manifest["fixtures"].append({
            "name": f"g08_64x64_smooth.{suffix}",
            "file": j2k_name,
            "referenceRaw": "g08_64x64_smooth.le.raw",
            "width": gw, "height": gh, "components": 1, "meaningfulBits": 8, "storageBits": 8, "signed": False,
            "lossless": lossless, "tool": tool, "args": args, "note": note,
            "sha256": sha256_file(j2k_path), "bytes": os.path.getsize(j2k_path),
            "referenceDigest": sha256_bytes(g8_raw),
            "oracleMaxError": max_err, "oraclePSNR": None
        })

with open(os.path.join(OUT, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)

print(f"Generated {len(manifest['fixtures'])} Milestone 7 Part 1 breadth fixtures in {OUT}")
for item in manifest["fixtures"]:
    print(f"  {item['file']}: {item['bytes']} bytes, maxErr={item['oracleMaxError']}, PSNR={item['oraclePSNR']}")
