#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate deterministic Milestone 8 JP2, JPH, and JPX container fixtures
using OpenJPEG 2.5.4 (opj_compress) and Kakadu v8.4.1 (kdu_compress)."""

import hashlib
import json
import os
import struct
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "Tests/SwiftJ2KTests/Fixtures/Containers"
OPJ_COMPRESS = os.environ.get("OPJ_COMPRESS", "/opt/homebrew/bin/opj_compress")
KDU_COMPRESS = os.environ.get("KDU_COMPRESS", "/usr/local/bin/kdu_compress")
KDU_LIB = "/usr/local/lib"


def kdu_env():
    env = dict(os.environ)
    env["DYLD_LIBRARY_PATH"] = KDU_LIB
    return env


def run(cmd, env=None):
    subprocess.run([str(x) for x in cmd], check=True, env=env, capture_output=True)


def write_pgm(path: Path, width: int, height: int, maxval: int, samples: list[int]):
    header = f"P5\n{width} {height}\n{maxval}\n".encode("ascii")
    if maxval <= 255:
        body = bytes(samples)
    else:
        body = b"".join(struct.pack(">H", s) for s in samples)
    path.write_bytes(header + body)


def write_ppm(path: Path, width: int, height: int, maxval: int, rgb_planar: list[list[int]]):
    header = f"P6\n{width} {height}\n{maxval}\n".encode("ascii")
    interleaved = bytearray()
    for i in range(width * height):
        for c in range(3):
            interleaved.append(rgb_planar[c][i])
    path.write_bytes(header + bytes(interleaved))


def write_indexed_bmp(path: Path, width: int, height: int, palette_rgb: list[tuple[int, int, int]], indices: list[int]):
    assert len(palette_rgb) <= 256
    pal_entries = list(palette_rgb) + [(0, 0, 0)] * (256 - len(palette_rgb))
    pal_bytes = b"".join(struct.pack("<BBBB", b, g, r, 0) for (r, g, b) in pal_entries)
    row_stride = (width + 3) & ~3
    pixel_bytes = bytearray()
    for y in range(height - 1, -1, -1):
        row = bytes(indices[y * width : (y + 1) * width])
        pixel_bytes.extend(row)
        pixel_bytes.extend(b"\x00" * (row_stride - width))
    offset = 14 + 40 + len(pal_bytes)
    file_size = offset + len(pixel_bytes)
    bmp_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, offset)
    # 2835 pixels/metre (~72 DPI) triggers Kakadu 'resc' capture resolution box
    dib_header = struct.pack(
        "<IiiHHIIiiII",
        40,
        width,
        height,
        1,
        8,
        0,
        len(pixel_bytes),
        2835,
        2835,
        256,
        len(palette_rgb),
    )
    path.write_bytes(bmp_header + dib_header + pal_bytes + bytes(pixel_bytes))


def sha256_hex(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {
        "milestone": 8,
        "generators": {
            "openjpeg": "2.5.4",
            "kakadu": "v8.4.1",
        },
        "fixtures": [],
    }

    w, h = 16, 12
    g12_samples = [((y * 197 + x * 131 + 17) & 0x0FFF) for y in range(h) for x in range(w)]
    s12_samples = [(((y * 173 + x * 89) & 0x0FFF) - 2048) for y in range(h) for x in range(w)]
    rgb8_planar = [
        [((x * 17 + y * 11 + 5) & 0xFF) for y in range(h) for x in range(w)],
        [((x * 9 + y * 23 + 40) & 0xFF) for y in range(h) for x in range(w)],
        [((x * 31 + y * 7 + 100) & 0xFF) for y in range(h) for x in range(w)],
    ]
    alpha8_plane = [((x * 15 + y * 21) & 0xFF) for y in range(h) for x in range(w)]
    rgba8_planar = rgb8_planar + [alpha8_plane]

    pal_colours = [
        ((i * 53 + 10) & 0xFF, (i * 97 + 40) & 0xFF, (i * 149 + 85) & 0xFF)
        for i in range(16)
    ]
    pal_indices = [((y * 5 + x * 3) & 0x0F) for y in range(h) for x in range(w)]
    pal_expanded_planar = [
        [pal_colours[idx][0] for idx in pal_indices],
        [pal_colours[idx][1] for idx in pal_indices],
        [pal_colours[idx][2] for idx in pal_indices],
    ]

    w_lossy, h_lossy = 32, 24
    rgb8_lossy_planar = [
        [int(128 + 60 * ((x / w_lossy) - 0.5) + 40 * ((y / h_lossy) - 0.5)) & 0xFF for y in range(h_lossy) for x in range(w_lossy)],
        [int(110 + 50 * ((y / h_lossy) - 0.5)) & 0xFF for y in range(h_lossy) for x in range(w_lossy)],
        [int(140 - 50 * ((x / w_lossy) - 0.5)) & 0xFF for y in range(h_lossy) for x in range(w_lossy)],
    ]

    xml_payload = b'<?xml version="1.0" encoding="UTF-8"?><swiftj2k><milestone>8</milestone></swiftj2k>'
    uuid_id = bytes.fromhex("be7acfcb97a942e89c71999491e3afac")
    uuid_payload = b"SwiftJ2K-M8-UUID-Payload"

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)

        # 1. 12-bit unsigned greyscale JP2 (OpenJPEG + Kakadu)
        g12_raw = tmp / "g12.rawl"
        g12_raw.write_bytes(b"".join(struct.pack("<H", s) for s in g12_samples))
        opj_g12 = OUT_DIR / "jp2_g16_lossless.opj.jp2"
        kdu_g12 = OUT_DIR / "jp2_g16_lossless.kdu.jp2"
        run([OPJ_COMPRESS, "-i", g12_raw, "-F", f"{w},{h},1,12,u", "-n", "3", "-o", opj_g12])
        run([KDU_COMPRESS, "-i", g12_raw, "-o", kdu_g12, f"Sdims={{{h},{w}}}", "Nprecision=12", "Nsigned=no", "Creversible=yes", "-jp2_space", "sLUM"], env=kdu_env())
        for p, gen in [(opj_g12, "openjpeg"), (kdu_g12, "kakadu")]:
            manifest["fixtures"].append({
                "file": p.name, "generator": gen, "format": "jp2",
                "width": w, "height": h, "components": 1, "meaningfulBits": 12,
                "signed": False, "lossless": True, "samples": [g12_samples],
            })

        # 2. 12-bit signed greyscale JP2 (OpenJPEG + Kakadu)
        s12_raw = tmp / "s12.rawl"
        s12_raw.write_bytes(b"".join(struct.pack("<h", s) for s in s12_samples))
        opj_s12 = OUT_DIR / "jp2_s16_lossless.opj.jp2"
        kdu_s12 = OUT_DIR / "jp2_s16_lossless.kdu.jp2"
        run([OPJ_COMPRESS, "-i", s12_raw, "-F", f"{w},{h},1,12,s", "-n", "3", "-o", opj_s12])
        run([KDU_COMPRESS, "-i", s12_raw, "-o", kdu_s12, f"Sdims={{{h},{w}}}", "Nprecision=12", "Nsigned=yes", "Creversible=yes", "-jp2_space", "sLUM"], env=kdu_env())
        for p, gen in [(opj_s12, "openjpeg"), (kdu_s12, "kakadu")]:
            manifest["fixtures"].append({
                "file": p.name, "generator": gen, "format": "jp2",
                "width": w, "height": h, "components": 1, "meaningfulBits": 12,
                "signed": True, "lossless": True, "samples": [s12_samples],
            })

        # 3. 8-bit RGB lossless RCT JP2 (OpenJPEG + Kakadu)
        rgb_ppm = tmp / "rgb8.ppm"
        write_ppm(rgb_ppm, w, h, 255, rgb8_planar)
        opj_rgb = OUT_DIR / "jp2_rgb8_rct.opj.jp2"
        kdu_rgb = OUT_DIR / "jp2_rgb8_rct.kdu.jp2"
        run([OPJ_COMPRESS, "-i", rgb_ppm, "-n", "3", "-o", opj_rgb])
        run([KDU_COMPRESS, "-i", rgb_ppm, "-o", kdu_rgb, "Creversible=yes"], env=kdu_env())
        for p, gen in [(opj_rgb, "openjpeg"), (kdu_rgb, "kakadu")]:
            manifest["fixtures"].append({
                "file": p.name, "generator": gen, "format": "jp2",
                "width": w, "height": h, "components": 3, "meaningfulBits": 8,
                "signed": False, "lossless": True, "samples": rgb8_planar,
            })

        # 4. 8-bit RGB lossy ICT JP2 (OpenJPEG + Kakadu)
        rgb_lossy_ppm = tmp / "rgb8_lossy.ppm"
        write_ppm(rgb_lossy_ppm, w_lossy, h_lossy, 255, rgb8_lossy_planar)
        opj_lossy = OUT_DIR / "jp2_rgb8_ict_lossy.opj.jp2"
        kdu_lossy = OUT_DIR / "jp2_rgb8_ict_lossy.kdu.jp2"
        run([OPJ_COMPRESS, "-i", rgb_lossy_ppm, "-I", "-r", "4", "-n", "3", "-o", opj_lossy])
        run([KDU_COMPRESS, "-i", rgb_lossy_ppm, "-o", kdu_lossy, "Creversible=no", "-rate", "4.0"], env=kdu_env())
        for p, gen in [(opj_lossy, "openjpeg"), (kdu_lossy, "kakadu")]:
            manifest["fixtures"].append({
                "file": p.name, "generator": gen, "format": "jp2",
                "width": w_lossy, "height": h_lossy, "components": 3, "meaningfulBits": 8,
                "signed": False, "lossless": False, "samples": rgb8_lossy_planar,
            })

        # 5. 8-bit RGBA with 'cdef' opacity box (Kakadu)
        comp_files = []
        for idx, plane in enumerate(rgba8_planar):
            cp = tmp / f"c{idx}.rawl"
            cp.write_bytes(bytes(plane))
            comp_files.append(str(cp))
        kdu_rgba = OUT_DIR / "jp2_rgba8_cdef.kdu.jp2"
        run([
            KDU_COMPRESS, "-i", ",".join(comp_files), "-o", kdu_rgba,
            f"Sdims={{{h},{w}}}", "Nprecision=8", "Nsigned=no",
            "-jp2_space", "sRGB", "-jp2_alpha", "Creversible=yes"
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_rgba.name, "generator": "kakadu", "format": "jp2",
            "width": w, "height": h, "components": 4, "meaningfulBits": 8,
            "signed": False, "lossless": True, "hasAlpha": True, "samples": rgba8_planar,
        })

        # 6. 8-bit RGB with restricted ICC 'colr', 'resd', 'xml ', and 'uuid' boxes (Kakadu)
        xml_box_file = tmp / "xml_box.dat"
        xml_box_file.write_bytes(b"xml \n" + xml_payload)
        uuid_box_file = tmp / "uuid_box.dat"
        uuid_box_file.write_bytes(b"uuid\n" + uuid_id + uuid_payload)
        kdu_icc = OUT_DIR / "jp2_rgb8_icc_res_meta.kdu.jp2"
        run([
            KDU_COMPRESS, "-i", rgb_ppm, "-o", kdu_icc,
            "-jp2_space", "iccRGB,2.4,0.055,0.64,0.33,0.30,0.60,0.15,0.06,D65",
            "-jp2_aspect", "1.5",
            "-jp2_box", f"{xml_box_file},{uuid_box_file}",
            "Creversible=yes",
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_icc.name, "generator": "kakadu", "format": "jp2",
            "width": w, "height": h, "components": 3, "meaningfulBits": 8,
            "signed": False, "lossless": True, "hasICC": True, "hasXML": True, "hasUUID": True,
            "samples": rgb8_planar,
        })

        # 7. 8-bit palettised BMP with 'pclr', 'cmap', and 'resc' boxes (Kakadu)
        pal_bmp = tmp / "pal.bmp"
        write_indexed_bmp(pal_bmp, w, h, pal_colours, pal_indices)
        kdu_pal = OUT_DIR / "jp2_pal8_pclr_cmap_resc.kdu.jp2"
        run([KDU_COMPRESS, "-i", pal_bmp, "-o", kdu_pal, "Creversible=yes"], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_pal.name, "generator": "kakadu", "format": "jp2",
            "width": w, "height": h, "components": 3, "meaningfulBits": 8,
            "signed": False, "lossless": True, "isPalettised": True,
            "samples": pal_expanded_planar,
        })

        # 8. 12-bit unsigned greyscale JPH container (Kakadu HTJ2K)
        kdu_jph_g12 = OUT_DIR / "jph_g16_lossless.kdu.jph"
        run([
            KDU_COMPRESS, "-i", g12_raw, "-o", kdu_jph_g12,
            f"Sdims={{{h},{w}}}", "Nprecision=12", "Nsigned=no",
            "Cmodes=HT", "Creversible=yes", "-jp2_space", "sLUM",
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_jph_g12.name, "generator": "kakadu", "format": "jph",
            "width": w, "height": h, "components": 1, "meaningfulBits": 12,
            "signed": False, "lossless": True, "samples": [g12_samples],
        })

        # 9. 8-bit RGB lossless JPH container (Kakadu HTJ2K)
        kdu_jph_rgb = OUT_DIR / "jph_rgb8_rct.kdu.jph"
        run([
            KDU_COMPRESS, "-i", rgb_ppm, "-o", kdu_jph_rgb,
            "Cmodes=HT", "Creversible=yes",
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_jph_rgb.name, "generator": "kakadu", "format": "jph",
            "width": w, "height": h, "components": 3, "meaningfulBits": 8,
            "signed": False, "lossless": True, "samples": rgb8_planar,
        })

        # 10. 8-bit RGBA with 'cdef' JPH container (Kakadu HTJ2K)
        kdu_jph_rgba = OUT_DIR / "jph_rgba8_cdef.kdu.jph"
        run([
            KDU_COMPRESS, "-i", ",".join(comp_files), "-o", kdu_jph_rgba,
            f"Sdims={{{h},{w}}}", "Nprecision=8", "Nsigned=no",
            "-jp2_space", "sRGB", "-jp2_alpha", "Cmodes=HT", "Creversible=yes",
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_jph_rgba.name, "generator": "kakadu", "format": "jph",
            "width": w, "height": h, "components": 4, "meaningfulBits": 8,
            "signed": False, "lossless": True, "hasAlpha": True, "samples": rgba8_planar,
        })

        # 11. 8-bit RGB Part 1 JPX container with 'rreq', 'jpch', 'jplh', and XLBox 'jp2c' (Kakadu)
        kdu_jpx_p1 = OUT_DIR / "jpx_rgb8_part1.kdu.jpx"
        run([
            KDU_COMPRESS, "-i", rgb_ppm, "-o", kdu_jpx_p1,
            "Creversible=yes",
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_jpx_p1.name, "generator": "kakadu", "format": "jpx",
            "width": w, "height": h, "components": 3, "meaningfulBits": 8,
            "signed": False, "lossless": True, "samples": rgb8_planar,
        })

        # 12. 8-bit RGB HTJ2K JPX container with 'rreq', 'jpch', 'jplh', and XLBox 'jp2c' (Kakadu)
        kdu_jpx_ht = OUT_DIR / "jpx_rgb8_htj2k.kdu.jpx"
        run([
            KDU_COMPRESS, "-i", rgb_ppm, "-o", kdu_jpx_ht,
            "Cmodes=HT", "Creversible=yes",
        ], env=kdu_env())
        manifest["fixtures"].append({
            "file": kdu_jpx_ht.name, "generator": "kakadu", "format": "jpx",
            "width": w, "height": h, "components": 3, "meaningfulBits": 8,
            "signed": False, "lossless": True, "samples": rgb8_planar,
        })

    for item in manifest["fixtures"]:
        fp = OUT_DIR / item["file"]
        item["bytes"] = fp.stat().st_size
        item["sha256"] = sha256_hex(fp)

    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated {len(manifest['fixtures'])} container fixtures in {OUT_DIR}")


if __name__ == "__main__":
    main()
