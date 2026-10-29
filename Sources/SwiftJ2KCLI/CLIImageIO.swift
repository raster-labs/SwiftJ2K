// SPDX-License-Identifier: Apache-2.0
//
// CLIImageIO.swift
// SwiftJ2KCLI
//
// Migrated and adapted from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/J2KCLICore/ImageIO.swift (648 lines, blob 7c76a4b52a4760880c73bfc7c816d329f2599d58)
//   - Sources/J2KCLICore/PNGSupport.swift (550 lines, blob abc9e997482ea1b5f894b029b5dae9a8cfafe016)
//   - Sources/J2KCLICore/TIFFSupport.swift (578 lines, blob 687793e98c2c023116ad3304d971eac5752d06e7)
//
// Changes relative to the predecessor:
//   - Fixed M12-AUD-001: Unified sample byte order across PGM/PPM, PNG, TIFF, RAW, and NRRD
//     via SwiftJ2K.Image descriptors so 16-bit sample values are never byte-swapped between
//     readers, writers, and metric evaluators.
//   - Fixed M12-AUD-003: Replaced external CZlib target assumption with standard `zlib` module
//     and replaced unchecked integer arithmetic in PNG/TIFF/PNM parsers with checked arithmetic
//     (`multipliedReportingOverflow`, `addingReportingOverflow`) bounded by `ResourceLimits`.
//   - Preserves exact meaningful bit depth (e.g. 10-bit and 12-bit samples) across PNM (`maxval`),
//     PNG (`sBIT` chunk), TIFF (`SMaxSampleValue` tag 341), and NRRD (`swiftj2k.meaningfulbits`)
//     without implicit display scaling.

import Foundation
import Synchronization
import SwiftJ2K
import SwiftJ2K3D
import CZlibShim

/// Uncompressed image interchange formats supported by `swiftj2k-cli`.
enum CLIUncompressedFormat: String, CaseIterable {
    case nrrd
    case pgm
    case ppm
    case pnm
    case png
    case tiff
    case raw

    init?(cliName: String) {
        switch cliName.lowercased() {
        case "nrrd": self = .nrrd
        case "pgm": self = .pgm
        case "ppm": self = .ppm
        case "pnm": self = .pnm
        case "png": self = .png
        case "tiff", "tif": self = .tiff
        case "raw", "bin": self = .raw
        default: return nil
        }
    }

    static func fromPathExtension(_ path: String) -> CLIUncompressedFormat? {
        guard path != "-" else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return CLIUncompressedFormat(cliName: ext)
    }
}

/// Magic-byte detector for uncompressed formats.
func detectUncompressedFormat(_ data: Data) -> CLIUncompressedFormat? {
    if data.count >= 8 {
        if let magic = String(data: data.prefix(8), encoding: .ascii),
           ["NRRD0001", "NRRD0002", "NRRD0003", "NRRD0004", "NRRD0005"].contains(magic) {
            return .nrrd
        }
        let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.starts(with: pngSig) {
            return .png
        }
    }
    if data.count >= 4 {
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]
        if (b0 == 0x49 && b1 == 0x49 && b2 == 0x2A && b3 == 0x00) ||
           (b0 == 0x4D && b1 == 0x4D && b2 == 0x00 && b3 == 0x2A) {
            return .tiff
        }
    }
    if data.count >= 3 {
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let isSep = (b2 == 0x20 || b2 == 0x09 || b2 == 0x0A || b2 == 0x0D || b2 == 0x23)
        if b0 == 0x50 && b1 == 0x35 && isSep {
            return .pgm
        }
        if b0 == 0x50 && b1 == 0x36 && isSep {
            return .ppm
        }
    }
    return nil
}

// MARK: - Logical Sample Accessors & Builders

func readLogicalSample(
    _ raw: UnsafeRawBufferPointer,
    descriptor d: ImageDescriptor,
    component c: Int,
    x: Int,
    y: Int
) -> Int {
    let signed = (d.sampleType == .signedInteger)
    let planeIndex = (d.planes.count == 1) ? 0 : c
    let plane = d.planes[planeIndex]
    let compOffset = (d.planes.count == 1 && d.components.count > 1) ? (c * plane.sampleStride) : 0
    let byteOffset = plane.offset + y * plane.rowBytes + x * plane.pixelStride + compOffset
    if d.storageBits == 8 {
        let b = raw[byteOffset]
        return signed ? Int(Int8(bitPattern: b)) : Int(b)
    } else {
        let b0 = UInt16(raw[byteOffset])
        let b1 = UInt16(raw[byteOffset + 1])
        let word = (d.byteOrder == .littleEndian) ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
        return signed ? Int(Int16(bitPattern: word)) : Int(word)
    }
}

enum CLIImageIOTelemetry {
    struct Event: Sendable, Equatable {
        enum Action: String, Sendable, Equatable {
            case enter
            case exit
        }
        let stage: String
        let action: Action
        let deltaBytes: Int
        let liveWorkspaceBytes: Int
        let liveTotalBytes: Int
        let liveTagOwners: Int

        init(
            stage: String,
            action: Action,
            deltaBytes: Int,
            liveWorkspaceBytes: Int,
            liveTotalBytes: Int,
            liveTagOwners: Int = 0
        ) {
            self.stage = stage
            self.action = action
            self.deltaBytes = deltaBytes
            self.liveWorkspaceBytes = liveWorkspaceBytes
            self.liveTotalBytes = liveTotalBytes
            self.liveTagOwners = liveTagOwners
        }
    }

    fileprivate struct State: Sendable {
        var events: [Event] = []
        var inputBytes: Int = 0
        var liveWorkspaceBytes: Int = 0
        var liveDecodedBytes: Int = 0
        var liveTagOwners: Int = 0
        var peakWorkspaceBytes: Int = 0
        var peakDecodedBytes: Int = 0
        var peakTotalBytes: Int = 0
        var peakTagOwners: Int = 0
    }

    final class Recorder: Sendable {
        private let state = Mutex(State())

        init() {}

        var events: [Event] { state.withLock { $0.events } }
        var liveWorkspaceBytes: Int { state.withLock { $0.liveWorkspaceBytes } }
        var liveDecodedBytes: Int { state.withLock { $0.liveDecodedBytes } }
        var liveTagOwners: Int { state.withLock { $0.liveTagOwners } }
        var peakWorkspaceBytes: Int { state.withLock { $0.peakWorkspaceBytes } }
        var peakDecodedBytes: Int { state.withLock { $0.peakDecodedBytes } }
        var peakTotalBytes: Int { state.withLock { $0.peakTotalBytes } }
        var peakTagOwners: Int { state.withLock { $0.peakTagOwners } }

        func setInputBytes(_ bytes: Int) {
            state.withLock { s in
                s.inputBytes = max(0, bytes)
                let total = s.inputBytes + s.liveWorkspaceBytes + s.liveDecodedBytes
                if total > s.peakTotalBytes {
                    s.peakTotalBytes = total
                }
            }
        }

        func enter(
            stage: String,
            workspaceBytes: Int,
            basePlusOtherLiveBytes: Int,
            tagOwnerDelta: Int = 0
        ) {
            state.withLock { s in
                s.liveWorkspaceBytes += workspaceBytes
                if s.liveWorkspaceBytes > s.peakWorkspaceBytes {
                    s.peakWorkspaceBytes = s.liveWorkspaceBytes
                }
                if tagOwnerDelta > 0 {
                    s.liveTagOwners += tagOwnerDelta
                    if s.liveTagOwners > s.peakTagOwners {
                        s.peakTagOwners = s.liveTagOwners
                    }
                }
                let nonWorkspace = max(basePlusOtherLiveBytes, s.inputBytes + s.liveDecodedBytes)
                let total = nonWorkspace + s.liveWorkspaceBytes
                if total > s.peakTotalBytes {
                    s.peakTotalBytes = total
                }
                s.events.append(Event(
                    stage: stage,
                    action: .enter,
                    deltaBytes: workspaceBytes,
                    liveWorkspaceBytes: s.liveWorkspaceBytes,
                    liveTotalBytes: total,
                    liveTagOwners: s.liveTagOwners
                ))
            }
            #if SWIFT_PACKAGE
            if workspaceBytes > 0 {
                StorageTelemetry.recordParserAllocation(stage: stage, bytes: workspaceBytes)
            }
            #endif
        }

        func enterDecoded(stage: String, decodedBytes: Int) {
            state.withLock { s in
                s.liveDecodedBytes += decodedBytes
                if s.liveDecodedBytes > s.peakDecodedBytes {
                    s.peakDecodedBytes = s.liveDecodedBytes
                }
                let total = s.inputBytes + s.liveWorkspaceBytes + s.liveDecodedBytes
                if total > s.peakTotalBytes {
                    s.peakTotalBytes = total
                }
                s.events.append(Event(
                    stage: stage,
                    action: .enter,
                    deltaBytes: decodedBytes,
                    liveWorkspaceBytes: s.liveWorkspaceBytes,
                    liveTotalBytes: total,
                    liveTagOwners: s.liveTagOwners
                ))
            }
        }

        func exit(
            stage: String,
            workspaceBytes: Int,
            basePlusOtherLiveBytes: Int,
            tagOwnerDelta: Int = 0
        ) {
            state.withLock { s in
                s.liveWorkspaceBytes = max(0, s.liveWorkspaceBytes - workspaceBytes)
                if tagOwnerDelta > 0 {
                    s.liveTagOwners = max(0, s.liveTagOwners - tagOwnerDelta)
                }
                let nonWorkspace = max(basePlusOtherLiveBytes, s.inputBytes + s.liveDecodedBytes)
                let total = nonWorkspace + s.liveWorkspaceBytes
                if total > s.peakTotalBytes {
                    s.peakTotalBytes = total
                }
                s.events.append(Event(
                    stage: stage,
                    action: .exit,
                    deltaBytes: workspaceBytes,
                    liveWorkspaceBytes: s.liveWorkspaceBytes,
                    liveTotalBytes: total,
                    liveTagOwners: s.liveTagOwners
                ))
            }
        }
    }

    @TaskLocal static var recorder: Recorder?

    @inline(__always)
    static func setInputBytes(_ bytes: Int) {
        recorder?.setInputBytes(bytes)
    }

    @inline(__always)
    static func enter(
        stage: String,
        workspaceBytes: Int,
        basePlusOtherLiveBytes: Int,
        tagOwnerDelta: Int = 0
    ) {
        if let recorder {
            recorder.enter(
                stage: stage,
                workspaceBytes: workspaceBytes,
                basePlusOtherLiveBytes: basePlusOtherLiveBytes,
                tagOwnerDelta: tagOwnerDelta
            )
        } else {
            #if SWIFT_PACKAGE
            if workspaceBytes > 0 {
                StorageTelemetry.recordParserAllocation(stage: stage, bytes: workspaceBytes)
            }
            #endif
        }
    }

    @inline(__always)
    static func enterDecoded(stage: String, decodedBytes: Int) {
        recorder?.enterDecoded(stage: stage, decodedBytes: decodedBytes)
    }

    @inline(__always)
    static func exit(
        stage: String,
        workspaceBytes: Int,
        basePlusOtherLiveBytes: Int,
        tagOwnerDelta: Int = 0
    ) {
        recorder?.exit(
            stage: stage,
            workspaceBytes: workspaceBytes,
            basePlusOtherLiveBytes: basePlusOtherLiveBytes,
            tagOwnerDelta: tagOwnerDelta
        )
    }
}

func makeContractImageDescriptor(
    width: Int,
    height: Int,
    componentCount: Int,
    meaningfulBits: Int,
    signed: Bool,
    alpha: AlphaInterpretation = .absent,
    limits: ResourceLimits
) throws -> ImageDescriptor {
    guard width > 0, height > 0 else {
        throw CodecError(.unsupportedFeature, "Image dimensions must be positive.")
    }
    guard (1...16).contains(meaningfulBits) else {
        throw CodecError(.unsupportedFeature, "Meaningful bits must be in 1...16.")
    }
    guard componentCount >= 1 else {
        throw CodecError(.unsupportedFeature, "Component count must be at least 1.")
    }
    let storageBits = (componentCount == 1) ? 16 : (meaningfulBits <= 8 ? 8 : 16)
    let sampleType: SampleType = signed ? .signedInteger : .unsignedInteger
    if componentCount == 1 {
        return signed
            ? try ImageDescriptor.signedGreyscale16(width: width, height: height, meaningfulBits: meaningfulBits, limits: limits)
            : try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: meaningfulBits, limits: limits)
    } else if componentCount == 2 && alpha != .absent && !signed {
        let baseDesc = try ImageDescriptor.multiComponentPlanar(
            width: width, height: height, componentCount: 2,
            storageBits: storageBits, meaningfulBits: meaningfulBits,
            sampleType: sampleType, limits: limits
        )
        return try ImageDescriptor(
            width: width,
            height: height,
            sampleType: sampleType,
            storageBits: storageBits,
            meaningfulBits: meaningfulBits,
            byteOrder: baseDesc.byteOrder,
            components: [.grey, .alpha],
            colour: .greyscale,
            alpha: alpha,
            planes: baseDesc.planes,
            limits: limits
        )
    } else if componentCount == 3 {
        return try ImageDescriptor.rgbPlanar(
            width: width, height: height, storageBits: storageBits,
            meaningfulBits: meaningfulBits, signed: signed, limits: limits
        )
    } else if componentCount == 4 && alpha != .absent {
        return try ImageDescriptor.rgbPlanar(
            width: width, height: height, storageBits: storageBits,
            meaningfulBits: meaningfulBits, signed: signed, alpha: alpha, limits: limits
        )
    } else {
        return try ImageDescriptor.multiComponentPlanar(
            width: width, height: height, componentCount: componentCount,
            storageBits: storageBits, meaningfulBits: meaningfulBits,
            sampleType: sampleType, limits: limits
        )
    }
}

func makeContractImage(
    descriptor: ImageDescriptor,
    limits: ResourceLimits,
    sampleAt: (_ component: Int, _ x: Int, _ y: Int) throws -> Int
) throws -> Image {
    let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
    CLIImageIOTelemetry.enterDecoded(stage: "image-destination", decodedBytes: descriptor.requiredByteCount)
    return try destination.writeSamples { c, x, y in
        try sampleAt(c, x, y)
    }
}

func makeContractImage(
    width: Int,
    height: Int,
    componentCount: Int,
    meaningfulBits: Int,
    signed: Bool,
    alpha: AlphaInterpretation = .absent,
    limits: ResourceLimits,
    sampleAt: (_ component: Int, _ x: Int, _ y: Int) throws -> Int
) throws -> Image {
    let descriptor = try makeContractImageDescriptor(
        width: width,
        height: height,
        componentCount: componentCount,
        meaningfulBits: meaningfulBits,
        signed: signed,
        alpha: alpha,
        limits: limits
    )
    return try makeContractImage(descriptor: descriptor, limits: limits, sampleAt: sampleAt)
}

func checkedMultiply(_ a: Int, _ b: Int, label: String = "Image dimension") throws -> Int {
    let (res, ov) = a.multipliedReportingOverflow(by: b)
    guard !ov else {
        throw CodecError(.malformedInput, "\(label) multiplication overflowed.")
    }
    return res
}

func checkedAdd(_ a: Int, _ b: Int, label: String = "Image offset") throws -> Int {
    let (res, ov) = a.addingReportingOverflow(b)
    guard !ov else {
        throw CodecError(.malformedInput, "\(label) addition overflowed.")
    }
    return res
}

// MARK: - PGM (P5) and PPM (P6) Reader & Writer

func parsePGMOrPPM(
    _ data: Data,
    declaredPrecision: Int?,
    limits: ResourceLimits
) throws -> (Image, CLIUncompressedFormat) {
    guard data.count <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "PNM input size (\(data.count) B) exceeds memory limit.")
    }
    return try data.withUnsafeBytes { rawBuf -> (Image, CLIUncompressedFormat) in
        guard rawBuf.count >= 7,
              let bytes = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw CodecError(.malformedInput, "PNM input is too short.")
        }
        let byteCount = rawBuf.count
        var idx = 0
        func isWS(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
        }
        func nextToken() throws -> String {
            while idx < byteCount {
                if isWS(bytes[idx]) {
                    idx += 1
                } else if bytes[idx] == 0x23 { // '#' comment
                    while idx < byteCount && bytes[idx] != 0x0A {
                        idx += 1
                    }
                } else {
                    break
                }
            }
            guard idx < byteCount else {
                throw CodecError(.malformedInput, "Unexpected end of PNM header.")
            }
            let start = idx
            while idx < byteCount && !isWS(bytes[idx]) && bytes[idx] != 0x23 {
                idx += 1
            }
            let slice = UnsafeBufferPointer(start: bytes + start, count: idx - start)
            guard let token = String(bytes: slice, encoding: .ascii) else {
                throw CodecError(.malformedInput, "Invalid ASCII in PNM header.")
            }
            return token
        }

        let magic = try nextToken()
        let components: Int
        let detectedFormat: CLIUncompressedFormat
        switch magic {
        case "P5":
            components = 1
            detectedFormat = .pgm
        case "P6":
            components = 3
            detectedFormat = .ppm
        default:
            throw CodecError(.unsupportedFormat, "Only binary P5 (PGM) and P6 (PPM) Netpbm formats are supported.")
        }

        guard let width = Int(try nextToken()),
              let height = Int(try nextToken()),
              let maxVal = Int(try nextToken()),
              width > 0, height > 0 else {
            throw CodecError(.malformedInput, "Invalid width, height, or maxval in PNM header.")
        }
        guard maxVal >= 1 && maxVal <= 65535 else {
            throw CodecError(.malformedInput, "PNM maxval must be in 1...65535.")
        }
        if idx < byteCount && bytes[idx] == 0x23 {
            while idx < byteCount && bytes[idx] != 0x0A { idx += 1 }
        }
        guard idx < byteCount && isWS(bytes[idx]) else {
            throw CodecError(.malformedInput, "Missing whitespace separator after PNM maxval.")
        }
        if bytes[idx] == 0x0D && idx + 1 < byteCount && bytes[idx + 1] == 0x0A {
            idx += 2
        } else {
            idx += 1
        }

        let inferredBits = max(1, min(16, Int.bitWidth - maxVal.leadingZeroBitCount))
        let meaningfulBits = declaredPrecision ?? inferredBits
        let bytesPerSample = (maxVal <= 255) ? 1 : 2
        if bytesPerSample == 1 && meaningfulBits > 8 {
            throw CodecError(.unsupportedFeature, "Declared precision exceeds 8-bit PNM storage.")
        }

        let descriptor = try makeContractImageDescriptor(
            width: width,
            height: height,
            componentCount: components,
            meaningfulBits: meaningfulBits,
            signed: false,
            limits: limits
        )
        let totalLiveBytes = try checkedAdd(data.count, descriptor.requiredByteCount, label: "PNM live memory")
        guard totalLiveBytes <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "PNM live memory (\(totalLiveBytes) B) exceeds memory limit.")
        }

        let pixelCount = try checkedMultiply(width, height, label: "PNM pixel count")
        let sampleCount = try checkedMultiply(pixelCount, components, label: "PNM sample count")
        let expectedBytes = try checkedMultiply(sampleCount, bytesPerSample, label: "PNM byte count")
        let remaining = byteCount - idx
        guard remaining == expectedBytes else {
            throw CodecError(.malformedInput, "PNM raster byte length does not match header geometry.")
        }

        let maxAllowedSample = (1 << meaningfulBits) - 1
        let rasterStart = idx
        let image = try makeContractImage(
            descriptor: descriptor,
            limits: limits
        ) { c, x, y in
            let sampleIndex = (y * width + x) * components + c
            let v: Int
            if bytesPerSample == 1 {
                v = Int(bytes[rasterStart + sampleIndex])
            } else {
                let off = rasterStart + sampleIndex * 2
                v = (Int(bytes[off]) << 8) | Int(bytes[off + 1])
            }
            return min(maxAllowedSample, max(0, v))
        }
        return (image, detectedFormat)
    }
}

func formatPGM(_ image: Image) throws -> Data {
    let d = image.descriptor
    guard d.components.count == 1 else {
        throw CodecError(.unsupportedFeature, "PGM format requires a 1-component greyscale image.")
    }
    guard d.sampleType == .unsignedInteger else {
        throw CodecError(.unsupportedFormat, "PGM format requires unsigned integer samples.")
    }
    let maxVal = (1 << d.meaningfulBits) - 1
    let header = "P5\n\(d.width) \(d.height)\n\(maxVal)\n"
    var out = Data(header.utf8)
    let bytesPerSample = (d.meaningfulBits <= 8) ? 1 : 2
    let pixelCount = try checkedMultiply(d.width, d.height)
    let rasterBytes = try checkedMultiply(pixelCount, bytesPerSample)
    out.reserveCapacity(out.count + rasterBytes)
    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            for x in 0..<d.width {
                let val = max(0, min(maxVal, readLogicalSample(raw, descriptor: d, component: 0, x: x, y: y)))
                if bytesPerSample == 1 {
                    out.append(UInt8(truncatingIfNeeded: val))
                } else {
                    out.append(UInt8(truncatingIfNeeded: (val >> 8) & 0xFF))
                    out.append(UInt8(truncatingIfNeeded: val & 0xFF))
                }
            }
        }
    }
    return out
}

func formatPPM(_ image: Image) throws -> Data {
    let d = image.descriptor
    guard d.components.count == 3 else {
        throw CodecError(.unsupportedFeature, "PPM format requires a 3-component RGB image.")
    }
    guard d.sampleType == .unsignedInteger else {
        throw CodecError(.unsupportedFormat, "PPM format requires unsigned integer samples.")
    }
    let maxVal = (1 << d.meaningfulBits) - 1
    let header = "P6\n\(d.width) \(d.height)\n\(maxVal)\n"
    var out = Data(header.utf8)
    let bytesPerSample = (d.meaningfulBits <= 8) ? 1 : 2
    let pixelCount = try checkedMultiply(d.width, d.height)
    let sampleCount = try checkedMultiply(pixelCount, 3)
    let rasterBytes = try checkedMultiply(sampleCount, bytesPerSample)
    out.reserveCapacity(out.count + rasterBytes)
    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            for x in 0..<d.width {
                for c in 0..<3 {
                    let val = max(0, min(maxVal, readLogicalSample(raw, descriptor: d, component: c, x: x, y: y)))
                    if bytesPerSample == 1 {
                        out.append(UInt8(truncatingIfNeeded: val))
                    } else {
                        out.append(UInt8(truncatingIfNeeded: (val >> 8) & 0xFF))
                        out.append(UInt8(truncatingIfNeeded: val & 0xFF))
                    }
                }
            }
        }
    }
    return out
}

func formatPNM(_ image: Image) throws -> Data {
    switch image.descriptor.components.count {
    case 1: return try formatPGM(image)
    case 3: return try formatPPM(image)
    default:
        throw CodecError(.unsupportedFeature, "PNM format supports 1 (PGM) or 3 (PPM) components.")
    }
}

// MARK: - PNG Reader & Writer (ISO/IEC 15948)

func parsePNG(
    _ data: Data,
    declaredPrecision: Int?,
    limits: ResourceLimits
) throws -> Image {
    guard data.count <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "PNG input size (\(data.count) B) exceeds memory limit.")
    }
    CLIImageIOTelemetry.setInputBytes(data.count)
    defer { CLIImageIOTelemetry.setInputBytes(0) }

    var width = 0
    var height = 0
    var bitDepth = 0
    var colorType = 0
    var headerParsed = false
    var sbitSeen = false
    var idatSeen = false
    var sbitDepth: Int?
    var idatCompressed = Data()
    var idatAdmittedBytes = 0
    defer {
        if idatAdmittedBytes > 0 {
            CLIImageIOTelemetry.exit(stage: "png-idat-buffer", workspaceBytes: idatAdmittedBytes, basePlusOtherLiveBytes: data.count)
        }
    }

    try data.withUnsafeBytes { rawBuf in
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard rawBuf.count >= 8,
              let bytes = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw CodecError(.malformedInput, "Invalid PNG signature.")
        }
        for i in 0..<8 where bytes[i] != signature[i] {
            throw CodecError(.malformedInput, "Invalid PNG signature.")
        }
        let byteCount = rawBuf.count

        func readBE32(at pos: Int) throws -> Int {
            let end = try checkedAdd(pos, 4, label: "PNG uint32")
            guard end <= byteCount else {
                throw CodecError(.malformedInput, "Truncated PNG chunk header.")
            }
            let u = (UInt32(bytes[pos]) << 24) |
                    (UInt32(bytes[pos + 1]) << 16) |
                    (UInt32(bytes[pos + 2]) << 8) |
                    UInt32(bytes[pos + 3])
            return Int(u)
        }

        var offset = 8
        var iendSeen = false
        while offset < byteCount {
            let chunkHeaderEnd = try checkedAdd(offset, 8, label: "PNG chunk header")
            guard chunkHeaderEnd <= byteCount else {
                throw CodecError(.malformedInput, "Truncated PNG chunk header.")
            }
            let chunkLen = try readBE32(at: offset)
            guard chunkLen >= 0, chunkLen <= limits.maximumCompressedBytes else {
                throw CodecError(.resourceLimitExceeded, "PNG chunk length exceeds compressed byte limit.")
            }
            let typeSlice = UnsafeBufferPointer(start: bytes + offset + 4, count: 4)
            let chunkType = String(bytes: typeSlice, encoding: .ascii) ?? ""
            let dataStart = chunkHeaderEnd
            let dataEnd = try checkedAdd(dataStart, chunkLen, label: "PNG chunk data")
            let chunkEnd = try checkedAdd(dataEnd, 4, label: "PNG chunk CRC")
            guard chunkEnd <= byteCount else {
                throw CodecError(.malformedInput, "Truncated PNG chunk payload.")
            }

            switch chunkType {
            case "IHDR":
                guard !headerParsed, chunkLen == 13 else {
                    throw CodecError(.malformedInput, "Invalid PNG IHDR chunk.")
                }
                width = try readBE32(at: dataStart)
                height = try readBE32(at: dataStart + 4)
                bitDepth = Int(bytes[dataStart + 8])
                colorType = Int(bytes[dataStart + 9])
                let compression = bytes[dataStart + 10]
                let filter = bytes[dataStart + 11]
                let interlace = bytes[dataStart + 12]

                guard width > 0, height > 0 else {
                    throw CodecError(.malformedInput, "PNG dimensions must be positive.")
                }
                guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
                    throw CodecError(.resourceLimitExceeded, "PNG dimensions exceed resource limit.")
                }
                guard compression == 0, filter == 0 else {
                    throw CodecError(.malformedInput, "Invalid PNG compression or filter method.")
                }
                guard interlace == 0 else {
                    throw CodecError(.unsupportedFormat, "Interlaced (Adam7) PNG files are not supported.")
                }
                guard bitDepth == 8 || bitDepth == 16 else {
                    throw CodecError(.unsupportedFeature, "Only 8-bit and 16-bit PNG files are supported.")
                }
                guard [0, 2, 4, 6].contains(colorType) else {
                    throw CodecError(.unsupportedFormat, "Indexed-colour (palette) PNG files are not supported.")
                }
                headerParsed = true

            case "sBIT":
                // W3C PNG §11.3.2.4: sBIT must appear after IHDR, before PLTE/IDAT, and at most once.
                guard headerParsed, !idatSeen, !sbitSeen else {
                    throw CodecError(.malformedInput, "Invalid or misplaced PNG sBIT chunk.")
                }
                let expectedSbitBytes: Int
                switch colorType {
                case 0: expectedSbitBytes = 1
                case 2: expectedSbitBytes = 3
                case 4: expectedSbitBytes = 2
                case 6: expectedSbitBytes = 4
                default:
                    throw CodecError(.unsupportedFormat, "Unsupported PNG colour type for sBIT.")
                }
                guard chunkLen == expectedSbitBytes else {
                    throw CodecError(
                        .malformedInput,
                        "PNG sBIT chunk length (\(chunkLen)) does not match colour type \(colorType) (expected \(expectedSbitBytes))."
                    )
                }
                let firstSig = Int(bytes[dataStart])
                for cIdx in 0..<expectedSbitBytes {
                    let sb = Int(bytes[dataStart + cIdx])
                    guard sb >= 1, sb <= bitDepth else {
                        throw CodecError(
                            .malformedInput,
                            "PNG sBIT significant bit count (\(sb)) must lie in 1...\(bitDepth)."
                        )
                    }
                    if sb != firstSig {
                        throw CodecError(
                            .unsupportedFeature,
                            "Unequal per-channel PNG sBIT depths are not supported by uniform ImageDescriptor."
                        )
                    }
                }
                sbitDepth = firstSig
                sbitSeen = true

            case "IDAT":
                guard headerParsed else {
                    throw CodecError(.malformedInput, "PNG IDAT chunk appeared before IHDR.")
                }
                idatSeen = true
                let newCount = try checkedAdd(idatCompressed.count, chunkLen, label: "PNG IDAT total")
                let liveWithIDAT = try checkedAdd(data.count, newCount, label: "PNG input and IDAT memory")
                guard newCount <= limits.maximumCompressedBytes,
                      newCount <= limits.maximumWorkspaceBytes,
                      liveWithIDAT <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, "PNG IDAT stream exceeds compressed, workspace, or memory limit.")
                }
                if chunkLen > 0 {
                    CLIImageIOTelemetry.enter(stage: "png-idat-buffer", workspaceBytes: chunkLen, basePlusOtherLiveBytes: data.count)
                    idatAdmittedBytes += chunkLen
                    idatCompressed.append(bytes + dataStart, count: chunkLen)
                }

            case "IEND":
                iendSeen = true

            default:
                break
            }
            offset = chunkEnd
            if iendSeen { break }
        }
    }

    guard headerParsed, !idatCompressed.isEmpty else {
        throw CodecError(.malformedInput, "PNG file is missing IHDR or IDAT chunks.")
    }

    let channels: Int
    let pngAlpha: AlphaInterpretation
    switch colorType {
    case 0: (channels, pngAlpha) = (1, .absent)
    case 2: (channels, pngAlpha) = (3, .absent)
    case 4: (channels, pngAlpha) = (2, .straight)
    case 6: (channels, pngAlpha) = (4, .straight)
    default:
        throw CodecError(.unsupportedFormat, "Unsupported PNG colour type.")
    }

    if let dp = declaredPrecision {
        guard (1...bitDepth).contains(dp) else {
            throw CodecError(.invalidArgument, "Declared precision (\(dp)) is outside PNG storage bit depth 1...\(bitDepth).")
        }
        if let sb = sbitDepth, dp != sb {
            throw CodecError(.invalidArgument, "Declared precision (\(dp)) conflicts with PNG sBIT chunk (\(sb)).")
        }
    }
    let meaningfulBits = declaredPrecision ?? sbitDepth ?? bitDepth
    guard (1...bitDepth).contains(meaningfulBits) else {
        throw CodecError(.invalidArgument, "Invalid PNG meaningful precision (\(meaningfulBits)).")
    }

    let descriptor = try makeContractImageDescriptor(
        width: width,
        height: height,
        componentCount: channels,
        meaningfulBits: meaningfulBits,
        signed: false,
        alpha: pngAlpha,
        limits: limits
    )
    let destBytes = descriptor.requiredByteCount

    let bytesPerSample = bitDepth / 8
    let bpp = try checkedMultiply(channels, bytesPerSample, label: "PNG bytes per pixel")
    let scanlineBytes = try checkedMultiply(width, bpp, label: "PNG scanline bytes")
    let strideWithFilter = try checkedAdd(scanlineBytes, 1, label: "PNG scanline stride")
    let expectedDecompressedSize = try checkedMultiply(height, strideWithFilter, label: "PNG decompressed size")

    let inflateWorkspace = try checkedAdd(idatAdmittedBytes, expectedDecompressedSize, label: "PNG inflate workspace")
    let inflateMemory = try checkedAdd(data.count, inflateWorkspace, label: "PNG inflate live memory")
    let decodeWorkspacePlusDest = try checkedAdd(expectedDecompressedSize, destBytes, label: "PNG decode buffers")
    let decodeMemory = try checkedAdd(data.count, decodeWorkspacePlusDest, label: "PNG decode live memory")
    guard inflateWorkspace <= limits.maximumWorkspaceBytes,
          expectedDecompressedSize <= limits.maximumWorkspaceBytes,
          inflateMemory <= limits.maximumMemoryBytes,
          decodeMemory <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "PNG decompressed scanlines and destination exceed workspace or memory limit.")
    }

    CLIImageIOTelemetry.enter(stage: "png-scanline-workspace", workspaceBytes: expectedDecompressedSize, basePlusOtherLiveBytes: data.count)
    var scanlinesExited = false
    defer {
        if !scanlinesExited {
            CLIImageIOTelemetry.exit(stage: "png-scanline-workspace", workspaceBytes: expectedDecompressedSize, basePlusOtherLiveBytes: data.count)
        }
    }

    var rawScanlines = try zlibInflateBounded(idatCompressed, expectedSize: expectedDecompressedSize)
    // Release compressed IDAT stream immediately after inflation before allocating ImageDestination.
    idatCompressed = Data()
    if idatAdmittedBytes > 0 {
        CLIImageIOTelemetry.exit(stage: "png-idat-buffer", workspaceBytes: idatAdmittedBytes, basePlusOtherLiveBytes: data.count)
        idatAdmittedBytes = 0
    }

    guard rawScanlines.count == expectedDecompressedSize else {
        throw CodecError(.malformedInput, "Decompressed PNG IDAT size does not match image geometry.")
    }

    // Reconstruct PNG scanlines in-place inside rawScanlines (zero duplicate unfiltered buffer).
    try rawScanlines.withUnsafeMutableBytes { rawBuf in
        guard let buf = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for row in 0..<height {
            let srcRowStart = row * strideWithFilter
            let filterType = buf[srcRowStart]
            let rowPixels = srcRowStart + 1
            let prevRowPixels = (row - 1) * strideWithFilter + 1

            for i in 0..<scanlineBytes {
                let rawByte = Int(buf[rowPixels + i])
                let a: Int = (i >= bpp) ? Int(buf[rowPixels + i - bpp]) : 0
                let b: Int = (row > 0) ? Int(buf[prevRowPixels + i]) : 0
                let c: Int = (row > 0 && i >= bpp) ? Int(buf[prevRowPixels + i - bpp]) : 0

                let recon: Int
                switch filterType {
                case 0: recon = rawByte
                case 1: recon = (rawByte + a) & 0xFF
                case 2: recon = (rawByte + b) & 0xFF
                case 3: recon = (rawByte + ((a + b) >> 1)) & 0xFF
                case 4: recon = (rawByte + paethPredictor(a: a, b: b, c: c)) & 0xFF
                default:
                    throw CodecError(.malformedInput, "Invalid PNG row filter type \(filterType).")
                }
                buf[rowPixels + i] = UInt8(truncatingIfNeeded: recon)
            }
        }
    }

    let maxAllowedSample = (1 << meaningfulBits) - 1
    let sbitShift: Int = {
        if let sb = sbitDepth, sb < bitDepth {
            return bitDepth - sb
        }
        return 0
    }()
    let image = try rawScanlines.withUnsafeBytes { rawBuf -> Image in
        let buf = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
        return try makeContractImage(
            descriptor: descriptor,
            limits: limits
        ) { c, x, y in
            let rowPixels = y * strideWithFilter + 1
            let sampleInRow = x * channels + c
            let rawSample: Int
            if bytesPerSample == 1 {
                rawSample = Int(buf[rowPixels + sampleInRow])
            } else {
                let off = rowPixels + sampleInRow * 2
                rawSample = (Int(buf[off]) << 8) | Int(buf[off + 1])
            }
            if sbitShift > 0 {
                // W3C PNG §11.3.2.4 & §12.4: significant bits are stored in the most-significant bits;
                // right-shift by (bitDepth - sBIT) to recover the exact original sBIT-bit sample.
                return rawSample >> sbitShift
            }
            guard rawSample >= 0, rawSample <= maxAllowedSample else {
                throw CodecError(
                    .invalidArgument,
                    "PNG sample value (\(rawSample)) exceeds declared precision \(meaningfulBits) (max \(maxAllowedSample)) without an sBIT chunk."
                )
            }
            return rawSample
        }
    }
    rawScanlines = Data()
    CLIImageIOTelemetry.exit(stage: "png-scanline-workspace", workspaceBytes: expectedDecompressedSize, basePlusOtherLiveBytes: data.count + destBytes)
    scanlinesExited = true
    return image
}

/// Scales an `s`-bit unsigned sample (`0...(1<<s)-1`) into `dBits`-bit PNG storage (`8` or `16`)
/// via normative W3C PNG §12.4 left-bit replication so `0 -> 0`, `maxVal -> (1<<dBits)-1`, and
/// `scaled >> (dBits - s) == value` bit-identically.
@inline(__always)
private func scalePNGSampleLeftBitReplication(_ value: Int, fromBits s: Int, toBits dBits: Int) -> Int {
    if s == dBits { return value }
    var acc = 0
    var remaining = dBits
    while remaining >= s {
        acc = (acc << s) | value
        remaining -= s
    }
    if remaining > 0 {
        acc = (acc << remaining) | (value >> (s - remaining))
    }
    return acc
}

func formatPNG(_ image: Image) throws -> Data {
    let d = image.descriptor
    guard d.sampleType == .unsignedInteger else {
        throw CodecError(.unsupportedFormat, "PNG output requires unsigned integer samples.")
    }
    let channels = d.components.count
    let colorType: UInt8
    switch channels {
    case 1: colorType = 0
    case 2: colorType = 4
    case 3: colorType = 2
    case 4: colorType = 6
    default:
        throw CodecError(.unsupportedFeature, "PNG output supports 1, 2, 3, or 4 components.")
    }

    let pngBitDepth = (d.meaningfulBits <= 8) ? 8 : 16
    let bytesPerSample = pngBitDepth / 8
    let bpp = try checkedMultiply(channels, bytesPerSample)
    let scanlineBytes = try checkedMultiply(d.width, bpp)
    let strideWithFilter = try checkedAdd(scanlineBytes, 1)
    let totalRawBytes = try checkedMultiply(d.height, strideWithFilter)
    let maxVal = (1 << d.meaningfulBits) - 1

    var rawFiltered = [UInt8](repeating: 0, count: totalRawBytes)
    var currentRow = [UInt8](repeating: 0, count: scanlineBytes)

    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            var byteIdx = 0
            for x in 0..<d.width {
                for c in 0..<channels {
                    let rawSample = readLogicalSample(raw, descriptor: d, component: c, x: x, y: y)
                    guard rawSample >= 0, rawSample <= maxVal else {
                        throw CodecError(
                            .invalidArgument,
                            "Logical sample (\(rawSample)) lies outside meaningful precision 0...\(maxVal)."
                        )
                    }
                    let v = scalePNGSampleLeftBitReplication(
                        rawSample,
                        fromBits: d.meaningfulBits,
                        toBits: pngBitDepth
                    )
                    if bytesPerSample == 1 {
                        currentRow[byteIdx] = UInt8(truncatingIfNeeded: v)
                        byteIdx += 1
                    } else {
                        currentRow[byteIdx] = UInt8(truncatingIfNeeded: (v >> 8) & 0xFF)
                        currentRow[byteIdx + 1] = UInt8(truncatingIfNeeded: v & 0xFF)
                        byteIdx += 2
                    }
                }
            }
            let rowDst = y * strideWithFilter
            // Filter 1 (Sub) provides fast, deterministic compression.
            rawFiltered[rowDst] = 1
            for i in 0..<scanlineBytes {
                let a: UInt8 = (i >= bpp) ? currentRow[i - bpp] : 0
                rawFiltered[rowDst + 1 + i] = currentRow[i] &- a
            }
        }
    }

    let compressedIDAT = try zlibDeflate(Data(rawFiltered))

    var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var ihdr = Data(capacity: 13)
    appendBE32(&ihdr, UInt32(d.width))
    appendBE32(&ihdr, UInt32(d.height))
    ihdr.append(UInt8(pngBitDepth))
    ihdr.append(colorType)
    ihdr.append(0) // compression
    ihdr.append(0) // filter
    ihdr.append(0) // interlace
    appendPNGChunk(&out, type: "IHDR", data: ihdr)

    if d.meaningfulBits != pngBitDepth {
        let sbit = Data(repeating: UInt8(d.meaningfulBits), count: channels)
        appendPNGChunk(&out, type: "sBIT", data: sbit)
    }

    appendPNGChunk(&out, type: "IDAT", data: compressedIDAT)
    appendPNGChunk(&out, type: "IEND", data: Data())
    return out
}

private func paethPredictor(a: Int, b: Int, c: Int) -> Int {
    let p = a + b - c
    let pa = abs(p - a)
    let pb = abs(p - b)
    let pc = abs(p - c)
    if pa <= pb && pa <= pc { return a }
    if pb <= pc { return b }
    return c
}

private func appendBE32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendPNGChunk(_ out: inout Data, type: String, data: Data) {
    appendBE32(&out, UInt32(data.count))
    let typeBytes = Data(type.utf8)
    out.append(typeBytes)
    out.append(data)
    var crcInput = Data(capacity: typeBytes.count + data.count)
    crcInput.append(typeBytes)
    crcInput.append(data)
    appendBE32(&out, pngCRC32(crcInput))
}

private func pngCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        let idx = Int((crc ^ UInt32(byte)) & 0xFF)
        var c = UInt32(idx)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        crc = c ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

func zlibInflateBounded(_ compressed: Data, expectedSize: Int) throws -> Data {
    guard expectedSize > 0 else { return Data() }
    guard compressed.count <= Int(uInt.max), expectedSize <= Int(uInt.max) else {
        throw CodecError(.resourceLimitExceeded, "PNG zlib stream exceeds 32-bit chunk bound.")
    }
    var output = Data(count: expectedSize)
    var stream = z_stream()
    let initStatus = inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else {
        throw CodecError(.internalFailure, "zlib inflateInit failed.")
    }
    defer { _ = inflateEnd(&stream) }

    let totalOut: Int = try compressed.withUnsafeBytes { srcRaw in
        try output.withUnsafeMutableBytes { dstRaw in
            guard let srcBase = srcRaw.baseAddress?.assumingMemoryBound(to: Bytef.self),
                  let dstBase = dstRaw.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                throw CodecError(.malformedInput, "Empty PNG compressed stream.")
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcBase)
            stream.avail_in = uInt(compressed.count)
            stream.next_out = dstBase
            stream.avail_out = uInt(expectedSize)
            let status = inflate(&stream, Z_FINISH)
            guard status == Z_STREAM_END || (status == Z_OK && stream.avail_out == 0) else {
                throw CodecError(.malformedInput, "Corrupt PNG zlib stream (status \(status)).")
            }
            return Int(stream.total_out)
        }
    }
    output.count = totalOut
    return output
}

private func zlibDeflate(_ raw: Data) throws -> Data {
    let bound = compressBound(uLong(raw.count))
    var destLen = bound
    var output = Data(count: Int(bound))
    let status: Int32 = raw.withUnsafeBytes { srcRaw in
        output.withUnsafeMutableBytes { dstRaw in
            guard let srcBase = srcRaw.baseAddress?.assumingMemoryBound(to: Bytef.self),
                  let dstBase = dstRaw.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                return Z_MEM_ERROR
            }
            return compress2(dstBase, &destLen, srcBase, uLong(raw.count), Z_DEFAULT_COMPRESSION)
        }
    }
    guard status == Z_OK else {
        throw CodecError(.internalFailure, "zlib compress2 failed (status \(status)).")
    }
    output.count = Int(destLen)
    return output
}

// MARK: - TIFF Reader & Writer (Baseline Uncompressed TIFF 6.0)

private final class TIFFOwnedTagList {
    private(set) var values: [Int]
    let byteCount: Int
    private let stage: String
    private let baseInputBytes: Int
    private weak var capturedRecorder: CLIImageIOTelemetry.Recorder?

    init(
        count: Int,
        byteCount: Int,
        stage: String,
        baseInputBytes: Int,
        readElement: (Int) throws -> Int
    ) throws {
        self.values = []
        self.byteCount = byteCount
        self.stage = stage
        self.baseInputBytes = baseInputBytes
        self.capturedRecorder = CLIImageIOTelemetry.recorder
        CLIImageIOTelemetry.enter(
            stage: stage,
            workspaceBytes: byteCount,
            basePlusOtherLiveBytes: baseInputBytes,
            tagOwnerDelta: 1
        )
        self.values.reserveCapacity(count)
        for idx in 0..<count {
            self.values.append(try readElement(idx))
        }
    }

    deinit {
        (CLIImageIOTelemetry.recorder ?? capturedRecorder)?.exit(
            stage: stage,
            workspaceBytes: byteCount,
            basePlusOtherLiveBytes: baseInputBytes,
            tagOwnerDelta: 1
        )
    }
}

private final class TIFFOwnedStripBuffer {
    var bytes: [UInt8]
    let byteCount: Int
    private let baseInputBytes: Int
    var exitExtraLiveBytes: Int = 0
    private weak var capturedRecorder: CLIImageIOTelemetry.Recorder?

    init(byteCount: Int, baseInputBytes: Int) {
        self.bytes = []
        self.byteCount = byteCount
        self.baseInputBytes = baseInputBytes
        self.capturedRecorder = CLIImageIOTelemetry.recorder
        CLIImageIOTelemetry.enter(
            stage: "tiff-strip-workspace",
            workspaceBytes: byteCount,
            basePlusOtherLiveBytes: baseInputBytes
        )
        self.bytes = [UInt8](repeating: 0, count: byteCount)
    }

    deinit {
        (CLIImageIOTelemetry.recorder ?? capturedRecorder)?.exit(
            stage: "tiff-strip-workspace",
            workspaceBytes: byteCount,
            basePlusOtherLiveBytes: baseInputBytes + exitExtraLiveBytes
        )
    }
}

private enum TIFFStripList {
    case empty
    case single(Int)
    case many(TIFFOwnedTagList)

    var count: Int {
        switch self {
        case .empty: return 0
        case .single: return 1
        case .many(let owned): return owned.values.count
        }
    }

    var heapBytes: Int {
        switch self {
        case .empty, .single: return 0
        case .many(let owned): return owned.byteCount
        }
    }

    var isMany: Bool {
        if case .many = self { return true }
        return false
    }
}

private func decodeTIFFSampleFromBuffer(
    _ src: UnsafePointer<UInt8>,
    baseOffset: Int,
    sampleIdx: Int,
    bps: Int,
    isLE: Bool,
    signed: Bool
) -> Int {
    if bps == 8 {
        let b = src[baseOffset + sampleIdx]
        return signed ? Int(Int8(bitPattern: b)) : Int(b)
    } else if bps == 16 {
        let p = baseOffset + sampleIdx * 2
        let word: UInt16 = isLE
            ? (UInt16(src[p]) | (UInt16(src[p + 1]) << 8))
            : ((UInt16(src[p]) << 8) | UInt16(src[p + 1]))
        return signed ? Int(Int16(bitPattern: word)) : Int(word)
    } else {
        let pairIdx = sampleIdx / 2
        let base = baseOffset + pairIdx * 3
        var s: Int
        if sampleIdx % 2 == 0 {
            let b0 = Int(src[base])
            let b1 = Int(src[base + 1])
            s = (b0 << 4) | (b1 >> 4)
        } else {
            let b1 = Int(src[base + 1])
            let b2 = Int(src[base + 2])
            s = ((b1 & 0x0F) << 8) | b2
        }
        if signed && s >= 2048 {
            s -= 4096
        }
        return s
    }
}

@inline(never)
private func assembleTIFFMultiStripWorkspace(
    stripOffsets: inout TIFFStripList,
    stripByteCounts: inout TIFFStripList,
    retainedTagBytes: inout Int,
    bytes: UnsafePointer<UInt8>,
    byteCount: Int,
    inputByteCount: Int,
    neededBytes: Int,
    destBytes: Int,
    limits: ResourceLimits
) throws -> TIFFOwnedStripBuffer {
    // Admit combined live buffers:
    // Phase A (strip assembly): input Data + retained tag arrays + strip workspace
    // Phase B (destination fill after tag owners deinit): input Data + strip workspace + ImageDestination
    let assemblyWorkspace = try checkedAdd(retainedTagBytes, neededBytes, label: "TIFF multi-strip workspace")
    let assemblyMemory = try checkedAdd(inputByteCount, assemblyWorkspace, label: "TIFF strip assembly memory")
    let stripPlusDest = try checkedAdd(neededBytes, destBytes, label: "TIFF strip and destination bytes")
    let decodeMemory = try checkedAdd(inputByteCount, stripPlusDest, label: "TIFF multi-strip decode memory")
    guard assemblyWorkspace <= limits.maximumWorkspaceBytes,
          assemblyMemory <= limits.maximumMemoryBytes,
          decodeMemory <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "TIFF multi-strip workspace or simultaneous live memory exceeds resource limits.")
    }

    let stripWorkspace: TIFFOwnedStripBuffer = try {
        guard case .many(let offsetsOwner) = stripOffsets,
              case .many(let countsOwner) = stripByteCounts else {
            throw CodecError(.malformedInput, "TIFF missing or mismatched StripOffsets and StripByteCounts.")
        }

        var totalStripBytes = 0
        for (off, cnt) in zip(offsetsOwner.values, countsOwner.values) {
            guard off >= 0, cnt >= 0 else {
                throw CodecError(.malformedInput, "Negative TIFF strip offset or byte count.")
            }
            let end = try checkedAdd(off, cnt, label: "TIFF strip end")
            guard end <= byteCount else {
                throw CodecError(.malformedInput, "TIFF strip extends past end of file.")
            }
            totalStripBytes = try checkedAdd(totalStripBytes, cnt, label: "TIFF strip total")
        }
        guard totalStripBytes >= neededBytes else {
            throw CodecError(.malformedInput, "TIFF strip data (\(totalStripBytes) B) is shorter than required sample bytes (\(neededBytes) B).")
        }

        let ws = TIFFOwnedStripBuffer(byteCount: neededBytes, baseInputBytes: inputByteCount)
        ws.bytes.withUnsafeMutableBufferPointer { dstBuf in
            guard let dstBase = dstBuf.baseAddress else { return }
            var written = 0
            for (off, cnt) in zip(offsetsOwner.values, countsOwner.values) where written < neededBytes {
                let take = min(cnt, neededBytes - written)
                if take > 0 {
                    dstBase.advanced(by: written).update(from: bytes + off, count: take)
                    written += take
                }
            }
        }
        return ws
    }()

    // Clear caller tag references in deterministic order so offsetsOwner and countsOwner lose
    // their final strong references and deinit prior to returning to decodeTIFFFromStripWorkspace.
    stripOffsets = .empty
    stripByteCounts = .empty
    retainedTagBytes = 0
    return stripWorkspace
}

private enum TIFFPhotometricMode {
    case direct(minAllowed: Int, maxAllowed: Int, hasDeclaredPrecision: Bool)
    case whiteIsZero(maxSample: Int, hasDeclaredPrecision: Bool)
    case palette(
        fileBytes: UnsafePointer<UInt8>,
        colorMapValPos: Int,
        paletteEntries: Int,
        isLE: Bool,
        output8Bit: Bool
    )
}

@inline(__always)
private func decodeTIFFLogicalSample(
    stripSrc: UnsafePointer<UInt8>,
    baseOffset: Int,
    component c: Int,
    x: Int,
    y: Int,
    width w: Int,
    pixelCount: Int,
    samplesPerPixel: Int,
    planarConfig: Int,
    bps: Int,
    isLE: Bool,
    signed: Bool,
    photometricMode: TIFFPhotometricMode
) throws -> Int {
    switch photometricMode {
    case .direct(let minAllowed, let maxAllowed, let hasDeclaredPrecision):
        let pixelIdx = y * w + x
        let sampleIdx = (planarConfig == 2)
            ? (c * pixelCount + pixelIdx)
            : (pixelIdx * samplesPerPixel + c)
        let raw = decodeTIFFSampleFromBuffer(
            stripSrc,
            baseOffset: baseOffset,
            sampleIdx: sampleIdx,
            bps: bps,
            isLE: isLE,
            signed: signed
        )
        guard raw >= minAllowed, raw <= maxAllowed else {
            throw CodecError(
                hasDeclaredPrecision ? .invalidArgument : .malformedInput,
                "TIFF sample value (\(raw)) lies outside meaningful precision range \(minAllowed)...\(maxAllowed)."
            )
        }
        return raw

    case .whiteIsZero(let maxSample, let hasDeclaredPrecision):
        let pixelIdx = y * w + x
        let sampleIdx = (planarConfig == 2)
            ? (c * pixelCount + pixelIdx)
            : (pixelIdx * samplesPerPixel + c)
        let raw = decodeTIFFSampleFromBuffer(
            stripSrc,
            baseOffset: baseOffset,
            sampleIdx: sampleIdx,
            bps: bps,
            isLE: isLE,
            signed: false
        )
        guard raw >= 0, raw <= maxSample else {
            throw CodecError(
                hasDeclaredPrecision ? .invalidArgument : .malformedInput,
                "TIFF WhiteIsZero sample value (\(raw)) lies outside 0...\(maxSample)."
            )
        }
        // Invert luminance channel 0 (0 = white -> maxSample, maxSample = black -> 0);
        // preserve any extra alpha channel (c == 1) uninverted.
        return (c == 0) ? (maxSample - raw) : raw

    case .palette(let fileBytes, let colorMapValPos, let paletteEntries, let mapIsLE, let output8Bit):
        let idx: Int
        if bps == 4 {
            let rowBytes = (w + 1) / 2
            let b = stripSrc[baseOffset + y * rowBytes + (x / 2)]
            idx = (x % 2 == 0) ? Int((b >> 4) & 0x0F) : Int(b & 0x0F)
        } else {
            idx = decodeTIFFSampleFromBuffer(
                stripSrc,
                baseOffset: baseOffset,
                sampleIdx: y * w + x,
                bps: bps,
                isLE: isLE,
                signed: false
            )
        }
        guard idx >= 0, idx < paletteEntries else {
            throw CodecError(.malformedInput, "TIFF palette index (\(idx)) is outside ColorMap range 0..<\(paletteEntries).")
        }
        let p = colorMapValPos + (c * paletteEntries + idx) * 2
        let entry: UInt16 = mapIsLE
            ? (UInt16(fileBytes[p]) | (UInt16(fileBytes[p + 1]) << 8))
            : ((UInt16(fileBytes[p]) << 8) | UInt16(fileBytes[p + 1]))
        return output8Bit ? Int(entry & 0xFF) : Int(entry)
    }
}

@inline(never)
private func decodeTIFFFromStripWorkspace(
    _ stripWorkspace: TIFFOwnedStripBuffer,
    descriptor: ImageDescriptor,
    limits: ResourceLimits,
    width w: Int,
    pixelCount: Int,
    samplesPerPixel: Int,
    planarConfig: Int,
    bps: Int,
    isLE: Bool,
    signed: Bool,
    photometricMode: TIFFPhotometricMode
) throws -> Image {
    let image = try stripWorkspace.bytes.withUnsafeBufferPointer { stripBuf -> Image in
        guard let stripPtr = stripBuf.baseAddress else {
            throw CodecError(.internalFailure, "Empty TIFF strip workspace buffer.")
        }
        return try makeContractImage(
            descriptor: descriptor,
            limits: limits
        ) { c, x, y in
            try decodeTIFFLogicalSample(
                stripSrc: stripPtr,
                baseOffset: 0,
                component: c,
                x: x,
                y: y,
                width: w,
                pixelCount: pixelCount,
                samplesPerPixel: samplesPerPixel,
                planarConfig: planarConfig,
                bps: bps,
                isLE: isLE,
                signed: signed,
                photometricMode: photometricMode
            )
        }
    }
    stripWorkspace.exitExtraLiveBytes = descriptor.requiredByteCount
    return image
}

func parseTIFF(
    _ data: Data,
    declaredPrecision: Int?,
    limits: ResourceLimits
) throws -> Image {
    guard data.count <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "TIFF input size (\(data.count) B) exceeds memory limit (\(limits.maximumMemoryBytes) B).")
    }
    CLIImageIOTelemetry.setInputBytes(data.count)
    defer { CLIImageIOTelemetry.setInputBytes(0) }

    return try data.withUnsafeBytes { rawBuf -> Image in
        guard rawBuf.count >= 8,
              let bytes = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw CodecError(.malformedInput, "TIFF input is too short.")
        }
        let byteCount = rawBuf.count
        let isLE: Bool
        if bytes[0] == 0x49 && bytes[1] == 0x49 {
            isLE = true
        } else if bytes[0] == 0x4D && bytes[1] == 0x4D {
            isLE = false
        } else {
            throw CodecError(.malformedInput, "Invalid TIFF byte-order mark.")
        }

        func readU16(_ pos: Int) throws -> UInt16 {
            let end = try checkedAdd(pos, 2, label: "TIFF uint16")
            guard pos >= 0, end <= byteCount else {
                throw CodecError(.malformedInput, "TIFF read out of bounds.")
            }
            return isLE
                ? (UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8))
                : ((UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1]))
        }

        func readU32(_ pos: Int) throws -> UInt32 {
            let end = try checkedAdd(pos, 4, label: "TIFF uint32")
            guard pos >= 0, end <= byteCount else {
                throw CodecError(.malformedInput, "TIFF read out of bounds.")
            }
            if isLE {
                return UInt32(bytes[pos]) |
                       (UInt32(bytes[pos + 1]) << 8) |
                       (UInt32(bytes[pos + 2]) << 16) |
                       (UInt32(bytes[pos + 3]) << 24)
            } else {
                return (UInt32(bytes[pos]) << 24) |
                       (UInt32(bytes[pos + 1]) << 16) |
                       (UInt32(bytes[pos + 2]) << 8) |
                       UInt32(bytes[pos + 3])
            }
        }

        guard try readU16(2) == 42 else {
            throw CodecError(.malformedInput, "Invalid TIFF magic number (expected 42).")
        }

        let ifdOffset = Int(try readU32(4))
        let countEnd = try checkedAdd(ifdOffset, 2, label: "TIFF IFD count")
        guard ifdOffset >= 8, countEnd <= byteCount else {
            throw CodecError(.malformedInput, "Invalid TIFF IFD offset.")
        }
        let entryCount = Int(try readU16(ifdOffset))
        let entriesBytes = try checkedMultiply(entryCount, 12, label: "TIFF IFD entries")
        let entriesEnd = try checkedAdd(countEnd, entriesBytes, label: "TIFF IFD end")
        guard entriesEnd <= byteCount else {
            throw CodecError(.malformedInput, "TIFF IFD entries extend past end of file.")
        }

        func resolveTagSpan(entryOffset: Int, fieldType: UInt16, count: Int) throws -> (valPos: Int, typeSize: Int)? {
            guard count > 0 else {
                throw CodecError(.malformedInput, "Invalid TIFF tag value count.")
            }
            let typeSize: Int
            switch fieldType {
            case 1, 6, 7: typeSize = 1
            case 3, 8: typeSize = 2
            case 4, 9: typeSize = 4
            default: return nil
            }
            let totalBytes = try checkedMultiply(count, typeSize, label: "TIFF tag payload")
            let valPos: Int
            if totalBytes <= 4 {
                valPos = entryOffset + 8
            } else {
                valPos = Int(try readU32(entryOffset + 8))
            }
            let valEnd = try checkedAdd(valPos, totalBytes, label: "TIFF tag array end")
            guard valPos >= 0, valEnd <= byteCount else {
                throw CodecError(.malformedInput, "TIFF tag value offset out of bounds.")
            }
            return (valPos, typeSize)
        }

        func readTagElement(valPos: Int, typeSize: Int, fieldType: UInt16, index: Int) throws -> Int {
            let p = valPos + index * typeSize
            switch fieldType {
            case 1, 7: return Int(bytes[p])
            case 6: return Int(Int8(bitPattern: bytes[p]))
            case 3: return Int(try readU16(p))
            case 8: return Int(Int16(bitPattern: try readU16(p)))
            case 4: return Int(try readU32(p))
            case 9: return Int(Int32(bitPattern: try readU32(p)))
            default: return 0
            }
        }

        func readFirstTagScalar(entryOffset: Int, fieldType: UInt16, count: Int) throws -> Int? {
            guard let span = try resolveTagSpan(entryOffset: entryOffset, fieldType: fieldType, count: count) else {
                return nil
            }
            return try readTagElement(valPos: span.valPos, typeSize: span.typeSize, fieldType: fieldType, index: 0)
        }

        var retainedTagBytes = 0

        func readStripTagList(
            entryOffset: Int,
            fieldType: UInt16,
            count: Int,
            stage: String,
            existingBytes: Int
        ) throws -> TIFFStripList {
            guard let span = try resolveTagSpan(entryOffset: entryOffset, fieldType: fieldType, count: count) else {
                retainedTagBytes = max(0, retainedTagBytes - existingBytes)
                return .empty
            }
            if count == 1 {
                let singleVal = try readTagElement(valPos: span.valPos, typeSize: span.typeSize, fieldType: fieldType, index: 0)
                retainedTagBytes = max(0, retainedTagBytes - existingBytes)
                return .single(singleVal)
            }
            let arrayMem = try checkedMultiply(count, MemoryLayout<Int>.stride, label: "TIFF tag array memory")
            // While constructing the replacement tag list, the caller still owns any previous tag list
            // (`existingBytes` included in `retainedTagBytes`) until assignment completes.
            // Admit simultaneous `retainedTagBytes + arrayMem` before allocating `[Int]`.
            let overlapRetained = try checkedAdd(retainedTagBytes, arrayMem, label: "TIFF simultaneous tag memory")
            let liveWithOverlap = try checkedAdd(data.count, overlapRetained, label: "TIFF input and simultaneous tag memory")
            guard overlapRetained <= limits.maximumMetadataBytes,
                  overlapRetained <= limits.maximumWorkspaceBytes,
                  liveWithOverlap <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "TIFF tag arrays (\(overlapRetained) B) exceed metadata, workspace, or memory limit.")
            }

            let owned = try TIFFOwnedTagList(
                count: count,
                byteCount: arrayMem,
                stage: stage,
                baseInputBytes: data.count
            ) { idx in
                try readTagElement(valPos: span.valPos, typeSize: span.typeSize, fieldType: fieldType, index: idx)
            }
            retainedTagBytes = max(0, retainedTagBytes - existingBytes) + arrayMem
            return .many(owned)
        }

        var width: Int?
        var height: Int?
        var bps = 8
        var bpsChannelCount = 1
        var compression = 1
        var photometric: Int?
        var fillOrder = 1
        var samplesPerPixel = 1
        var stripOffsets: TIFFStripList = .empty
        var stripByteCounts: TIFFStripList = .empty
        var planarConfig = 1
        var colorMapInfo: (valPos: Int, fieldType: UInt16, count: Int)?
        var extraSampleTypes: [Int] = []
        var sampleFormat = 1
        var sMaxSampleValue: Int?

        for i in 0..<entryCount {
            let entryPos = countEnd + i * 12
            let tag = try readU16(entryPos)
            let fieldType = try readU16(entryPos + 2)
            let count = Int(try readU32(entryPos + 4))
            switch tag {
            case 256:
                width = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count)
            case 257:
                height = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count)
            case 258:
                guard let span = try resolveTagSpan(entryOffset: entryPos, fieldType: fieldType, count: count) else {
                    throw CodecError(.malformedInput, "Invalid TIFF BitsPerSample tag (258).")
                }
                let first = try readTagElement(valPos: span.valPos, typeSize: span.typeSize, fieldType: fieldType, index: 0)
                for cIdx in 1..<count {
                    let other = try readTagElement(valPos: span.valPos, typeSize: span.typeSize, fieldType: fieldType, index: cIdx)
                    if other != first {
                        throw CodecError(.unsupportedFeature, "Mixed per-channel TIFF BitsPerSample (\(first) vs \(other)) is not supported.")
                    }
                }
                bps = first
                bpsChannelCount = count
            case 259:
                if let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count) {
                    compression = v
                }
            case 262:
                guard count == 1,
                      let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count) else {
                    throw CodecError(.malformedInput, "Invalid TIFF PhotometricInterpretation tag (262).")
                }
                photometric = v
            case 266:
                if let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count) {
                    fillOrder = v
                }
            case 273:
                stripOffsets = try readStripTagList(
                    entryOffset: entryPos,
                    fieldType: fieldType,
                    count: count,
                    stage: "tiff-strip-offsets",
                    existingBytes: stripOffsets.heapBytes
                )
            case 277:
                if let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count) {
                    samplesPerPixel = v
                }
            case 279:
                stripByteCounts = try readStripTagList(
                    entryOffset: entryPos,
                    fieldType: fieldType,
                    count: count,
                    stage: "tiff-strip-byte-counts",
                    existingBytes: stripByteCounts.heapBytes
                )
            case 284:
                if let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count) {
                    planarConfig = v
                }
            case 320:
                guard let span = try resolveTagSpan(entryOffset: entryPos, fieldType: fieldType, count: count) else {
                    throw CodecError(.malformedInput, "Invalid TIFF ColorMap tag (320).")
                }
                colorMapInfo = (valPos: span.valPos, fieldType: fieldType, count: count)
            case 338:
                guard count <= 16,
                      let span = try resolveTagSpan(entryOffset: entryPos, fieldType: fieldType, count: count) else {
                    throw CodecError(.malformedInput, "Invalid TIFF ExtraSamples tag (338).")
                }
                extraSampleTypes = []
                extraSampleTypes.reserveCapacity(count)
                for idx in 0..<count {
                    extraSampleTypes.append(
                        try readTagElement(valPos: span.valPos, typeSize: span.typeSize, fieldType: fieldType, index: idx)
                    )
                }
            case 339:
                if let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count) {
                    sampleFormat = v
                }
            case 341:
                if let v = try readFirstTagScalar(entryOffset: entryPos, fieldType: fieldType, count: count), v > 0 {
                    sMaxSampleValue = v
                }
            default:
                _ = try resolveTagSpan(entryOffset: entryPos, fieldType: fieldType, count: count)
            }
        }

        guard let w = width, let h = height, w > 0, h > 0 else {
            throw CodecError(.malformedInput, "TIFF missing valid ImageWidth or ImageLength.")
        }
        guard w <= limits.maximumDimension, h <= limits.maximumDimension else {
            throw CodecError(.resourceLimitExceeded, "TIFF dimensions exceed resource limit.")
        }
        guard compression == 1 else {
            throw CodecError(.unsupportedFormat, "Compressed TIFF (compression=\(compression)) is not supported; use uncompressed TIFF.")
        }
        guard fillOrder == 1 else {
            throw CodecError(.unsupportedFeature, "TIFF FillOrder (\(fillOrder)) != 1 is not supported.")
        }
        guard let photo = photometric else {
            throw CodecError(.malformedInput, "TIFF missing required PhotometricInterpretation tag (262).")
        }
        guard (1...4).contains(samplesPerPixel) else {
            throw CodecError(.unsupportedFeature, "TIFF SamplesPerPixel (\(samplesPerPixel)) must be in 1...4.")
        }
        if bpsChannelCount > 1 && bpsChannelCount != samplesPerPixel {
            throw CodecError(.malformedInput, "TIFF BitsPerSample count (\(bpsChannelCount)) does not match SamplesPerPixel (\(samplesPerPixel)).")
        }
        guard planarConfig == 1 || planarConfig == 2 else {
            throw CodecError(.unsupportedFormat, "Unsupported TIFF PlanarConfiguration (\(planarConfig)).")
        }
        guard sampleFormat == 1 || sampleFormat == 2 else {
            throw CodecError(.unsupportedFormat, "Floating-point or unsupported TIFF SampleFormat (\(sampleFormat)).")
        }
        let signed = (sampleFormat == 2)
        guard stripOffsets.count > 0, stripOffsets.count == stripByteCounts.count else {
            throw CodecError(.malformedInput, "TIFF missing or mismatched StripOffsets and StripByteCounts.")
        }

        func resolveAlphaMode() throws -> AlphaInterpretation {
            if extraSampleTypes.isEmpty {
                return .straight
            }
            guard extraSampleTypes.count == 1 else {
                throw CodecError(.unsupportedFeature, "Multiple TIFF ExtraSamples channels (\(extraSampleTypes.count)) are not supported.")
            }
            switch extraSampleTypes[0] {
            case 1: return .premultiplied
            case 0, 2: return .straight
            default:
                throw CodecError(.unsupportedFeature, "Unsupported TIFF ExtraSamples value (\(extraSampleTypes[0])).")
            }
        }

        let pixelCount = try checkedMultiply(w, h, label: "TIFF pixel count")
        guard pixelCount <= limits.maximumPixels else {
            throw CodecError(.resourceLimitExceeded, "TIFF pixel count (\(pixelCount)) exceeds pixel limit (\(limits.maximumPixels)).")
        }

        let outputComponentCount: Int
        let outputSigned: Bool
        let outputMeaningfulBits: Int
        let outputAlpha: AlphaInterpretation
        let photometricMode: TIFFPhotometricMode
        let neededBytes: Int

        switch photo {
        case 0, 1: // 0 = WhiteIsZero, 1 = BlackIsZero
            guard samplesPerPixel == 1 || samplesPerPixel == 2 else {
                throw CodecError(
                    .malformedInput,
                    "TIFF \(photo == 0 ? "WhiteIsZero" : "BlackIsZero") PhotometricInterpretation requires 1 or 2 SamplesPerPixel, got \(samplesPerPixel)."
                )
            }
            guard bps == 8 || bps == 12 || bps == 16 else {
                throw CodecError(.unsupportedFeature, "Unsupported TIFF BitsPerSample (\(bps)); expected 8, 12, or 16.")
            }
            if photo == 0 && signed {
                throw CodecError(.unsupportedFeature, "Signed TIFF WhiteIsZero is not supported.")
            }
            if samplesPerPixel == 1 && !extraSampleTypes.isEmpty {
                throw CodecError(.malformedInput, "TIFF ExtraSamples specified without an extra channel in SamplesPerPixel.")
            }
            outputAlpha = (samplesPerPixel == 2) ? try resolveAlphaMode() : .absent
            if samplesPerPixel == 2 && signed {
                throw CodecError(.unsupportedFeature, "Signed greyscale+alpha TIFF is not supported.")
            }

            let inferredBits: Int
            if let smax = sMaxSampleValue, smax > 0, smax < 65535 {
                let bits = Int.bitWidth - smax.leadingZeroBitCount
                inferredBits = signed ? min(16, bits + 1) : max(1, min(16, bits))
            } else {
                inferredBits = bps
            }
            if let dp = declaredPrecision {
                guard (1...bps).contains(dp) else {
                    throw CodecError(.invalidArgument, "Declared precision (\(dp)) is outside TIFF BitsPerSample 1...\(bps).")
                }
            }
            outputMeaningfulBits = declaredPrecision ?? inferredBits
            guard (1...16).contains(outputMeaningfulBits) else {
                throw CodecError(.unsupportedFeature, "Invalid TIFF meaningful bit depth.")
            }
            outputComponentCount = samplesPerPixel
            outputSigned = signed

            if photo == 0 {
                let maxSample = (1 << outputMeaningfulBits) - 1
                photometricMode = .whiteIsZero(maxSample: maxSample, hasDeclaredPrecision: declaredPrecision != nil)
            } else {
                let minAllowed = signed ? -(1 << (outputMeaningfulBits - 1)) : 0
                let maxAllowed = signed ? ((1 << (outputMeaningfulBits - 1)) - 1) : ((1 << outputMeaningfulBits) - 1)
                photometricMode = .direct(minAllowed: minAllowed, maxAllowed: maxAllowed, hasDeclaredPrecision: declaredPrecision != nil)
            }

            let totalSamples = try checkedMultiply(pixelCount, samplesPerPixel, label: "TIFF sample count")
            if bps == 8 {
                neededBytes = totalSamples
            } else if bps == 16 {
                neededBytes = try checkedMultiply(totalSamples, 2, label: "TIFF 16-bit byte count")
            } else {
                let pairs = totalSamples / 2
                let rem = totalSamples % 2
                let pairBytes = try checkedMultiply(pairs, 3, label: "TIFF 12-bit packed pair byte count")
                neededBytes = try checkedAdd(pairBytes, rem == 1 ? 2 : 0, label: "TIFF 12-bit byte count")
            }

        case 2: // RGB
            guard samplesPerPixel == 3 || samplesPerPixel == 4 else {
                throw CodecError(
                    .malformedInput,
                    "TIFF RGB PhotometricInterpretation requires 3 or 4 SamplesPerPixel, got \(samplesPerPixel)."
                )
            }
            guard bps == 8 || bps == 12 || bps == 16 else {
                throw CodecError(.unsupportedFeature, "Unsupported TIFF BitsPerSample (\(bps)); expected 8, 12, or 16.")
            }
            if samplesPerPixel == 3 && !extraSampleTypes.isEmpty {
                throw CodecError(.malformedInput, "TIFF ExtraSamples specified without a 4th channel in SamplesPerPixel.")
            }
            outputAlpha = (samplesPerPixel == 4) ? try resolveAlphaMode() : .absent

            let inferredBits: Int
            if let smax = sMaxSampleValue, smax > 0, smax < 65535 {
                let bits = Int.bitWidth - smax.leadingZeroBitCount
                inferredBits = signed ? min(16, bits + 1) : max(1, min(16, bits))
            } else {
                inferredBits = bps
            }
            if let dp = declaredPrecision {
                guard (1...bps).contains(dp) else {
                    throw CodecError(.invalidArgument, "Declared precision (\(dp)) is outside TIFF BitsPerSample 1...\(bps).")
                }
            }
            outputMeaningfulBits = declaredPrecision ?? inferredBits
            guard (1...16).contains(outputMeaningfulBits) else {
                throw CodecError(.unsupportedFeature, "Invalid TIFF meaningful bit depth.")
            }
            outputComponentCount = samplesPerPixel
            outputSigned = signed

            let minAllowed = signed ? -(1 << (outputMeaningfulBits - 1)) : 0
            let maxAllowed = signed ? ((1 << (outputMeaningfulBits - 1)) - 1) : ((1 << outputMeaningfulBits) - 1)
            photometricMode = .direct(minAllowed: minAllowed, maxAllowed: maxAllowed, hasDeclaredPrecision: declaredPrecision != nil)

            let totalSamples = try checkedMultiply(pixelCount, samplesPerPixel, label: "TIFF sample count")
            if bps == 8 {
                neededBytes = totalSamples
            } else if bps == 16 {
                neededBytes = try checkedMultiply(totalSamples, 2, label: "TIFF 16-bit byte count")
            } else {
                let pairs = totalSamples / 2
                let rem = totalSamples % 2
                let pairBytes = try checkedMultiply(pairs, 3, label: "TIFF 12-bit packed pair byte count")
                neededBytes = try checkedAdd(pairBytes, rem == 1 ? 2 : 0, label: "TIFF 12-bit byte count")
            }

        case 3: // Palette Color
            guard !signed else {
                throw CodecError(.unsupportedFeature, "Signed TIFF Palette Color is not supported.")
            }
            guard samplesPerPixel == 1, extraSampleTypes.isEmpty else {
                throw CodecError(.malformedInput, "TIFF Palette Color requires SamplesPerPixel == 1 without ExtraSamples.")
            }
            guard bps == 4 || bps == 8 || bps == 16 else {
                throw CodecError(.unsupportedFeature, "Unsupported TIFF Palette Color BitsPerSample (\(bps)); expected 4, 8, or 16.")
            }
            let paletteEntries = 1 << bps
            let expectedMapCount = 3 * paletteEntries
            guard let cmap = colorMapInfo,
                  cmap.fieldType == 3,
                  cmap.count == expectedMapCount else {
                throw CodecError(
                    .malformedInput,
                    "TIFF Palette Color requires ColorMap tag (320) of SHORT with \(expectedMapCount) entries."
                )
            }
            let cmapBytes = try checkedMultiply(expectedMapCount, 2, label: "TIFF ColorMap byte count")
            let totalMetaBytes = try checkedAdd(retainedTagBytes, cmapBytes, label: "TIFF ColorMap metadata budget")
            guard totalMetaBytes <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "TIFF ColorMap exceeds metadata byte limit.")
            }

            // TIFF 6.0 §5 stores 16-bit ColorMap entries; 8-bit palettes replicate v * 257 = (v << 8) | v.
            var allReplicated8Bit = true
            for entryIdx in 0..<expectedMapCount {
                let w16 = try readU16(cmap.valPos + entryIdx * 2)
                if (w16 >> 8) != (w16 & 0xFF) {
                    allReplicated8Bit = false
                    break
                }
            }
            let output8Bit: Bool
            if let dp = declaredPrecision {
                if dp == 8 && allReplicated8Bit {
                    output8Bit = true
                } else if dp == 16 {
                    output8Bit = false
                } else {
                    throw CodecError(
                        .invalidArgument,
                        "Declared precision (\(dp)) is incompatible with TIFF ColorMap precision."
                    )
                }
                outputMeaningfulBits = dp
            } else {
                output8Bit = allReplicated8Bit
                outputMeaningfulBits = allReplicated8Bit ? 8 : 16
            }
            outputComponentCount = 3
            outputSigned = false
            outputAlpha = .absent
            photometricMode = .palette(
                fileBytes: bytes,
                colorMapValPos: cmap.valPos,
                paletteEntries: paletteEntries,
                isLE: isLE,
                output8Bit: output8Bit
            )
            if bps == 4 {
                let rowBytes = (w + 1) / 2
                neededBytes = try checkedMultiply(h, rowBytes, label: "TIFF 4-bit palette byte count")
            } else if bps == 8 {
                neededBytes = pixelCount
            } else {
                neededBytes = try checkedMultiply(pixelCount, 2, label: "TIFF 16-bit palette byte count")
            }

        default:
            // PhotometricInterpretation 4 (Transparency Mask), 5 (CMYK), 6 (YCbCr),
            // 8/9/10 (CIE L*a*b*), 32803 (CFA), 34892 (LinearRaw), etc.
            throw CodecError(.unsupportedFeature, "Unsupported TIFF PhotometricInterpretation (\(photo)).")
        }

        // Build actual ImageDescriptor BEFORE any strip allocation so 1-component 8-bit greyscale's
        // 16-bit contract storage (requiredByteCount) is admitted against maximumDecodedBytes upfront.
        let descriptor = try makeContractImageDescriptor(
            width: w,
            height: h,
            componentCount: outputComponentCount,
            meaningfulBits: outputMeaningfulBits,
            signed: outputSigned,
            alpha: outputAlpha,
            limits: limits
        )
        let destBytes = descriptor.requiredByteCount
        guard destBytes <= limits.maximumDecodedBytes else {
            throw CodecError(.resourceLimitExceeded, "TIFF decoded image size (\(destBytes) B) exceeds decoded byte limit (\(limits.maximumDecodedBytes) B).")
        }

        if case .single(let off) = stripOffsets, case .single(let cnt) = stripByteCounts {
            // Zero strip workspace copy on single-strip TIFF: only input Data + destination Image are simultaneously live.
            let totalLiveMemory = try checkedAdd(data.count, destBytes, label: "TIFF single-strip total live memory")
            guard totalLiveMemory <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "TIFF decode memory (\(totalLiveMemory) B) exceeds memory limit (\(limits.maximumMemoryBytes) B).")
            }
            guard off >= 0, cnt >= 0 else {
                throw CodecError(.malformedInput, "Negative TIFF strip offset or byte count.")
            }
            let end = try checkedAdd(off, cnt, label: "TIFF strip end")
            guard end <= byteCount else {
                throw CodecError(.malformedInput, "TIFF strip extends past end of file.")
            }
            guard cnt >= neededBytes else {
                throw CodecError(.malformedInput, "TIFF strip data (\(cnt) B) is shorter than required sample bytes (\(neededBytes) B).")
            }
            return try makeContractImage(
                descriptor: descriptor,
                limits: limits
            ) { c, x, y in
                try decodeTIFFLogicalSample(
                    stripSrc: bytes,
                    baseOffset: off,
                    component: c,
                    x: x,
                    y: y,
                    width: w,
                    pixelCount: pixelCount,
                    samplesPerPixel: samplesPerPixel,
                    planarConfig: planarConfig,
                    bps: bps,
                    isLE: isLE,
                    signed: signed,
                    photometricMode: photometricMode
                )
            }
        } else if stripOffsets.isMany && stripByteCounts.isMany {
            return try decodeTIFFFromStripWorkspace(
                try assembleTIFFMultiStripWorkspace(
                    stripOffsets: &stripOffsets,
                    stripByteCounts: &stripByteCounts,
                    retainedTagBytes: &retainedTagBytes,
                    bytes: bytes,
                    byteCount: byteCount,
                    inputByteCount: data.count,
                    neededBytes: neededBytes,
                    destBytes: destBytes,
                    limits: limits
                ),
                descriptor: descriptor,
                limits: limits,
                width: w,
                pixelCount: pixelCount,
                samplesPerPixel: samplesPerPixel,
                planarConfig: planarConfig,
                bps: bps,
                isLE: isLE,
                signed: signed,
                photometricMode: photometricMode
            )
        } else {
            throw CodecError(.malformedInput, "TIFF missing or mismatched StripOffsets and StripByteCounts.")
        }
    }
}

func formatTIFF(_ image: Image) throws -> Data {
    let d = image.descriptor
    let channels = d.components.count
    guard (1...4).contains(channels) else {
        throw CodecError(.unsupportedFeature, "TIFF output supports 1 to 4 components.")
    }
    let signed = (d.sampleType == .signedInteger)
    let tiffBitDepth = (d.meaningfulBits <= 8) ? 8 : 16
    let bytesPerSample = tiffBitDepth / 8
    let pixelCount = try checkedMultiply(d.width, d.height)
    let sampleCount = try checkedMultiply(pixelCount, channels)
    let stripByteCount = try checkedMultiply(sampleCount, bytesPerSample)

    var pixelData = Data(capacity: stripByteCount)
    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            for x in 0..<d.width {
                for c in 0..<channels {
                    let val = readLogicalSample(raw, descriptor: d, component: c, x: x, y: y)
                    if bytesPerSample == 1 {
                        if signed {
                            pixelData.append(UInt8(bitPattern: Int8(clamping: val)))
                        } else {
                            pixelData.append(UInt8(clamping: max(0, val)))
                        }
                    } else {
                        let word: UInt16 = signed
                            ? UInt16(bitPattern: Int16(clamping: val))
                            : UInt16(clamping: max(0, val))
                        pixelData.append(UInt8(truncatingIfNeeded: word & 0xFF))
                        pixelData.append(UInt8(truncatingIfNeeded: (word >> 8) & 0xFF))
                    }
                }
            }
        }
    }

    let includeExtraSamples = (channels == 2 || channels == 4)
    let includeSMax = (d.meaningfulBits != tiffBitDepth)
    let tagCount: UInt16 = 11 + (includeExtraSamples ? 1 : 0) + (includeSMax ? 1 : 0)
    let ifdOffset = 8
    let ifdSize = 2 + Int(tagCount) * 12 + 4
    let extraOffset = ifdOffset + ifdSize
    let bpsExtraBytes = (channels > 2) ? (channels * 2) : 0
    let sfExtraOffset = extraOffset + bpsExtraBytes
    let sfExtraBytes = (channels > 2) ? (channels * 2) : 0
    let stripOffset = sfExtraOffset + sfExtraBytes

    var out = Data()
    out.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]) // Little-endian TIFF
    appendLE32(&out, UInt32(ifdOffset))
    appendLE16(&out, tagCount)

    func writeTag(_ tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
        appendLE16(&out, tag)
        appendLE16(&out, type)
        appendLE32(&out, count)
        appendLE32(&out, valueOrOffset)
    }

    // 256 ImageWidth (LONG)
    writeTag(256, type: 4, count: 1, valueOrOffset: UInt32(d.width))
    // 257 ImageLength (LONG)
    writeTag(257, type: 4, count: 1, valueOrOffset: UInt32(d.height))
    // 258 BitsPerSample (SHORT)
    if channels == 1 {
        writeTag(258, type: 3, count: 1, valueOrOffset: UInt32(tiffBitDepth))
    } else if channels == 2 {
        let packed = UInt32(tiffBitDepth) | (UInt32(tiffBitDepth) << 16)
        writeTag(258, type: 3, count: 2, valueOrOffset: packed)
    } else {
        writeTag(258, type: 3, count: UInt32(channels), valueOrOffset: UInt32(extraOffset))
    }
    // 259 Compression = 1 (Uncompressed)
    writeTag(259, type: 3, count: 1, valueOrOffset: 1)
    // 262 PhotometricInterpretation (1 = BlackIsZero, 2 = RGB)
    let photometric: UInt32 = (channels >= 3) ? 2 : 1
    writeTag(262, type: 3, count: 1, valueOrOffset: photometric)
    // 273 StripOffsets (LONG)
    writeTag(273, type: 4, count: 1, valueOrOffset: UInt32(stripOffset))
    // 277 SamplesPerPixel (SHORT)
    writeTag(277, type: 3, count: 1, valueOrOffset: UInt32(channels))
    // 278 RowsPerStrip (LONG)
    writeTag(278, type: 4, count: 1, valueOrOffset: UInt32(d.height))
    // 279 StripByteCounts (LONG)
    writeTag(279, type: 4, count: 1, valueOrOffset: UInt32(stripByteCount))
    // 284 PlanarConfiguration = 1 (Chunky)
    writeTag(284, type: 3, count: 1, valueOrOffset: 1)
    if includeExtraSamples {
        // 338 ExtraSamples (SHORT: 1 = Associated/premultiplied alpha, 2 = Unassociated/straight alpha)
        let extraSampleType: UInt32 = (d.alpha == .premultiplied) ? 1 : 2
        writeTag(338, type: 3, count: 1, valueOrOffset: extraSampleType)
    }
    // 339 SampleFormat (SHORT: 1 = unsigned, 2 = signed)
    let sfVal: UInt32 = signed ? 2 : 1
    if channels == 1 {
        writeTag(339, type: 3, count: 1, valueOrOffset: sfVal)
    } else if channels == 2 {
        let packed = sfVal | (sfVal << 16)
        writeTag(339, type: 3, count: 2, valueOrOffset: packed)
    } else {
        writeTag(339, type: 3, count: UInt32(channels), valueOrOffset: UInt32(sfExtraOffset))
    }
    if includeSMax {
        // 341 SMaxSampleValue (SHORT) records exact meaningful precision (e.g. 4095 for 12-bit)
        let smax = signed ? ((1 << (d.meaningfulBits - 1)) - 1) : ((1 << d.meaningfulBits) - 1)
        writeTag(341, type: 3, count: 1, valueOrOffset: UInt32(max(1, smax)))
    }
    appendLE32(&out, 0) // Next IFD offset = 0

    if channels > 2 {
        for _ in 0..<channels {
            appendLE16(&out, UInt16(tiffBitDepth))
        }
        for _ in 0..<channels {
            appendLE16(&out, UInt16(sfVal))
        }
    }
    out.append(pixelData)
    return out
}

private func appendLE16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(truncatingIfNeeded: value & 0xFF))
    data.append(UInt8(truncatingIfNeeded: (value >> 8) & 0xFF))
}

private func appendLE32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(truncatingIfNeeded: value & 0xFF))
    data.append(UInt8(truncatingIfNeeded: (value >> 8) & 0xFF))
    data.append(UInt8(truncatingIfNeeded: (value >> 16) & 0xFF))
    data.append(UInt8(truncatingIfNeeded: (value >> 24) & 0xFF))
}

// MARK: - RAW 2D Reader & Writer

func parseRAW(
    _ data: Data,
    width: Int,
    height: Int,
    components: Int,
    bitDepth: Int,
    signed: Bool,
    bigEndian: Bool = false,
    limits: ResourceLimits
) throws -> Image {
    guard data.count <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "RAW input size (\(data.count) B) exceeds memory limit.")
    }
    guard width > 0, height > 0 else {
        throw CodecError(.invalidArgument, "RAW input requires positive --dimensions WxH.")
    }
    guard (1...16).contains(bitDepth) else {
        throw CodecError(.unsupportedFeature, "RAW bit depth must be in 1...16.")
    }
    guard (1...4).contains(components) else {
        throw CodecError(.unsupportedFeature, "RAW components must be in 1...4.")
    }
    let descriptor = try makeContractImageDescriptor(
        width: width,
        height: height,
        componentCount: components,
        meaningfulBits: bitDepth,
        signed: signed,
        limits: limits
    )
    let totalLiveMemory = try checkedAdd(data.count, descriptor.requiredByteCount, label: "RAW live memory")
    guard totalLiveMemory <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "RAW live memory (\(totalLiveMemory) B) exceeds memory limit.")
    }
    let bytesPerSample = (bitDepth <= 8) ? 1 : 2
    let pixelCount = try checkedMultiply(width, height, label: "RAW pixel count")
    let sampleCount = try checkedMultiply(pixelCount, components, label: "RAW sample count")
    let expectedBytes = try checkedMultiply(sampleCount, bytesPerSample, label: "RAW byte count")
    guard data.count == expectedBytes else {
        throw CodecError(.malformedInput, "RAW input byte length does not match declared geometry and bit depth.")
    }
    return try data.withUnsafeBytes { rawBuf -> Image in
        guard let bytes = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return try makeContractImage(descriptor: descriptor, limits: limits) { _, _, _ in 0 }
        }
        return try makeContractImage(
            descriptor: descriptor,
            limits: limits
        ) { c, x, y in
            let sampleIdx = (y * width + x) * components + c
            if bytesPerSample == 1 {
                let b = bytes[sampleIdx]
                return signed ? Int(Int8(bitPattern: b)) : Int(b)
            } else {
                let off = sampleIdx * 2
                let word: UInt16 = bigEndian
                    ? ((UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1]))
                    : (UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8))
                return signed ? Int(Int16(bitPattern: word)) : Int(word)
            }
        }
    }
}

func formatRAW(_ image: Image) throws -> Data {
    let d = image.descriptor
    let signed = (d.sampleType == .signedInteger)
    let bytesPerSample = (d.meaningfulBits <= 8) ? 1 : 2
    let pixelCount = try checkedMultiply(d.width, d.height)
    let sampleCount = try checkedMultiply(pixelCount, d.components.count)
    let totalBytes = try checkedMultiply(sampleCount, bytesPerSample)
    var out = Data(capacity: totalBytes)
    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            for x in 0..<d.width {
                for c in 0..<d.components.count {
                    let val = readLogicalSample(raw, descriptor: d, component: c, x: x, y: y)
                    if bytesPerSample == 1 {
                        out.append(signed ? UInt8(bitPattern: Int8(clamping: val)) : UInt8(clamping: max(0, val)))
                    } else {
                        let word: UInt16 = signed
                            ? UInt16(bitPattern: Int16(clamping: val))
                            : UInt16(clamping: max(0, val))
                        out.append(UInt8(truncatingIfNeeded: word & 0xFF))
                        out.append(UInt8(truncatingIfNeeded: (word >> 8) & 0xFF))
                    }
                }
            }
        }
    }
    return out
}

// MARK: - Explicit Bit-Depth Conversion (for `convert --bit-depth`)

func convertImageBitDepth(
    _ image: Image,
    to targetBits: Int,
    limits: ResourceLimits
) throws -> Image {
    guard targetBits == 8 || targetBits == 16 else {
        throw CodecError(.unsupportedFeature, "Bit-depth conversion only supports 8 or 16 bits.")
    }
    let d = image.descriptor
    guard d.sampleType == .unsignedInteger else {
        throw CodecError(.unsupportedFormat, "Bit-depth scaling requires unsigned integer samples.")
    }
    if d.meaningfulBits == targetBits {
        return image
    }
    let srcMax = max(1, (1 << d.meaningfulBits) - 1)
    let dstMax = (1 << targetBits) - 1
    var samples = [Int](repeating: 0, count: d.width * d.height * d.components.count)
    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            for x in 0..<d.width {
                for c in 0..<d.components.count {
                    let v = max(0, min(srcMax, readLogicalSample(raw, descriptor: d, component: c, x: x, y: y)))
                    let scaled = (v * dstMax + (srcMax / 2)) / srcMax
                    samples[(y * d.width + x) * d.components.count + c] = min(dstMax, max(0, scaled))
                }
            }
        }
    }
    return try makeContractImage(
        width: d.width,
        height: d.height,
        componentCount: d.components.count,
        meaningfulBits: targetBits,
        signed: false,
        limits: limits
    ) { c, x, y in
        samples[(y * d.width + x) * d.components.count + c]
    }
}

// MARK: - 3D Volumetric Readers & Writers (for `encode3d`, `decode3d`, `compare --mode 3d`)

private func parseNRRDVolumeSpacings(_ raw: String, dim: Int) throws -> (Double, Double, Double) {
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.count == dim else {
        throw CodecError(.malformedInput, "NRRD volume spacings count (\(tokens.count)) does not match dimension (\(dim)).")
    }
    let startIdx: Int
    if dim == 4 {
        let compTok = tokens[0].lowercased()
        guard compTok == "nan" || compTok == "none" else {
            throw CodecError(.malformedInput, "NRRD 4D volume component-axis spacing must be NaN or none.")
        }
        startIdx = 1
    } else {
        startIdx = 0
    }
    var out: [Double] = []
    out.reserveCapacity(3)
    for axis in 0..<3 {
        let tok = tokens[startIdx + axis]
        let lower = tok.lowercased()
        if lower == "nan" || lower == "none" {
            out.append(0.0)
        } else if let v = Double(tok), v.isFinite, v > 0 {
            out.append(v)
        } else {
            throw CodecError(.malformedInput, "Invalid NRRD volume spacing token '\(tok)'; expected positive finite number or NaN.")
        }
    }
    return (out[0], out[1], out[2])
}

private func parseNRRDParenthesisedTriplet(_ raw: String, label: String) throws -> (Double, Double, Double) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else {
        throw CodecError(.malformedInput, "Invalid NRRD \(label) '\(raw)'; expected (x,y,z).")
    }
    let inner = trimmed.dropFirst().dropLast()
    let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 3 else {
        throw CodecError(.malformedInput, "Invalid NRRD \(label) '\(raw)'; expected 3 comma-separated components.")
    }
    var vals: [Double] = []
    vals.reserveCapacity(3)
    for part in parts {
        let s = part.trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v.isFinite else {
            throw CodecError(.malformedInput, "Non-finite or invalid number in NRRD \(label) '\(raw)'.")
        }
        vals.append(v == 0 ? 0.0 : v)
    }
    return (vals[0], vals[1], vals[2])
}

private func parseNRRDVolumeSpaceDirections(_ raw: String, dim: Int) throws -> (Double, Double, Double) {
    var tokens: [String] = []
    var idx = raw.startIndex
    while idx < raw.endIndex {
        while idx < raw.endIndex && raw[idx].isWhitespace {
            idx = raw.index(after: idx)
        }
        guard idx < raw.endIndex else { break }
        if raw[idx] == "(" {
            guard let closeIdx = raw[idx...].firstIndex(of: ")") else {
                throw CodecError(.malformedInput, "Unterminated vector in NRRD space directions.")
            }
            let nextIdx = raw.index(after: closeIdx)
            tokens.append(String(raw[idx..<nextIdx]))
            idx = nextIdx
        } else {
            var endIdx = idx
            while endIdx < raw.endIndex && !raw[endIdx].isWhitespace {
                endIdx = raw.index(after: endIdx)
            }
            tokens.append(String(raw[idx..<endIdx]))
            idx = endIdx
        }
    }
    guard tokens.count == dim else {
        throw CodecError(.malformedInput, "NRRD space directions count (\(tokens.count)) does not match dimension (\(dim)).")
    }
    let startIdx: Int
    if dim == 4 {
        guard tokens[0].lowercased() == "none" else {
            throw CodecError(.malformedInput, "NRRD 4D volume component-axis space direction must be 'none'.")
        }
        startIdx = 1
    } else {
        startIdx = 0
    }
    var spacings: [Double] = []
    spacings.reserveCapacity(3)
    for axis in 0..<3 {
        let tok = tokens[startIdx + axis]
        if tok.lowercased() == "none" {
            spacings.append(0.0)
        } else {
            let (vx, vy, vz) = try parseNRRDParenthesisedTriplet(tok, label: "space direction")
            let vec = [vx, vy, vz]
            for k in 0..<3 where k != axis {
                if vec[k] != 0.0 {
                    throw CodecError(
                        .unsupportedFeature,
                        "Non-axis-aligned NRRD space directions are not supported by J2KVolume."
                    )
                }
            }
            let diag = vec[axis]
            if diag < 0 {
                throw CodecError(
                    .unsupportedFeature,
                    "Negative or axis-flipped NRRD space directions are not supported by J2KVolume."
                )
            }
            guard diag > 0 else {
                throw CodecError(.malformedInput, "NRRD space direction vector cannot be zero; use 'none' for unset spacing.")
            }
            spacings.append(diag)
        }
    }
    return (spacings[0], spacings[1], spacings[2])
}

func parseNRRDVolume(
    _ data: Data,
    spacingOverride: (Double, Double, Double)? = nil,
    originOverride: (Double, Double, Double)? = nil,
    limits: ResourceLimits
) throws -> J2KVolume {
    guard data.count <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "NRRD volume input exceeds memory limit.")
    }
    guard let split = data.range(of: Data([0x0A, 0x0A])) ?? data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
        throw CodecError(.malformedInput, "NRRD volume header terminator was not found.")
    }
    guard let header = String(data: data[..<split.lowerBound], encoding: .utf8) else {
        throw CodecError(.malformedInput, "NRRD volume header is not UTF-8.")
    }
    let lines = header.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
    guard let magic = lines.first.map(String.init),
          ["NRRD0001", "NRRD0002", "NRRD0003", "NRRD0004", "NRRD0005"].contains(magic) else {
        throw CodecError(.unsupportedFormat, "Input is not a supported NRRD volume.")
    }
    var fields: [String: String] = [:]
    var keys: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty && !line.hasPrefix("#") {
        if let r = line.range(of: ":=") {
            keys[line[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        } else if let r = line.range(of: ":") {
            fields[line[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        }
    }
    guard fields["encoding"]?.lowercased() == "raw" else {
        throw CodecError(.unsupportedFormat, "Only raw NRRD volume encoding is supported.")
    }
    guard let rawType = fields["type"]?.lowercased(),
          let dim = fields["dimension"].flatMap(Int.init),
          let sizes = fields["sizes"]?.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }),
          sizes.count == dim else {
        throw CodecError(.malformedInput, "NRRD volume is missing type, dimension, or sizes.")
    }
    let storageBits: Int
    let signed: Bool
    switch rawType {
    case "uint8", "uchar", "unsigned char", "uint8_t":
        (storageBits, signed) = (8, false)
    case "int8", "signed char", "int8_t":
        (storageBits, signed) = (8, true)
    case "uint16", "ushort", "unsigned short", "unsigned short int", "uint16_t":
        (storageBits, signed) = (16, false)
    case "int16", "short", "short int", "signed short", "signed short int", "int16_t":
        (storageBits, signed) = (16, true)
    case "uint32", "uint", "unsigned int", "uint32_t":
        (storageBits, signed) = (32, false)
    case "int32", "int", "signed int", "int32_t":
        (storageBits, signed) = (32, true)
    case "uint64", "ulonglong", "unsigned long long", "unsigned long long int", "uint64_t":
        (storageBits, signed) = (64, false)
    case "int64", "longlong", "long long", "long long int", "signed long long", "signed long long int", "int64_t":
        (storageBits, signed) = (64, true)
    default:
        throw CodecError(.unsupportedFormat, "Unsupported NRRD volume type.")
    }
    let isLE = (fields["endian"]?.lowercased() != "big")
    let (w, h, d, compCount): (Int, Int, Int, Int)
    if dim == 3 {
        (w, h, d, compCount) = (sizes[0], sizes[1], sizes[2], 1)
    } else if dim == 4 {
        (compCount, w, h, d) = (sizes[0], sizes[1], sizes[2], sizes[3])
    } else {
        throw CodecError(.unsupportedFeature, "NRRD volume dimension must be 3 (W H D) or 4 (C W H D).")
    }
    guard w > 0, h > 0, d > 0, compCount >= 1 else {
        throw CodecError(.unsupportedFeature, "NRRD volume dimensions must be positive.")
    }
    guard w <= limits.maximumDimension, h <= limits.maximumDimension, d <= limits.maximumDimension else {
        throw CodecError(.resourceLimitExceeded, "NRRD volume dimensions exceed resource limit.")
    }
    guard d <= limits.maximumFrames else {
        throw CodecError(.resourceLimitExceeded, "NRRD volume depth exceeds frame limit.")
    }

    if let spaceDimRaw = fields["space dimension"] {
        guard let spaceDim = Int(spaceDimRaw), spaceDim == 3 else {
            throw CodecError(.unsupportedFeature, "NRRD volume space dimension must be 3.")
        }
    }
    if fields["spacings"] != nil && fields["space directions"] != nil {
        throw CodecError(.malformedInput, "NRRD volume header cannot specify both spacings and space directions.")
    }
    var parsedSpacing: (Double, Double, Double) = (0.0, 0.0, 0.0)
    if let rawSpacings = fields["spacings"] {
        parsedSpacing = try parseNRRDVolumeSpacings(rawSpacings, dim: dim)
    } else if let rawDirs = fields["space directions"] {
        parsedSpacing = try parseNRRDVolumeSpaceDirections(rawDirs, dim: dim)
    }
    var parsedOrigin: (Double, Double, Double) = (0.0, 0.0, 0.0)
    if let rawOrigin = fields["space origin"] {
        parsedOrigin = try parseNRRDParenthesisedTriplet(rawOrigin, label: "space origin")
    }
    let finalSpacing = spacingOverride ?? parsedSpacing
    let finalOrigin = originOverride ?? parsedOrigin

    let defaultMeaningful = min(38, storageBits)
    let meaningful = keys["swiftj2k.meaningfulbits"].flatMap(Int.init) ?? defaultMeaningful
    guard (1...min(38, storageBits)).contains(meaningful) else {
        throw CodecError(.unsupportedFeature, "NRRD volume meaningful bit depth (\(meaningful)) must be in 1..\(min(38, storageBits)).")
    }
    let nrrdBps = storageBits / 8
    let compBps = (meaningful + 7) / 8
    let slicePixels = try checkedMultiply(w, h, label: "NRRD volume slice pixels")
    let voxelCount = try checkedMultiply(slicePixels, d, label: "NRRD volume voxel count")
    guard voxelCount <= limits.maximumPixels else {
        throw CodecError(.resourceLimitExceeded, "NRRD volume voxel count exceeds pixel limit.")
    }
    let totalSamples = try checkedMultiply(voxelCount, compCount, label: "NRRD volume sample count")
    let expectedBytes = try checkedMultiply(totalSamples, nrrdBps, label: "NRRD volume expected bytes")
    let compBytesEach = try checkedMultiply(voxelCount, compBps, label: "NRRD volume component bytes")
    let totalCompBytes = try checkedMultiply(compBytesEach, compCount, label: "NRRD volume decoded bytes")
    guard totalCompBytes <= limits.maximumDecodedBytes else {
        throw CodecError(.resourceLimitExceeded, "NRRD volume decoded size exceeds decoded byte limit.")
    }
    let liveBytes = try checkedAdd(data.count, totalCompBytes, label: "NRRD volume live memory")
    guard liveBytes <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "NRRD volume exceeds memory limit.")
    }

    let body = data[split.upperBound...]
    guard body.count == expectedBytes else {
        throw CodecError(.malformedInput, "NRRD volume data byte length does not match header.")
    }
    var volComponents: [J2KVolumeComponent] = []
    volComponents.reserveCapacity(compCount)
    body.withUnsafeBytes { bodyRaw in
        guard let src = bodyRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for c in 0..<compCount {
            var compData = Data(count: compBytesEach)
            compData.withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for vIdx in 0..<voxelCount {
                    let srcSampleIdx = (dim == 4) ? (vIdx * compCount + c) : vIdx
                    let srcOff = srcSampleIdx * nrrdBps
                    let dstOff = vIdx * compBps
                    if isLE {
                        for b in 0..<compBps {
                            dst[dstOff + b] = src[srcOff + b]
                        }
                    } else {
                        for b in 0..<compBps {
                            dst[dstOff + b] = src[srcOff + (nrrdBps - 1 - b)]
                        }
                    }
                }
            }
            volComponents.append(
                J2KVolumeComponent(
                    index: c,
                    bitDepth: meaningful,
                    signed: signed,
                    width: w,
                    height: h,
                    depth: d,
                    data: compData
                )
            )
        }
    }
    let vol = J2KVolume(
        width: w,
        height: h,
        depth: d,
        components: volComponents,
        spacingX: finalSpacing.0,
        spacingY: finalSpacing.1,
        spacingZ: finalSpacing.2,
        originX: finalOrigin.0,
        originY: finalOrigin.1,
        originZ: finalOrigin.2
    )
    do {
        try vol.validate()
    } catch let error as J2KError {
        throw error.asCodecError
    }
    return vol
}

@inline(__always)
private func formatNRRDDouble(_ v: Double) -> String {
    v == 0 ? "0" : String(v)
}

func formatNRRDVolume(_ volume: J2KVolume) throws -> Data {
    do {
        try volume.validate()
    } catch let error as J2KError {
        throw error.asCodecError
    }
    guard let first = volume.components.first else {
        throw CodecError(.malformedInput, "Volume has no components.")
    }
    let w = volume.width
    let h = volume.height
    let d = volume.depth
    let cCount = volume.components.count
    let compBps = (first.bitDepth + 7) / 8
    let nrrdBps: Int
    if first.bitDepth <= 8 {
        nrrdBps = 1
    } else if first.bitDepth <= 16 {
        nrrdBps = 2
    } else if first.bitDepth <= 32 {
        nrrdBps = 4
    } else {
        nrrdBps = 8
    }
    let typeName: String
    switch (nrrdBps, first.signed) {
    case (1, false): typeName = "uint8"
    case (1, true):  typeName = "int8"
    case (2, false): typeName = "uint16"
    case (2, true):  typeName = "int16"
    case (4, false): typeName = "uint32"
    case (4, true):  typeName = "int32"
    case (_, false): typeName = "uint64"
    default:         typeName = "int64"
    }
    var header = "NRRD0004\ntype: \(typeName)\n"
    if cCount == 1 {
        header += "dimension: 3\nsizes: \(w) \(h) \(d)\n"
    } else {
        header += "dimension: 4\nsizes: \(cCount) \(w) \(h) \(d)\n"
    }
    let hasSpacing = (volume.spacingX != 0 || volume.spacingY != 0 || volume.spacingZ != 0)
    let hasOrigin = (volume.originX != 0 || volume.originY != 0 || volume.originZ != 0)
    if hasOrigin {
        header += "space dimension: 3\n"
        if hasSpacing {
            let dirX = volume.spacingX > 0 ? "(\(formatNRRDDouble(volume.spacingX)),0,0)" : "none"
            let dirY = volume.spacingY > 0 ? "(0,\(formatNRRDDouble(volume.spacingY)),0)" : "none"
            let dirZ = volume.spacingZ > 0 ? "(0,0,\(formatNRRDDouble(volume.spacingZ)))" : "none"
            let prefix = (cCount > 1) ? "none " : ""
            header += "space directions: \(prefix)\(dirX) \(dirY) \(dirZ)\n"
        }
        header += "space origin: (\(formatNRRDDouble(volume.originX)),\(formatNRRDDouble(volume.originY)),\(formatNRRDDouble(volume.originZ)))\n"
    } else if hasSpacing {
        let spX = volume.spacingX > 0 ? formatNRRDDouble(volume.spacingX) : "NaN"
        let spY = volume.spacingY > 0 ? formatNRRDDouble(volume.spacingY) : "NaN"
        let spZ = volume.spacingZ > 0 ? formatNRRDDouble(volume.spacingZ) : "NaN"
        let prefix = (cCount > 1) ? "NaN " : ""
        header += "spacings: \(prefix)\(spX) \(spY) \(spZ)\n"
    }
    header += "encoding: raw\n"
    if nrrdBps > 1 {
        header += "endian: little\n"
    }
    header += "swiftj2k.meaningfulbits:=\(first.bitDepth)\n\n"
    var out = Data(header.utf8)
    let voxelCount = try checkedMultiply(try checkedMultiply(w, h), d)
    if cCount == 1 && compBps == nrrdBps {
        out.append(first.data.prefix(try checkedMultiply(voxelCount, nrrdBps)))
    } else {
        let totalOutBytes = try checkedMultiply(try checkedMultiply(voxelCount, cCount), nrrdBps)
        var interleaved = Data(count: totalOutBytes)
        interleaved.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for (cIdx, comp) in volume.components.enumerated() {
                let srcBps = (comp.bitDepth + 7) / 8
                let srcBitWidth = srcBps * 8
                comp.data.withUnsafeBytes { srcRaw in
                    guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for vIdx in 0..<voxelCount {
                        let dstOff = (vIdx * cCount + cIdx) * nrrdBps
                        let srcOff = vIdx * srcBps
                        var rawWord: UInt64 = 0
                        for b in 0..<srcBps where srcOff + b < comp.data.count {
                            rawWord |= UInt64(src[srcOff + b]) << (b * 8)
                        }
                        if comp.signed && srcBitWidth < 64 {
                            let storageSign = UInt64(1) << (srcBitWidth - 1)
                            let bitSign = UInt64(1) << (comp.bitDepth - 1)
                            if (rawWord & storageSign) != 0 {
                                rawWord |= (~UInt64(0) << srcBitWidth)
                            } else if comp.bitDepth < srcBitWidth
                                && (rawWord >> comp.bitDepth) == 0
                                && (rawWord & bitSign) != 0 {
                                rawWord |= (~UInt64(0) << comp.bitDepth)
                            }
                        }
                        for b in 0..<nrrdBps {
                            dst[dstOff + b] = UInt8(truncatingIfNeeded: rawWord >> (b * 8))
                        }
                    }
                }
            }
        }
        out.append(interleaved)
    }
    return out
}

// MARK: - Unified Uncompressed 2D & 3D Volume Helpers

struct CLIRawGeometry {
    var width: Int
    var height: Int
    var depth: Int = 1
    var components: Int = 1
    var bitDepth: Int = 8
    var signed: Bool = false
}

func parseUncompressedImage(
    _ data: Data,
    declaredFormat: CLIUncompressedFormat?,
    declaredPrecision: Int?,
    rawGeometry: CLIRawGeometry?,
    limits: ResourceLimits
) throws -> (Image, CLIUncompressedFormat) {
    if declaredFormat == .raw || (declaredFormat == nil && detectUncompressedFormat(data) == nil && rawGeometry != nil) {
        guard let geom = rawGeometry else {
            throw CodecError(.invalidArgument, "RAW input requires --dimensions WxH.")
        }
        let bits = declaredPrecision ?? geom.bitDepth
        let img = try parseRAW(
            data,
            width: geom.width,
            height: geom.height,
            components: geom.components,
            bitDepth: bits,
            signed: geom.signed,
            limits: limits
        )
        return (img, .raw)
    }

    guard let detected = detectUncompressedFormat(data) else {
        throw CodecError(.unsupportedFormat, "Input is not a supported uncompressed image format.")
    }

    if let declared = declaredFormat {
        let matches: Bool
        if declared == .pnm {
            matches = (detected == .pgm || detected == .ppm)
        } else {
            matches = (declared == detected)
        }
        guard matches else {
            throw CodecError(.unsupportedFormat, "Input bytes do not match the declared input format.")
        }
    }

    switch detected {
    case .nrrd:
        let img = try parseNRRD(data, declaredPrecision: declaredPrecision, limits: limits)
        return (img, .nrrd)
    case .pgm, .ppm, .pnm:
        return try parsePGMOrPPM(data, declaredPrecision: declaredPrecision, limits: limits)
    case .png:
        let img = try parsePNG(data, declaredPrecision: declaredPrecision, limits: limits)
        return (img, .png)
    case .tiff:
        let img = try parseTIFF(data, declaredPrecision: declaredPrecision, limits: limits)
        return (img, .tiff)
    case .raw:
        throw CodecError(.unsupportedFormat, "RAW input requires --input-format raw and --dimensions WxH.")
    }
}

func formatUncompressedImage(_ image: Image, format: CLIUncompressedFormat) throws -> Data {
    switch format {
    case .nrrd: return try formatNRRD(image)
    case .pgm:  return try formatPGM(image)
    case .ppm:  return try formatPPM(image)
    case .pnm:  return try formatPNM(image)
    case .png:  return try formatPNG(image)
    case .tiff: return try formatTIFF(image)
    case .raw:  return try formatRAW(image)
    }
}

func parseRAWVolume(
    _ data: Data,
    geometry: CLIRawGeometry,
    spacing: (Double, Double, Double)? = nil,
    origin: (Double, Double, Double)? = nil,
    limits: ResourceLimits
) throws -> J2KVolume {
    guard data.count <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "RAW 3D volume input exceeds memory limit.")
    }
    let w = geometry.width
    let h = geometry.height
    let d = geometry.depth
    let cCount = geometry.components
    let bits = geometry.bitDepth
    let signed = geometry.signed
    guard w > 0, h > 0, d > 0, cCount >= 1, (1...38).contains(bits) else {
        throw CodecError(.unsupportedFeature, "Invalid 3D volume geometry or bit depth.")
    }
    guard w <= limits.maximumDimension, h <= limits.maximumDimension, d <= limits.maximumDimension else {
        throw CodecError(.resourceLimitExceeded, "RAW 3D volume dimensions exceed resource limit.")
    }
    guard d <= limits.maximumFrames else {
        throw CodecError(.resourceLimitExceeded, "RAW 3D volume depth exceeds frame limit.")
    }
    let bps = (bits + 7) / 8
    let voxelCount = try checkedMultiply(try checkedMultiply(w, h), d)
    guard voxelCount <= limits.maximumPixels else {
        throw CodecError(.resourceLimitExceeded, "RAW 3D volume voxel count exceeds pixel limit.")
    }
    let sampleCount = try checkedMultiply(voxelCount, cCount)
    let expectedBytes = try checkedMultiply(sampleCount, bps)
    guard expectedBytes <= limits.maximumDecodedBytes else {
        throw CodecError(.resourceLimitExceeded, "RAW 3D volume exceeds decoded byte limit.")
    }
    let liveBytes = try checkedAdd(data.count, expectedBytes, label: "RAW 3D volume live memory")
    guard liveBytes <= limits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "RAW 3D volume exceeds memory limit.")
    }
    guard data.count == expectedBytes else {
        throw CodecError(.malformedInput, "RAW 3D volume byte length does not match declared geometry.")
    }
    var components: [J2KVolumeComponent] = []
    components.reserveCapacity(cCount)
    let compByteCount = try checkedMultiply(voxelCount, bps)
    data.withUnsafeBytes { srcRaw in
        guard let bytes = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for c in 0..<cCount {
            var compData = Data(count: compByteCount)
            compData.withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                if cCount == 1 {
                    for i in 0..<compByteCount { dst[i] = bytes[i] }
                } else {
                    for vIdx in 0..<voxelCount {
                        let srcOff = (vIdx * cCount + c) * bps
                        let dstOff = vIdx * bps
                        for b in 0..<bps { dst[dstOff + b] = bytes[srcOff + b] }
                    }
                }
            }
            components.append(
                J2KVolumeComponent(
                    index: c,
                    bitDepth: bits,
                    signed: signed,
                    width: w,
                    height: h,
                    depth: d,
                    data: compData
                )
            )
        }
    }
    return J2KVolume(
        width: w,
        height: h,
        depth: d,
        components: components,
        spacingX: spacing?.0 ?? 1.0,
        spacingY: spacing?.1 ?? 1.0,
        spacingZ: spacing?.2 ?? 1.0,
        originX: origin?.0 ?? 0.0,
        originY: origin?.1 ?? 0.0,
        originZ: origin?.2 ?? 0.0
    )
}

func formatRAWVolume(_ volume: J2KVolume) throws -> Data {
    guard let first = volume.components.first else {
        throw CodecError(.malformedInput, "Volume has no components.")
    }
    let bps = (first.bitDepth + 7) / 8
    let voxelCount = try checkedMultiply(try checkedMultiply(volume.width, volume.height), volume.depth)
    let cCount = volume.components.count
    if cCount == 1 {
        return first.data.prefix(try checkedMultiply(voxelCount, bps))
    }
    let totalBytes = try checkedMultiply(try checkedMultiply(voxelCount, cCount), bps)
    var out = Data(count: totalBytes)
    out.withUnsafeMutableBytes { dstRaw in
        guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for (cIdx, comp) in volume.components.enumerated() {
            comp.data.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for vIdx in 0..<voxelCount {
                    let dstOff = (vIdx * cCount + cIdx) * bps
                    let srcOff = vIdx * bps
                    for b in 0..<bps where srcOff + b < comp.data.count {
                        dst[dstOff + b] = src[srcOff + b]
                    }
                }
            }
        }
    }
    return out
}

func loadSliceDirectoryVolume(
    at dirURL: URL,
    sliceRange: ClosedRange<Int>?,
    spacing: (Double, Double, Double)? = nil,
    origin: (Double, Double, Double)? = nil,
    limits: ResourceLimits
) throws -> J2KVolume {
    let supportedExts: Set<String> = ["pgm", "ppm", "pnm", "png", "tiff", "tif", "nrrd"]
    let entries: [URL]
    do {
        entries = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    } catch {
        throw ExitFailure(status: 6, message: "I/O failure: input slice directory could not be read.")
    }
    var sliceURLs = entries.filter { supportedExts.contains($0.pathExtension.lowercased()) }
    sliceURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    guard !sliceURLs.isEmpty else {
        throw CodecError(.malformedInput, "No supported image slices found in directory.")
    }
    if let range = sliceRange {
        guard range.lowerBound >= 0, range.upperBound < sliceURLs.count, range.lowerBound <= range.upperBound else {
            throw CodecError(.invalidArgument, "Slice range is out of bounds for directory slice count (\(sliceURLs.count)).")
        }
        sliceURLs = Array(sliceURLs[range])
    }

    var sliceImages: [Image] = []
    sliceImages.reserveCapacity(sliceURLs.count)
    for url in sliceURLs {
        let data = try readInput(url.path)
        guard data.count <= limits.maximumDecodedBytes else {
            throw CodecError(.resourceLimitExceeded, "Slice file exceeds decoded byte limit.")
        }
        let (img, _) = try parseUncompressedImage(
            data,
            declaredFormat: nil,
            declaredPrecision: nil,
            rawGeometry: nil,
            limits: limits
        )
        sliceImages.append(img)
    }

    let firstDesc = sliceImages[0].descriptor
    let w = firstDesc.width
    let h = firstDesc.height
    let d = sliceImages.count
    let cCount = firstDesc.components.count
    let bits = firstDesc.meaningfulBits
    let signed = (firstDesc.sampleType == .signedInteger)
    let bps = (bits <= 8) ? 1 : 2
    let slicePixels = try checkedMultiply(w, h)
    let voxelCount = try checkedMultiply(slicePixels, d)

    for sImg in sliceImages.dropFirst() {
        let sd = sImg.descriptor
        guard sd.width == w, sd.height == h, sd.components.count == cCount else {
            throw CodecError(.malformedInput, "All slices in a 3D directory must have identical width, height, and component count.")
        }
    }

    var compBuffers = Array(repeating: Data(count: voxelCount * bps), count: cCount)
    for (z, sImg) in sliceImages.enumerated() {
        let sd = sImg.descriptor
        try sImg.storage.withUnsafeBytes { raw in
            for c in 0..<cCount {
                compBuffers[c].withUnsafeMutableBytes { dstRaw in
                    guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for y in 0..<h {
                        for x in 0..<w {
                            let val = readLogicalSample(raw, descriptor: sd, component: c, x: x, y: y)
                            let vIdx = z * slicePixels + y * w + x
                            if bps == 1 {
                                dst[vIdx] = signed
                                    ? UInt8(bitPattern: Int8(clamping: val))
                                    : UInt8(clamping: max(0, val))
                            } else {
                                let word: UInt16 = signed
                                    ? UInt16(bitPattern: Int16(clamping: val))
                                    : UInt16(clamping: max(0, val))
                                dst[vIdx * 2] = UInt8(truncatingIfNeeded: word & 0xFF)
                                dst[vIdx * 2 + 1] = UInt8(truncatingIfNeeded: (word >> 8) & 0xFF)
                            }
                        }
                    }
                }
            }
        }
    }

    let volComponents = (0..<cCount).map { c in
        J2KVolumeComponent(
            index: c,
            bitDepth: bits,
            signed: signed,
            width: w,
            height: h,
            depth: d,
            data: compBuffers[c]
        )
    }
    return J2KVolume(
        width: w,
        height: h,
        depth: d,
        components: volComponents,
        spacingX: spacing?.0 ?? 1.0,
        spacingY: spacing?.1 ?? 1.0,
        spacingZ: spacing?.2 ?? 1.0,
        originX: origin?.0 ?? 0.0,
        originY: origin?.1 ?? 0.0,
        originZ: origin?.2 ?? 0.0
    )
}

func extractVolumeSliceImage(
    _ volume: J2KVolume,
    sliceIndex z: Int,
    limits: ResourceLimits
) throws -> Image {
    guard let first = volume.components.first else {
        throw CodecError(.malformedInput, "Volume has no components.")
    }
    let w = volume.width
    let h = volume.height
    let cCount = volume.components.count
    let bits = max(1, min(16, first.bitDepth))
    let signed = first.signed
    let bps = (bits <= 8) ? 1 : 2
    let slicePixels = try checkedMultiply(w, h)
    let compBytesList = volume.components.map { [UInt8]($0.data) }

    return try makeContractImage(
        width: w,
        height: h,
        componentCount: cCount,
        meaningfulBits: bits,
        signed: signed,
        limits: limits
    ) { c, x, y in
        let vIdx = z * slicePixels + y * w + x
        let bytes = compBytesList[c]
        if bps == 1 {
            guard vIdx < bytes.count else { return 0 }
            return signed ? Int(Int8(bitPattern: bytes[vIdx])) : Int(bytes[vIdx])
        } else {
            let off = vIdx * 2
            guard off + 1 < bytes.count else { return 0 }
            let word = UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8)
            return signed ? Int(Int16(bitPattern: word)) : Int(word)
        }
    }
}

// MARK: - NRRD <-> Contract Image Bridge

func parseNRRD(
    _ data: Data,
    declaredPrecision: Int?,
    limits: ResourceLimits
) throws -> Image {
    let nrrd = try NRRD.parse(data, defaultPrecision: declaredPrecision)
    let descriptor: ImageDescriptor
    if nrrd.components == 1 {
        if nrrd.storageBits == 16 && !nrrd.signed {
            descriptor = try ImageDescriptor.greyscale16(
                width: nrrd.width, height: nrrd.height, meaningfulBits: nrrd.meaningfulBits, limits: limits
            )
        } else if nrrd.storageBits == 16 && nrrd.signed {
            descriptor = try ImageDescriptor.signedGreyscale16(
                width: nrrd.width, height: nrrd.height, meaningfulBits: nrrd.meaningfulBits, limits: limits
            )
        } else {
            descriptor = try ImageDescriptor.greyscale8(
                width: nrrd.width, height: nrrd.height, meaningfulBits: nrrd.meaningfulBits,
                signed: nrrd.signed, limits: limits
            )
        }
    } else if nrrd.components == 3 {
        descriptor = try ImageDescriptor.rgbPlanar(
            width: nrrd.width, height: nrrd.height, storageBits: nrrd.storageBits,
            meaningfulBits: nrrd.meaningfulBits, signed: nrrd.signed, limits: limits
        )
    } else {
        descriptor = try ImageDescriptor.multiComponentPlanar(
            width: nrrd.width, height: nrrd.height, componentCount: nrrd.components,
            storageBits: nrrd.storageBits, meaningfulBits: nrrd.meaningfulBits,
            sampleType: nrrd.signed ? .signedInteger : .unsignedInteger, limits: limits
        )
    }

    let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
    let minVal = nrrd.signed ? -(1 << (nrrd.meaningfulBits - 1)) : 0
    let maxVal = nrrd.signed ? ((1 << (nrrd.meaningfulBits - 1)) - 1) : ((1 << nrrd.meaningfulBits) - 1)
    let bytesPerSample = nrrd.storageBits / 8

    return try nrrd.samples.withUnsafeBytes { source -> Image in
        try destination.writeSamples { c, x, y in
            let sampleIndex: Int
            if nrrd.components == 1 {
                sampleIndex = y * nrrd.width + x
            } else if nrrd.componentsFirst {
                sampleIndex = (y * nrrd.width + x) * nrrd.components + c
            } else {
                sampleIndex = (c * nrrd.height + y) * nrrd.width + x
            }
            let at = sampleIndex * bytesPerSample
            let value: Int
            if bytesPerSample == 1 {
                let raw = source[at]
                value = nrrd.signed ? Int(Int8(bitPattern: raw)) : Int(raw)
            } else {
                let word = nrrd.bigEndian
                    ? (UInt16(source[at]) << 8 | UInt16(source[at + 1]))
                    : (UInt16(source[at]) | UInt16(source[at + 1]) << 8)
                value = nrrd.signed ? Int(Int16(bitPattern: word)) : Int(word)
            }
            guard value >= minVal && value <= maxVal else {
                throw CodecError(.invalidArgument, "a sample exceeds \(nrrd.meaningfulBits) meaningful bits; use --precision or fix the header key.")
            }
            return value
        }
    }
}

func formatNRRD(_ image: Image) throws -> Data {
    let descriptor = image.descriptor
    let compCount = descriptor.components.count
    let sampleBytes = descriptor.storageBits / 8
    var output = NRRD.header(descriptor: descriptor)
    output.reserveCapacity(output.count + descriptor.width * descriptor.height * compCount * sampleBytes)

    if compCount == 1 {
        try image.storage.withUnsafeBytes { bytes in
            let plane = descriptor.planes[0]
            for y in 0..<descriptor.height {
                let row = plane.offset + y * plane.rowBytes
                for x in 0..<descriptor.width {
                    let at = row + x * plane.pixelStride
                    if sampleBytes == 1 {
                        output.append(bytes[at])
                    } else if descriptor.byteOrder == .littleEndian {
                        output.append(bytes[at]); output.append(bytes[at + 1])
                    } else {
                        output.append(bytes[at + 1]); output.append(bytes[at])
                    }
                }
            }
        }
    } else {
        for y in 0..<descriptor.height {
            for x in 0..<descriptor.width {
                for c in 0..<compCount {
                    let val = try image.sampleInt(component: c, x: x, y: y)
                    if sampleBytes == 1 {
                        let b = descriptor.sampleType == .signedInteger
                            ? UInt8(bitPattern: Int8(truncatingIfNeeded: val))
                            : UInt8(truncatingIfNeeded: val)
                        output.append(b)
                    } else {
                        let w = descriptor.sampleType == .signedInteger
                            ? UInt16(bitPattern: Int16(truncatingIfNeeded: val))
                            : UInt16(truncatingIfNeeded: val)
                        output.append(UInt8(truncatingIfNeeded: w))
                        output.append(UInt8(truncatingIfNeeded: w >> 8))
                    }
                }
            }
        }
    }
    return output
}
