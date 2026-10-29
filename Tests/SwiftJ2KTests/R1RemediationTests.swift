// SPDX-License-Identifier: Apache-2.0
//
// R1RemediationTests.swift
// SwiftJ2KTests
//
// Phase R1 audit remediation regression suite covering:
// - R1-CODE-02 (pre-allocation parser admission reaching 1-component SIZ, small <=16-entry QCD, and 16384-component SIZ)
// - M6-AUD-006 (cumulative multiple-small-retained COC/QCC/COM parser admission + decode workspace admission)
// - F13 (post-.completed cancellation & deadline enforcement across Encoder/Decoder/ImageDestination/Transcoder)
// - M12-CX-01 + follow-up (64x64 8-bit single-strip & multi-strip TIFF lifetime/allocation-order checks + CLI admission)
// - M12-CX-02 (checked ROI/slice-range arithmetic & volume bounds in CLI)
// - CLI F02 (32-bit integer NRRD lossless round-trip preserving 2^24 + 1 = 16,777,217)
// - CLI F03 (--resolution-level > 32 rejected cleanly without shift trap)
// - CLI F05 (--max-memory / ResourceLimits enforced on encode3d, decode3d, jpip)
// - M12-CI (CZlibShim PNG deflate/inflate round-trip via CLI)

import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2KCLI

// MARK: - CLI Subprocess Helpers

private struct R1CLIResult: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
    let stdout: Data
    let stderr: Data
    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

private func locateSwiftJ2KCLI() throws -> URL {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repoRoot.appendingPathComponent(".build/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/out/Products/Debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/release/swiftj2k-cli")
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    let buildProc = Process()
    buildProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    buildProc.arguments = ["swift", "build", "--product", "swiftj2k-cli"]
    buildProc.currentDirectoryURL = repoRoot
    try buildProc.run()
    buildProc.waitUntilExit()
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw CodecError(.internalFailure, "Unable to locate swiftj2k-cli executable for R1 regression tests.")
}

private func runSwiftJ2KCLI(_ args: [String]) throws -> R1CLIResult {
    let binary = try locateSwiftJ2KCLI()
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
    return R1CLIResult(
        status: proc.terminationStatus,
        reason: proc.terminationReason,
        stdout: outData,
        stderr: errData
    )
}

private func makeGray16Image(width: Int = 4, height: Int = 4) throws -> Image {
    let descriptor = try ImageDescriptor.greyscale16(width: width, height: height)
    let dest = try ImageDestination.allocate(descriptor: descriptor)
    return try dest.writeUInt16 { x, y in
        UInt16(((y * width + x) * 257 + 13) & 0xFFFF)
    }
}

private func makeRGB8Image(width: Int = 4, height: Int = 4) throws -> Image {
    let descriptor = try ImageDescriptor.rgbPlanar(
        width: width,
        height: height,
        storageBits: 8,
        meaningfulBits: 8,
        signed: false
    )
    let dest = try ImageDestination.allocate(descriptor: descriptor)
    return try dest.writeSamples { c, x, y in
        (x * 17 + y * 31 + c * 53) & 0xFF
    }
}

/// Scans main-header marker segments (before SOT = 0xFF90) to return the raw payload bytes (`L - 2`) of `targetMarker`.
private func mainHeaderMarkerPayload(marker targetMarker: UInt16, in codestream: Data) -> [UInt8]? {
    let bytes = [UInt8](codestream)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0x4F else { return nil }
    var pos = 2
    while pos + 2 <= bytes.count {
        let m = (UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1])
        pos += 2
        if m == 0xFF90 || m == 0xFFD9 { break }
        if (0xFF30...0xFF3F).contains(m) { continue }
        guard pos + 2 <= bytes.count else { return nil }
        let segLen = Int((UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1]))
        guard segLen >= 2, pos + segLen <= bytes.count else { return nil }
        if m == targetMarker {
            return Array(bytes[(pos + 2)..<(pos + segLen)])
        }
        pos += segLen
    }
    return nil
}

private func mainHeaderMarkerPayloadLength(marker targetMarker: UInt16, in codestream: Data) -> Int? {
    mainHeaderMarkerPayload(marker: targetMarker, in: codestream)?.count
}

/// Returns the byte offset of the first SOT marker (`0xFF90`) in a codestream.
private func firstSOTOffset(in codestream: Data) -> Int? {
    let bytes = [UInt8](codestream)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0x4F else { return nil }
    var pos = 2
    while pos + 2 <= bytes.count {
        let m = (UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1])
        if m == 0xFF90 { return pos }
        pos += 2
        if (0xFF30...0xFF3F).contains(m) { continue }
        guard pos + 2 <= bytes.count else { return nil }
        let segLen = Int((UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1]))
        guard segLen >= 2, pos + segLen <= bytes.count else { return nil }
        pos += segLen
    }
    return nil
}

/// Builds a synthetic little-endian baseline uncompressed single-strip TIFF.
private func makeSyntheticLittleEndianTIFF(
    width: UInt32,
    height: UInt32,
    bitsPerSample: UInt16 = 8,
    stripPayload: [UInt8]
) -> Data {
    var bytes: [UInt8] = []
    func putU16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    func putU32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }
    bytes.append(contentsOf: [0x49, 0x49])
    putU16(42)
    putU32(8)

    let entryCount: UInt16 = 7
    let stripOffset: UInt32 = 8 + 2 + UInt32(entryCount) * 12 + 4
    putU16(entryCount)

    func putIFDEntry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
        putU16(tag)
        putU16(type)
        putU32(count)
        putU32(valueOrOffset)
    }

    putIFDEntry(tag: 256, type: 4, count: 1, valueOrOffset: width)
    putIFDEntry(tag: 257, type: 4, count: 1, valueOrOffset: height)
    putIFDEntry(tag: 258, type: 3, count: 1, valueOrOffset: UInt32(bitsPerSample))
    putIFDEntry(tag: 259, type: 3, count: 1, valueOrOffset: 1)
    putIFDEntry(tag: 262, type: 3, count: 1, valueOrOffset: 1)
    putIFDEntry(tag: 273, type: 4, count: 1, valueOrOffset: stripOffset)
    putIFDEntry(tag: 279, type: 4, count: 1, valueOrOffset: UInt32(stripPayload.count))
    putU32(0)
    bytes.append(contentsOf: stripPayload)
    return Data(bytes)
}

/// Builds a synthetic little-endian baseline uncompressed multi-strip TIFF (`stripCount >= 2`).
private func makeSyntheticMultiStripLittleEndianTIFF(
    width: UInt32,
    height: UInt32,
    bitsPerSample: UInt16 = 8,
    strips: [[UInt8]]
) -> Data {
    precondition(strips.count >= 2)
    var bytes: [UInt8] = []
    func putU16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    func putU32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }
    bytes.append(contentsOf: [0x49, 0x49])
    putU16(42)
    putU32(8)

    let entryCount: UInt16 = 7
    let offsetsTablePos: UInt32 = 8 + 2 + UInt32(entryCount) * 12 + 4
    let countsTablePos: UInt32 = offsetsTablePos + UInt32(strips.count * 4)
    let firstStripPos: UInt32 = countsTablePos + UInt32(strips.count * 4)

    putU16(entryCount)
    func putIFDEntry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
        putU16(tag)
        putU16(type)
        putU32(count)
        putU32(valueOrOffset)
    }

    putIFDEntry(tag: 256, type: 4, count: 1, valueOrOffset: width)
    putIFDEntry(tag: 257, type: 4, count: 1, valueOrOffset: height)
    putIFDEntry(tag: 258, type: 3, count: 1, valueOrOffset: UInt32(bitsPerSample))
    putIFDEntry(tag: 259, type: 3, count: 1, valueOrOffset: 1)
    putIFDEntry(tag: 262, type: 3, count: 1, valueOrOffset: 1)
    putIFDEntry(tag: 273, type: 4, count: UInt32(strips.count), valueOrOffset: offsetsTablePos)
    putIFDEntry(tag: 279, type: 4, count: UInt32(strips.count), valueOrOffset: countsTablePos)
    putU32(0)

    var runningOffset = firstStripPos
    for s in strips {
        putU32(runningOffset)
        runningOffset += UInt32(s.count)
    }
    for s in strips {
        putU32(UInt32(s.count))
    }
    for s in strips {
        bytes.append(contentsOf: s)
    }
    return Data(bytes)
}

/// Generates `count` deterministic bytes `UInt8((i * multiplier + addend) & 255)` for `i in 0..<count`
/// using explicitly typed scalar statements without nested generic range/closure expressions.
private func makeLinearTestBytes(count: Int, multiplier: Int, addend: Int) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(count)
    var i: Int = 0
    while i < count {
        let product: Int = i * multiplier
        let sum: Int = product + addend
        let masked: Int = sum & 255
        result.append(UInt8(truncatingIfNeeded: masked))
        i += 1
    }
    return result
}

/// Counts sample mismatches between a 1-component decoded `Image` and an expected row-major 8-bit raster.
private func countGrayscaleSampleMismatches(_ image: Image, expectedPixels: [UInt8]) throws -> Int {
    let width: Int = image.descriptor.width
    let height: Int = image.descriptor.height
    guard width * height == expectedPixels.count else { return expectedPixels.count + 1 }
    return try image.storage.withUnsafeBytes { raw -> Int in
        var mismatches: Int = 0
        var y: Int = 0
        while y < height {
            let rowBase: Int = y * width
            var x: Int = 0
            while x < width {
                let actual: Int = readLogicalSample(raw, descriptor: image.descriptor, component: 0, x: x, y: y)
                let expected: Int = Int(expectedPixels[rowBase + x])
                if actual != expected {
                    mismatches += 1
                }
                x += 1
            }
            y += 1
        }
        return mismatches
    }
}

/// Evaluates the intended 7-event partial-order lifetime contract for multi-strip TIFF decoding:
/// exact multiplicity 1 for all 7 expected events, both tag enters before strip enter, strip enter before
/// both tag exits (either mutual tag-exit order allowed), both tag exits before destination enter, and
/// destination enter before strip exit.
private func isValidTwoStripTIFFActionOrder(_ actionTrace: [String]) -> Bool {
    let expected: [String] = [
        "tiff-strip-offsets:enter",
        "tiff-strip-byte-counts:enter",
        "tiff-strip-workspace:enter",
        "tiff-strip-offsets:exit",
        "tiff-strip-byte-counts:exit",
        "image-destination:enter",
        "tiff-strip-workspace:exit"
    ]
    guard actionTrace.count == expected.count else { return false }
    for item in expected {
        if actionTrace.filter({ $0 == item }).count != 1 {
            return false
        }
    }
    guard let offsetsEnterIdx = actionTrace.firstIndex(of: "tiff-strip-offsets:enter"),
          let countsEnterIdx = actionTrace.firstIndex(of: "tiff-strip-byte-counts:enter"),
          let stripEnterIdx = actionTrace.firstIndex(of: "tiff-strip-workspace:enter"),
          let offsetsExitIdx = actionTrace.firstIndex(of: "tiff-strip-offsets:exit"),
          let countsExitIdx = actionTrace.firstIndex(of: "tiff-strip-byte-counts:exit"),
          let destEnterIdx = actionTrace.firstIndex(of: "image-destination:enter"),
          let stripExitIdx = actionTrace.firstIndex(of: "tiff-strip-workspace:exit") else {
        return false
    }
    return offsetsEnterIdx < stripEnterIdx
        && countsEnterIdx < stripEnterIdx
        && offsetsEnterIdx < offsetsExitIdx
        && countsEnterIdx < countsExitIdx
        && stripEnterIdx < offsetsExitIdx
        && stripEnterIdx < countsExitIdx
        && offsetsExitIdx < destEnterIdx
        && countsExitIdx < destEnterIdx
        && destEnterIdx < stripExitIdx
}

@Suite("Phase R1 — Core & CLI Audit Remediation Regressions")
struct R1RemediationTests {

    @Test("R1-CODE-02: pre-allocation parser admission reaches 1-component SIZ, small <=16-entry QCD, larger-budget control, and 16384-component SIZ")
    func parserPreAllocationAdmissionReachesSmallAndLargeBoundaries() async throws {
        // 8x8 1-component image encoded with 2 decomposition levels -> 1 + 3*2 = 7 QCD bands (<= 16 entries,
        // exercising the exact R1-CODE-02 small-QCD residual while ensuring QCD peak > SIZ transient peak).
        let img = try makeGray16Image(width: 8, height: 8)
        let encConfig = try EncoderConfiguration(
            codecOptions: try CodecOptions(decompositionLevels: 2)
        )
        let encoded = try await SwiftJ2K.Encoder(configuration: encConfig).encode(img)
        let decoder = try SwiftJ2K.Decoder()

        let sizPayloadLen = try #require(mainHeaderMarkerPayloadLength(marker: 0xFF51, in: encoded.data))
        let qcdPayloadLen = try #require(mainHeaderMarkerPayloadLength(marker: 0xFF5C, in: encoded.data))
        let sizTransient = 32 + sizPayloadLen
        let qcdTransient = 32 + qcdPayloadLen

        // Baseline run to verify exact retained structure sizes (including 32-byte array/struct overhead)
        let baselineRecorder = StorageTelemetry.Recorder()
        let baselineInfo = try StorageTelemetry.$recorder.withValue(baselineRecorder) {
            try decoder.inspect(encoded.data)
        }
        #expect(baselineInfo.descriptor.width == 8 && baselineInfo.descriptor.height == 8)

        let parserEvents = baselineRecorder.parserEvents
        let markersBytes = try #require(parserEvents.first { $0.stage == "parser-markers" }?.bytes)
        let sizBytes = try #require(parserEvents.first { $0.stage == "siz-components" }?.bytes)
        let qcdBytes = try #require(parserEvents.first { $0.stage == "qcd-parameters" }?.bytes)
        let tilePartBytes = try #require(parserEvents.first { $0.stage == "tile-part-record" }?.bytes)
        let sourceGeometryBytes = baselineRecorder.events
            .filter { $0.stage == "source-geometry" }
            .reduce(0) { $0 + $1.bytes }
        #expect(markersBytes == 128)
        #expect(sizBytes == 32 + MemoryLayout<ComponentSignalling>.stride)
        #expect(qcdBytes == 32 + 7 * MemoryLayout<Int>.stride)

        // 1. Exact boundary reaching 1-component SIZ:
        // Admits SIZ segment read (sizTransient) + initial "parser-markers" (128 + sizTransient),
        // then rejects 1 byte below "siz-components" (128 + sizBytes + sizTransient - 1) BEFORE [ComponentSignalling] allocation:
        let sizPeakNeeded = markersBytes + sizBytes + sizTransient
        let denySingleSIZRecorder = StorageTelemetry.Recorder()
        let denySingleSIZLimits = try ResourceLimits(maximumWorkspaceBytes: sizPeakNeeded - 1)
        do {
            _ = try StorageTelemetry.$recorder.withValue(denySingleSIZRecorder) {
                try decoder.inspect(
                    encoded.data,
                    options: DecodeOptions(resourceLimits: denySingleSIZLimits)
                )
            }
            Issue.record("Expected 1-component SIZ to be denied right at siz-components boundary")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denySingleSIZRecorder.parserEvents.map(\.stage) == ["parser-markers"])
        #expect(!denySingleSIZRecorder.parserEvents.map(\.stage).contains("siz-components"))

        // 2. Exact boundary reaching small (7-band <= 16-entry) QCD:
        // Admits "parser-markers" + "siz-components" + COD + QCD segment read, then rejects 1 byte below
        // "qcd-parameters" BEFORE exponents/mantissas allocation:
        let qcdPeakNeeded = markersBytes + sizBytes + qcdBytes + qcdTransient
        #expect(qcdPeakNeeded > sizPeakNeeded)
        let denySmallQCDRecorder = StorageTelemetry.Recorder()
        let denySmallQCDLimits = try ResourceLimits(maximumWorkspaceBytes: qcdPeakNeeded - 1)
        do {
            _ = try StorageTelemetry.$recorder.withValue(denySmallQCDRecorder) {
                try decoder.inspect(
                    encoded.data,
                    options: DecodeOptions(resourceLimits: denySmallQCDLimits)
                )
            }
            Issue.record("Expected small <=16-entry QCD to be denied right at qcd-parameters boundary")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denySmallQCDRecorder.parserEvents.map(\.stage) == ["parser-markers", "siz-components"])
        #expect(!denySmallQCDRecorder.parserEvents.map(\.stage).contains("qcd-parameters"))

        // 3. Larger-budget successful control: raising budget to accommodate qcd-parameters + tile-part-record + source-geometry succeeds:
        let totalRetainedForInspect = markersBytes + sizBytes + qcdBytes + tilePartBytes + sourceGeometryBytes
        let controlBudget = max(qcdPeakNeeded, totalRetainedForInspect)
        let controlRecorder = StorageTelemetry.Recorder()
        let controlInfo = try StorageTelemetry.$recorder.withValue(controlRecorder) {
            try decoder.inspect(
                encoded.data,
                options: DecodeOptions(resourceLimits: try ResourceLimits(maximumWorkspaceBytes: controlBudget))
            )
        }
        #expect(controlInfo.descriptor.width == 8)
        #expect(controlRecorder.parserEvents.map(\.stage) == [
            "parser-markers", "siz-components", "qcd-parameters", "tile-part-record"
        ])

        // 4. 16,384-component SIZ (~49 KiB marker segment) under 64 KiB workspace budget denied before allocating ~393 KiB [ComponentSignalling]:
        let csiz: UInt16 = 16_384
        let lsiz: UInt16 = UInt16(38 + 3 * Int(csiz))
        var hugeSIZ = Data()
        hugeSIZ.append(contentsOf: [0xFF, 0x4F]) // SOC
        hugeSIZ.append(contentsOf: [0xFF, 0x51, UInt8(lsiz >> 8), UInt8(lsiz & 0xFF)]) // SIZ + Lsiz
        hugeSIZ.append(contentsOf: [0x00, 0x00]) // Rsiz
        for v: UInt32 in [4, 4, 0, 0, 4, 4, 0, 0] {
            hugeSIZ.append(contentsOf: [
                UInt8((v >> 24) & 0xFF),
                UInt8((v >> 16) & 0xFF),
                UInt8((v >> 8) & 0xFF),
                UInt8(v & 0xFF)
            ])
        }
        hugeSIZ.append(contentsOf: [UInt8(csiz >> 8), UInt8(csiz & 0xFF)])
        for _ in 0..<Int(csiz) {
            hugeSIZ.append(contentsOf: [7, 1, 1])
        }
        hugeSIZ.append(contentsOf: [0xFF, 0xD9]) // EOC

        let denyHugeSIZRecorder = StorageTelemetry.Recorder()
        let budget64K = try ResourceLimits(
            maximumCompressedBytes: 128 * 1024,
            maximumWorkspaceBytes: 64 * 1024,
            maximumMemoryBytes: 256 * 1024
        )
        do {
            _ = try await StorageTelemetry.$recorder.withValue(denyHugeSIZRecorder) {
                try await decoder.decode(
                    hugeSIZ,
                    options: DecodeOptions(resourceLimits: budget64K)
                )
            }
            Issue.record("Expected 16384-component SIZ to fail workspace admission under 64 KiB budget")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denyHugeSIZRecorder.parserEvents.map(\.stage) == ["parser-markers"])
        #expect(!denyHugeSIZRecorder.parserEvents.map(\.stage).contains("siz-components"))
    }

    @Test("M6-AUD-006: multiple small retained COC/QCC/COM structures accumulate to reject a final individually-fitting payload before allocation")
    func cumulativeMultipleSmallRetainedStructuresRejectCrossingPayload() async throws {
        // Encode a 3-component 4x4 lossless image with 1 decomposition level (4 subbands),
        // then inject COC (comp 1 with 2 precincts), QCC (comp 2 with 4 bands), and four small 256-byte COM segments
        // immediately before the first SOT marker.
        let rgb = try makeRGB8Image(width: 4, height: 4)
        let encConfig = try EncoderConfiguration(
            codecOptions: try CodecOptions(decompositionLevels: 1)
        )
        let baseEncoded = try await SwiftJ2K.Encoder(configuration: encConfig).encode(rgb)
        let sotPos = try #require(firstSOTOffset(in: baseEncoded.data))

        var crafted = Data(baseEncoded.data.prefix(sotPos))
        // COC (0xFF53) for component 1: Lcoc = 11, comp=1, Scoc=0x01 (precincts), levels=1, xcb=4, ycb=4, style=0, rev=1, PP=[0x55, 0x55]
        crafted.append(contentsOf: [
            0xFF, 0x53, 0x00, 0x0B,
            0x01, 0x01,
            0x01, 0x04, 0x04, 0x00, 0x01,
            0x55, 0x55
        ])
        // QCC (0xFF5D) for component 2 mirroring baseEncoded's exact QCD band exponents so tile bit-planes decode cleanly:
        let baseQCDPayload = try #require(mainHeaderMarkerPayload(marker: 0xFF5C, in: baseEncoded.data))
        let lqcc = UInt16(2 + 1 + baseQCDPayload.count)
        crafted.append(contentsOf: [0xFF, 0x5D, UInt8(lqcc >> 8), UInt8(lqcc & 0xFF), 0x02])
        crafted.append(contentsOf: baseQCDPayload)
        // Four small COM segments (each payload = 256 B -> Lcom = 258, retained = 36 + 256 = 292 B):
        let smallCOMPayload: [UInt8] = [0x00, 0x01] + [UInt8](repeating: 0x61, count: 254)
        let lcom = UInt16(2 + smallCOMPayload.count)
        for _ in 0..<4 {
            crafted.append(contentsOf: [0xFF, 0x64, UInt8(lcom >> 8), UInt8(lcom & 0xFF)])
            crafted.append(contentsOf: smallCOMPayload)
        }
        crafted.append(contentsOf: baseEncoded.data.suffix(from: sotPos))

        let craftedBytes = [UInt8](crafted)
        let decoder = try SwiftJ2K.Decoder()

        // Measure exact single-pass cumulative parser events on unconstrained baseline:
        let baselineRec = StorageTelemetry.Recorder()
        let parsedBaseline = try StorageTelemetry.$recorder.withValue(baselineRec) {
            try CodestreamSyntax.parse(
                craftedBytes,
                limits: .default,
                metadataPolicy: .preserve
            )
        }
        #expect(parsedBaseline.size.components.count == 3)
        let stages = baselineRec.parserEvents.map(\.stage)
        #expect(stages.contains("coc-parameters"))
        #expect(stages.contains("qcc-parameters"))
        #expect(baselineRec.parserEvents.filter { $0.stage == "comment-metadata" }.count == 4)

        // Cumulative retained bytes right through the 4th COM (everything before "tile-part-record"):
        let preTileEvents = baselineRec.parserEvents.filter { $0.stage != "tile-part-record" }
        let cumulativeThrough4thCOM = preTileEvents.reduce(0) { $0 + $1.bytes }
        let singleSmallCOMRetained = 36 + smallCOMPayload.count // 292 B (well below ~1.7 KiB cumulative budget!)
        #expect(singleSmallCOMRetained * 4 < cumulativeThrough4thCOM)

        // 1. Workspace budget 1 byte below the 4th small COM:
        // Admits SIZ, COD, QCD, COC, QCC, and the first THREE small COMs, then rejects the 4th small COM before allocation!
        let deny4thWorkspaceBudget = cumulativeThrough4thCOM - 1
        #expect(singleSmallCOMRetained < deny4thWorkspaceBudget / 4)
        let deny4thWSRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(deny4thWSRec) {
                try CodestreamSyntax.parse(
                    craftedBytes,
                    limits: try ResourceLimits(maximumWorkspaceBytes: deny4thWorkspaceBudget),
                    metadataPolicy: .preserve
                )
            }
            Issue.record("Expected 4th small COM to cross cumulative workspace budget and fail before allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(deny4thWSRec.parserEvents.map(\.stage).contains("coc-parameters"))
        #expect(deny4thWSRec.parserEvents.map(\.stage).contains("qcc-parameters"))
        #expect(deny4thWSRec.parserEvents.filter { $0.stage == "comment-metadata" }.count == 3)

        // 2. Total-memory budget (codestream + cumulative retained) 1 byte below the 4th small COM, with generous workspace:
        let deny4thMemoryBudget = craftedBytes.count + cumulativeThrough4thCOM - 1
        let deny4thMemRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(deny4thMemRec) {
                try CodestreamSyntax.parse(
                    craftedBytes,
                    limits: try ResourceLimits(maximumMemoryBytes: deny4thMemoryBudget),
                    metadataPolicy: .preserve
                )
            }
            Issue.record("Expected 4th small COM to cross cumulative live memory budget and fail before allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(deny4thMemRec.parserEvents.filter { $0.stage == "comment-metadata" }.count == 3)

        // 3. Larger-budget parser control admits all 4 small COMs + tile-part-record:
        let totalParserRetained = baselineRec.parserEvents.reduce(0) { $0 + $1.bytes }
        let passRec = StorageTelemetry.Recorder()
        let parsedPass = try StorageTelemetry.$recorder.withValue(passRec) {
            try CodestreamSyntax.parse(
                craftedBytes,
                limits: try ResourceLimits(
                    maximumWorkspaceBytes: totalParserRetained,
                    maximumMemoryBytes: craftedBytes.count + totalParserRetained
                ),
                metadataPolicy: .preserve
            )
        }
        #expect(parsedPass.mainHeaderComments.count == 4)
        #expect(passRec.parserEvents.filter { $0.stage == "comment-metadata" }.count == 4)

        // 4. End-to-end Decoder.decode carries cumulative retained parser metadata into coefficient workspace admission:
        let plainDecode = try await decoder.decode(baseEncoded.data)
        let plainWorkspace = try #require(plainDecode.report.peakWorkspaceBytes)
        let denyDecodeRec = StorageTelemetry.Recorder()
        do {
            _ = try await StorageTelemetry.$recorder.withValue(denyDecodeRec) {
                try await decoder.decode(
                    crafted,
                    options: DecodeOptions(
                        resourceLimits: try ResourceLimits(maximumWorkspaceBytes: plainWorkspace + 256)
                    )
                )
            }
            Issue.record("Expected cumulative COC+QCC+4xCOM retained metadata to deny decode workspace before coefficient allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denyDecodeRec.counts.workspaceAllocations == 0)

        let fullDecoded = try await decoder.decode(crafted)
        #expect(fullDecoded.image.descriptor.width == 4 && fullDecoded.image.descriptor.height == 4)
    }

    @Test("F13: cancellation inside .completed progress callback aborts Encoder, Decoder, ImageDestination, and Transcoder")
    func postCompletedProgressCancellationAbortsCoreOperations() async throws {
        let img = try makeGray16Image(width: 8, height: 8)
        let encoder = try SwiftJ2K.Encoder()
        let decoder = try SwiftJ2K.Decoder()
        let transcoder = try SwiftJ2K.Transcoder()
        let baselineEncoded = try await encoder.encode(img)

        // 1. Encoder.encode self-cancels in .completed
        let encTask = Task {
            try await encoder.encode(
                img,
                options: EncodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await encTask.value
        }

        // 2. Decoder.decode self-cancels in .completed
        let decTask = Task {
            try await decoder.decode(
                baselineEncoded.data,
                options: DecodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await decTask.value
        }

        // 3. Decoder.decode(_:into:) self-cancels in .completed AND in .inspecting (destination invalidated)
        let destCompleted = try ImageDestination.allocate(descriptor: img.descriptor)
        let decIntoCompletedTask = Task {
            try await decoder.decode(
                baselineEncoded.data,
                into: destCompleted,
                options: DecodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await decIntoCompletedTask.value
        }

        let destInspect = try ImageDestination.allocate(descriptor: img.descriptor)
        let decIntoInspectTask = Task {
            try await decoder.decode(
                baselineEncoded.data,
                into: destInspect,
                options: DecodeOptions(progress: { update in
                    if update.phase == .inspecting {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await decIntoInspectTask.value
        }
        await #expect(throws: CodecError.self) {
            _ = try await decoder.decode(baselineEncoded.data, into: destInspect)
        }

        // 4. Transcoder.transcode self-cancels in .completed
        let transTask = Task {
            try await transcoder.transcode(
                baselineEncoded.data,
                to: .htj2k,
                options: TranscodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await transTask.value
        }
    }

    @Test("M12-CX-01 + follow-up: 64x64 8-bit single-strip & multi-strip TIFF combined live-memory, 16-bit contract storage pre-strip check, and lifetime telemetry")
    func tiffCombinedLiveMemoryAndPreStripStorageAdmission() throws {
        let pixels64: [UInt8] = makeLinearTestBytes(count: 4096, multiplier: 13, addend: 7)
        #expect(pixels64.count == 4096)
        let singleStrip64 = makeSyntheticLittleEndianTIFF(
            width: 64,
            height: 64,
            bitsPerSample: 8,
            stripPayload: pixels64
        )
        let firstHalfStrip: [UInt8] = Array(pixels64[0..<2048])
        let secondHalfStrip: [UInt8] = Array(pixels64[2048..<4096])
        let twoStrip64 = makeSyntheticMultiStripLittleEndianTIFF(
            width: 64,
            height: 64,
            bitsPerSample: 8,
            strips: [firstHalfStrip, secondHalfStrip]
        )

        // 1. Valid 64x64 8-bit single-strip TIFF with maximumWorkspaceBytes == file.count and generous other budgets:
        let singleRec = CLIImageIOTelemetry.Recorder()
        let singleImg = try CLIImageIOTelemetry.$recorder.withValue(singleRec) {
            try parseTIFF(
                singleStrip64,
                declaredPrecision: nil,
                limits: try ResourceLimits(maximumWorkspaceBytes: singleStrip64.count)
            )
        }
        #expect(singleImg.descriptor.width == 64 && singleImg.descriptor.height == 64)
        #expect(singleImg.descriptor.meaningfulBits == 8)
        #expect(singleImg.descriptor.storageBits == 16)
        #expect(singleImg.descriptor.requiredByteCount == 8192)
        #expect(try countGrayscaleSampleMismatches(singleImg, expectedPixels: pixels64) == 0)
        // Single-strip TIFF performs zero workspace copies (no [UInt8] input copy, no tag arrays, no stripBytes copy):
        #expect(singleRec.peakWorkspaceBytes == 0)
        #expect(singleRec.peakDecodedBytes == 8192)
        #expect(singleRec.peakTotalBytes == singleStrip64.count + 8192)
        #expect(singleRec.liveWorkspaceBytes == 0)
        #expect(singleRec.liveTagOwners == 0)

        // 2. Decoded-byte budget between 4096 and 8192 (e.g. 6000 B) MUST reject BEFORE strip allocation
        // because 1-component 8-bit greyscale uses 16-bit contract storage (8192 B):
        let midDecodedLimits = try ResourceLimits(maximumDecodedBytes: 6000)
        for tiffData in [singleStrip64, twoStrip64] {
            let ioRec = CLIImageIOTelemetry.Recorder()
            let stRec = StorageTelemetry.Recorder()
            do {
                _ = try StorageTelemetry.$recorder.withValue(stRec) {
                    try CLIImageIOTelemetry.$recorder.withValue(ioRec) {
                        try parseTIFF(tiffData, declaredPrecision: nil, limits: midDecodedLimits)
                    }
                }
                Issue.record("Expected 6000 B maximumDecodedBytes to reject 64x64 8-bit greyscale TIFF before strip allocation")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(!ioRec.events.map(\.stage).contains("tiff-strip-workspace"))
            #expect(!ioRec.events.map(\.stage).contains("image-destination"))
            #expect(stRec.counts.pixelAllocations == 0)
            #expect(ioRec.liveWorkspaceBytes == 0)
        }

        // 3. Separate maximumMemoryBytes budget crossing simultaneous allocations on 2-strip 64x64 TIFF:
        // Simultaneous live peak during destination fill is input (4210 B) + strip workspace (4096 B) + 16-bit destination (8192 B) = 16,498 B.
        // Individually, input + strip = 8,306 B and input + destination = 12,402 B both fit inside 16,497 B!
        let simultaneousPeak = twoStrip64.count + 4096 + 8192
        let denySimultaneousMemRec = CLIImageIOTelemetry.Recorder()
        let denySimultaneousStRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denySimultaneousStRec) {
                try CLIImageIOTelemetry.$recorder.withValue(denySimultaneousMemRec) {
                    try parseTIFF(
                        twoStrip64,
                        declaredPrecision: nil,
                        limits: try ResourceLimits(maximumMemoryBytes: simultaneousPeak - 1)
                    )
                }
            }
            Issue.record("Expected maximumMemoryBytes = \(simultaneousPeak - 1) to reject simultaneous input + strip + destination live buffers")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!denySimultaneousMemRec.events.map(\.stage).contains("tiff-strip-workspace"))
        #expect(!denySimultaneousMemRec.events.map(\.stage).contains("image-destination"))
        #expect(denySimultaneousStRec.counts.pixelAllocations == 0)
        #expect(denySimultaneousMemRec.liveWorkspaceBytes == 0)

        // 4. Exact simultaneous peak control (workspace == twoStrip64.count, memory == simultaneousPeak) succeeds;
        // ARC deinit trace proves both tag owners exit after strip workspace allocation and before ImageDestination
        // allocation (without constraining the mutual destruction order of the two independent tag owners), while
        // decodeTIFFFromStripWorkspace retains the strip workspace owner across the synchronous writeSamples fill so
        // strip exit follows destination entry:
        let passTwoStripRec = CLIImageIOTelemetry.Recorder()
        let twoStripImg = try CLIImageIOTelemetry.$recorder.withValue(passTwoStripRec) {
            try parseTIFF(
                twoStrip64,
                declaredPrecision: nil,
                limits: try ResourceLimits(
                    maximumWorkspaceBytes: twoStrip64.count,
                    maximumMemoryBytes: simultaneousPeak
                )
            )
        }
        #expect(twoStripImg.storage.byteCount == 8192)
        #expect(try countGrayscaleSampleMismatches(twoStripImg, expectedPixels: pixels64) == 0)
        #expect(passTwoStripRec.peakWorkspaceBytes == 32 + 4096)
        #expect(passTwoStripRec.peakWorkspaceBytes <= twoStrip64.count)
        #expect(passTwoStripRec.peakTotalBytes == simultaneousPeak)
        #expect(passTwoStripRec.peakTotalBytes <= simultaneousPeak)
        #expect(passTwoStripRec.liveWorkspaceBytes == 0)
        #expect(passTwoStripRec.liveTagOwners == 0)
        let actionTrace: [String] = passTwoStripRec.events.map { "\($0.stage):\($0.action.rawValue)" }
        let expectedTwoStripEvents: [String] = [
            "tiff-strip-offsets:enter",
            "tiff-strip-byte-counts:enter",
            "tiff-strip-workspace:enter",
            "tiff-strip-offsets:exit",
            "tiff-strip-byte-counts:exit",
            "image-destination:enter",
            "tiff-strip-workspace:exit"
        ]
        #expect(actionTrace.count == expectedTwoStripEvents.count)
        for expectedEvent in expectedTwoStripEvents {
            #expect(actionTrace.filter { $0 == expectedEvent }.count == 1)
        }
        let offsetsEnterIdx = try #require(actionTrace.firstIndex(of: "tiff-strip-offsets:enter"))
        let countsEnterIdx = try #require(actionTrace.firstIndex(of: "tiff-strip-byte-counts:enter"))
        let stripEnterIdx = try #require(actionTrace.firstIndex(of: "tiff-strip-workspace:enter"))
        let offsetsExitIdx = try #require(actionTrace.firstIndex(of: "tiff-strip-offsets:exit"))
        let countsExitIdx = try #require(actionTrace.firstIndex(of: "tiff-strip-byte-counts:exit"))
        let destEnterIdx = try #require(actionTrace.firstIndex(of: "image-destination:enter"))
        let stripExitIdx = try #require(actionTrace.firstIndex(of: "tiff-strip-workspace:exit"))
        #expect(offsetsEnterIdx < stripEnterIdx)
        #expect(countsEnterIdx < stripEnterIdx)
        #expect(offsetsEnterIdx < offsetsExitIdx)
        #expect(countsEnterIdx < countsExitIdx)
        #expect(stripEnterIdx < offsetsExitIdx)
        #expect(stripEnterIdx < countsExitIdx)
        #expect(offsetsExitIdx < destEnterIdx)
        #expect(countsExitIdx < destEnterIdx)
        #expect(destEnterIdx < stripExitIdx)
        let twoStripDestEnter = passTwoStripRec.events[destEnterIdx]
        #expect(twoStripDestEnter.liveTagOwners == 0)
        #expect(twoStripDestEnter.liveWorkspaceBytes == 4096)
        #expect(twoStripDestEnter.liveTotalBytes == simultaneousPeak)
        #expect(isValidTwoStripTIFFActionOrder(actionTrace))
        // Verify the partial-order contract accepts the optimized Linux release LIFO tag-exit order
        // while rejecting duplicate events, post-destination tag exits, and premature strip exits:
        #expect(isValidTwoStripTIFFActionOrder([
            "tiff-strip-offsets:enter",
            "tiff-strip-byte-counts:enter",
            "tiff-strip-workspace:enter",
            "tiff-strip-byte-counts:exit",
            "tiff-strip-offsets:exit",
            "image-destination:enter",
            "tiff-strip-workspace:exit"
        ]))
        #expect(!isValidTwoStripTIFFActionOrder([
            "tiff-strip-offsets:enter",
            "tiff-strip-offsets:enter",
            "tiff-strip-workspace:enter",
            "tiff-strip-offsets:exit",
            "tiff-strip-byte-counts:exit",
            "image-destination:enter",
            "tiff-strip-workspace:exit"
        ]))
        #expect(!isValidTwoStripTIFFActionOrder([
            "tiff-strip-offsets:enter",
            "tiff-strip-byte-counts:enter",
            "tiff-strip-workspace:enter",
            "tiff-strip-offsets:exit",
            "image-destination:enter",
            "tiff-strip-byte-counts:exit",
            "tiff-strip-workspace:exit"
        ]))
        #expect(!isValidTwoStripTIFFActionOrder([
            "tiff-strip-offsets:enter",
            "tiff-strip-byte-counts:enter",
            "tiff-strip-workspace:enter",
            "tiff-strip-offsets:exit",
            "tiff-strip-byte-counts:exit",
            "tiff-strip-workspace:exit",
            "image-destination:enter"
        ]))

        // 5. Cumulative multi-strip tag array admission: 64 strips -> 512 B StripOffsets + 512 B StripByteCounts = 1024 B.
        // Under maximumMetadataBytes = 768 B (each 512 B tag fits individually!), StripByteCounts is denied before allocation:
        var strips64: [[UInt8]] = []
        for s in 0..<64 {
            strips64.append(Array(pixels64[(s * 64)..<((s + 1) * 64)]))
        }
        let tiff64Strips = makeSyntheticMultiStripLittleEndianTIFF(
            width: 64,
            height: 64,
            bitsPerSample: 8,
            strips: strips64
        )
        let denyTagRec = CLIImageIOTelemetry.Recorder()
        do {
            _ = try CLIImageIOTelemetry.$recorder.withValue(denyTagRec) {
                try parseTIFF(
                    tiff64Strips,
                    declaredPrecision: nil,
                    limits: try ResourceLimits(maximumMetadataBytes: 768)
                )
            }
            Issue.record("Expected cumulative 1024 B multi-strip tag arrays to fail 768 B metadata limit")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
            #expect(denyTagRec.events.map { "\($0.stage):\($0.action.rawValue)" } == [
                "tiff-strip-offsets:enter",
                "tiff-strip-offsets:exit"
            ])
            #expect(denyTagRec.liveWorkspaceBytes == 0)
            #expect(denyTagRec.liveTagOwners == 0)
        }

    @Test("M12-CX-01 rework: duplicate StripOffsets/StripByteCounts replacement overlap, ARC deinit multi-strip ownership proof, and tag+strip workspace boundary")
    func tiffDuplicateTagReplacementAndARCDeinitOwnershipBoundaries() throws {
        func makeDuplicateStripTagTIFF(
            width: UInt32,
            height: UInt32,
            strips: [[UInt8]],
            duplicateOffsets: Bool,
            duplicateByteCounts: Bool,
            byteCountsBeforeOffsets: Bool = false
        ) -> Data {
            var bytes: [UInt8] = []
            func putU16(_ v: UInt16) {
                bytes.append(UInt8(truncatingIfNeeded: v))
                bytes.append(UInt8(truncatingIfNeeded: v >> 8))
            }
            func putU32(_ v: UInt32) {
                bytes.append(UInt8(truncatingIfNeeded: v))
                bytes.append(UInt8(truncatingIfNeeded: v >> 8))
                bytes.append(UInt8(truncatingIfNeeded: v >> 16))
                bytes.append(UInt8(truncatingIfNeeded: v >> 24))
            }
            func putIFDEntry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
                putU16(tag)
                putU16(type)
                putU32(count)
                putU32(valueOrOffset)
            }

            bytes.append(contentsOf: [0x49, 0x49])
            putU16(42)
            putU32(8)

            let offsetsOccurrences = duplicateOffsets ? 2 : 1
            let countsOccurrences = duplicateByteCounts ? 2 : 1
            let entryCount = UInt16(7 + offsetsOccurrences + countsOccurrences)
            let offsetsTablePos: UInt32 = 8 + 2 + UInt32(entryCount) * 12 + 4
            let countsTablePos: UInt32 = offsetsTablePos + UInt32(strips.count * 4)
            let firstStripPos: UInt32 = countsTablePos + UInt32(strips.count * 4)

            putU16(entryCount)
            putIFDEntry(tag: 256, type: 4, count: 1, valueOrOffset: width)
            putIFDEntry(tag: 257, type: 4, count: 1, valueOrOffset: height)
            putIFDEntry(tag: 258, type: 3, count: 1, valueOrOffset: 8)
            putIFDEntry(tag: 259, type: 3, count: 1, valueOrOffset: 1)
            putIFDEntry(tag: 262, type: 3, count: 1, valueOrOffset: 1)

            if byteCountsBeforeOffsets {
                for _ in 0..<countsOccurrences {
                    putIFDEntry(tag: 279, type: 4, count: UInt32(strips.count), valueOrOffset: countsTablePos)
                }
                putIFDEntry(tag: 277, type: 3, count: 1, valueOrOffset: 1)
                for _ in 0..<offsetsOccurrences {
                    putIFDEntry(tag: 273, type: 4, count: UInt32(strips.count), valueOrOffset: offsetsTablePos)
                }
            } else {
                for _ in 0..<offsetsOccurrences {
                    putIFDEntry(tag: 273, type: 4, count: UInt32(strips.count), valueOrOffset: offsetsTablePos)
                }
                putIFDEntry(tag: 277, type: 3, count: 1, valueOrOffset: 1)
                for _ in 0..<countsOccurrences {
                    putIFDEntry(tag: 279, type: 4, count: UInt32(strips.count), valueOrOffset: countsTablePos)
                }
            }
            putIFDEntry(tag: 284, type: 3, count: 1, valueOrOffset: 1)
            putU32(0)

            var runningOffset = firstStripPos
            for s in strips {
                putU32(runningOffset)
                runningOffset += UInt32(s.count)
            }
            for s in strips {
                putU32(UInt32(s.count))
            }
            for s in strips {
                bytes.append(contentsOf: s)
            }
            return Data(bytes)
        }

        // 1. Duplicate 64-entry StripOffsets (tag 273): old 512 B owner remains live while replacement 512 B array is built (1024 B peak).
        let strips8x8 = (0..<64).map { [UInt8(($0 * 3 + 11) & 0xFF)] }
        let dupOffsetsTIFF = makeDuplicateStripTagTIFF(
            width: 8,
            height: 8,
            strips: strips8x8,
            duplicateOffsets: true,
            duplicateByteCounts: false
        )
        let dupOffsetsDenyRec = CLIImageIOTelemetry.Recorder()
        do {
            _ = try CLIImageIOTelemetry.$recorder.withValue(dupOffsetsDenyRec) {
                try parseTIFF(
                    dupOffsetsTIFF,
                    declaredPrecision: nil,
                    limits: try ResourceLimits(maximumWorkspaceBytes: 768)
                )
            }
            Issue.record("Expected duplicate 64-entry StripOffsets to deny replacement before 2nd 512 B array allocation under 768 B workspace")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        let offsetEnters = dupOffsetsDenyRec.events.filter { $0.stage == "tiff-strip-offsets" && $0.action == .enter }
        #expect(offsetEnters.count == 1)
        #expect(dupOffsetsDenyRec.liveWorkspaceBytes == 0)
        #expect(dupOffsetsDenyRec.liveTagOwners == 0)

        let dupOffsetsControlRec = CLIImageIOTelemetry.Recorder()
        let dupOffsetsImg = try CLIImageIOTelemetry.$recorder.withValue(dupOffsetsControlRec) {
            try parseTIFF(
                dupOffsetsTIFF,
                declaredPrecision: nil,
                limits: try ResourceLimits(maximumWorkspaceBytes: 2048)
            )
        }
        #expect(dupOffsetsImg.descriptor.width == 8 && dupOffsetsImg.descriptor.height == 8)
        #expect(dupOffsetsImg.storage.byteCount == 128)
        #expect(dupOffsetsControlRec.liveWorkspaceBytes == 0)
        #expect(dupOffsetsControlRec.liveTagOwners == 0)

        // 1b. 1100 B workspace fits steady-state 1024 B retained tag pair + 64 B strip raster (1088 B),
        // so non-duplicate 64-strip 8x8 TIFF passes at 1100 B, whereas repeating StripOffsets after both 512 B
        // lists exist requires 1536 B during replacement and is denied before the 2nd StripOffsets allocation:
        let nonDup64Strip8x8TIFF = makeDuplicateStripTagTIFF(
            width: 8,
            height: 8,
            strips: strips8x8,
            duplicateOffsets: false,
            duplicateByteCounts: false
        )
        let nonDup1100Img = try parseTIFF(
            nonDup64Strip8x8TIFF,
            declaredPrecision: nil,
            limits: try ResourceLimits(maximumWorkspaceBytes: 1100)
        )
        #expect(nonDup1100Img.descriptor.width == 8 && nonDup1100Img.descriptor.height == 8)

        let dupOffsetsAfterCountsTIFF = makeDuplicateStripTagTIFF(
            width: 8,
            height: 8,
            strips: strips8x8,
            duplicateOffsets: true,
            duplicateByteCounts: false,
            byteCountsBeforeOffsets: true
        )
        let dupOffsets1100Rec = CLIImageIOTelemetry.Recorder()
        do {
            _ = try CLIImageIOTelemetry.$recorder.withValue(dupOffsets1100Rec) {
                try parseTIFF(
                    dupOffsetsAfterCountsTIFF,
                    declaredPrecision: nil,
                    limits: try ResourceLimits(maximumWorkspaceBytes: 1100)
                )
            }
            Issue.record("Expected 1024 B retained pair + 512 B replacement StripOffsets (1536 B) to fail 1100 B workspace")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(dupOffsets1100Rec.events.filter { $0.stage == "tiff-strip-offsets" && $0.action == .enter }.count == 1)
        #expect(dupOffsets1100Rec.liveWorkspaceBytes == 0)
        #expect(dupOffsets1100Rec.liveTagOwners == 0)

        // 2. Duplicate 64-entry StripByteCounts (tag 279) — both before StripOffsets (512 + 512 = 1024 > 768)
        // and after StripOffsets (512 retained offsets + 512 old counts + 512 new counts = 1536 > 1280):
        let dupCountsFirstTIFF = makeDuplicateStripTagTIFF(
            width: 8,
            height: 8,
            strips: strips8x8,
            duplicateOffsets: false,
            duplicateByteCounts: true,
            byteCountsBeforeOffsets: true
        )
        let dupCountsFirstDenyRec = CLIImageIOTelemetry.Recorder()
        do {
            _ = try CLIImageIOTelemetry.$recorder.withValue(dupCountsFirstDenyRec) {
                try parseTIFF(
                    dupCountsFirstTIFF,
                    declaredPrecision: nil,
                    limits: try ResourceLimits(maximumWorkspaceBytes: 768)
                )
            }
            Issue.record("Expected duplicate 64-entry StripByteCounts to deny replacement before 2nd 512 B allocation under 768 B workspace")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(dupCountsFirstDenyRec.events.filter { $0.stage == "tiff-strip-byte-counts" && $0.action == .enter }.count == 1)
        #expect(dupCountsFirstDenyRec.liveWorkspaceBytes == 0)
        #expect(dupCountsFirstDenyRec.liveTagOwners == 0)

        let dupCountsAfterOffsetsTIFF = makeDuplicateStripTagTIFF(
            width: 8,
            height: 8,
            strips: strips8x8,
            duplicateOffsets: false,
            duplicateByteCounts: true,
            byteCountsBeforeOffsets: false
        )
        let dupCountsAfterDenyRec = CLIImageIOTelemetry.Recorder()
        do {
            _ = try CLIImageIOTelemetry.$recorder.withValue(dupCountsAfterDenyRec) {
                try parseTIFF(
                    dupCountsAfterOffsetsTIFF,
                    declaredPrecision: nil,
                    limits: try ResourceLimits(maximumWorkspaceBytes: 1280)
                )
            }
            Issue.record("Expected StripOffsets (512 B) + duplicate StripByteCounts (512 + 512 B) = 1536 B to fail 1280 B workspace before 2nd counts allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(dupCountsAfterDenyRec.events.filter { $0.stage == "tiff-strip-byte-counts" && $0.action == .enter }.count == 1)
        #expect(dupCountsAfterDenyRec.liveWorkspaceBytes == 0)
        #expect(dupCountsAfterDenyRec.liveTagOwners == 0)

        let dupCountsControlImg = try parseTIFF(
            dupCountsAfterOffsetsTIFF,
            declaredPrecision: nil,
            limits: try ResourceLimits(maximumWorkspaceBytes: 2048)
        )
        #expect(dupCountsControlImg.descriptor.width == 8 && dupCountsControlImg.storage.byteCount == 128)

        // 3. Multi-strip tag arrays (1024 B) + strip workspace (4096 B) = 5120 B crossing workspace boundary
        // + ARC deinit proof that liveTagOwners == 0 before ImageDestination allocates:
        let pixels64: [UInt8] = makeLinearTestBytes(count: 4096, multiplier: 17, addend: 5)
        #expect(pixels64.count == 4096)
        var strips64: [[UInt8]] = []
        strips64.reserveCapacity(64)
        for s: Int in 0..<64 {
            let start: Int = s * 64
            let end: Int = start + 64
            strips64.append(Array(pixels64[start..<end]))
        }
        let tiff64Strips = makeSyntheticMultiStripLittleEndianTIFF(
            width: 64,
            height: 64,
            bitsPerSample: 8,
            strips: strips64
        )

        // Both 1024 B tag arrays and 4096 B stripBytes fit 4500 B individually, but simultaneous 5120 B > 4500 B must reject before strip workspace:
        let denyAssemblyWSRec = CLIImageIOTelemetry.Recorder()
        do {
            _ = try CLIImageIOTelemetry.$recorder.withValue(denyAssemblyWSRec) {
                try parseTIFF(
                    tiff64Strips,
                    declaredPrecision: nil,
                    limits: try ResourceLimits(maximumWorkspaceBytes: 4500)
                )
            }
            Issue.record("Expected 1024 B retained tags + 4096 B strip workspace (5120 B) to reject 4500 B workspace before strip allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!denyAssemblyWSRec.events.map(\.stage).contains("tiff-strip-workspace"))
        #expect(!denyAssemblyWSRec.events.map(\.stage).contains("image-destination"))
        #expect(denyAssemblyWSRec.liveWorkspaceBytes == 0)
        #expect(denyAssemblyWSRec.liveTagOwners == 0)

        // Exact 5120 B workspace control succeeds, and ARC deinit drops liveTagOwners from 2 -> 0 before image-destination enters:
        let passAssemblyWSRec = CLIImageIOTelemetry.Recorder()
        let img64 = try CLIImageIOTelemetry.$recorder.withValue(passAssemblyWSRec) {
            try parseTIFF(
                tiff64Strips,
                declaredPrecision: nil,
                limits: try ResourceLimits(maximumWorkspaceBytes: 5120)
            )
        }
        #expect(img64.storage.byteCount == 8192)
        #expect(try countGrayscaleSampleMismatches(img64, expectedPixels: pixels64) == 0)
        #expect(passAssemblyWSRec.peakWorkspaceBytes == 5120)
        #expect(passAssemblyWSRec.peakTagOwners == 2)
        let destEnter = try #require(
            passAssemblyWSRec.events.first { $0.stage == "image-destination" && $0.action == .enter }
        )
        #expect(destEnter.liveTagOwners == 0)
        #expect(destEnter.liveWorkspaceBytes == 4096)
        #expect(passAssemblyWSRec.liveTagOwners == 0)
        #expect(passAssemblyWSRec.liveWorkspaceBytes == 0)
    }

    @Test("M6-AUD-006 rework: repeated main-header and tile-part POC simultaneous growth admission and zero-allocation validateHTSignalling")
    func parserRepeatedPOCAndZeroAllocHTSignallingBoundaries() async throws {
        // Build a 4-entry POC marker segment (0xFF5F) for Csiz < 257 (7 bytes/entry -> 28 B payload, Lpoc = 30):
        func makeFourEntryPOCMarker() -> [UInt8] {
            var seg: [UInt8] = [0xFF, 0x5F, 0x00, 0x1E]
            for r in 0..<4 {
                seg.append(UInt8(r))     // RSpoc
                seg.append(0x00)         // CSpoc = 0
                seg.append(0x00)         // LYEpoc hi
                seg.append(0x01)         // LYEpoc lo = 1
                seg.append(UInt8(r + 1)) // REpoc = r + 1 (> RSpoc, <= 33)
                seg.append(0x01)         // CEpoc = 1 (> CSpoc)
                seg.append(UInt8(r % 5)) // Ppoc in 0...4
            }
            return seg
        }

        let baseImg = try makeGray16Image(width: 8, height: 8)
        let baseEncoded = try await SwiftJ2K.Encoder(
            configuration: try EncoderConfiguration(
                codecOptions: try CodecOptions(decompositionLevels: 2)
            )
        ).encode(baseImg)
        let sotPos = try #require(firstSOTOffset(in: baseEncoded.data))
        let pocSeg = makeFourEntryPOCMarker()
        let pocPayloadTransient = 32 + 28
        let entryStride = MemoryLayout<ProgressionOrderChangeEntry>.stride

        // --- 1. Repeated main-header POC (two 4-entry POC segments -> 8 entries total) ---
        var repeatedMainPOC = Data(baseEncoded.data.prefix(sotPos))
        repeatedMainPOC.append(contentsOf: pocSeg)
        repeatedMainPOC.append(contentsOf: pocSeg)
        repeatedMainPOC.append(contentsOf: baseEncoded.data.suffix(from: sotPos))
        let repeatedMainBytes = [UInt8](repeatedMainPOC)

        let mainBaselineRec = StorageTelemetry.Recorder()
        let parsedMainBaseline = try StorageTelemetry.$recorder.withValue(mainBaselineRec) {
            try CodestreamSyntax.parse(repeatedMainBytes, limits: .default)
        }
        #expect(parsedMainBaseline.progressionChanges.count == 8)
        let mainPOCEvents = mainBaselineRec.parserEvents.filter { $0.stage == "poc-entries" }
        #expect(mainPOCEvents.count == 2)
        #expect(mainPOCEvents[0].bytes == 32 + 4 * entryStride)
        #expect(mainPOCEvents[1].bytes == 4 * entryStride)

        // Compute exact simultaneous peak during 2nd POC growth:
        // retainedAfterSecondPOC + live payloadTransient (60 B) + live old 4-entry poc buffer (32 + 4 * stride = 224 B):
        let preTileRetained = mainBaselineRec.parserEvents
            .filter { $0.stage != "tile-part-record" }
            .reduce(0) { $0 + $1.bytes }
        let oldFourEntryBuffer = 32 + 4 * entryStride
        let peakDuringSecondMainPOC = preTileRetained + pocPayloadTransient + oldFourEntryBuffer
        // Notice peakDuringSecondMainPOC exceeds steady-state parsedMainBaseline.retainedMetadataBytes!
        #expect(peakDuringSecondMainPOC > parsedMainBaseline.retainedMetadataBytes)

        // 1 byte below simultaneous old + new + payload overlap must admit 1st POC and reject 2nd POC before allocation:
        let denySecondMainPOCRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denySecondMainPOCRec) {
                try CodestreamSyntax.parse(
                    repeatedMainBytes,
                    limits: try ResourceLimits(maximumWorkspaceBytes: peakDuringSecondMainPOC - 1)
                )
            }
            Issue.record("Expected 2nd main-header POC simultaneous old+new+payload overlap to fail at \(peakDuringSecondMainPOC - 1) B")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denySecondMainPOCRec.parserEvents.filter { $0.stage == "poc-entries" }.count == 1)

        // Exact simultaneous peak control succeeds:
        let passMainPOC = try CodestreamSyntax.parse(
            repeatedMainBytes,
            limits: try ResourceLimits(
                maximumWorkspaceBytes: peakDuringSecondMainPOC,
                maximumMemoryBytes: repeatedMainBytes.count + peakDuringSecondMainPOC
            )
        )
        #expect(passMainPOC.progressionChanges.count == 8)

        // --- 2. Repeated tile-part POC (two 4-entry POC segments inside Tile 0 header) ---
        var tileBytes = [UInt8](baseEncoded.data)
        // SOT is 12 bytes (FF90, L=000A, Isot(2), Psot(4), TPsot(1), TNsot(1)); update Psot by +2 * pocSeg.count:
        let oldPsot = (UInt32(tileBytes[sotPos + 6]) << 24)
            | (UInt32(tileBytes[sotPos + 7]) << 16)
            | (UInt32(tileBytes[sotPos + 8]) << 8)
            | UInt32(tileBytes[sotPos + 9])
        if oldPsot > 0 {
            let newPsot = oldPsot + UInt32(2 * pocSeg.count)
            tileBytes[sotPos + 6] = UInt8((newPsot >> 24) & 0xFF)
            tileBytes[sotPos + 7] = UInt8((newPsot >> 16) & 0xFF)
            tileBytes[sotPos + 8] = UInt8((newPsot >> 8) & 0xFF)
            tileBytes[sotPos + 9] = UInt8(newPsot & 0xFF)
        }
        var repeatedTilePOCBytes = Array(tileBytes[0..<(sotPos + 12)])
        repeatedTilePOCBytes.append(contentsOf: pocSeg)
        repeatedTilePOCBytes.append(contentsOf: pocSeg)
        repeatedTilePOCBytes.append(contentsOf: tileBytes[(sotPos + 12)...])

        let tileBaselineRec = StorageTelemetry.Recorder()
        let parsedTileBaseline = try StorageTelemetry.$recorder.withValue(tileBaselineRec) {
            try CodestreamSyntax.parse(repeatedTilePOCBytes, limits: .default)
        }
        #expect(parsedTileBaseline.effectiveProgressionChanges(tile: 0).count == 8)
        let tilePOCEvents = tileBaselineRec.parserEvents.filter { $0.stage == "tile-poc-entries" }
        #expect(tilePOCEvents.count == 2)

        let preTileRecordRetained = tileBaselineRec.parserEvents
            .filter { $0.stage != "tile-part-record" }
            .reduce(0) { $0 + $1.bytes }
        let peakDuringSecondTilePOC = preTileRecordRetained + pocPayloadTransient + oldFourEntryBuffer
        #expect(peakDuringSecondTilePOC > parsedTileBaseline.retainedMetadataBytes)

        let denySecondTilePOCRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denySecondTilePOCRec) {
                try CodestreamSyntax.parse(
                    repeatedTilePOCBytes,
                    limits: try ResourceLimits(maximumWorkspaceBytes: peakDuringSecondTilePOC - 1)
                )
            }
            Issue.record("Expected 2nd tile-part POC simultaneous old+new+payload overlap to fail at \(peakDuringSecondTilePOC - 1) B")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denySecondTilePOCRec.parserEvents.filter { $0.stage == "tile-poc-entries" }.count == 1)

        let passTilePOC = try CodestreamSyntax.parse(
            repeatedTilePOCBytes,
            limits: try ResourceLimits(
                maximumWorkspaceBytes: peakDuringSecondTilePOC,
                maximumMemoryBytes: repeatedTilePOCBytes.count + peakDuringSecondTilePOC
            )
        )
        #expect(passTilePOC.effectiveProgressionChanges(tile: 0).count == 8)

        // --- 3. Multi-tile HTJ2K codestream with tile-header COC overrides: validateHTSignalling uses zero extra budget ---
        let htImg = try makeGray16Image(width: 16, height: 16)
        let htConfig = try EncoderConfiguration(
            codecOptions: try CodecOptions(
                decompositionLevels: 1,
                blockCoding: .htj2k,
                tileWidth: 4,
                tileHeight: 4
            )
        )
        let htEncoded = try await SwiftJ2K.Encoder(configuration: htConfig).encode(htImg)
        let firstHTSOT = try #require(firstSOTOffset(in: htEncoded.data))

        // Valid HT COC for component 0 (Lcoc = 9, comp=0, Scoc=0, levels=1, xcb=4, ycb=4, style=0x40 HT, rev=1):
        let validHTCOC: [UInt8] = [0xFF, 0x53, 0x00, 0x09, 0x00, 0x00, 0x01, 0x04, 0x04, 0x40, 0x01]
        var htWithTileCOCs = [UInt8](htEncoded.data[0..<firstHTSOT])
        let htSrc = [UInt8](htEncoded.data)
        var cursor = firstHTSOT
        var injectedTiles = 0
        while cursor + 2 <= htSrc.count {
            let m = (UInt16(htSrc[cursor]) << 8) | UInt16(htSrc[cursor + 1])
            if m == 0xFFD9 {
                htWithTileCOCs.append(contentsOf: htSrc[cursor..<(cursor + 2)])
                break
            }
            #expect(m == 0xFF90)
            let p0 = UInt32(htSrc[cursor + 6]) << 24
            let p1 = UInt32(htSrc[cursor + 7]) << 16
            let p2 = UInt32(htSrc[cursor + 8]) << 8
            let p3 = UInt32(htSrc[cursor + 9])
            let psot = Int(p0 | p1 | p2 | p3)
            var sotHeader = Array(htSrc[cursor..<(cursor + 12)])
            if injectedTiles < 4 {
                let updatedPsot = UInt32(psot + validHTCOC.count)
                sotHeader[6] = UInt8((updatedPsot >> 24) & 0xFF)
                sotHeader[7] = UInt8((updatedPsot >> 16) & 0xFF)
                sotHeader[8] = UInt8((updatedPsot >> 8) & 0xFF)
                sotHeader[9] = UInt8(updatedPsot & 0xFF)
                htWithTileCOCs.append(contentsOf: sotHeader)
                htWithTileCOCs.append(contentsOf: validHTCOC)
                injectedTiles += 1
            } else {
                htWithTileCOCs.append(contentsOf: sotHeader)
            }
            htWithTileCOCs.append(contentsOf: htSrc[(cursor + 12)..<(cursor + psot)])
            cursor += psot
        }
        #expect(injectedTiles == 4)

        let htRec = StorageTelemetry.Recorder()
        let parsedHT = try StorageTelemetry.$recorder.withValue(htRec) {
            try CodestreamSyntax.parse(htWithTileCOCs, limits: .default)
        }
        #expect(parsedHT.tileOverrides.count == 4)
        let exactHTBudget = parsedHT.retainedMetadataBytes
        #expect(htRec.parserEvents.reduce(0) { $0 + $1.bytes } == exactHTBudget)

        // Parse succeeds at exact retainedMetadataBytes budget (validateHTSignalling requires zero post-admission workspace):
        let tightHTParsed = try CodestreamSyntax.parse(
            htWithTileCOCs,
            limits: try ResourceLimits(
                maximumWorkspaceBytes: exactHTBudget,
                maximumMemoryBytes: htWithTileCOCs.count + exactHTBudget
            )
        )
        #expect(tightHTParsed.isHTJ2K)

        // Corrupting a tile override COC in an HTONLY stream to Part 1 (style = 0x00) still fails validateHTSignalling:
        var invalidHTTileOverride = htWithTileCOCs
        let firstTileCOCStyleIdx = firstHTSOT + 12 + 9
        #expect(invalidHTTileOverride[firstTileCOCStyleIdx] == 0x40)
        invalidHTTileOverride[firstTileCOCStyleIdx] = 0x00
        do {
            _ = try CodestreamSyntax.parse(invalidHTTileOverride, limits: .default)
            Issue.record("Expected HTONLY codestream with Part 1 tile COC override to fail validateHTSignalling")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }
    }

    @Test("M12-CX-01, M12-CX-02, CLI F02/F03/F05, and M12-CI: CLI subprocess regressions")
    func cliRemediationSubprocessRegressions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("r1-cli-remediation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // --- M12-CX-01: 103-byte TIFF claiming 256x256 with 1-byte strip ---
        let badTIFF = tempDir.appendingPathComponent("bad256.tiff")
        let badOutJ2K = tempDir.appendingPathComponent("bad256.j2k")
        let craftedTIFF = makeSyntheticLittleEndianTIFF(width: 256, height: 256, bitsPerSample: 8, stripPayload: [0x7F])
        try craftedTIFF.write(to: badTIFF)

        let badTIFFLowMem = try runSwiftJ2KCLI([
            "encode", "-i", badTIFF.path, "-o", badOutJ2K.path, "--max-memory", "512"
        ])
        #expect(badTIFFLowMem.reason == .exit)
        #expect(badTIFFLowMem.status == 5, "Expected exit 5 under --max-memory 512, got \(badTIFFLowMem.status): \(badTIFFLowMem.stderrText)")

        let badTIFFDefault = try runSwiftJ2KCLI([
            "encode", "-i", badTIFF.path, "-o", badOutJ2K.path
        ])
        #expect(badTIFFDefault.reason == .exit)
        #expect(badTIFFDefault.status == 3, "Expected exit 3 for truncated strip under default budget, got \(badTIFFDefault.status)")

        // Valid 16-bit 4x4 TIFF round-trip succeeds:
        var validStrip16: [UInt8] = []
        for i in 0..<16 {
            let sample = UInt16(i * 4000)
            validStrip16.append(UInt8(truncatingIfNeeded: sample))
            validStrip16.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        let goodTIFF = tempDir.appendingPathComponent("good16.tiff")
        let goodTIFFJ2K = tempDir.appendingPathComponent("good16.j2k")
        let goodTIFFOut = tempDir.appendingPathComponent("good16-out.tiff")
        try makeSyntheticLittleEndianTIFF(width: 4, height: 4, bitsPerSample: 16, stripPayload: validStrip16)
            .write(to: goodTIFF)
        let encGoodTIFF = try runSwiftJ2KCLI(["encode", "-i", goodTIFF.path, "-o", goodTIFFJ2K.path, "--mode", "lossless"])
        #expect(encGoodTIFF.reason == .exit && encGoodTIFF.status == 0, "TIFF encode failed: \(encGoodTIFF.stderrText)")
        let decGoodTIFF = try runSwiftJ2KCLI(["decode", "-i", goodTIFFJ2K.path, "-o", goodTIFFOut.path])
        #expect(decGoodTIFF.reason == .exit && decGoodTIFF.status == 0, "TIFF decode failed: \(decGoodTIFF.stderrText)")

        // --- CLI F02: 32-bit unsigned NRRD containing 16,777,217 (2^24 + 1) lossless round-trip ---
        let nrrd32In = tempDir.appendingPathComponent("vol32.nrrd")
        let j3d32 = tempDir.appendingPathComponent("vol32.j3d")
        let nrrd32Out = tempDir.appendingPathComponent("vol32-out.nrrd")
        let header32 = "NRRD0004\ntype: uint32\ndimension: 3\nsizes: 4 4 2\nendian: little\nencoding: raw\n\n"
        var nrrd32Data = Data(header32.utf8)
        let specialValues: [UInt32] = [0, 1, 16_777_216, 16_777_217, 16_777_219, 2_147_483_647, 4_000_000_001, UInt32.max]
        for idx in 0..<(4 * 4 * 2) {
            var v = specialValues[idx % specialValues.count].littleEndian
            withUnsafeBytes(of: &v) { nrrd32Data.append(contentsOf: $0) }
        }
        try nrrd32Data.write(to: nrrd32In)

        let enc32 = try runSwiftJ2KCLI(["encode3d", "-i", nrrd32In.path, "-o", j3d32.path, "--mode", "lossless"])
        #expect(enc32.reason == .exit && enc32.status == 0, "encode3d 32-bit failed: \(enc32.stderrText)")
        let dec32 = try runSwiftJ2KCLI(["decode3d", "-i", j3d32.path, "-o", nrrd32Out.path])
        #expect(dec32.reason == .exit && dec32.status == 0, "decode3d 32-bit failed: \(dec32.stderrText)")
        let cmp32 = try runSwiftJ2KCLI([
            "compare", "-i", nrrd32Out.path, "-r", nrrd32In.path, "--mode", "3d", "--max-error", "0"
        ])
        #expect(cmp32.reason == .exit && cmp32.status == 0, "compare 3d 32-bit max-error 0 failed: \(cmp32.stderrText)")

        // --- M12-CX-02: decode3d --region Int.max overflow & out-of-bounds, --slice-range, encode --roi, jpip --region ---
        let roiOverflow3D = try runSwiftJ2KCLI([
            "decode3d", "-i", j3d32.path, "-o", nrrd32Out.path,
            "--region", "9223372036854775807,0,0,1,1,1", "--overwrite"
        ])
        #expect(roiOverflow3D.reason == .exit, "decode3d --region Int.max must exit cleanly, not trap with signal")
        #expect(roiOverflow3D.status == 2)

        let roiOOB3D = try runSwiftJ2KCLI([
            "decode3d", "-i", j3d32.path, "-o", nrrd32Out.path,
            "--region", "0,0,0,99,99,99", "--overwrite"
        ])
        #expect(roiOOB3D.reason == .exit && roiOOB3D.status == 2)

        let sliceOOB3D = try runSwiftJ2KCLI([
            "decode3d", "-i", j3d32.path, "-o", nrrd32Out.path,
            "--slice-range", "0:99", "--overwrite"
        ])
        #expect(sliceOOB3D.reason == .exit && sliceOOB3D.status == 2)

        // --- CLI F03: --resolution-level 64 rejected cleanly with exit 2 ---
        let res64Decode3D = try runSwiftJ2KCLI([
            "decode3d", "-i", j3d32.path, "-o", nrrd32Out.path,
            "--resolution-level", "64", "--overwrite"
        ])
        #expect(res64Decode3D.reason == .exit && res64Decode3D.status == 2)

        let res64JPIP = try runSwiftJ2KCLI([
            "jpip", "client", "--single-file", goodTIFFJ2K.path,
            "--resolution-level", "64", "-o", tempDir.appendingPathComponent("jpip64.tiff").path
        ])
        #expect(res64JPIP.reason == .exit && res64JPIP.status == 2)

        let jpipROIOverflow = try runSwiftJ2KCLI([
            "jpip", "client", "--single-file", goodTIFFJ2K.path,
            "--region", "9223372036854775807,0,1,1",
            "-o", tempDir.appendingPathComponent("jpip-roi.tiff").path
        ])
        #expect(jpipROIOverflow.reason == .exit && jpipROIOverflow.status == 2)

        let encROIOverflow = try runSwiftJ2KCLI([
            "encode", "-i", goodTIFF.path,
            "-o", tempDir.appendingPathComponent("roi-ov.j2k").path,
            "--roi", "9223372036854775807,0,1,1"
        ])
        #expect(encROIOverflow.reason == .exit && encROIOverflow.status == 2)

        // --- CLI F05: --max-memory 64 enforced on encode3d, decode3d, and jpip client ---
        let lowMemEnc3D = try runSwiftJ2KCLI([
            "encode3d", "-i", nrrd32In.path,
            "-o", tempDir.appendingPathComponent("lowmem.j3d").path,
            "--max-memory", "64"
        ])
        #expect(lowMemEnc3D.reason == .exit && lowMemEnc3D.status == 5)

        let lowMemDec3D = try runSwiftJ2KCLI([
            "decode3d", "-i", j3d32.path,
            "-o", tempDir.appendingPathComponent("lowmem-out.nrrd").path,
            "--max-memory", "64"
        ])
        #expect(lowMemDec3D.reason == .exit && lowMemDec3D.status == 5)

        let lowMemJPIP = try runSwiftJ2KCLI([
            "jpip", "client", "--single-file", goodTIFFJ2K.path,
            "-o", tempDir.appendingPathComponent("lowmem-jpip.tiff").path,
            "--max-memory", "64"
        ])
        #expect(lowMemJPIP.reason == .exit && lowMemJPIP.status == 5)

        // --- M12-CI: PNG CZlibShim deflate + inflate lossless round-trip ---
        let pgmIn = tempDir.appendingPathComponent("in.pgm")
        let pngIn = tempDir.appendingPathComponent("in.png")
        let pngJ2K = tempDir.appendingPathComponent("png.j2k")
        let pngOut = tempDir.appendingPathComponent("out.png")
        var pgmBytes = Data("P5\n4 4\n255\n".utf8)
        for i in 0..<16 { pgmBytes.append(UInt8(i * 15)) }
        try pgmBytes.write(to: pgmIn)

        let toPNG = try runSwiftJ2KCLI(["convert", "-i", pgmIn.path, "-o", pngIn.path])
        #expect(toPNG.reason == .exit && toPNG.status == 0, "PGM->PNG convert failed: \(toPNG.stderrText)")
        let encPNG = try runSwiftJ2KCLI(["encode", "-i", pngIn.path, "-o", pngJ2K.path, "--mode", "lossless"])
        #expect(encPNG.reason == .exit && encPNG.status == 0, "PNG->J2K encode failed: \(encPNG.stderrText)")
        let decPNG = try runSwiftJ2KCLI(["decode", "-i", pngJ2K.path, "-o", pngOut.path])
        #expect(decPNG.reason == .exit && decPNG.status == 0, "J2K->PNG decode failed: \(decPNG.stderrText)")
        let cmpPNG = try runSwiftJ2KCLI(["compare", "-i", pngOut.path, "-r", pngIn.path, "--max-error", "0"])
        #expect(cmpPNG.reason == .exit && cmpPNG.status == 0, "PNG max-error 0 compare failed: \(cmpPNG.stderrText)")
    }
}
