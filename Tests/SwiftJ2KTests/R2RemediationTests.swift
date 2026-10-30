// SPDX-License-Identifier: Apache-2.0
//
// R2RemediationTests.swift
// SwiftJ2KTests
//
// Phase R2 semantics remediation regressions covering:
// - F07: Palette/channel/colour reconciliation (`pclr`/`cmap`/`cdef`/`colr`) across
//        legacy adapters (`J2KDecoder`, `J2KImage`, `J2KTranscoder`).
// - F08: ISO/IEC 15444-2 Table M.14 JPX reader-requirements (`rreq`) feature codes,
//        display/fully-understand masks, disjunctive/conjunctive evaluation, and
//        deterministic rejection of unsupported required features.
// - F12: Deterministic rejection of duplicate `jp2c` boxes in JP2/JPH (`.malformedInput`)
//        and multiple `jp2c` boxes in JPX (`.unsupportedFeature`).
// - M12-CX-03: Normative W3C PNG `sBIT` handling (high-order right-shift on read,
//              left-bit-replication scaling on write, unequal channel `sBIT` rejection,
//              out-of-range precision rejection without silent clipping, and raw PNG
//              chunk + unfiltered `IDAT` byte-layout verification).
// - M12-CX-04: Deliberate TIFF `PhotometricInterpretation` (tag 262) handling for
//              `WhiteIsZero` (0), `BlackIsZero` (1), `RGB` (2), and `Palette Color` (3)
//              across single-strip and multi-strip TIFFs, plus truthful rejection of
//              unsupported photometric modes (`YCbCr`, `CMYK`, `Transparency Mask`, `Lab`).

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2KCLI

// MARK: - CLI & Binary Fixture Helpers

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func containerFixtureURL(_ name: String) -> URL {
    repoRootURL()
        .appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Containers")
        .appendingPathComponent(name)
}

private func locateR2CLIBinary() throws -> URL {
    let root = repoRootURL()
    let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
    let candidates = [
        bundleDir.appendingPathComponent("swiftj2k-cli"),
        root.appendingPathComponent(".build/out/Products/Debug/swiftj2k-cli"),
        root.appendingPathComponent(".build/debug/swiftj2k-cli"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/swiftj2k-cli"),
        root.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/swiftj2k-cli"),
        root.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/swiftj2k-cli"),
        root.appendingPathComponent(".build/out/Products/Release/swiftj2k-cli"),
        root.appendingPathComponent(".build/release/swiftj2k-cli")
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    let buildProc = Process()
    buildProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    buildProc.arguments = ["swift", "build", "--product", "swiftj2k-cli"]
    buildProc.currentDirectoryURL = root
    try buildProc.run()
    buildProc.waitUntilExit()
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw CodecError(.internalFailure, "Could not locate or build swiftj2k-cli binary for Phase R2 tests.")
}

private struct R2CLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

private func runR2CLI(_ args: [String]) throws -> R2CLIResult {
    let binary = try locateR2CLIBinary()
    let proc = Process()
    proc.executableURL = binary
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try proc.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return R2CLIResult(status: proc.terminationStatus, stdout: outData, stderr: errData)
}

private func makeJP2Box(_ type: String, payload: [UInt8]) -> [UInt8] {
    let length = UInt32(8 + payload.count)
    var out: [UInt8] = [
        UInt8((length >> 24) & 0xFF),
        UInt8((length >> 16) & 0xFF),
        UInt8((length >> 8) & 0xFF),
        UInt8(length & 0xFF)
    ]
    out.append(contentsOf: type.utf8)
    out.append(contentsOf: payload)
    return out
}

// MARK: - Independent Raw PNG & Zlib Builders/Inspectors

private func testPNGCRC32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        var c = (crc ^ UInt32(byte)) & 0xFF
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        crc = c ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

/// Independent RFC-1950 + RFC-1951 stored-block zlib encoder (independent of `formatPNG`).
private func zlibCompress(_ raw: [UInt8]) throws -> [UInt8] {
    guard raw.count <= 65535 else {
        throw CodecError(.invalidArgument, "Test PNG payload exceeds single stored DEFLATE block")
    }
    var out: [UInt8] = [0x78, 0x01, 0x01] // CMF=0x78, FLG=0x01, BFINAL=1 + BTYPE=00 (stored)
    let len = UInt16(raw.count)
    let nlen = ~len
    out.append(UInt8(len & 0xFF))
    out.append(UInt8((len >> 8) & 0xFF))
    out.append(UInt8(nlen & 0xFF))
    out.append(UInt8((nlen >> 8) & 0xFF))
    out.append(contentsOf: raw)
    var s1: UInt32 = 1
    var s2: UInt32 = 0
    for b in raw {
        s1 = (s1 + UInt32(b)) % 65521
        s2 = (s2 + s1) % 65521
    }
    let adler = (s2 << 16) | s1
    out.append(UInt8((adler >> 24) & 0xFF))
    out.append(UInt8((adler >> 16) & 0xFF))
    out.append(UInt8((adler >> 8) & 0xFF))
    out.append(UInt8(adler & 0xFF))
    return out
}

private func zlibDecompress(_ compressed: [UInt8], expectedCount: Int) throws -> [UInt8] {
    let inflated = try zlibInflateBounded(Data(compressed), expectedSize: expectedCount)
    return [UInt8](inflated)
}

private func appendPNGChunkBytes(_ out: inout [UInt8], type: String, payload: [UInt8]) {
    let len = UInt32(payload.count)
    out.append(contentsOf: [
        UInt8((len >> 24) & 0xFF),
        UInt8((len >> 16) & 0xFF),
        UInt8((len >> 8) & 0xFF),
        UInt8(len & 0xFF)
    ])
    var typeAndData = Array(type.utf8)
    typeAndData.append(contentsOf: payload)
    out.append(contentsOf: typeAndData)
    let crc = testPNGCRC32(typeAndData)
    out.append(contentsOf: [
        UInt8((crc >> 24) & 0xFF),
        UInt8((crc >> 16) & 0xFF),
        UInt8((crc >> 8) & 0xFF),
        UInt8(crc & 0xFF)
    ])
}

private func buildIndependentPNG(
    width: Int,
    height: Int,
    bitDepth: Int,
    colorType: UInt8,
    sbitBeforeIDAT: [UInt8]? = nil,
    extraSbitBeforeIDAT: [UInt8]? = nil,
    sbitAfterIDAT: [UInt8]? = nil,
    samplesBigEndian: [UInt16]
) throws -> Data {
    let channels: Int
    switch colorType {
    case 0: channels = 1
    case 2: channels = 3
    case 4: channels = 2
    case 6: channels = 4
    default: channels = 1
    }
    let bytesPerSample = bitDepth / 8
    var rawScanlines: [UInt8] = []
    rawScanlines.reserveCapacity(height * (1 + width * channels * bytesPerSample))
    var idx = 0
    for _ in 0..<height {
        rawScanlines.append(0) // Filter type 0 (None)
        for _ in 0..<(width * channels) {
            let s = samplesBigEndian[idx]
            idx += 1
            if bytesPerSample == 1 {
                rawScanlines.append(UInt8(truncatingIfNeeded: s))
            } else {
                rawScanlines.append(UInt8((s >> 8) & 0xFF))
                rawScanlines.append(UInt8(s & 0xFF))
            }
        }
    }
    let idat = try zlibCompress(rawScanlines)
    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    let w32 = UInt32(width)
    let h32 = UInt32(height)
    let ihdr: [UInt8] = [
        UInt8((w32 >> 24) & 0xFF), UInt8((w32 >> 16) & 0xFF), UInt8((w32 >> 8) & 0xFF), UInt8(w32 & 0xFF),
        UInt8((h32 >> 24) & 0xFF), UInt8((h32 >> 16) & 0xFF), UInt8((h32 >> 8) & 0xFF), UInt8(h32 & 0xFF),
        UInt8(bitDepth), colorType, 0, 0, 0
    ]
    appendPNGChunkBytes(&out, type: "IHDR", payload: ihdr)
    if let sb = sbitBeforeIDAT {
        appendPNGChunkBytes(&out, type: "sBIT", payload: sb)
    }
    if let sb2 = extraSbitBeforeIDAT {
        appendPNGChunkBytes(&out, type: "sBIT", payload: sb2)
    }
    appendPNGChunkBytes(&out, type: "IDAT", payload: idat)
    if let sbPost = sbitAfterIDAT {
        appendPNGChunkBytes(&out, type: "sBIT", payload: sbPost)
    }
    appendPNGChunkBytes(&out, type: "IEND", payload: [])
    return Data(out)
}

private func inspectRawPNG16Greyscale(_ data: Data) throws -> (bitDepth: Int, sbit: [UInt8]?, rawWords: [UInt16]) {
    let bytes = [UInt8](data)
    var pos = 8
    var width = 0
    var height = 0
    var bitDepth = 0
    var channels = 1
    var sbit: [UInt8]?
    var idat: [UInt8] = []
    while pos + 8 <= bytes.count {
        let len = (Int(bytes[pos]) << 24) | (Int(bytes[pos + 1]) << 16) | (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
        let type = String(bytes: bytes[(pos + 4)..<(pos + 8)], encoding: .ascii) ?? ""
        let start = pos + 8
        let end = start + len
        if type == "IHDR" {
            width = (Int(bytes[start]) << 24) | (Int(bytes[start + 1]) << 16) | (Int(bytes[start + 2]) << 8) | Int(bytes[start + 3])
            height = (Int(bytes[start + 4]) << 24) | (Int(bytes[start + 5]) << 16) | (Int(bytes[start + 6]) << 8) | Int(bytes[start + 7])
            bitDepth = Int(bytes[start + 8])
            let ct = bytes[start + 9]
            channels = (ct == 0) ? 1 : (ct == 2 ? 3 : (ct == 4 ? 2 : 4))
        } else if type == "sBIT" {
            sbit = Array(bytes[start..<end])
        } else if type == "IDAT" {
            idat.append(contentsOf: bytes[start..<end])
        } else if type == "IEND" {
            break
        }
        pos = end + 4
    }
    let bpp = channels * (bitDepth / 8)
    let scanlineBytes = width * bpp
    let stride = 1 + scanlineBytes
    var scanlines = try zlibDecompress(idat, expectedCount: height * stride)
    for row in 0..<height {
        let rowStart = row * stride
        let filter = scanlines[rowStart]
        let cur = rowStart + 1
        let prev = (row - 1) * stride + 1
        for i in 0..<scanlineBytes {
            let x = Int(scanlines[cur + i])
            let a = (i >= bpp) ? Int(scanlines[cur + i - bpp]) : 0
            let b = (row > 0) ? Int(scanlines[prev + i]) : 0
            let c = (row > 0 && i >= bpp) ? Int(scanlines[prev + i - bpp]) : 0
            let recon: Int
            switch filter {
            case 0: recon = x
            case 1: recon = (x + a) & 0xFF
            case 2: recon = (x + b) & 0xFF
            case 3: recon = (x + ((a + b) >> 1)) & 0xFF
            case 4:
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                let pr = (pa <= pb && pa <= pc) ? a : ((pb <= pc) ? b : c)
                recon = (x + pr) & 0xFF
            default:
                throw CodecError(.malformedInput, "Unexpected PNG filter \(filter)")
            }
            scanlines[cur + i] = UInt8(truncatingIfNeeded: recon)
        }
    }
    var words: [UInt16] = []
    for row in 0..<height {
        let cur = row * stride + 1
        for sIdx in 0..<(width * channels) {
            let off = cur + sIdx * 2
            words.append((UInt16(scanlines[off]) << 8) | UInt16(scanlines[off + 1]))
        }
    }
    return (bitDepth, sbit, words)
}

// MARK: - Independent Uncompressed TIFF Builder

private struct RawTIFFTag {
    let tag: UInt16
    let type: UInt16 // 3 = SHORT, 4 = LONG
    let values: [UInt32]
}

private func buildIndependentTIFF(
    tags: [RawTIFFTag],
    strips: [[UInt8]],
    omitStripTags: Bool = false
) -> Data {
    var sortedTags = tags
    let stripCount = strips.count
    // Reserve placeholder tags 273 (StripOffsets) and 279 (StripByteCounts) unless omitted
    if !omitStripTags {
        sortedTags.append(RawTIFFTag(tag: 273, type: 4, values: [UInt32](repeating: 0, count: stripCount)))
        sortedTags.append(RawTIFFTag(tag: 279, type: 4, values: strips.map { UInt32($0.count) }))
    }
    sortedTags.sort { $0.tag < $1.tag }

    let ifdOffset = 8
    let ifdSize = 2 + sortedTags.count * 12 + 4
    var extraData: [UInt8] = []
    var tagPayloadOffsets: [UInt16: Int] = [:]

    func appendU16LE(_ arr: inout [UInt8], _ v: UInt16) {
        arr.append(UInt8(v & 0xFF))
        arr.append(UInt8((v >> 8) & 0xFF))
    }
    func appendU32LE(_ arr: inout [UInt8], _ v: UInt32) {
        arr.append(UInt8(v & 0xFF))
        arr.append(UInt8((v >> 8) & 0xFF))
        arr.append(UInt8((v >> 16) & 0xFF))
        arr.append(UInt8((v >> 24) & 0xFF))
    }

    for entry in sortedTags {
        let elemSize = (entry.type == 3) ? 2 : 4
        let byteLen = entry.values.count * elemSize
        if byteLen > 4 {
            tagPayloadOffsets[entry.tag] = ifdOffset + ifdSize + extraData.count
            for v in entry.values {
                if entry.type == 3 {
                    appendU16LE(&extraData, UInt16(truncatingIfNeeded: v))
                } else {
                    appendU32LE(&extraData, v)
                }
            }
            if extraData.count % 2 == 1 {
                extraData.append(0)
            }
        }
    }

    let stripsBaseOffset = ifdOffset + ifdSize + extraData.count
    var stripOffsets: [UInt32] = []
    var runningStripPos = stripsBaseOffset
    for strip in strips {
        stripOffsets.append(UInt32(runningStripPos))
        runningStripPos += strip.count
    }

    // Patch StripOffsets into extraData if multi-strip
    if !omitStripTags && stripCount > 1, let offPos = tagPayloadOffsets[273] {
        let localStart = offPos - (ifdOffset + ifdSize)
        for (i, so) in stripOffsets.enumerated() {
            let p = localStart + i * 4
            extraData[p] = UInt8(so & 0xFF)
            extraData[p + 1] = UInt8((so >> 8) & 0xFF)
            extraData[p + 2] = UInt8((so >> 16) & 0xFF)
            extraData[p + 3] = UInt8((so >> 24) & 0xFF)
        }
    }

    var out: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
    appendU32LE(&out, UInt32(ifdOffset))
    appendU16LE(&out, UInt16(sortedTags.count))

    for entry in sortedTags {
        appendU16LE(&out, entry.tag)
        appendU16LE(&out, entry.type)
        let vals: [UInt32] = (entry.tag == 273 && !omitStripTags) ? stripOffsets : entry.values
        appendU32LE(&out, UInt32(vals.count))
        let elemSize = (entry.type == 3) ? 2 : 4
        let byteLen = vals.count * elemSize
        if byteLen <= 4 {
            var inlineBytes: [UInt8] = []
            for v in vals {
                if entry.type == 3 {
                    appendU16LE(&inlineBytes, UInt16(truncatingIfNeeded: v))
                } else {
                    appendU32LE(&inlineBytes, v)
                }
            }
            while inlineBytes.count < 4 { inlineBytes.append(0) }
            out.append(contentsOf: inlineBytes)
        } else {
            appendU32LE(&out, UInt32(tagPayloadOffsets[entry.tag]!))
        }
    }
    appendU32LE(&out, 0) // Next IFD = 0
    out.append(contentsOf: extraData)
    for strip in strips {
        out.append(contentsOf: strip)
    }
    return Data(out)
}

private func parseNRRDSamples(_ data: Data) throws -> (header: String, width: Int, height: Int, components: Int, meaningfulBits: Int, samples: [Int]) {
    guard let split = data.range(of: Data([0x0A, 0x0A])) else {
        throw CodecError(.malformedInput, "Missing NRRD header terminator")
    }
    let header = String(data: data[..<split.lowerBound], encoding: .utf8) ?? ""
    var fields: [String: String] = [:]
    var keys: [String: String] = [:]
    for line in header.split(separator: "\n").dropFirst() {
        if let r = line.range(of: ":=") {
            keys[line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)] =
                line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        } else if let r = line.range(of: ":") {
            fields[line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)] =
                line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        }
    }
    let dim = Int(fields["dimension"] ?? "2") ?? 2
    let sizes = (fields["sizes"] ?? "").split(separator: " ").compactMap { Int($0) }
    let (comps, w, h): (Int, Int, Int) = (dim == 2) ? (1, sizes[0], sizes[1]) : (sizes[0], sizes[1], sizes[2])
    let type = fields["type"] ?? "uint8"
    let bits = Int(keys["swiftj2k.meaningfulbits"] ?? (type.contains("16") ? "16" : "8")) ?? 8
    let body = [UInt8](data[split.upperBound...])
    var samples: [Int] = []
    if type == "uint16" {
        for i in stride(from: 0, to: body.count, by: 2) {
            samples.append(Int(body[i]) | (Int(body[i + 1]) << 8))
        }
    } else {
        samples = body.map { Int($0) }
    }
    return (header, w, h, comps, bits, samples)
}

// MARK: - Phase R2 Core & CLI Regression Suite

@Suite("Phase R2 — Core, Container & CLI Semantics Remediation Regressions")
struct R2RemediationTests {

    // MARK: F07 — Palette, Channel Definition, and Colour Reconciliation in Legacy Adapters

    @Test("F07: J2KDecoder, J2KImage.toContractImage, and J2KTranscoder preserve pclr/cmap, cdef, and ICC semantics")
    func legacyBridgePreservesPaletteChannelPermutationAndICC() async throws {
        // 1. Kakadu palettised JP2 (`pclr` + `cmap` + `resc`): 1-component index codestream -> 3-component RGB
        let palData = try Data(contentsOf: containerFixtureURL("jp2_pal8_pclr_cmap_resc.kdu.jp2"))
        let contractPal = try await Decoder().decode(palData).image
        #expect(contractPal.descriptor.components == [.red, .green, .blue])
        #expect(contractPal.descriptor.colour == .rgb)

        let legacyPal = try await J2KDecoder().decode(palData)
        #expect(legacyPal.componentCount == 3)
        #expect(legacyPal.colorSpace == .sRGB)
        for y in 0..<contractPal.descriptor.height {
            for x in 0..<contractPal.descriptor.width {
                for c in 0..<3 {
                    let expected = try contractPal.sampleInt(component: c, x: x, y: y)
                    let actual = Int(legacyPal.components[c].data[y * legacyPal.width + x])
                    #expect(actual == expected)
                }
            }
        }
        let roundTripContractPal = try legacyPal.toContractImage()
        #expect(roundTripContractPal.descriptor.components == [.red, .green, .blue])

        // Transcoding palettised JP2 -> HTJ2K container and back via J2KTranscoder must preserve
        // the 1-component index codestream AND the `pclr`/`cmap`/`colr`/`resc` JP2 header boxes.
        let transcodedPalHT = try J2KTranscoder().transcode(palData, direction: .legacyToHT)
        let decodedPalHT = try await Decoder().decode(transcodedPalHT.data).image
        #expect(decodedPalHT.descriptor.components == [.red, .green, .blue])
        let legacyPalHT = try await J2KDecoder().decode(transcodedPalHT.data)
        #expect(legacyPalHT.componentCount == 3)
        for c in 0..<3 {
            #expect(legacyPalHT.components[c].data == legacyPal.components[c].data)
        }

        // 2. Synthetic BGR `cdef` permutation (`cn: 0->B(3), 1->G(2), 2->R(1)`)
        let w = 4, h = 4
        let rawBGRDesc = try ImageDescriptor.rgbPlanar(width: w, height: h, storageBits: 8, meaningfulBits: 8)
        let rawBGRDest = try ImageDestination.allocate(descriptor: rawBGRDesc)
        // Store Blue=10 in codestream component 0, Green=90 in component 1, Red=210 in component 2
        let rawBGRImg = try rawBGRDest.writeSamples { c, x, _ in
            switch c {
            case 0: return 10 + x   // Stored in codestream channel 0 (associated with Blue = 3)
            case 1: return 90 + x   // Stored in codestream channel 1 (associated with Green = 2)
            default: return 210 + x // Stored in codestream channel 2 (associated with Red = 1)
            }
        }
        let encCodestream = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(colourTransform: .none, containerFormat: .codestream)
            )
        ).encode(rawBGRImg).data

        let ftyp = makeJP2Box(
            "ftyp",
            payload: try JP2FileTypeBox(brand: "jp2 ", minorVersion: 0, compatibleBrands: ["jp2 "]).serialise()
        )
        let ihdr = makeJP2Box(
            "ihdr",
            payload: try JP2ImageHeaderBox(
                height: UInt32(h),
                width: UInt32(w),
                numComponents: 3,
                uniformBitDepth: try JP2ComponentBitDepth(bitDepth: 8, isSigned: false)
            ).serialise()
        )
        let colr = makeJP2Box(
            "colr",
            payload: try JP2ColourSpecificationBox(
                method: .enumerated(JP2ColourSpecificationBox.EnumeratedColourSpace.sRGB.rawValue)
            ).serialise()
        )
        let cdef = makeJP2Box(
            "cdef",
            payload: try JP2ChannelDefinitionBox(entries: [
                .init(channelIndex: 0, channelType: 0, association: 3), // Blue
                .init(channelIndex: 1, channelType: 0, association: 2), // Green
                .init(channelIndex: 2, channelType: 0, association: 1)  // Red
            ]).serialise()
        )
        let jp2h = makeJP2Box("jp2h", payload: ihdr + colr + cdef)
        let jp2c = makeJP2Box("jp2c", payload: [UInt8](encCodestream))
        let bgrJP2 = Data(JP2SignatureBox.fullBoxBytes + ftyp + jp2h + jp2c)

        let decodedBGRLegacy = try await J2KDecoder().decode(bgrJP2)
        #expect(decodedBGRLegacy.componentCount == 3)
        for x in 0..<w {
            #expect(Int(decodedBGRLegacy.components[0].data[x]) == 210 + x) // Red
            #expect(Int(decodedBGRLegacy.components[1].data[x]) == 90 + x)  // Green
            #expect(Int(decodedBGRLegacy.components[2].data[x]) == 10 + x)  // Blue
        }

        let transcodedBGR = try J2KTranscoder().transcode(bgrJP2, direction: .legacyToHT)
        let decodedBGRHT = try await J2KDecoder().decode(transcodedBGR.data)
        for x in 0..<w {
            #expect(Int(decodedBGRHT.components[0].data[x]) == 210 + x)
            #expect(Int(decodedBGRHT.components[1].data[x]) == 90 + x)
            #expect(Int(decodedBGRHT.components[2].data[x]) == 10 + x)
        }

        // 3. Kakadu Restricted ICC + RGBA `cdef` fixtures
        let iccData = try Data(contentsOf: containerFixtureURL("jp2_rgb8_icc_res_meta.kdu.jp2"))
        let legacyICC = try await J2KDecoder().decode(iccData)
        if case .iccProfile(let prof) = legacyICC.colorSpace {
            #expect(!prof.isEmpty)
        } else {
            Issue.record("Expected J2KDecoder to preserve Restricted ICC profile in J2KImage.colorSpace")
        }
        let contractFromLegacyICC = try legacyICC.toContractImage()
        #expect(contractFromLegacyICC.descriptor.iccProfile != nil)

        let rgbaData = try Data(contentsOf: containerFixtureURL("jp2_rgba8_cdef.kdu.jp2"))
        let legacyRGBA = try await J2KDecoder().decode(rgbaData)
        #expect(legacyRGBA.componentCount == 4)
        #expect(legacyRGBA.alpha == .straight)
        #expect(try legacyRGBA.toContractImage().descriptor.alpha == .straight)
    }

    @Test("F07: Public J2KImage, J2KDecoder, and toContractImage preserve straight, premultiplied, and absent alpha without altering samples")
    func publicLegacyAdaptersPreserveAlphaInterpretationAndSamples() async throws {
        // 1. Premultiplied and straight RGBA (8-bit and 16-bit), including exact [64, 64, 64, 128] probe vector
        for (alphaMode, storageBits) in [
            (AlphaInterpretation.premultiplied, 8),
            (AlphaInterpretation.premultiplied, 16),
            (AlphaInterpretation.straight, 8)
        ] {
            let desc = try ImageDescriptor.rgbPlanar(
                width: 4,
                height: 4,
                storageBits: storageBits,
                meaningfulBits: storageBits,
                alpha: alphaMode
            )
            let dest = try ImageDestination.allocate(descriptor: desc)
            let scale = (storageBits == 16) ? 257 : 1
            let source = try dest.writeSamples { c, x, y in
                if x == 0 && y == 0 {
                    return (c == 3 ? 128 : 64) * scale
                }
                switch c {
                case 0: return (32 + x * 11 + y * 5) * scale
                case 1: return (48 + x * 7 + y * 9) * scale
                case 2: return (20 + x * 13 + y * 3) * scale
                default: return (140 + x * 15 + y * 6) * scale
                }
            }

            // Direct public adapter round-trip: Image -> J2KImage -> Image
            let legacy = try J2KImage(contractImage: source)
            #expect(legacy.alpha == alphaMode)
            let roundTripped = try legacy.toContractImage()
            #expect(roundTripped.descriptor.alpha == alphaMode)
            #expect(roundTripped.descriptor.colour == .rgb)
            #expect(roundTripped.descriptor.components == [.red, .green, .blue, .alpha])
            for y in 0..<4 {
                for x in 0..<4 {
                    for c in 0..<4 {
                        #expect(
                            try roundTripped.sampleInt(component: c, x: x, y: y)
                            == source.sampleInt(component: c, x: x, y: y)
                        )
                    }
                }
            }

            // Container encode -> public J2KDecoder.decode -> J2KImage.toContractImage across JP2, JPH, JPX
            for fmt in [CodecOptions.ContainerFormat.jp2, .jph, .jpx] {
                let blockCoding: CodecOptions.BlockCoding = (fmt == .jph) ? .htj2k : .part1
                let encoded = try await Encoder(
                    configuration: EncoderConfiguration(
                        mode: .lossless,
                        codecOptions: CodecOptions(blockCoding: blockCoding, containerFormat: fmt)
                    )
                ).encode(source).data

                let decodedLegacy = try await J2KDecoder().decode(encoded)
                #expect(decodedLegacy.alpha == alphaMode)
                let decodedContract = try decodedLegacy.toContractImage()
                #expect(decodedContract.descriptor.alpha == alphaMode)
                #expect(decodedContract.descriptor.colour == .rgb)
                #expect(decodedContract.descriptor.components == [.red, .green, .blue, .alpha])
                for c in 0..<4 {
                    #expect(
                        try decodedContract.sampleInt(component: c, x: 0, y: 0)
                        == (c == 3 ? 128 : 64) * scale
                    )
                }

                // Region + downsample decode via J2KDecoder.decodeSync must also preserve AlphaInterpretation
                let windowedLegacy = try J2KDecoder.decodeSync(
                    encoded,
                    resolutionLevel: 1,
                    region: (x: 0, y: 0, width: 4, height: 4)
                )
                #expect(windowedLegacy.alpha == alphaMode)
                #expect(try windowedLegacy.toContractImage().descriptor.alpha == alphaMode)
            }
        }

        // 2. Premultiplied and straight 2-channel Grey-Alpha (with and without Restricted ICC profile)
        let iccFixture = try await Decoder().decode(
            Data(contentsOf: containerFixtureURL("jp2_rgb8_icc_res_meta.kdu.jp2"))
        ).image.descriptor.iccProfile
        let gaPlanes = [
            try PlaneDescriptor(width: 4, height: 4, components: [0], offset: 0, sampleStride: 1, pixelStride: 1, rowBytes: 4, byteCount: 16),
            try PlaneDescriptor(width: 4, height: 4, components: [1], offset: 16, sampleStride: 1, pixelStride: 1, rowBytes: 4, byteCount: 32)
        ]
        for (alphaMode, icc) in [
            (AlphaInterpretation.premultiplied, nil),
            (AlphaInterpretation.premultiplied, iccFixture),
            (AlphaInterpretation.straight, nil)
        ] {
            let gaDesc = try ImageDescriptor(
                width: 4,
                height: 4,
                sampleType: .unsignedInteger,
                storageBits: 8,
                meaningfulBits: 8,
                byteOrder: .littleEndian,
                components: [.grey, .alpha],
                colour: .greyscale,
                alpha: alphaMode,
                planes: gaPlanes,
                iccProfile: icc
            )
            let gaSource = try ImageDestination.allocate(descriptor: gaDesc).writeSamples { c, x, y in
                c == 0 ? (40 + x * 9 + y * 4) : (160 + x * 7 + y * 5)
            }
            let legacyGA = try J2KImage(contractImage: gaSource)
            #expect(legacyGA.alpha == alphaMode)
            let roundTrippedGA = try legacyGA.toContractImage()
            #expect(roundTrippedGA.descriptor.alpha == alphaMode)
            #expect(roundTrippedGA.descriptor.colour == .greyscale)
            #expect(roundTrippedGA.descriptor.components == [.grey, .alpha])
            #expect(roundTrippedGA.descriptor.iccProfile == icc)
            for y in 0..<4 {
                for x in 0..<4 {
                    #expect(try roundTrippedGA.sampleInt(component: 0, x: x, y: y) == 40 + x * 9 + y * 4)
                    #expect(try roundTrippedGA.sampleInt(component: 1, x: x, y: y) == 160 + x * 7 + y * 5)
                }
            }

            let encodedGA = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(containerFormat: .jp2)
                )
            ).encode(gaSource).data
            let decodedLegacyGA = try await J2KDecoder().decode(encodedGA)
            #expect(decodedLegacyGA.alpha == alphaMode)
            let decodedContractGA = try decodedLegacyGA.toContractImage()
            #expect(decodedContractGA.descriptor.alpha == alphaMode)
            #expect(decodedContractGA.descriptor.colour == .greyscale)
            #expect(decodedContractGA.descriptor.components == [.grey, .alpha])
            #expect(decodedContractGA.descriptor.iccProfile == icc)
            #expect(try decodedContractGA.sampleInt(component: 0, x: 2, y: 1) == 40 + 18 + 4)
            #expect(try decodedContractGA.sampleInt(component: 1, x: 2, y: 1) == 160 + 14 + 5)
        }

        // 3. Non-alpha 2-channel and 4-channel images: alpha MUST remain .absent (never inferred from channel count)
        for compCount in [2, 4] {
            let nonAlphaDesc = try ImageDescriptor.multiComponentPlanar(
                width: 4,
                height: 4,
                componentCount: compCount,
                storageBits: 8,
                meaningfulBits: 8
            )
            let nonAlphaSrc = try ImageDestination.allocate(descriptor: nonAlphaDesc).writeSamples { c, x, y in
                (c * 41 + x * 13 + y * 7) & 0xFF
            }
            let legacyNonAlpha = try J2KImage(contractImage: nonAlphaSrc)
            #expect(legacyNonAlpha.alpha == .absent)
            let contractNonAlpha = try legacyNonAlpha.toContractImage()
            #expect(contractNonAlpha.descriptor.alpha == .absent)
            #expect(!contractNonAlpha.descriptor.components.contains(.alpha))
            for c in 0..<compCount {
                #expect(
                    try contractNonAlpha.sampleInt(component: c, x: 3, y: 2)
                    == ((c * 41 + 3 * 13 + 2 * 7) & 0xFF)
                )
            }

            // Encode non-alpha 2-channel / 4-channel image to JP2 (no `cdef`) and verify both Decoder and J2KDecoder keep alpha == .absent
            let encodedNonAlphaJP2 = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jp2)
                )
            ).encode(nonAlphaSrc).data
            let directNonAlpha = try await Decoder().decode(encodedNonAlphaJP2).image
            #expect(directNonAlpha.descriptor.alpha == .absent)
            let decodedLegacyNonAlpha = try await J2KDecoder().decode(encodedNonAlphaJP2)
            #expect(decodedLegacyNonAlpha.alpha == .absent)
            let roundTripNonAlpha = try decodedLegacyNonAlpha.toContractImage()
            #expect(roundTripNonAlpha.descriptor.alpha == .absent)
            #expect(!roundTripNonAlpha.descriptor.components.contains(.alpha))

            // Direct public legacy convenience initialiser without alpha must also keep alpha == .absent
            let manualLegacy = J2KImage(width: 4, height: 4, components: compCount, bitDepth: 8)
            #expect(manualLegacy.alpha == .absent)
            #expect(try manualLegacy.toContractImage().descriptor.alpha == .absent)
        }
    }

    // MARK: F08 — Normative ISO/IEC 15444-2 Table M.14 JPX `rreq` Semantics

    @Test("F08: JP2ReaderRequirementsBox uses normative Table M.14 feature codes, masks, and disjunctive/conjunctive evaluation")
    func jpxReaderRequirementsTableM14CodesMasksAndEvaluation() async throws {
        typealias SF = JP2ReaderRequirementsBox.StandardFeature
        // 1. Exact ISO/IEC 15444-2 (ITU-T T.801) Table M.14 & ISO/IEC 15444-15 Annex A feature codes
        #expect(SF.codestreamContainsNoExtensions.rawValue == 1)
        #expect(SF.multipleCompositionLayers.rawValue == 2)
        #expect(SF.profile0Codestream.rawValue == 3)
        #expect(SF.profile1Codestream.rawValue == 4)
        #expect(SF.unrestrictedJPEG2000Part1.rawValue == 5)
        #expect(SF.unrestrictedJPEG2000Part2.rawValue == 6)
        #expect(SF.dctCodestream.rawValue == 7)
        #expect(SF.noOpacity.rawValue == 8)
        #expect(SF.opacityChannel.rawValue == 9)
        #expect(SF.premultipliedOpacityChannel.rawValue == 10)
        #expect(SF.codestreamContiguous.rawValue == 12)
        #expect(SF.noCompositingRequired.rawValue == 18)
        #expect(SF.compositingLayerSingleCodestream.rawValue == 20)
        #expect(SF.noScalingRequired.rawValue == 31)
        #expect(SF.restrictedICCProfile.rawValue == 43)
        #expect(SF.anyICCProfile.rawValue == 44)
        #expect(SF.sRGBEnumeratedColourSpace.rawValue == 45)
        #expect(SF.greyscaleEnumeratedColourSpace.rawValue == 46)
        #expect(SF.sYCCEnumeratedColourSpace.rawValue == 70)
        #expect(SF.htj2kCodestream.rawValue == 86)

        // 2. Generated `defaultJPX` boxes never set undefined bits in `dcm` or `fuam`
        for (colour, isHT, hasAlpha, isPremul, hasICC) in [
            (ColourInterpretation.rgb, false, false, false, false),
            (ColourInterpretation.greyscale, true, false, false, false),
            (ColourInterpretation.rgb, true, true, false, false),
            (ColourInterpretation.rgb, false, true, true, true)
        ] {
            let box = try JP2ReaderRequirementsBox.defaultJPX(
                isLossless: true,
                isHTJ2K: isHT,
                colour: colour,
                hasAlpha: hasAlpha,
                isPremultipliedAlpha: isPremul,
                hasRestrictedICC: hasICC
            )
            let payload = box.serialise()
            let parsed = try JP2ReaderRequirementsBox.parse(bytes: payload, range: 0..<payload.count)
            #expect(parsed == box)
            let definedBits = parsed.standardFeatures.reduce(UInt64(0)) { $0 | $1.mask }
            #expect((parsed.dcm & ~definedBits) == 0)
            #expect((parsed.fuam & ~definedBits) == 0)
            #expect(parsed.evaluate().canDecodeCompletely)
            #expect(parsed.evaluate().understandsAllAspects)
        }

        // 3. Disjunctive (alternative paths sharing a DCM bit) vs conjunctive feature mask evaluation
        // Under T.801 M.6:
        // - Disjunctive alternative for DCM bit 0b0010: satisfied by EITHER `.sRGBEnumeratedColourSpace` (supported)
        //   OR `.multipleCompositionLayers` (unsupported); DCM bit 0b0001 requires `.codestreamContainsNoExtensions`.
        let disjunctive = try JP2ReaderRequirementsBox(
            maskLength: 1,
            fuam: 0b0111,
            dcm: 0b0011,
            standardFeatures: [
                .init(feature: .codestreamContainsNoExtensions, mask: 0b0001),
                .init(feature: .sRGBEnumeratedColourSpace, mask: 0b0010),
                .init(feature: .multipleCompositionLayers, mask: 0b0110)
            ]
        )
        #expect(disjunctive.evaluate(supportedFeatures: [.codestreamContainsNoExtensions, .sRGBEnumeratedColourSpace]).canDecodeCompletely)
        #expect(!disjunctive.evaluate(supportedFeatures: [.codestreamContainsNoExtensions, .sRGBEnumeratedColourSpace]).understandsAllAspects)
        #expect(!disjunctive.evaluate(supportedFeatures: [.codestreamContainsNoExtensions]).canDecodeCompletely)

        // Conjunctive: DCM 0b0011 requires BOTH `.sRGBEnumeratedColourSpace` AND unsupported `.multipleCompositionLayers` (SF=2)
        let conjunctiveUnsupported = try JP2ReaderRequirementsBox(
            maskLength: 1,
            fuam: 0b0011,
            dcm: 0b0011,
            standardFeatures: [
                .init(feature: .sRGBEnumeratedColourSpace, mask: 0b0001),
                .init(feature: .multipleCompositionLayers, mask: 0b0010)
            ]
        )
        let conjEval = conjunctiveUnsupported.evaluate()
        #expect(!conjEval.canDecodeCompletely)
        #expect(conjEval.unsupportedRequiredFeatures.contains(SF.multipleCompositionLayers.rawValue))

        // Vendor UUID requirement must fail unless explicitly supported
        let vendorUUID = [UInt8](repeating: 0xAB, count: 16)
        let vendorRequired = try JP2ReaderRequirementsBox(
            maskLength: 1,
            fuam: 0b0011,
            dcm: 0b0011,
            standardFeatures: [.init(feature: .sRGBEnumeratedColourSpace, mask: 0b0001)],
            vendorFeatures: [try .init(uuid: vendorUUID, mask: 0b0010)]
        )
        #expect(!vendorRequired.evaluate().canDecodeCompletely)
        #expect(vendorRequired.evaluate(supportedVendorUUIDs: [vendorUUID]).canDecodeCompletely)

        // 4. End-to-end JPX container enforcement: valid Kakadu JPX succeeds; unsupported `rreq` fails with .unsupportedFeature
        let kduJPXPart1 = try Data(contentsOf: containerFixtureURL("jpx_rgb8_part1.kdu.jpx"))
        let kduJPXHT = try Data(contentsOf: containerFixtureURL("jpx_rgb8_htj2k.kdu.jpx"))
        #expect(try Decoder().inspect(kduJPXPart1).format == "jpx")
        #expect(try Decoder().inspect(kduJPXHT).format == "jpx")

        // Build a JPX container whose `rreq` requires `multipleCompositionLayers` (SF=2)
        let desc = try ImageDescriptor.greyscale16(width: 4, height: 4, meaningfulBits: 8)
        let dest = try ImageDestination.allocate(descriptor: desc)
        let img = try dest.writeUInt16 { x, y in UInt16(x + y) }
        let validJPX = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(containerFormat: .jpx)
            )
        ).encode(img).data
        // Replace the `rreq` box in `validJPX` with `conjunctiveUnsupported`
        let badRreqBox = makeJP2Box("rreq", payload: conjunctiveUnsupported.serialise())
        let srcBytes = [UInt8](validJPX)
        var reader = try JP2BoxReader(bytes: srcBytes, limits: .default)
        var rebuiltJPX: [UInt8] = []
        while let box = try reader.nextBox() {
            if box.type == .readerRequirements {
                rebuiltJPX.append(contentsOf: badRreqBox)
            } else {
                let start = box.payloadRange.lowerBound - box.headerSize
                rebuiltJPX.append(contentsOf: srcBytes[start..<box.payloadRange.upperBound])
            }
        }
        let unsupportedJPX = Data(rebuiltJPX)

        do {
            _ = try Decoder().inspect(unsupportedJPX)
            Issue.record("Expected Decoder.inspect to reject JPX with unsupported required rreq feature")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }
        do {
            _ = try await Decoder().decode(unsupportedJPX)
            Issue.record("Expected Decoder.decode to reject JPX with unsupported required rreq feature")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }
        await #expect(throws: J2KError.self) {
            _ = try await J2KDecoder().decode(unsupportedJPX)
        }
    }

    @Test("F08: Normative T.801 M.6.2 rejects undefined DCM bits and unverified shifted-DCM masks while preserving verified Kakadu v8.x JPX fixtures")
    func normativeRreqRejectsUndefinedDecodeMaskBits() async throws {
        func replaceRreqBox(in containerData: Data, with payload: [UInt8]) throws -> Data {
            let srcBytes = [UInt8](containerData)
            var reader = try JP2BoxReader(bytes: srcBytes, limits: .default)
            var rebuilt: [UInt8] = []
            while let box = try reader.nextBox() {
                if box.type == .readerRequirements {
                    rebuilt.append(contentsOf: makeJP2Box("rreq", payload: payload))
                } else {
                    let start = box.payloadRange.lowerBound - box.headerSize
                    rebuilt.append(contentsOf: srcBytes[start..<box.payloadRange.upperBound])
                }
            }
            return Data(rebuilt)
        }

        // 1. Exact normative T.801 M.6.2 probe: ML=1, FUAM=0x80, DCM=0x40, [(SF=45, SM=0x80)]
        // Bit 0x40 in DCM is not defined by any SM^i or VM^j and MUST remain unsatisfied.
        let undefinedDecodeBit = try JP2ReaderRequirementsBox(
            maskLength: 1,
            fuam: 0x80,
            dcm: 0x40,
            standardFeatures: [
                .init(feature: .sRGBEnumeratedColourSpace, mask: 0x80)
            ]
        )
        let eval = undefinedDecodeBit.evaluate()
        #expect(eval.satisfiedMask == 0x80)
        #expect(!eval.canDecodeCompletely)
        #expect(eval.unsatisfiedDecodeMask == 0x40)
        #expect(eval.understandsAllAspects)
        #expect(eval.unsatisfiedUnderstandMask == 0x00)

        let kduJPXPart1 = try Data(contentsOf: containerFixtureURL("jpx_rgb8_part1.kdu.jpx"))
        let kduJPXHT = try Data(contentsOf: containerFixtureURL("jpx_rgb8_htj2k.kdu.jpx"))

        // Splicing `undefinedDecodeBit` into `jpx_rgb8_part1.kdu.jpx` (which carries `"Kakadu-v8.4.1"` COM)
        // MUST still be rejected with `.unsupportedFeature`.
        let kduWithUndefinedDCM = try replaceRreqBox(in: kduJPXPart1, with: undefinedDecodeBit.serialise())
        do {
            _ = try Decoder().inspect(kduWithUndefinedDCM)
            Issue.record("Expected Decoder.inspect to reject undefined DCM requirement bit")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }
        do {
            _ = try await Decoder().decode(kduWithUndefinedDCM)
            Issue.record("Expected Decoder.decode to reject undefined DCM requirement bit")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }
        do {
            _ = try await Transcoder().transcode(kduWithUndefinedDCM, to: .htj2k)
            Issue.record("Expected Transcoder.transcode to reject undefined DCM requirement bit")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }
        await #expect(throws: J2KError.self) {
            _ = try await J2KDecoder().decode(kduWithUndefinedDCM)
        }

        // 2. Direct `JP2ReaderRequirementsBox.evaluate()` on Kakadu's raw `rreq` has ZERO heuristics
        // (truthfully reports `!canDecodeCompletely` and `unsatisfiedDecodeMask == 0x00FF`), while
        // `Decoder().inspect` and `Decoder().decode` succeed on unmodified Kakadu JPX fixtures via
        // provenance + full 7-category container reconciliation.
        let parsedKduPart1 = try JP2Container.parse([UInt8](kduJPXPart1), limits: .default, metadataPolicy: .preserve)
        let rawKduRreq = try #require(parsedKduPart1.readerRequirements)
        let rawKduEval = rawKduRreq.evaluate()
        #expect(!rawKduEval.canDecodeCompletely)
        #expect(rawKduEval.understandsAllAspects)
        #expect(rawKduEval.satisfiedMask == 0xFF00)
        #expect(rawKduEval.unsatisfiedDecodeMask == 0x00FF)

        let decodedKduPart1 = try await Decoder().decode(kduJPXPart1)
        #expect(decodedKduPart1.image.descriptor.colour == .rgb)
        let decodedKduHT = try await Decoder().decode(kduJPXHT)
        #expect(decodedKduHT.image.descriptor.colour == .rgb)

        // 3. A non-Kakadu JPX container carrying Kakadu's exact 8-feature shifted `FUAM=0xFF00, DCM=0x00FF`
        // `rreq` MUST be rejected (mask shape and feature list alone without Kakadu v8.x provenance fail).
        let rgbDesc = try ImageDescriptor.rgbPlanar(width: 4, height: 4, storageBits: 8, meaningfulBits: 8)
        let rgbImg = try ImageDestination.allocate(descriptor: rgbDesc).writeSamples { c, x, y in c * 40 + x + y }
        let nonKakaduJPX = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(containerFormat: .jpx)
            )
        ).encode(rgbImg).data
        let nonKakaduWithShiftedDCM = try replaceRreqBox(in: nonKakaduJPX, with: rawKduRreq.serialise())
        do {
            _ = try Decoder().inspect(nonKakaduWithShiftedDCM)
            Issue.record("Expected non-Kakadu JPX with shifted undefined DCM bits to be rejected")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }

        // 4. Kakadu JPX with an extra undefined bit in DCM (`ML=4, FUAM=0xFF00_0000, DCM=0x00FF_0001`)
        // or mismatched opacity feature (`SF=9` opacity without `cdef`) MUST be rejected.
        let extraUndefinedBit = try JP2ReaderRequirementsBox(
            maskLength: 4,
            fuam: 0xFF00_0000,
            dcm: 0x00FF_0001,
            standardFeatures: rawKduRreq.standardFeatures.map {
                .init(code: $0.code, mask: $0.mask << 16)
            }
        )
        let kduWithExtraDCMBit = try replaceRreqBox(in: kduJPXPart1, with: extraUndefinedBit.serialise())
        do {
            _ = try Decoder().inspect(kduWithExtraDCMBit)
            Issue.record("Expected Kakadu JPX with extra undefined DCM bit 0x1 to be rejected")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }

        let mismatchedOpacityFeatures = rawKduRreq.standardFeatures.map { entry -> JP2ReaderRequirementsBox.StandardFeatureEntry in
            if entry.knownFeature == .noOpacity {
                return .init(feature: .opacityChannel, mask: entry.mask)
            }
            return entry
        }
        let mismatchedOpacityRreq = try JP2ReaderRequirementsBox(
            maskLength: rawKduRreq.maskLength,
            fuam: rawKduRreq.fuam,
            dcm: rawKduRreq.dcm,
            standardFeatures: mismatchedOpacityFeatures
        )
        let kduWithMismatchedOpacity = try replaceRreqBox(in: kduJPXPart1, with: mismatchedOpacityRreq.serialise())
        do {
            _ = try Decoder().inspect(kduWithMismatchedOpacity)
            Issue.record("Expected Kakadu JPX whose rreq declares opacityChannel without cdef to be rejected")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFeature)
        }
    }

    // MARK: F12 — Deterministic Rejection of Duplicate `jp2c` Boxes

    @Test("F12: Duplicate jp2c boxes are deterministically rejected in JP2/JPH (.malformedInput) and JPX (.unsupportedFeature)")
    func duplicateContiguousCodestreamBoxesRejected() async throws {
        let desc = try ImageDescriptor.greyscale16(width: 4, height: 4, meaningfulBits: 8)
        let destA = try ImageDestination.allocate(descriptor: desc)
        let imgA = try destA.writeUInt16 { _, _ in 17 }
        let destB = try ImageDestination.allocate(descriptor: desc)
        let imgB = try destB.writeUInt16 { _, _ in 240 }

        for (fmt, expectedCategory) in [
            (CodecOptions.ContainerFormat.jp2, CodecError.Category.malformedInput),
            (CodecOptions.ContainerFormat.jph, CodecError.Category.malformedInput),
            (CodecOptions.ContainerFormat.jpx, CodecError.Category.unsupportedFeature)
        ] {
            let blockCoding: CodecOptions.BlockCoding = (fmt == .jph) ? .htj2k : .part1
            let encA = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(blockCoding: blockCoding, containerFormat: fmt)
                )
            ).encode(imgA).data
            let csB = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(blockCoding: blockCoding, containerFormat: .codestream)
                )
            ).encode(imgB).data

            var dup = [UInt8](encA)
            dup.append(contentsOf: makeJP2Box("jp2c", payload: [UInt8](csB)))
            let dupData = Data(dup)

            do {
                _ = try Decoder().inspect(dupData)
                Issue.record("Expected Decoder.inspect to reject duplicate jp2c in \(fmt)")
            } catch let err as CodecError {
                #expect(err.category == expectedCategory)
            }
            do {
                _ = try await Decoder().decode(dupData)
                Issue.record("Expected Decoder.decode to reject duplicate jp2c in \(fmt)")
            } catch let err as CodecError {
                #expect(err.category == expectedCategory)
            }
            do {
                let target: TranscodeTarget = (fmt == .jph) ? .jpeg2000 : .htj2k
                _ = try await Transcoder().transcode(dupData, to: target)
                Issue.record("Expected Transcoder.transcode to reject duplicate jp2c in \(fmt)")
            } catch let err as CodecError {
                #expect(err.category == expectedCategory)
            }
            await #expect(throws: J2KError.self) {
                _ = try await J2KDecoder().decode(dupData)
            }
            #expect(throws: J2KError.self) {
                let dir: TranscodingDirection = (fmt == .jph) ? .htToLegacy : .legacyToHT
                _ = try J2KTranscoder().transcode(dupData, direction: dir)
            }
        }
    }

    // MARK: M12-CX-03 — Normative W3C PNG `sBIT` Representation & Byte-Layout Verification

    @Test("M12-CX-03: PNG sBIT preserves significant samples normatively on read/write and rejects invalid/unequal sBIT or unscaled clipping")
    func normativePNGSbitReadWriteAndValidation() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Independent 12-in-16-bit greyscale PNGs:
        //    (a) pure high-order shifted `[0x0000, 0x4000, 0x8000, 0xFFF0]`
        //    (b) W3C left-bit-replicated `[0x0000, 0x4004, 0x8008, 0xFFFF]`
        //    Both must decode to exact 12-bit samples `[0, 1024, 2048, 4095]`!
        for (name, words) in [
            ("high_shifted", [UInt16(0x0000), 0x4000, 0x8000, 0xFFF0]),
            ("left_replicated", [UInt16(0x0000), 0x4004, 0x8008, 0xFFFF])
        ] {
            let pngURL = tmpDir.appendingPathComponent("\(name).png")
            let nrrdURL = tmpDir.appendingPathComponent("\(name).nrrd")
            let pngData = try buildIndependentPNG(
                width: 4,
                height: 1,
                bitDepth: 16,
                colorType: 0,
                sbitBeforeIDAT: [12],
                samplesBigEndian: words
            )
            try pngData.write(to: pngURL)

            let res = try runR2CLI(["convert", "-i", pngURL.path, "-o", nrrdURL.path])
            #expect(res.status == 0, "CLI stderr: \(res.stderrText)")
            let parsed = try parseNRRDSamples(Data(contentsOf: nrrdURL))
            #expect(parsed.meaningfulBits == 12)
            #expect(parsed.samples == [0, 1024, 2048, 4095])
        }

        // 2. Independent 10-in-16-bit RGB PNG (`sBIT = [10, 10, 10]`)
        let rgb10PNG = tmpDir.appendingPathComponent("rgb10.png")
        let rgb10NRRD = tmpDir.appendingPathComponent("rgb10.nrrd")
        // 2 pixels x 3 channels: (0, 256, 512), (513, 768, 1023) left-bit-replicated to 16 bits
        func rep10To16(_ v: UInt16) -> UInt16 { (v << 6) | (v >> 4) }
        try buildIndependentPNG(
            width: 2,
            height: 1,
            bitDepth: 16,
            colorType: 2,
            sbitBeforeIDAT: [10, 10, 10],
            samplesBigEndian: [0, 256, 512, 513, 768, 1023].map(rep10To16)
        ).write(to: rgb10PNG)
        let rgb10Res = try runR2CLI(["convert", "-i", rgb10PNG.path, "-o", rgb10NRRD.path])
        #expect(rgb10Res.status == 0, "CLI stderr: \(rgb10Res.stderrText)")
        let rgb10Parsed = try parseNRRDSamples(Data(contentsOf: rgb10NRRD))
        #expect(rgb10Parsed.meaningfulBits == 10)
        #expect(rgb10Parsed.samples == [0, 256, 512, 513, 768, 1023])

        // 3. Independent 5-in-8-bit greyscale PNG (`sBIT = [5]`)
        let g5PNG = tmpDir.appendingPathComponent("g5.png")
        let g5NRRD = tmpDir.appendingPathComponent("g5.nrrd")
        try buildIndependentPNG(
            width: 3,
            height: 1,
            bitDepth: 8,
            colorType: 0,
            sbitBeforeIDAT: [5],
            samplesBigEndian: [0x00, 0x84, 0xFF] // 0, 16 ((16<<3)|(16>>2)=132=0x84), 31 (0xFF)
        ).write(to: g5PNG)
        let g5Res = try runR2CLI(["convert", "-i", g5PNG.path, "-o", g5NRRD.path])
        #expect(g5Res.status == 0, "CLI stderr: \(g5Res.stderrText)")
        let g5Parsed = try parseNRRDSamples(Data(contentsOf: g5NRRD))
        #expect(g5Parsed.meaningfulBits == 5)
        #expect(g5Parsed.samples == [0, 16, 31])

        // 4. Raw PNG byte-layout check on write: 12-bit PGM `[0, 1024, 2048, 4095]` -> PNG
        //    Verify IHDR bitDepth == 16, sBIT == [12], AND unfiltered IDAT words == `[0x0000, 0x4004, 0x8008, 0xFFFF]`!
        let src12PGM = tmpDir.appendingPathComponent("src12.pgm")
        let out12PNG = tmpDir.appendingPathComponent("out12.png")
        var pgmBytes = Array("P5\n4 1\n4095\n".utf8)
        for v: UInt16 in [0, 1024, 2048, 4095] {
            pgmBytes.append(UInt8((v >> 8) & 0xFF))
            pgmBytes.append(UInt8(v & 0xFF))
        }
        try Data(pgmBytes).write(to: src12PGM)
        let writeRes = try runR2CLI(["convert", "-i", src12PGM.path, "-o", out12PNG.path])
        #expect(writeRes.status == 0, "CLI stderr: \(writeRes.stderrText)")
        let rawPNGInfo = try inspectRawPNG16Greyscale(Data(contentsOf: out12PNG))
        #expect(rawPNGInfo.bitDepth == 16)
        #expect(rawPNGInfo.sbit == [12])
        #expect(rawPNGInfo.rawWords == [0x0000, 0x4004, 0x8008, 0xFFFF])

        // 5. Negative PNG `sBIT` & precision checks
        let dummyOut = tmpDir.appendingPathComponent("rejected.nrrd")

        // 5a. Unequal per-channel `sBIT` (`[5, 6, 5]` on RGB) -> exit 4 (.unsupportedFeature)
        let unequalRGB = tmpDir.appendingPathComponent("unequal_sbit.png")
        try buildIndependentPNG(
            width: 1, height: 1, bitDepth: 8, colorType: 2,
            sbitBeforeIDAT: [5, 6, 5], samplesBigEndian: [0xFF, 0xFF, 0xFF]
        ).write(to: unequalRGB)
        #expect(try runR2CLI(["convert", "-i", unequalRGB.path, "-o", dummyOut.path]).status == 4)

        // 5b. Out-of-range `sBIT` (`0` and `17`), wrong byte length, duplicate `sBIT`, post-`IDAT` `sBIT` -> exit 3 (.malformedInput)
        for (idx, badPNG) in [
            try buildIndependentPNG(width: 1, height: 1, bitDepth: 16, colorType: 0, sbitBeforeIDAT: [0], samplesBigEndian: [0]),
            try buildIndependentPNG(width: 1, height: 1, bitDepth: 16, colorType: 0, sbitBeforeIDAT: [17], samplesBigEndian: [0]),
            try buildIndependentPNG(width: 1, height: 1, bitDepth: 16, colorType: 0, sbitBeforeIDAT: [12, 12], samplesBigEndian: [0]),
            try buildIndependentPNG(width: 1, height: 1, bitDepth: 16, colorType: 0, sbitBeforeIDAT: [12], extraSbitBeforeIDAT: [12], samplesBigEndian: [0]),
            try buildIndependentPNG(width: 1, height: 1, bitDepth: 16, colorType: 0, sbitAfterIDAT: [12], samplesBigEndian: [0])
        ].enumerated() {
            let badURL = tmpDir.appendingPathComponent("bad_sbit_\(idx).png")
            try badPNG.write(to: badURL)
            #expect(try runR2CLI(["convert", "-i", badURL.path, "-o", dummyOut.path]).status == 3)
        }

        // 5c. Conflicting `--precision 10` vs `sBIT = 12`, and unscaled 16-bit PNG (`60000`) with `--precision 12` (no silent clipping!) -> exit 2 (.invalidArgument)
        let j2kDummy = tmpDir.appendingPathComponent("rejected.j2k")
        #expect(try runR2CLI(["encode", "-i", out12PNG.path, "--precision", "10", "-o", j2kDummy.path]).status == 2)

        let unscaled16 = tmpDir.appendingPathComponent("unscaled16.png")
        try buildIndependentPNG(
            width: 2, height: 1, bitDepth: 16, colorType: 0,
            sbitBeforeIDAT: nil, samplesBigEndian: [100, 60000]
        ).write(to: unscaled16)
        #expect(try runR2CLI(["encode", "-i", unscaled16.path, "--precision", "12", "-o", j2kDummy.path]).status == 2)
    }

    // MARK: M12-CX-04 — Deliberate TIFF `PhotometricInterpretation` (Tag 262)

    @Test("M12-CX-04: TIFF PhotometricInterpretation handles WhiteIsZero and Palette Color (single- and multi-strip) and rejects YCbCr/CMYK/invalid tags")
    func tiffPhotometricInterpretationSemanticsAndRejection() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-tiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. 8-bit `WhiteIsZero` (tag 262 = 0) across single-strip AND multi-strip TIFFs:
        //    Raw stored `[0, 64, 200, 255]` must invert to `[255, 191, 55, 0]`.
        for (name, strips, rowsPerStrip) in [
            ("wiz8_single", [[UInt8(0), 64, 200, 255]], UInt32(2)),
            ("wiz8_multi", [[UInt8(0), 64], [UInt8(200), 255]], UInt32(1))
        ] {
            let tiffURL = tmpDir.appendingPathComponent("\(name).tiff")
            let nrrdURL = tmpDir.appendingPathComponent("\(name).nrrd")
            let tiffData = buildIndependentTIFF(
                tags: [
                    RawTIFFTag(tag: 256, type: 4, values: [2]),
                    RawTIFFTag(tag: 257, type: 4, values: [2]),
                    RawTIFFTag(tag: 258, type: 3, values: [8]),
                    RawTIFFTag(tag: 259, type: 3, values: [1]),
                    RawTIFFTag(tag: 262, type: 3, values: [0]), // WhiteIsZero
                    RawTIFFTag(tag: 277, type: 3, values: [1]),
                    RawTIFFTag(tag: 278, type: 4, values: [rowsPerStrip])
                ],
                strips: strips
            )
            try tiffData.write(to: tiffURL)
            let res = try runR2CLI(["convert", "-i", tiffURL.path, "-o", nrrdURL.path])
            #expect(res.status == 0, "CLI stderr: \(res.stderrText)")
            let parsed = try parseNRRDSamples(Data(contentsOf: nrrdURL))
            #expect(parsed.meaningfulBits == 8)
            #expect(parsed.samples == [255, 191, 55, 0])
        }

        // 2. 12-in-16-bit `WhiteIsZero` (tag 262 = 0, SMaxSampleValue tag 341 = 4095)
        let wiz12URL = tmpDir.appendingPathComponent("wiz12.tiff")
        let wiz12NRRD = tmpDir.appendingPathComponent("wiz12.nrrd")
        let raw12LE: [UInt8] = [
            0x00, 0x00, // 0 -> 4095
            0x00, 0x04, // 1024 -> 3071
            0xFF, 0x0F  // 4095 -> 0
        ]
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [3]),
                RawTIFFTag(tag: 257, type: 4, values: [1]),
                RawTIFFTag(tag: 258, type: 3, values: [16]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 262, type: 3, values: [0]),
                RawTIFFTag(tag: 277, type: 3, values: [1]),
                RawTIFFTag(tag: 278, type: 4, values: [1]),
                RawTIFFTag(tag: 341, type: 3, values: [4095])
            ],
            strips: [raw12LE]
        ).write(to: wiz12URL)
        #expect(try runR2CLI(["convert", "-i", wiz12URL.path, "-o", wiz12NRRD.path]).status == 0)
        let wiz12Parsed = try parseNRRDSamples(Data(contentsOf: wiz12NRRD))
        #expect(wiz12Parsed.meaningfulBits == 12)
        #expect(wiz12Parsed.samples == [4095, 3071, 0])

        // 3. 2-channel `WhiteIsZero` + `ExtraSamples = 2` (alpha uninverted!)
        let wizAlphaURL = tmpDir.appendingPathComponent("wiz_alpha.tiff")
        let wizAlphaNRRD = tmpDir.appendingPathComponent("wiz_alpha.nrrd")
        // Pixel 0: grey=0 (->255), alpha=12; Pixel 1: grey=200 (->55), alpha=250
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [2]),
                RawTIFFTag(tag: 257, type: 4, values: [1]),
                RawTIFFTag(tag: 258, type: 3, values: [8, 8]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 262, type: 3, values: [0]),
                RawTIFFTag(tag: 277, type: 3, values: [2]),
                RawTIFFTag(tag: 278, type: 4, values: [1]),
                RawTIFFTag(tag: 338, type: 3, values: [2])
            ],
            strips: [[0, 12, 200, 250]]
        ).write(to: wizAlphaURL)
        #expect(try runR2CLI(["convert", "-i", wizAlphaURL.path, "-o", wizAlphaNRRD.path]).status == 0)
        let wizAlphaParsed = try parseNRRDSamples(Data(contentsOf: wizAlphaNRRD))
        #expect(wizAlphaParsed.components == 2)
        #expect(wizAlphaParsed.samples == [255, 12, 55, 250])

        // 4. `Palette Color` (tag 262 = 3, tag 320 `ColorMap`) across single-strip & multi-strip (8-bit replicated LUT)
        var rMap = [UInt32](repeating: 0, count: 256)
        var gMap = [UInt32](repeating: 0, count: 256)
        var bMap = [UInt32](repeating: 0, count: 256)
        // Index 0 -> (255, 0, 16), Index 1 -> (0, 128, 255), Index 2 -> (40, 200, 80), Index 3 -> (9, 9, 9)
        let entries8: [(UInt32, UInt32, UInt32)] = [(255, 0, 16), (0, 128, 255), (40, 200, 80), (9, 9, 9)]
        for (i, e) in entries8.enumerated() {
            rMap[i] = e.0 * 257
            gMap[i] = e.1 * 257
            bMap[i] = e.2 * 257
        }
        for (name, strips, rps) in [
            ("pal8_single", [[UInt8(0), 1, 2, 3]], UInt32(2)),
            ("pal8_multi", [[UInt8(0), 1], [UInt8(2), 3]], UInt32(1))
        ] {
            let palURL = tmpDir.appendingPathComponent("\(name).tiff")
            let palNRRD = tmpDir.appendingPathComponent("\(name).nrrd")
            try buildIndependentTIFF(
                tags: [
                    RawTIFFTag(tag: 256, type: 4, values: [2]),
                    RawTIFFTag(tag: 257, type: 4, values: [2]),
                    RawTIFFTag(tag: 258, type: 3, values: [8]),
                    RawTIFFTag(tag: 259, type: 3, values: [1]),
                    RawTIFFTag(tag: 262, type: 3, values: [3]),
                    RawTIFFTag(tag: 277, type: 3, values: [1]),
                    RawTIFFTag(tag: 278, type: 4, values: [rps]),
                    RawTIFFTag(tag: 320, type: 3, values: rMap + gMap + bMap)
                ],
                strips: strips
            ).write(to: palURL)
            let res = try runR2CLI(["convert", "-i", palURL.path, "-o", palNRRD.path])
            #expect(res.status == 0, "CLI stderr: \(res.stderrText)")
            let parsed = try parseNRRDSamples(Data(contentsOf: palNRRD))
            #expect(parsed.components == 3)
            #expect(parsed.meaningfulBits == 8)
            #expect(parsed.samples == [255, 0, 16, 0, 128, 255, 40, 200, 80, 9, 9, 9])
        }

        // 5. `Palette Color` with true 16-bit `ColorMap` entries preserves full 16-bit RGB precision
        var r16 = [UInt32](repeating: 0, count: 256)
        var g16 = [UInt32](repeating: 0, count: 256)
        var b16 = [UInt32](repeating: 0, count: 256)
        r16[0] = 0x1234; g16[0] = 0x5678; b16[0] = 0x9ABC
        r16[1] = 0xFEDC; g16[1] = 0x0102; b16[1] = 0x8001
        let pal16URL = tmpDir.appendingPathComponent("pal16lut.tiff")
        let pal16NRRD = tmpDir.appendingPathComponent("pal16lut.nrrd")
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [2]),
                RawTIFFTag(tag: 257, type: 4, values: [1]),
                RawTIFFTag(tag: 258, type: 3, values: [8]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 262, type: 3, values: [3]),
                RawTIFFTag(tag: 277, type: 3, values: [1]),
                RawTIFFTag(tag: 278, type: 4, values: [1]),
                RawTIFFTag(tag: 320, type: 3, values: r16 + g16 + b16)
            ],
            strips: [[0, 1]]
        ).write(to: pal16URL)
        #expect(try runR2CLI(["convert", "-i", pal16URL.path, "-o", pal16NRRD.path]).status == 0)
        let pal16Parsed = try parseNRRDSamples(Data(contentsOf: pal16NRRD))
        #expect(pal16Parsed.components == 3)
        #expect(pal16Parsed.meaningfulBits == 16)
        #expect(pal16Parsed.samples == [0x1234, 0x5678, 0x9ABC, 0xFEDC, 0x0102, 0x8001])

        // 6. 4-bit packed `Palette Color` (`BitsPerSample = 4`, row-padded nibbles)
        var r4 = [UInt32](repeating: 0, count: 16)
        var g4 = [UInt32](repeating: 0, count: 16)
        var b4 = [UInt32](repeating: 0, count: 16)
        r4[1] = 10 * 257; g4[1] = 20 * 257; b4[1] = 30 * 257
        r4[2] = 40 * 257; g4[2] = 50 * 257; b4[2] = 60 * 257
        r4[15] = 200 * 257; g4[15] = 210 * 257; b4[15] = 220 * 257
        let pal4URL = tmpDir.appendingPathComponent("pal4.tiff")
        let pal4NRRD = tmpDir.appendingPathComponent("pal4.nrrd")
        // 3 pixels wide, 1 row: indices [1, 15, 2] packed as [0x1F, 0x20]
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [3]),
                RawTIFFTag(tag: 257, type: 4, values: [1]),
                RawTIFFTag(tag: 258, type: 3, values: [4]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 262, type: 3, values: [3]),
                RawTIFFTag(tag: 277, type: 3, values: [1]),
                RawTIFFTag(tag: 278, type: 4, values: [1]),
                RawTIFFTag(tag: 320, type: 3, values: r4 + g4 + b4)
            ],
            strips: [[0x1F, 0x20]]
        ).write(to: pal4URL)
        #expect(try runR2CLI(["convert", "-i", pal4URL.path, "-o", pal4NRRD.path]).status == 0)
        let pal4Parsed = try parseNRRDSamples(Data(contentsOf: pal4NRRD))
        #expect(pal4Parsed.samples == [10, 20, 30, 200, 210, 220, 40, 50, 60])

        // 7. Negative TIFF PhotometricInterpretation tests
        let rejectedOut = tmpDir.appendingPathComponent("rejected_tiff.nrrd")

        // Unsupported PhotometricInterpretation codes: 4 (Mask), 5 (CMYK), 6 (YCbCr), 8 (CIE Lab) -> exit 4
        for unsupportedPhoto: UInt32 in [4, 5, 6, 8] {
            let badURL = tmpDir.appendingPathComponent("photo_\(unsupportedPhoto).tiff")
            try buildIndependentTIFF(
                tags: [
                    RawTIFFTag(tag: 256, type: 4, values: [2]),
                    RawTIFFTag(tag: 257, type: 4, values: [2]),
                    RawTIFFTag(tag: 258, type: 3, values: [8, 8, 8]),
                    RawTIFFTag(tag: 259, type: 3, values: [1]),
                    RawTIFFTag(tag: 262, type: 3, values: [unsupportedPhoto]),
                    RawTIFFTag(tag: 277, type: 3, values: [3]),
                    RawTIFFTag(tag: 278, type: 4, values: [2])
                ],
                strips: [[UInt8](repeating: 128, count: 12)]
            ).write(to: badURL)
            #expect(try runR2CLI(["convert", "-i", badURL.path, "-o", rejectedOut.path]).status == 4)
        }

        // Malformed PhotometricInterpretation combinations -> exit 3:
        // (a) Missing tag 262
        let missing262URL = tmpDir.appendingPathComponent("missing_262.tiff")
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [2]),
                RawTIFFTag(tag: 257, type: 4, values: [2]),
                RawTIFFTag(tag: 258, type: 3, values: [8]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 277, type: 3, values: [1]),
                RawTIFFTag(tag: 278, type: 4, values: [2])
            ],
            strips: [[0, 1, 2, 3]]
        ).write(to: missing262URL)
        #expect(try runR2CLI(["convert", "-i", missing262URL.path, "-o", rejectedOut.path]).status == 3)

        // (b) Palette Color (262 = 3) missing ColorMap (320)
        let palNoMapURL = tmpDir.appendingPathComponent("pal_no_cmap.tiff")
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [2]),
                RawTIFFTag(tag: 257, type: 4, values: [2]),
                RawTIFFTag(tag: 258, type: 3, values: [8]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 262, type: 3, values: [3]),
                RawTIFFTag(tag: 277, type: 3, values: [1]),
                RawTIFFTag(tag: 278, type: 4, values: [2])
            ],
            strips: [[0, 1, 2, 3]]
        ).write(to: palNoMapURL)
        #expect(try runR2CLI(["convert", "-i", palNoMapURL.path, "-o", rejectedOut.path]).status == 3)

        // (c) WhiteIsZero (262 = 0) with SamplesPerPixel = 3
        let wiz3URL = tmpDir.appendingPathComponent("wiz_spp3.tiff")
        try buildIndependentTIFF(
            tags: [
                RawTIFFTag(tag: 256, type: 4, values: [2]),
                RawTIFFTag(tag: 257, type: 4, values: [2]),
                RawTIFFTag(tag: 258, type: 3, values: [8, 8, 8]),
                RawTIFFTag(tag: 259, type: 3, values: [1]),
                RawTIFFTag(tag: 262, type: 3, values: [0]),
                RawTIFFTag(tag: 277, type: 3, values: [3]),
                RawTIFFTag(tag: 278, type: 4, values: [2])
            ],
            strips: [[UInt8](repeating: 0, count: 12)]
        ).write(to: wiz3URL)
        #expect(try runR2CLI(["convert", "-i", wiz3URL.path, "-o", rejectedOut.path]).status == 3)
    }

    // MARK: F09, F10, F11 — CLI End-to-End Policy, View-Window & 3D NRRD Geometry Checks

    @Test("F09, F10 & F11 CLI: 3D NRRD geometry round-trip (including negative --origin), --copy-policy require-sharing rejection, and JPIP --components validation")
    func cliVolumeGeometryCopyPolicyAndJPIPValidation() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-cli-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. 3D NRRD with anisotropic spacing and negative physical origin -> encode3d -> decode3d
        let nrrdIn = tmpDir.appendingPathComponent("vol_in.nrrd")
        let j3dOut = tmpDir.appendingPathComponent("vol.j3d")
        let nrrdOut = tmpDir.appendingPathComponent("vol_out.nrrd")
        let nrrdDisc = tmpDir.appendingPathComponent("vol_disc.nrrd")
        let voxels = Data((0..<(8 * 8 * 2)).map { UInt8($0 & 0xFF) })
        let nrrdHeader = [
            "NRRD0004",
            "type: uint8",
            "dimension: 3",
            "sizes: 8 8 2",
            "space dimension: 3",
            "space directions: (0.7,0,0) (0,0.7,0) (0,0,1.5)",
            "space origin: (-120.5,14.25,-30)",
            "encoding: raw",
            "",
            ""
        ].joined(separator: "\n")
        try (Data(nrrdHeader.utf8) + voxels).write(to: nrrdIn)

        // F09: `--copy-policy require-sharing` on encode3d must exit 4
        #expect(
            try runR2CLI([
                "encode3d", "-i", nrrdIn.path, "-o", j3dOut.path,
                "--levels", "1,1,1", "--copy-policy", "require-sharing"
            ]).status == 4
        )

        // F11: Default encode3d + decode3d preserves spacing & negative origin in output NRRD
        let encRes = try runR2CLI([
            "encode3d", "-i", nrrdIn.path, "-o", j3dOut.path, "--levels", "1,1,1"
        ])
        #expect(encRes.status == 0, "encode3d stderr: \(encRes.stderrText)")

        // F09: `--copy-policy require-sharing` on decode3d must exit 4
        #expect(
            try runR2CLI([
                "decode3d", "-i", j3dOut.path, "-o", nrrdOut.path,
                "--copy-policy", "require-sharing"
            ]).status == 4
        )

        let decRes = try runR2CLI(["decode3d", "-i", j3dOut.path, "-o", nrrdOut.path])
        #expect(decRes.status == 0, "decode3d stderr: \(decRes.stderrText)")
        let parsedVol = try parseNRRDVolume(Data(contentsOf: nrrdOut), limits: .default)
        #expect(parsedVol.spacingX == 0.7 && parsedVol.spacingY == 0.7 && parsedVol.spacingZ == 1.5)
        #expect(parsedVol.originX == -120.5 && parsedVol.originY == 14.25 && parsedVol.originZ == -30.0)

        // F11: Negative `--origin` flag directly on CLI command line overrides geometry cleanly
        let j3dCLIOrigin = tmpDir.appendingPathComponent("vol_cli_origin.j3d")
        let nrrdCLIOrigin = tmpDir.appendingPathComponent("vol_cli_origin.nrrd")
        let cliOriginRes = try runR2CLI([
            "encode3d", "-i", nrrdIn.path, "-o", j3dCLIOrigin.path,
            "--levels", "1,1,1", "--spacing", "0.5,0.5,2.0", "--origin", "-250.25,10,-99.5"
        ])
        #expect(cliOriginRes.status == 0, "encode3d negative --origin stderr: \(cliOriginRes.stderrText)")
        #expect(try runR2CLI(["decode3d", "-i", j3dCLIOrigin.path, "-o", nrrdCLIOrigin.path]).status == 0)
        let parsedCLIOrigin = try parseNRRDVolume(Data(contentsOf: nrrdCLIOrigin), limits: .default)
        #expect(parsedCLIOrigin.spacingX == 0.5 && parsedCLIOrigin.spacingZ == 2.0)
        #expect(parsedCLIOrigin.originX == -250.25 && parsedCLIOrigin.originZ == -99.5)

        // F11: `--metadata-policy discard-ancillary` strips geometry
        #expect(
            try runR2CLI([
                "decode3d", "-i", j3dOut.path, "-o", nrrdDisc.path,
                "--metadata-policy", "discard-ancillary"
            ]).status == 0
        )
        let parsedDisc = try parseNRRDVolume(Data(contentsOf: nrrdDisc), limits: .default)
        #expect(!parsedDisc.hasExplicitGeometry)

        // F11: Rotated off-diagonal NRRD `space directions` rejected cleanly with exit 4 (never silently dropped)
        let rotatedNRRD = tmpDir.appendingPathComponent("vol_rotated.nrrd")
        let rotatedHeader = [
            "NRRD0004",
            "type: uint8",
            "dimension: 3",
            "sizes: 8 8 2",
            "space dimension: 3",
            "space directions: (0.7,0.1,0) (0,0.7,0) (0,0,1.5)",
            "encoding: raw",
            "",
            ""
        ].joined(separator: "\n")
        try (Data(rotatedHeader.utf8) + voxels).write(to: rotatedNRRD)
        #expect(
            try runR2CLI([
                "encode3d", "-i", rotatedNRRD.path, "-o", tmpDir.appendingPathComponent("rot.j3d").path,
                "--levels", "1,1,1"
            ]).status == 4
        )

        // 2. F09 & F10 on `jpip client` CLI
        let rgbJP2 = containerFixtureURL("jp2_rgb8_rct.kdu.jp2")
        // `--copy-policy require-sharing` -> exit 4
        #expect(
            try runR2CLI([
                "jpip", "client", "--single-file", rgbJP2.path,
                "--port", "19421", "--copy-policy", "require-sharing"
            ]).status == 4
        )
        // Malformed `--components 0,abc` -> exit 2 (UsageError)
        #expect(
            try runR2CLI([
                "jpip", "client", "--single-file", rgbJP2.path,
                "--port", "19422", "--components", "0,abc"
            ]).status == 2
        )
        // Out-of-range `--components 99` -> exit 2 (CodecError.invalidArgument)
        #expect(
            try runR2CLI([
                "jpip", "client", "--single-file", rgbJP2.path,
                "--port", "19423", "--components", "99"
            ]).status == 2
        )
    }
}
