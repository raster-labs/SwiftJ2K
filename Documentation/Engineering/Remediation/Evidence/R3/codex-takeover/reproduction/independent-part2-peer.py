#!/usr/bin/env python3
"""Bounded diagnostic: Kakadu limb decode + independent exact Annex J synthesis.

This is NOT a direct Part 10, combined Part 10+15, or direct logical38 peer
test. It converts dimensional header syntax for a strictly bounded depth-one
fixture, preserves its entropy bytes and Part 2 markers, independently asks
Kakadu to decode signed <=20-bit codestream components, then applies the
transmitted integer matrix. No production Swift code is imported.

Example (run only by the native-experiment owner):
  python3 work/independent-part2-peer.py --input candidate.jp3d \
      --expected expected.json --output-dir new-receipt-directory

Expected JSON: {"width":8,"height":8,"bitDepth":38,"signed":true,
                "samples":[...]} with width*height exact integer samples.
Alternatively replace bitDepth/signed/samples with a "components" list of
objects containing those fields. All components share width and height.

Only one tile/part, origin zero, depth=1, NLx=NLy=NLz=0, zcb=0, reversible XY
levels, implicit precincts, matching main COC geometry, reversible main QCC,
one MCT array [1,524288], one MCC stage with 2->1
collections and zero offset are admitted. Native timeout defaults to30s.
ITU-T T.801 (08/2023) A.2.1, A.3.6-9, Annex J define the Part2 interpretation;
T.809 dimensional COD becomes ordinary 2D COD only under these restrictions.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import time


class DiagnosticError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise DiagnosticError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Reader:
    def __init__(self, data, label):
        self.data, self.pos, self.label = data, 0, label

    def take(self, count):
        require(count >= 0 and self.pos + count <= len(self.data),
                f"truncated {self.label} at {self.pos}, need {count}")
        result = self.data[self.pos:self.pos + count]
        self.pos += count
        return result

    def uint(self, count):
        return int.from_bytes(self.take(count), "big")

    def done(self):
        require(self.pos == len(self.data), f"unexpected tail in {self.label}")


def segment(marker, body):
    require(len(body) + 2 <= 65535, "marker too long")
    return struct.pack(">HH", marker, len(body) + 2) + body


def field_depth(value):
    depth, signed = (value & 127) + 1, bool(value & 128)
    require(1 <= depth <= 38, "invalid bit depth")
    return {"bitDepth": depth, "signed": signed}


def load_expected(path):
    require(path.stat().st_size <= 16 * 1024 * 1024, "expectation JSON too large")
    obj = json.loads(path.read_text())
    require(isinstance(obj, dict), "expectation must be an object")
    width, height = obj.get("width"), obj.get("height")
    require(type(width) is int and type(height) is int and
            1 <= width <= 4096 and 1 <= height <= 4096 and
            width * height <= 262144, "expectation dimensions exceed bounds")
    require(obj.get("depth", 1) == 1, "only depth1 is supported")
    components = obj.get("components", [obj])
    require(isinstance(components, list) and 1 <= len(components) <= 256,
            "expectation component count exceeds diagnostic bounds")
    for c in components:
        require(isinstance(c, dict), "component expectation must be object")
        bits, signed, samples = c.get("bitDepth"), c.get("signed"), c.get("samples")
        require(type(bits) is int and 20 <= bits <= 38 and type(signed) is bool,
                "explicit logical bitDepth20..38 and signed bool required")
        require(isinstance(samples, list) and len(samples) == width * height,
                "wrong sample count")
        lo = -(1 << (bits - 1)) if signed else 0
        hi = (1 << (bits - int(signed))) - 1
        require(all(type(x) is int and lo <= x <= hi for x in samples),
                "noninteger or out-of-range expected sample")
    require(width * height * len(components) <= 262144,
            "too many aggregate logical samples")
    return width, height, components


def parse_and_adapt(data, expected):
    require(data[:2] == b"\xff\x4f", "raw SOC codestream required")
    pos, ordered, bodies, full = 2, [], {}, {}
    allowed = {0xFF50, 0xFF51, 0xFF52, 0xFF53, 0xFF54, 0xFF59, 0xFF5C, 0xFF5D, 0xFF64,
               0xFF74, 0xFF75, 0xFF77, 0xFF78}
    while True:
        require(pos + 2 <= len(data), "missing SOT")
        marker = int.from_bytes(data[pos:pos + 2], "big")
        if marker == 0xFF90:
            break
        require(marker in allowed, f"unsupported main marker 0x{marker:04x}")
        require(pos + 4 <= len(data), "truncated marker length")
        size = int.from_bytes(data[pos + 2:pos + 4], "big")
        require(size >= 2 and pos + 2 + size <= len(data), "bad marker length")
        raw, body = data[pos:pos + 2 + size], data[pos + 4:pos + 2 + size]
        if marker not in (0xFF53, 0xFF5D, 0xFF64):
            require(marker not in bodies, f"duplicate marker0x{marker:04x}")
            bodies[marker], full[marker] = body, raw
        ordered.append((marker, body, raw))
        pos += 2 + size
    for marker in allowed - {0xFF53, 0xFF5D, 0xFF64, 0xFF59}:
        require(marker in bodies, f"missing required marker0x{marker:04x}")
    require(ordered[0][0] == 0xFF51, "SIZ must immediately follow SOC")

    width, height, components = expected
    r = Reader(bodies[0xFF51], "SIZ")
    rsiz = r.uint(2)
    xs, ys, xo, yo, xt, yt, xto, yto = [r.uint(4) for _ in range(8)]
    count = r.uint(2)
    require(rsiz == 0xC100, "original Rsiz must signal Part2 MCT + CAP (0xc100)")
    require((xs, ys) == (width, height) and (xo, yo, xto, yto) == (0, 0, 0, 0)
            and xt >= xs and yt >= ys, "only one origin-zero XY tile supported")
    require(count == len(components) * 2, "wire component count must be twice logical")
    wire = []
    for _ in range(count):
        info = field_depth(r.uint(1))
        require(info["signed"] and info["bitDepth"] <= 20,
                "wire components must be signed, <=20bits")
        require((r.uint(1), r.uint(1)) == (1, 1), "XY subsampling unsupported")
        wire.append(info)
    r.done()

    r = Reader(bodies[0xFF54], "NSI")
    require(r.uint(1) == 3, "NSI dimensionality must be3")
    require([r.uint(4) for _ in range(4)] == [1, 0, 1, 0],
            "NSI must have Zsiz1 ZOsiz0 ZTsiz1 ZTOsiz0")
    require(r.take(count) == bytes([1]) * count, "Z subsampling unsupported")
    r.done()

    r = Reader(bodies[0xFF50], "CAP")
    pcap = r.uint(4)
    require(pcap in (0x00400000, 0x00420000, 0x40400000, 0x40420000),
            "only Part10, optional Part15 and zero-extension Part2 CAP supported")
    caps = {}
    for part in range(1, 33):
        if pcap & (1 << (32 - part)):
            caps[part] = r.uint(2)
    r.done()
    require(caps[10] == 0, "unsupported Part10 capability word")
    require(caps.get(2, 0) == 0, "Part2 block-coder/progression extensions unsupported")
    remaining_caps = {part: word for part, word in caps.items() if part != 10}
    cpfnum = None
    if 0xFF59 in bodies:
        cpf = bodies[0xFF59]
        require(2 <= len(cpf) <= 8 and len(cpf) % 2 == 0 and cpf[-2:] != b"\0\0",
                "malformed CPF representation")
        cpfnum = sum(int.from_bytes(cpf[i:i + 2], "big") << (8 * i)
                     for i in range(0, len(cpf), 2)) - 1

    cod = bodies[0xFF52]
    require(len(cod) == 15, "only base 3D COD without explicit precincts supported")
    scod, progression = cod[:2]
    layers = int.from_bytes(cod[2:4], "big")
    mct, nx, ny, nz, xcb, ycb, zcb, style, dx, dy, dz = cod[4:]
    require(scod == 0 and progression == 0 and layers >= 1,
            "only implicit precinct LRCP without SOP/EPH supported")
    require(mct == 2, "COD must signal array-based MCT (2)")
    require(nx == 0 and ny == 0 and nz == 0 and zcb == 0,
            "require zero DWT levels: Part1/10 integer filtering orders differ")
    require(2 <= xcb <= 10 and 2 <= ycb <= 10 and xcb + ycb <= 12,
            "code-block dimensions must fit Part1/15 planar limits")
    require((dx, dy, dz) == (1, 1, 1), "only reversible5/3 supported")
    require(style in (0, 0x40), "only ordinary EBCOT or HT-only codeblock style")
    require((style == 0x40) == (15 in caps), "HT style/CAP mismatch")
    if 15 in caps:
        require(caps[15] & 0xFFE0 == 0, "only simple HTONLY/HTREV/HOMOGENEOUS CAP")
    require(0xFF59 not in bodies or 15 in caps, "CPF requires Part15")
    qcd = bodies[0xFF5C]
    require(len(qcd) == 2 + 3 * nx and (qcd[0] & 31) == 0,
            "QCD must contain exactly the 2D reversible subband table")
    index_width = 1 if count < 257 else 2
    seen_coc, seen_qcc, quantizers = set(), set(), []
    for marker, body, raw in ordered:
        if marker not in (0xFF53, 0xFF5D):
            continue
        require(len(body) >= index_width + 1, "truncated COC/QCC component selector")
        component = int.from_bytes(body[:index_width], "big")
        require(component < count, "COC/QCC component selector out of range")
        if marker == 0xFF53:
            require(component not in seen_coc, "duplicate COC component")
            seen_coc.add(component)
            require(body[index_width:] == bytes([0]) + cod[5:],
                    "bounded COC must match main COD spatial parameters and implicit precincts")
        else:
            require(component not in seen_qcc, "duplicate QCC component")
            seen_qcc.add(component)
            quantizer = body[index_width:]
            require(len(quantizer) == 2 + 3 * nx and (quantizer[0] & 31) == 0,
                    "QCC must contain the bounded 2D reversible subband table")
            quantizers.append({"component": component, "markerSHA256": digest(raw)})

    r = Reader(bodies[0xFF78], "CBD")
    ncbd = r.uint(2)
    require((ncbd & 0x7FFF) == len(components), "CBD logical component count mismatch")
    cbd = [field_depth(r.uint(1)) for _ in range(1 if ncbd & 0x8000 else len(components))]
    r.done()
    if ncbd & 0x8000:
        cbd *= len(components)
    for i, c in enumerate(components):
        require(cbd[i] == {"bitDepth": c["bitDepth"], "signed": c["signed"]},
                "CBD depth/signedness differs from independent expectation")

    r = Reader(bodies[0xFF74], "MCT")
    z, imct, y = r.uint(2), r.uint(2), r.uint(2)
    require(z == y == 0 and imct == 0x0501, "one unfragmented int32 decorrelation array1 required")
    matrix = list(struct.unpack(">ii", r.take(8)))
    r.done()
    require(matrix == [1, 524288], "transmitted matrix is not [1,524288]")

    r = Reader(bodies[0xFF75], "MCC")
    z, stage, y, ncollections = r.uint(2), r.uint(1), r.uint(2), r.uint(2)
    require(z == y == 0 and ncollections == len(components), "unsupported MCC stages/collections")
    collections, seen_inputs, seen_outputs = [], set(), set()
    for _ in range(ncollections):
        require(r.uint(1) == 1, "Xmcc must be0x01 (0x09 sets a reserved bit)")
        nmcc = r.uint(2)
        require(nmcc & 0x7FFF == 2, "each collection must have two inputs")
        inputs = [r.uint(2 if nmcc & 0x8000 else 1) for _ in range(2)]
        mmcc = r.uint(2)
        require(mmcc & 0x7FFF == 1, "each collection must have one output")
        output = r.uint(2 if mmcc & 0x8000 else 1)
        tmcc = r.uint(3)
        require(tmcc == 1, "require irreversible decorrelation matrix1, offset0, reserved0")
        require(len(set(inputs)) == 2 and all(0 <= i < count for i in inputs)
                and not seen_inputs.intersection(inputs), "duplicate/out-of-range MCC inputs")
        require(0 <= output < len(components) and output not in seen_outputs,
                "duplicate/out-of-range MCC output")
        seen_inputs.update(inputs)
        seen_outputs.add(output)
        collections.append({"inputs": inputs, "output": output, "tmcc": tmcc})
    r.done()
    require(seen_inputs == set(range(count)) and seen_outputs == set(range(len(components))),
            "MCC does not cover all components")
    require(bodies[0xFF77] == bytes([1, stage]), "MCO must select the single transmitted MCC")

    require(pos + 14 <= len(data), "truncated tile part")
    require(data[pos + 2:pos + 4] == b"\x00\x0a", "SOT length must be10")
    tile, psot, tpart, nparts = struct.unpack(">HIBB", data[pos + 4:pos + 12])
    require((tile, tpart, nparts) == (0, 0, 1), "one tile-part required")
    require(psot >= 14 and pos + psot + 2 == len(data) and data[-2:] == b"\xff\xd9",
            "SOT length/EOC does not exactly bound the sole tile")
    require(data[pos + 12:pos + 14] == b"\xff\x93", "tile header overrides unsupported")
    entropy = data[pos + 14:pos + psot]
    adapted = bytearray(b"\xff\x4f")
    changes = []
    for marker, body, raw in ordered:
        if marker == 0xFF54:
            changes.append("removed NSI dimensional marker")
            continue
        if marker == 0xFF59:
            changes.append("removed optional CPF: derived dimensional fixture does not assert original corresponding-profile claim")
            continue
        if marker == 0xFF50:
            if remaining_caps:
                new_pcap = sum(1 << (32 - part) for part in remaining_caps)
                new_body = struct.pack(">I", new_pcap) + b"".join(
                    struct.pack(">H", remaining_caps[part]) for part in sorted(remaining_caps))
                adapted += segment(marker, new_body)
            changes.append("removed Part10 CAP; preserved optional Part2/15 CAP words")
            continue
        if marker == 0xFF51:
            adapted += segment(marker, struct.pack(">H", 0xC100 if remaining_caps else 0x8100) + body[2:])
            changes.append("SIZ Rsiz signals Part2 MCT and any remaining CAP")
        elif marker == 0xFF52:
            adapted += segment(marker, body[:5] + bytes([nx, xcb - 2, ycb - 2, style, dx]))
            changes.append("3D COD replaced by equivalent bounded2D COD")
        elif marker == 0xFF53:
            adapted += segment(marker, body[:index_width + 1] + bytes([nx, xcb - 2, ycb - 2, style, dx]))
            changes.append("matching main COC converted to equivalent bounded2D COC")
        else:
            adapted += raw
    tail_start = len(adapted)
    adapted += data[pos:]
    require(adapted[tail_start:] == data[pos:], "tile/entropy preservation failed")
    metadata = {"originalRsiz": rsiz, "originalPcap": pcap, "wireComponents": wire,
                "logicalComponents": cbd, "levelsXY": nx, "layers": layers,
                "codeBlockStyle": style, "matrix": matrix, "collections": collections,
                "entropySHA256": digest(entropy), "entropyBytes": len(entropy),
                "originalCPFnum": cpfnum, "originalCorrespondingProfileClaimValidated": False,
                "preservedQCDSHA256": digest(full[0xFF5C]), "preservedQCC": quantizers,
                "tilePartSHA256": digest(data[pos:pos + psot]),
                "preservedPart2MarkerSHA256": {f"{m:04x}": digest(full[m])
                    for m in (0xFF74, 0xFF75, 0xFF77, 0xFF78)},
                "headerChanges": changes}
    return bytes(adapted), metadata


def signed_limb_only_codestream(adapted):
    """Explicit fallback: external peer sees signed limbs, never the Part2 transform."""
    records = []
    pos = 2
    while pos + 4 <= len(adapted):
        marker = int.from_bytes(adapted[pos:pos + 2], "big")
        if marker == 0xFF90:
            break
        length = int.from_bytes(adapted[pos + 2:pos + 4], "big")
        body = adapted[pos + 4:pos + 2 + length]
        if marker == 0xFF50:
            r = Reader(body, "adapted CAP")
            mask = r.uint(4)
            caps = {part: r.uint(2) for part in range(1, 33) if mask & (1 << (32 - part))}
            r.done()
            caps.pop(2, None)
            body = struct.pack(">I", sum(1 << (32 - part) for part in caps)) + b"".join(
                struct.pack(">H", caps[part]) for part in sorted(caps))
            if not caps:
                pos += 2 + length
                continue
        if marker not in (0xFF74, 0xFF75, 0xFF77, 0xFF78):
            records.append((marker, body))
        pos += 2 + length
    has_cap = any(marker == 0xFF50 for marker, _ in records)
    result = bytearray(b"\xff\x4f")
    for marker, body in records:
        if marker == 0xFF51:
            body = struct.pack(">H", 0x4000 if has_cap else 0) + body[2:]
        elif marker == 0xFF52:
            body = body[:4] + bytes([0]) + body[5:]
        result += segment(marker, body)
    result += adapted[pos:]
    return bytes(result)


def read_pgx(path, width, height, info):
    raw = path.read_bytes()
    newline = raw.find(b"\n", 0, 128)
    require(newline >= 0, f"missing PGX header: {path.name}")
    header = raw[:newline].rstrip(b"\r")
    match = re.fullmatch(rb"PG\s+(ML|LM)\s+([+-])\s*(\d+)\s+(\d+)\s+(\d+)\s*", header)
    require(match is not None, f"invalid PGX header: {header!r}")
    order, sign, bits, w, h = match.groups()
    require((int(w), int(h), int(bits), sign == b"-") ==
            (width, height, info["bitDepth"], info["signed"]),
            "PGX precision/signedness/dimensions differ from SIZ")
    payload = raw[newline + 1:]
    count = width * height
    require(len(payload) % count == 0, "PGX payload does not contain whole samples")
    stride = len(payload) // count
    require(1 <= stride <= 4 and stride * 8 >= int(bits), "unsupported PGX sample storage")
    endian = "big" if order == b"ML" else "little"
    samples = [int.from_bytes(payload[i:i + stride], endian, signed=sign == b"-")
               for i in range(0, len(payload), stride)]
    limit = 1 << (int(bits) - 1)
    require(all(-limit <= x < limit for x in samples), "PGX signed samples out of range")
    return samples, {"file": path.name, "sha256": digest(raw),
                     "header": header.decode("ascii"), "bytesPerSample": stride,
                     "endianness": endian, "minimum": min(samples), "maximum": max(samples)}


def run(args, receipt):
    expected_path, source = Path(args.expected).resolve(), Path(args.input).resolve()
    out = Path(args.output_dir).resolve()
    expected = load_expected(expected_path)
    require(source.stat().st_size <= 32 * 1024 * 1024, "codestream exceeds32MiB bound")
    data = source.read_bytes()
    adapted, metadata = parse_and_adapt(data, expected)
    if args.limbs_only:
        adapted = signed_limb_only_codestream(adapted)
        metadata["headerChanges"].append("EXPLICIT LIMBS-ONLY FALLBACK: removed CBD/MCT/MCC/MCO, Part2 capability and COD array usage after validating original; peer does not interpret the matrix")
        receipt["part2MarkerPeer"] = "NOT_EXECUTED_BY_LIMBS_ONLY_FALLBACK"
    else:
        receipt["part2MarkerPeer"] = "ATTEMPTED_WITH_ORIGINAL_TRANSFORM_MARKERS"
    receipt.update(metadata)
    receipt.update({"input": str(source), "inputSHA256": digest(data),
                    "expectation": str(expected_path), "expectationSHA256": digest(expected_path.read_bytes())})
    kdu = Path(args.kdu).resolve(strict=True)
    receipt["peer"] = {"path": str(kdu), "sha256": digest(kdu.read_bytes())}
    adapted_path = out / "derived-2d-part2.j2c"
    adapted_path.write_bytes(adapted)
    receipt["adaptedSHA256"] = digest(adapted)
    pgxs = [out / f"wire-{i:03d}.pgx" for i in range(len(metadata["wireComponents"]))]
    command = [str(kdu), "-i", str(adapted_path), "-o", ",".join(map(str, pgxs)),
               "-codestream_components", "-precise", "-fussy", "-num_threads", "0",
               "-record", str(out / "kakadu-parameters.txt")]
    receipt["command"] = command
    receipt["nativeStatus"] = "started"
    start = time.monotonic()
    with (out / "kakadu.stdout.txt").open("wb") as stdout, (out / "kakadu.stderr.txt").open("wb") as stderr:
        try:
            result = subprocess.run(command, stdout=stdout, stderr=stderr,
                                    timeout=args.timeout, check=False, cwd=out)
        except subprocess.TimeoutExpired as error:
            receipt["nativeStatus"] = "timed-out"
            raise DiagnosticError(f"Kakadu exceeded {args.timeout}s") from error
    receipt["nativeSeconds"] = time.monotonic() - start
    receipt["nativeExitCode"] = result.returncode
    receipt["nativeStatus"] = "exited"
    require(result.returncode == 0, "Kakadu failed; retained stdout/stderr explain failure")
    width, height, expected_components = expected
    wire, pgx_receipts = [], []
    for path, info in zip(pgxs, metadata["wireComponents"]):
        samples, details = read_pgx(path, width, height, info)
        wire.append(samples)
        pgx_receipts.append(details)
    receipt["peerOutputs"] = pgx_receipts
    actual = [None] * len(expected_components)
    for collection in metadata["collections"]:
        a, b = collection["inputs"]
        # Exact integer evaluation of the transmitted array; no own-codec reassembly.
        actual[collection["output"]] = [metadata["matrix"][0] * x + metadata["matrix"][1] * y
                                          for x, y in zip(wire[a], wire[b])]
    comparisons, total_mismatches = [], 0
    for i, (samples, exp) in enumerate(zip(actual, expected_components)):
        mismatches = [{"sample": p, "expected": e, "actual": a}
                      for p, (a, e) in enumerate(zip(samples, exp["samples"])) if a != e]
        total_mismatches += len(mismatches)
        comparisons.append({"component": i, "samples": len(samples), "minimum": min(samples),
                            "maximum": max(samples), "mismatches": len(mismatches),
                            "firstMismatches": mismatches[:16],
                            "actualSignedInt64LESHA256": digest(b"".join(struct.pack("<q", x) for x in samples)),
                            "expectedSignedInt64LESHA256": digest(b"".join(struct.pack("<q", x) for x in exp["samples"]))})
    receipt["comparisons"] = comparisons
    require(total_mismatches == 0, f"{total_mismatches} logical sample mismatches")
    receipt["status"] = "passed-narrow-composite-diagnostic"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--output-dir", required=True, help="new directory; never overwritten")
    parser.add_argument("--kdu", default="/Library/Kakadu/8.4.1/bin/kdu_expand")
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--limbs-only", action="store_true", help="Explicitly remove validated Part2 markers for signed-limb decoding; no Part2 peer claim")
    args = parser.parse_args()
    require(1 <= args.timeout <= 60, "native timeout must be1..60s")
    out = Path(args.output_dir).resolve()
    require(not out.exists(), "output directory already exists; choose new receipt directory")
    out.mkdir(parents=True, exist_ok=False)
    receipt = {"status": "failed", "nativeStatus": "not-started",
               "scope": "independent Kakadu signed-limb decode + separate exact AnnexJ synthesis of header-adapted2D fixture",
               "directPart10Peer": "UNEXECUTED", "directPart10Plus15Peer": "UNEXECUTED",
               "directLogical38KakaduDecode": "UNEXECUTED", "gatesWaived": False,
               "scriptSHA256": digest(Path(__file__).read_bytes())}
    code = 0
    try:
        run(args, receipt)
    except (DiagnosticError, OSError, ValueError, struct.error) as error:
        receipt["error"] = str(error)
        code = 1
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "receipt": str(out / "receipt.json"),
                      "error": receipt.get("error")}, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
