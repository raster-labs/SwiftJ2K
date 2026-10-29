// SPDX-License-Identifier: Apache-2.0
//
// CLIVerbs.swift
// SwiftJ2KCLI
//
// Migrated and adapted from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/J2KCLICore/Convert.swift (224 lines, blob 8c073d18d054a363a6a3bf5268615871d17667c7)
//   - Sources/J2KCLICore/Compare.swift (263 lines, blob 49136655273e2cbe3062222a877b766b05f5aaf8)
//   - Sources/J2KCLICore/Batch.swift (290 lines, blob 6f80b681c38b7b9ede6eedcfabbad910cd66e891)
//   - Sources/J2KCLICore/MultiFileProcessor.swift (402 lines, blob db6cf8e5e697425ed0d0b7c2dc8601e7bef61e0c)
//   - Sources/J2KCLICore/Encode3D.swift (414 lines, blob 24ee3401665de7d22a0560891edf7eab7ade6555)
//   - Sources/J2KCLICore/Decode3D.swift (235 lines, blob 088cd4e4073927691839f090fbbdba17b4534553)
//   - Sources/J2KCLICore/JPIPClient.swift (277 lines, blob b00e1467424dd392aacac37dfe8219d644d44727)
//   - Sources/J2KCLICore/JPIPServer.swift (172 lines, blob b0d3f009e3ea45557d4711e6ae6d70f8fb76219f)
//   - Sources/J2KCLICore/Benchmark.swift (832 lines, blob 6f480b4a21e2342161d2d4851009978785c3d329)
//   - Sources/J2KCLICore/Completions.swift (239 lines, blob d0f1f578a49493e2559d73b863f859ea940e90a3)
//
// Changes relative to the predecessor:
//   - Fixed M12-AUD-001: Compare.swift now evaluates MSE, MAE, MaxError, and PSNR using
//     descriptor-aware logical sample values (`readLogicalSample`), eliminating the 16-bit
//     big-endian vs little-endian byte-swap defect on PNG/NRRD/decoded components.
//   - Fixed M12-AUD-002: MultiFileProcessor (`batch`) now executes files concurrently via a
//     bounded `withTaskGroup` respecting `--threads 1..8` instead of a sequential loop.
//   - Fixed M12-AUD-004: Benchmark.swift runs strictly in-process against SwiftJ2K with zero
//     runtime shell-outs to external `opj_compress`/`opj_decompress` executables (`POL-01`).
//   - Fixed M12-AUD-005: Replaced `exit(1)` calls, non-atomic file writes, and path-leaking
//     stderr diagnostics with contract exit codes (`0, 2, 3, 4, 5, 6, 7, 130`), atomic sibling
//     temp-file replacement (`publish`), and path-redacted diagnostic logging (`CLI-08`).

import Foundation
import SwiftJ2K
import SwiftJ2K3D
import SwiftJ2KJPIP

// MARK: - Option Parsing Helpers for Milestone 12 Verbs

func admitRegularFileSize(_ path: String, maxCategoryBytes: Int, memoryLimit: Int) throws {
    guard path != "-" else { return }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        return
    }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let sizeNum = attrs[.size] as? NSNumber {
        let byteSize = sizeNum.int64Value
        let cap = Int64(min(maxCategoryBytes, memoryLimit))
        if byteSize > cap {
            throw CodecError(
                .resourceLimitExceeded,
                "Input size (\(byteSize) B) exceeds resource admission limit (\(cap) B)."
            )
        }
    }
}

func isCompressedJ2KStream(_ data: Data) -> Bool {
    if data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x4F {
        return true
    }
    if data.count >= 12 && data[data.startIndex..<(data.startIndex + 12)].elementsEqual([
        0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A
    ]) {
        return true
    }
    return false
}

func parseRawGeometry(from options: Options) throws -> CLIRawGeometry? {
    var width: Int?
    var height: Int?
    var depth = 1
    if let dims = options.values["--dimensions"] {
        let parts = dims.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 > 0 }) else {
            throw UsageError(message: "--dimensions must be WxH or WxHxD with positive integers.")
        }
        width = parts[0]
        height = parts[1]
        if parts.count == 3 { depth = parts[2] }
    }
    if let wStr = options.values["--width"] {
        guard let w = Int(wStr), w > 0 else { throw UsageError(message: "--width must be a positive integer.") }
        width = w
    }
    if let hStr = options.values["--height"] {
        guard let h = Int(hStr), h > 0 else { throw UsageError(message: "--height must be a positive integer.") }
        height = h
    }
    if let dStr = options.values["--depth"] {
        guard let d = Int(dStr), d > 0 else { throw UsageError(message: "--depth must be a positive integer.") }
        depth = d
    }
    guard let w = width, let h = height else { return nil }
    var comps = 1
    if let cStr = options.values["--components"] {
        // Only treat --components as a count if it's a single positive integer (for JPIP it can be 0,1,2)
        if !cStr.contains(",") {
            guard let c = Int(cStr), (1...16).contains(c) else {
                throw UsageError(message: "--components must be 1..16.")
            }
            comps = c
        }
    }
    var bits = 8
    if let bStr = options.values["--bit-depth"] ?? options.values["--precision"] {
        let is3DCommand = ["encode3d", "decode3d", "compare"].contains(options.command ?? "")
            || depth > 1
            || options.values["--mode"]?.lowercased() == "3d"
        let maxBits = is3DCommand ? 38 : 16
        guard let b = Int(bStr), (1...maxBits).contains(b) else {
            throw UsageError(message: "--bit-depth/--precision must be 1..\(maxBits).")
        }
        bits = b
    }
    return CLIRawGeometry(width: w, height: h, depth: depth, components: comps, bitDepth: bits, signed: options.signed)
}

func parseOptionalPrecision(from options: Options) throws -> Int? {
    guard let text = options.values["--precision"] else { return nil }
    guard let val = Int(text), (1...16).contains(val) else {
        throw UsageError(message: "--precision must be 1..16.")
    }
    return val
}

func parseSliceRange(from options: Options) throws -> ClosedRange<Int>? {
    guard let text = options.values["--slice-range"] else { return nil }
    let sep: Character = text.contains(":") ? ":" : "-"
    let parts = text.split(separator: sep).compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 0, parts[0] <= parts[1] else {
        throw UsageError(message: "--slice-range must be START:END with non-negative integers (START <= END).")
    }
    return parts[0]...parts[1]
}

func parse3DDoubleTriplet(_ raw: String?, name: String) throws -> (Double, Double, Double)? {
    guard let raw else { return nil }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 3, parts.allSatisfy({ $0.isFinite }) else {
        throw UsageError(message: "\(name) must be X,Y,Z numbers.")
    }
    return (parts[0], parts[1], parts[2])
}

// MARK: - Convert Command (`swiftj2k-cli convert`)

func runConvertCommand(_ context: CodecContext, started: ContinuousClock.Instant) throws -> Int32 {
    let options = context.options
    guard let inPath = options.values["--input"], let outPath = options.values["--output"] else {
        throw UsageError(message: "convert requires --input and --output.")
    }
    let compressedNames: Set<String> = ["j2k", "j2c", "jhc", "htj2k", "jp2", "jph", "jpx"]
    if let inf = options.values["--input-format"]?.lowercased() {
        if compressedNames.contains(inf) {
            throw ExitFailure(status: 4, message: "unsupported format: convert handles uncompressed image formats (nrrd, pgm, ppm, pnm, png, tiff, raw); use decode or transcode.")
        }
        guard CLIUncompressedFormat(cliName: inf) != nil else {
            throw UsageError(message: "--input-format for convert must be nrrd, pgm, ppm, pnm, png, tiff or raw.")
        }
    }
    if let outf = options.values["--output-format"]?.lowercased() {
        if compressedNames.contains(outf) {
            throw ExitFailure(status: 4, message: "unsupported format: convert handles uncompressed image formats (nrrd, pgm, ppm, pnm, png, tiff, raw); use encode or transcode.")
        }
        guard CLIUncompressedFormat(cliName: outf) != nil else {
            throw UsageError(message: "--output-format for convert must be nrrd, pgm, ppm, pnm, png, tiff or raw.")
        }
    }
    if inPath != "-" {
        let inExt = URL(fileURLWithPath: inPath).pathExtension.lowercased()
        if compressedNames.contains(inExt) {
            throw ExitFailure(status: 4, message: "unsupported format: convert handles uncompressed image formats; use decode or transcode for JPEG 2000 inputs.")
        }
    }
    if outPath != "-" {
        let outExt = URL(fileURLWithPath: outPath).pathExtension.lowercased()
        if compressedNames.contains(outExt) {
            throw ExitFailure(status: 4, message: "unsupported format: convert handles uncompressed image formats; use encode or transcode for JPEG 2000 outputs.")
        }
    }

    var targetBitDepth: Int? = nil
    if let bdStr = options.values["--bit-depth"] {
        guard let bd = Int(bdStr), bd == 8 || bd == 16 else {
            throw UsageError(message: "--bit-depth for convert must be 8 or 16.")
        }
        targetBitDepth = bd
    }

    let lim = try limits(from: options, command: "convert")
    let rawGeom = try parseRawGeometry(from: options)
    let precision = try parseOptionalPrecision(from: options)
    let declaredInFmt = options.values["--input-format"].flatMap { CLIUncompressedFormat(cliName: $0) }
    let declaredOutFmt = options.values["--output-format"].flatMap { CLIUncompressedFormat(cliName: $0) }

    try context.diagnostic(2, "reading input")
    try admitRegularFileSize(inPath, maxCategoryBytes: lim.maximumDecodedBytes, memoryLimit: lim.maximumMemoryBytes)
    let rawData = try readInput(inPath)
    guard rawData.count <= lim.maximumDecodedBytes, rawData.count <= lim.maximumMemoryBytes else {
        throw ExitFailure(status: 5, message: "resource limit: input exceeds maximum memory limit.")
    }
    if isCompressedJ2KStream(rawData) {
        throw ExitFailure(status: 4, message: "unsupported format: input bytes are a compressed JPEG 2000 stream; use decode or transcode.")
    }

    let (sourceImage, detectedSourceFormat) = try parseUncompressedImage(
        rawData,
        declaredFormat: declaredInFmt,
        declaredPrecision: precision,
        rawGeometry: rawGeom,
        limits: lim
    )

    guard let rawTargetFormat = declaredOutFmt ?? CLIUncompressedFormat.fromPathExtension(outPath) else {
        throw UsageError(message: "convert requires --output-format or an output filename with a recognised uncompressed extension (nrrd, pgm, ppm, pnm, png, tiff, raw).")
    }

    let resolvedTargetFormat: CLIUncompressedFormat
    if rawTargetFormat == .pnm {
        resolvedTargetFormat = (sourceImage.descriptor.components.count == 1) ? .pgm : .ppm
    } else {
        resolvedTargetFormat = rawTargetFormat
    }

    let effectiveSourceFormat: CLIUncompressedFormat = (detectedSourceFormat == .pnm)
        ? ((sourceImage.descriptor.components.count == 1) ? .pgm : .ppm)
        : detectedSourceFormat

    if effectiveSourceFormat == resolvedTargetFormat && targetBitDepth == nil {
        throw ExitFailure(status: 4, message: "unsupported format: input and output image formats are identical (\(effectiveSourceFormat.rawValue)).")
    }

    try context.diagnostic(2, "converting \(effectiveSourceFormat.rawValue) -> \(resolvedTargetFormat.rawValue)")
    let convertedImage: Image
    if let targetBits = targetBitDepth {
        convertedImage = try convertImageBitDepth(sourceImage, to: targetBits, limits: lim)
    } else {
        convertedImage = sourceImage
    }

    let outputBytes = try formatUncompressedImage(convertedImage, format: resolvedTargetFormat)
    try context.diagnostic(2, "publishing output")
    try publish(outputBytes, to: outPath, overwrite: options.overwrite)

    let d = convertedImage.descriptor
    let elapsed = ContinuousClock.now - started
    try report([
        "bitDepth": d.meaningfulBits,
        "command": "convert",
        "components": d.components.count,
        "elapsedSeconds": elapsedSeconds(elapsed),
        "height": d.height,
        "inputBytes": rawData.count,
        "meaningfulBits": d.meaningfulBits,
        "outputBytes": outputBytes.count,
        "outputFormat": resolvedTargetFormat.rawValue,
        "sourceFormat": effectiveSourceFormat.rawValue,
        "targetFormat": resolvedTargetFormat.rawValue,
        "width": d.width
    ], json: options.json, to: .standardError)

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "convert completed; output published")
    return 0
}

// MARK: - Compare Command (`swiftj2k-cli compare`)

struct ComponentComparisonMetrics {
    let component: Int
    let mse: Double
    let mae: Double
    let maxError: Int
    let psnr: Double?
    var bitExact: Bool { maxError == 0 }
}

func runCompareCommand(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    guard let inPath = options.values["--input"], let refPath = options.values["--reference"] else {
        throw UsageError(message: "compare requires --input (-i) and --reference (-r).")
    }
    if options.values["--output"] != nil {
        throw UsageError(message: "--output is not accepted by compare.")
    }

    let modeOpt = options.values["--mode"]?.lowercased()
    if let modeOpt, !["2d", "3d", "lossless"].contains(modeOpt) {
        throw UsageError(message: "--mode for compare must be 2d or 3d.")
    }

    var maxAllowedErr: Int? = nil
    if let meStr = options.values["--max-error"] {
        guard let me = Int(meStr), me >= 0 else {
            throw UsageError(message: "--max-error for compare must be a non-negative integer.")
        }
        maxAllowedErr = me
    }
    var minAllowedPSNR: Double? = nil
    if let mpStr = options.values["--min-psnr"] {
        guard let mp = Double(mpStr), mp.isFinite, mp > 0 else {
            throw UsageError(message: "--min-psnr must be a positive number.")
        }
        minAllowedPSNR = mp
    }

    var limitOpts = options
    limitOpts.values.removeValue(forKey: "--mode")
    limitOpts.values.removeValue(forKey: "--max-error")
    let lim = try limits(from: limitOpts, command: "compare")
    let execPolicy = try parseExecutionPolicy(options.values["--backend"])
    let rawGeom = try parseRawGeometry(from: options)

    let ext1 = URL(fileURLWithPath: inPath).pathExtension.lowercased()
    let ext2 = URL(fileURLWithPath: refPath).pathExtension.lowercased()
    let is3D = (modeOpt == "3d") ||
               ["jp3d", "j3d"].contains(ext1) ||
               ["jp3d", "j3d"].contains(ext2) ||
               ((rawGeom?.depth ?? 1) > 1)

    if is3D {
        return try await runCompare3D(
            inPath: inPath,
            refPath: refPath,
            context: context,
            limits: lim,
            executionPolicy: execPolicy,
            rawGeom: rawGeom,
            maxAllowedErr: maxAllowedErr,
            minAllowedPSNR: minAllowedPSNR,
            started: started
        )
    }

    let precision = try parseOptionalPrecision(from: options)

    try context.diagnostic(2, "loading images for 2D comparison")
    let imgA = try await load2DImageForAnalysis(
        path: inPath,
        options: options,
        limits: lim,
        executionPolicy: execPolicy,
        precision: precision,
        rawGeometry: rawGeom
    )
    let imgB = try await load2DImageForAnalysis(
        path: refPath,
        options: options,
        limits: lim,
        executionPolicy: execPolicy,
        precision: precision,
        rawGeometry: rawGeom
    )

    let dA = imgA.descriptor
    let dB = imgB.descriptor
    guard dA.width == dB.width,
          dA.height == dB.height,
          dA.components.count == dB.components.count else {
        throw ExitFailure(
            status: 4,
            message: "unsupported: compared images do not have matching dimensions or component counts (\(dA.width)x\(dA.height)x\(dA.components.count) vs \(dB.width)x\(dB.height)x\(dB.components.count))."
        )
    }

    let w = dA.width
    let h = dA.height
    let cCount = dA.components.count
    let bitDepth = max(dA.meaningfulBits, dB.meaningfulBits)
    let peak = Double(max(1, (1 << bitDepth) - 1))
    let pixelCount = Double(max(1, w * h))

    var compMetrics: [ComponentComparisonMetrics] = []
    compMetrics.reserveCapacity(cCount)

    try imgA.storage.withUnsafeBytes { rawA in
        try imgB.storage.withUnsafeBytes { rawB in
            for c in 0..<cCount {
                var sumSq = 0.0
                var sumAbs = 0.0
                var maxErr = 0
                for y in 0..<h {
                    for x in 0..<w {
                        let sA = readLogicalSample(rawA, descriptor: dA, component: c, x: x, y: y)
                        let sB = readLogicalSample(rawB, descriptor: dB, component: c, x: x, y: y)
                        let diff = abs(sA - sB)
                        if diff > maxErr { maxErr = diff }
                        let dVal = Double(diff)
                        sumAbs += dVal
                        sumSq += dVal * dVal
                    }
                }
                let mse = sumSq / pixelCount
                let mae = sumAbs / pixelCount
                let psnr: Double? = (mse == 0.0) ? nil : (10.0 * log10((peak * peak) / mse))
                compMetrics.append(
                    ComponentComparisonMetrics(
                        component: c,
                        mse: mse,
                        mae: mae,
                        maxError: maxErr,
                        psnr: psnr
                    )
                )
            }
        }
    }

    let overallMSE = compMetrics.reduce(0.0) { $0 + $1.mse } / Double(max(1, cCount))
    let overallMAE = compMetrics.reduce(0.0) { $0 + $1.mae } / Double(max(1, cCount))
    let overallMaxErr = compMetrics.reduce(0) { max($0, $1.maxError) }
    let overallPSNR: Double? = (overallMSE == 0.0) ? nil : (10.0 * log10((peak * peak) / overallMSE))
    let bitExact = (overallMaxErr == 0)

    try verifyComparisonThresholds(
        requireBitExact: options.bitExact,
        maxAllowedErr: maxAllowedErr,
        minAllowedPSNR: minAllowedPSNR,
        bitExact: bitExact,
        maxError: overallMaxErr,
        psnr: overallPSNR
    )

    let elapsed = ContinuousClock.now - started
    if options.json {
        let compJSON: [[String: Any]] = compMetrics.map { m in
            [
                "bitExact": m.bitExact,
                "component": m.component,
                "mae": m.mae,
                "maxError": m.maxError,
                "mse": m.mse,
                "psnr": m.psnr.map { $0 as Any } ?? "infinity"
            ]
        }
        try report([
            "bitDepth": bitDepth,
            "bitExact": bitExact,
            "components": compJSON,
            "elapsedSeconds": elapsedSeconds(elapsed),
            "height": h,
            "mae": overallMAE,
            "maxError": overallMaxErr,
            "mode": "2d",
            "mse": overallMSE,
            "passed": true,
            "psnr": overallPSNR.map { $0 as Any } ?? "infinity",
            "signed": dA.sampleType == .signedInteger,
            "width": w
        ], json: true, to: .standardOutput)
    } else {
        let psnrStr = overallPSNR.map { String(format: "%.2f dB", $0) } ?? "infinity (bit-exact)"
        var lines = [
            "mode: 2d",
            "width: \(w)",
            "height: \(h)",
            "components: \(cCount)",
            "bit depth: \(bitDepth)",
            "bit-exact: \(bitExact)",
            "max error: \(overallMaxErr)",
            String(format: "mae: %.6f", overallMAE),
            String(format: "mse: %.6f", overallMSE),
            "psnr: \(psnrStr)"
        ]
        for m in compMetrics {
            let cp = m.psnr.map { String(format: "%.2f dB", $0) } ?? "infinity"
            lines.append(String(format: "component %d: mse=%.6f mae=%.6f maxError=%d psnr=%@", m.component, m.mse, m.mae, m.maxError, cp))
        }
        try write(lines.joined(separator: "\n") + "\n", to: .standardOutput)
    }

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "compare completed")
    return 0
}

private func runCompare3D(
    inPath: String,
    refPath: String,
    context: CodecContext,
    limits: ResourceLimits,
    executionPolicy: ExecutionPolicy,
    rawGeom: CLIRawGeometry?,
    maxAllowedErr: Int?,
    minAllowedPSNR: Double?,
    started: ContinuousClock.Instant
) async throws -> Int32 {
    let options = context.options
    try context.diagnostic(2, "loading volumes for 3D comparison")
    let volA = try await load3DVolumeForAnalysis(
        path: inPath,
        options: options,
        limits: limits,
        executionPolicy: executionPolicy,
        rawGeom: rawGeom
    )
    let volB = try await load3DVolumeForAnalysis(
        path: refPath,
        options: options,
        limits: limits,
        executionPolicy: executionPolicy,
        rawGeom: rawGeom
    )

    guard volA.width == volB.width,
          volA.height == volB.height,
          volA.depth == volB.depth,
          volA.components.count == volB.components.count else {
        throw ExitFailure(status: 4, message: "unsupported: compared 3D volumes do not have matching dimensions or component counts.")
    }

    let w = volA.width
    let h = volA.height
    let d = volA.depth
    let cCount = volA.components.count
    let voxelCount = try checkedMultiply(try checkedMultiply(w, h), d)
    let firstA = volA.components[0]
    let bitDepth = max(firstA.bitDepth, volB.components[0].bitDepth)
    let clampedPeakShift = UInt64(min(62, max(1, bitDepth)))
    let peak = Double((UInt64(1) << clampedPeakShift) - 1)
    let totalVoxelsDouble = Double(max(1, voxelCount))

    var compMetrics: [ComponentComparisonMetrics] = []
    for c in 0..<cCount {
        let compA = volA.components[c]
        let compB = volB.components[c]
        let bpsA = compA.bytesPerSample
        let bpsB = compB.bytesPerSample
        var sumSq = 0.0
        var sumAbs = 0.0
        var maxErr = 0
        compA.data.withUnsafeBytes { rawA in
            compB.data.withUnsafeBytes { rawB in
                let ptrA = rawA.bindMemory(to: UInt8.self)
                let ptrB = rawB.bindMemory(to: UInt8.self)
                for vIdx in 0..<voxelCount {
                    let sA = readVolumeComponentSample64(ptrA, vIdx: vIdx, bps: bpsA, bitDepth: compA.bitDepth, signed: compA.signed)
                    let sB = readVolumeComponentSample64(ptrB, vIdx: vIdx, bps: bpsB, bitDepth: compB.bitDepth, signed: compB.signed)
                    let diffU64: UInt64 = sA >= sB
                        ? UInt64(bitPattern: sA &- sB)
                        : UInt64(bitPattern: sB &- sA)
                    let clampedErr = diffU64 > UInt64(Int.max) ? Int.max : Int(diffU64)
                    if clampedErr > maxErr { maxErr = clampedErr }
                    let dVal = Double(diffU64)
                    sumAbs += dVal
                    sumSq += dVal * dVal
                }
            }
        }
        let mse = sumSq / totalVoxelsDouble
        let mae = sumAbs / totalVoxelsDouble
        let psnr: Double? = (mse == 0.0) ? nil : (10.0 * log10((peak * peak) / mse))
        compMetrics.append(ComponentComparisonMetrics(component: c, mse: mse, mae: mae, maxError: maxErr, psnr: psnr))
    }

    let overallMSE = compMetrics.reduce(0.0) { $0 + $1.mse } / Double(max(1, cCount))
    let overallMAE = compMetrics.reduce(0.0) { $0 + $1.mae } / Double(max(1, cCount))
    let overallMaxErr = compMetrics.reduce(0) { max($0, $1.maxError) }
    let overallPSNR: Double? = (overallMSE == 0.0) ? nil : (10.0 * log10((peak * peak) / overallMSE))
    let bitExact = (overallMaxErr == 0)

    try verifyComparisonThresholds(
        requireBitExact: options.bitExact,
        maxAllowedErr: maxAllowedErr,
        minAllowedPSNR: minAllowedPSNR,
        bitExact: bitExact,
        maxError: overallMaxErr,
        psnr: overallPSNR
    )

    let elapsed = ContinuousClock.now - started
    if options.json {
        let compJSON: [[String: Any]] = compMetrics.map { m in
            [
                "bitExact": m.bitExact,
                "component": m.component,
                "mae": m.mae,
                "maxError": m.maxError,
                "mse": m.mse,
                "psnr": m.psnr.map { $0 as Any } ?? "infinity"
            ]
        }
        try report([
            "bitDepth": bitDepth,
            "bitExact": bitExact,
            "components": compJSON,
            "depth": d,
            "elapsedSeconds": elapsedSeconds(elapsed),
            "height": h,
            "mae": overallMAE,
            "maxError": overallMaxErr,
            "mode": "3d",
            "mse": overallMSE,
            "passed": true,
            "psnr": overallPSNR.map { $0 as Any } ?? "infinity",
            "signed": firstA.signed,
            "width": w
        ], json: true, to: .standardOutput)
    } else {
        let psnrStr = overallPSNR.map { String(format: "%.2f dB", $0) } ?? "infinity (bit-exact)"
        let lines = [
            "mode: 3d",
            "width: \(w)",
            "height: \(h)",
            "depth: \(d)",
            "components: \(cCount)",
            "bit depth: \(bitDepth)",
            "bit-exact: \(bitExact)",
            "max error: \(overallMaxErr)",
            String(format: "mae: %.6f", overallMAE),
            String(format: "mse: %.6f", overallMSE),
            "psnr: \(psnrStr)"
        ]
        try write(lines.joined(separator: "\n") + "\n", to: .standardOutput)
    }

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "compare 3d completed")
    return 0
}

private func readVolumeComponentSample64(
    _ bytes: UnsafeBufferPointer<UInt8>,
    vIdx: Int,
    bps: Int,
    bitDepth: Int,
    signed: Bool
) -> Int64 {
    let off = vIdx * bps
    guard bps > 0, off + bps <= bytes.count else { return 0 }
    var rawWord: UInt64 = 0
    for b in 0..<bps {
        rawWord |= UInt64(bytes[off + b]) << (b * 8)
    }
    let storageBitWidth = bps * 8
    if signed {
        let storageSignMask = UInt64(1) << (storageBitWidth - 1)
        let bitDepthSignMask = UInt64(1) << (max(1, bitDepth) - 1)
        if (rawWord & storageSignMask) != 0 {
            let extended = storageBitWidth < 64
                ? (rawWord | (~UInt64(0) << storageBitWidth))
                : rawWord
            return Int64(bitPattern: extended)
        } else if bitDepth < storageBitWidth
            && (rawWord >> bitDepth) == 0
            && (rawWord & bitDepthSignMask) != 0 {
            let extended = rawWord | (~UInt64(0) << bitDepth)
            return Int64(bitPattern: extended)
        }
        return Int64(bitPattern: rawWord)
    } else {
        let mask: UInt64 = bitDepth < 64 ? ((UInt64(1) << bitDepth) - 1) : ~UInt64(0)
        return Int64(bitPattern: rawWord & mask)
    }
}

private func verifyComparisonThresholds(
    requireBitExact: Bool,
    maxAllowedErr: Int?,
    minAllowedPSNR: Double?,
    bitExact: Bool,
    maxError: Int,
    psnr: Double?
) throws {
    if requireBitExact && !bitExact {
        throw ExitFailure(status: 3, message: "comparison failed: images are not bit-exact (maxError=\(maxError)).")
    }
    if let allowedMax = maxAllowedErr, maxError > allowedMax {
        throw ExitFailure(status: 3, message: "comparison failed: maxError (\(maxError)) exceeds threshold (\(allowedMax)).")
    }
    if let minPSNR = minAllowedPSNR, let actualPSNR = psnr, actualPSNR < minPSNR {
        throw ExitFailure(status: 3, message: String(format: "comparison failed: PSNR (%.2f dB) is below threshold (%.2f dB).", actualPSNR, minPSNR))
    }
}

func load2DImageForAnalysis(
    path: String,
    options: Options,
    limits: ResourceLimits,
    executionPolicy: ExecutionPolicy,
    precision: Int?,
    rawGeometry: CLIRawGeometry?
) async throws -> Image {
    try admitRegularFileSize(
        path,
        maxCategoryBytes: max(limits.maximumCompressedBytes, limits.maximumDecodedBytes),
        memoryLimit: limits.maximumMemoryBytes
    )
    let data = try readInput(path)
    guard data.count <= max(limits.maximumCompressedBytes, limits.maximumDecodedBytes),
          data.count <= limits.maximumMemoryBytes else {
        throw ExitFailure(status: 5, message: "resource limit: input exceeds memory admission limit.")
    }
    if isCompressedJ2KStream(data) {
        let decoded = try await Decoder().decode(
            data,
            options: .init(resourceLimits: limits, executionPolicy: executionPolicy)
        )
        return decoded.image
    }
    let declaredInFmt = options.values["--input-format"].flatMap { CLIUncompressedFormat(cliName: $0) }
    let (img, _) = try parseUncompressedImage(
        data,
        declaredFormat: declaredInFmt,
        declaredPrecision: precision,
        rawGeometry: rawGeometry,
        limits: limits
    )
    return img
}

private func load3DVolumeForAnalysis(
    path: String,
    options: Options,
    limits: ResourceLimits,
    executionPolicy: ExecutionPolicy,
    rawGeom: CLIRawGeometry?
) async throws -> J2KVolume {
    let sliceRange = try parseSliceRange(from: options)
    let spacing = try parse3DDoubleTriplet(options.values["--spacing"], name: "--spacing")
    let origin = try parse3DDoubleTriplet(options.values["--origin"], name: "--origin")

    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        return try loadSliceDirectoryVolume(
            at: URL(fileURLWithPath: path),
            sliceRange: sliceRange,
            spacing: spacing,
            origin: origin,
            limits: limits
        )
    }
    try admitRegularFileSize(
        path,
        maxCategoryBytes: max(limits.maximumCompressedBytes, limits.maximumDecodedBytes),
        memoryLimit: limits.maximumMemoryBytes
    )
    let data = try readInput(path)
    if detectUncompressedFormat(data) == .nrrd {
        return try parseNRRDVolume(data, limits: limits)
    }
    if data.count >= 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0x4F {
        let dec = try VolumeDecoder()
        let result = try await dec.decode(
            data,
            options: VolumeDecodeOptions(resourceLimits: limits, executionPolicy: executionPolicy)
        )
        return result.volume
    }
    if let geom = rawGeom, geom.depth >= 1 {
        return try parseRAWVolume(
            data,
            geometry: geom,
            spacing: spacing,
            origin: origin,
            limits: limits
        )
    }
    let dec = try VolumeDecoder()
    let result = try await dec.decode(
        data,
        options: VolumeDecodeOptions(resourceLimits: limits, executionPolicy: executionPolicy)
    )
    return result.volume
}

// MARK: - Encode3D & Decode3D Commands (`swiftj2k-cli encode3d` / `decode3d`)

func runEncode3DCommand(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    guard let inPath = options.values["--input"], let outPath = options.values["--output"] else {
        throw UsageError(message: "encode3d requires --input and --output.")
    }
    var limitOpts = options
    limitOpts.values.removeValue(forKey: "--mode")
    let lim = try limits(from: limitOpts, command: "encode3d")
    let rawGeom = try parseRawGeometry(from: options)
    let sliceRange = try parseSliceRange(from: options)
    let spacing = try parse3DDoubleTriplet(options.values["--spacing"], name: "--spacing")
    let origin = try parse3DDoubleTriplet(options.values["--origin"], name: "--origin")

    var targetPSNR = 40.0
    if let psnrText = options.values["--psnr"] {
        guard let p = Double(psnrText), p.isFinite, p > 0 else {
            throw UsageError(message: "--psnr must be a positive number.")
        }
        targetPSNR = p
    } else if let qText = options.values["--quality"] {
        guard let q = Double(qText), q.isFinite, (0.0...1.0).contains(q) else {
            throw UsageError(message: "--quality must be in 0.0..1.0.")
        }
        targetPSNR = 25.0 + q * 35.0
    }

    let compressionMode: JP3DCompressionMode
    if let codecName = options.values["--codec"]?.lowercased() {
        switch codecName {
        case "j2k-lossless", "lossless":
            compressionMode = .lossless
        case "j2k-lossy", "lossy":
            compressionMode = .lossy(psnr: targetPSNR)
        case "htj2k-lossless", "htj2k":
            compressionMode = .losslessHTJ2K
        case "htj2k-lossy":
            compressionMode = .lossyHTJ2K(psnr: targetPSNR)
        default:
            throw UsageError(message: "Unknown 3D --codec '\(codecName)'; expected j2k-lossless, j2k-lossy, htj2k-lossless or htj2k-lossy.")
        }
    } else {
        let outFmt = options.values["--output-format"]?.lowercased()
        let isHT = (outFmt == "htj2k" || outFmt == "jph" || options.htj2k)
        let modeStr = options.values["--mode"]?.lowercased() ?? "lossless"
        guard ["lossless", "near-lossless", "lossy"].contains(modeStr) else {
            throw UsageError(message: "--mode must be lossless, near-lossless or lossy.")
        }
        let isLossy = (modeStr != "lossless")
        switch (isHT, isLossy) {
        case (false, false): compressionMode = .lossless
        case (false, true):  compressionMode = .lossy(psnr: targetPSNR)
        case (true, false):  compressionMode = .losslessHTJ2K
        case (true, true):   compressionMode = .lossyHTJ2K(psnr: targetPSNR)
        }
    }

    var tiling: JP3DTilingConfiguration = .default
    if let tsText = options.values["--tile-size"] {
        let parts = tsText.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 >= 1 }) else {
            throw UsageError(message: "--tile-size for encode3d must be WxHxD with positive integers.")
        }
        tiling = JP3DTilingConfiguration(tileSizeX: parts[0], tileSizeY: parts[1], tileSizeZ: parts[2])
    }

    var levelsX = 3, levelsY = 3, levelsZ = 2
    if let lvlText = options.values["--levels"] {
        let parts = lvlText.split(whereSeparator: { $0 == "," || $0 == "x" || $0 == "X" }).compactMap { Int($0) }
        if parts.count == 1, (0...10).contains(parts[0]) {
            levelsX = parts[0]; levelsY = parts[0]; levelsZ = min(2, parts[0])
        } else if parts.count == 3, parts.allSatisfy({ (0...10).contains($0) }) {
            levelsX = parts[0]; levelsY = parts[1]; levelsZ = parts[2]
        } else {
            throw UsageError(message: "--levels for encode3d must be N or X,Y,Z in 0..10.")
        }
    }

    var progression: JP3DProgressionOrder = .lrcps
    if let pName = options.values["--progression"]?.lowercased() {
        switch pName {
        case "lrcps": progression = .lrcps
        case "rlcps": progression = .rlcps
        case "pcrls", "pcrs": progression = .pcrls
        case "slrcp": progression = .slrcp
        case "cprls": progression = .cprls
        default:
            throw UsageError(message: "--progression for encode3d must be lrcps, rlcps, pcrls, slrcp or cprls.")
        }
    }

    var qualityLayers = 1
    if let lText = options.values["--layers"] {
        guard let l = Int(lText), (1...255).contains(l) else {
            throw UsageError(message: "--layers must be 1..255.")
        }
        qualityLayers = l
    }

    try context.diagnostic(2, "loading 3D volume")
    let execPolicy = try parseExecutionPolicy(options.values["--backend"])
    let copyPolicy: CopyPolicy = options.values["--copy-policy"] == "allow-copy" ? .allowCopy : .requireSharedStorage
    let metadataPolicy: MetadataPolicy = options.values["--metadata-policy"] == "discard-ancillary" ? .discardAncillary : .preserve
    let volume: J2KVolume
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: inPath, isDirectory: &isDir), isDir.boolValue {
        volume = try loadSliceDirectoryVolume(
            at: URL(fileURLWithPath: inPath),
            sliceRange: sliceRange,
            spacing: spacing,
            origin: origin,
            limits: lim
        )
    } else {
        try admitRegularFileSize(inPath, maxCategoryBytes: lim.maximumDecodedBytes, memoryLimit: lim.maximumMemoryBytes)
        let data = try readInput(inPath)
        guard data.count <= lim.maximumDecodedBytes, data.count <= lim.maximumMemoryBytes else {
            throw ExitFailure(status: 5, message: "resource limit: volume input exceeds memory limit.")
        }
        if detectUncompressedFormat(data) == .nrrd {
            volume = try parseNRRDVolume(data, limits: lim)
        } else if let geom = rawGeom, geom.depth >= 1 {
            volume = try parseRAWVolume(
                data,
                geometry: geom,
                spacing: spacing,
                origin: origin,
                limits: lim
            )
        } else {
            throw UsageError(message: "encode3d input must be a slice directory, a 3D NRRD volume, or a RAW volume with --dimensions WxHxD.")
        }
    }

    let volEncConfig = try VolumeEncoderConfiguration(
        compressionMode: compressionMode,
        tiling: tiling,
        progressionOrder: progression,
        qualityLayers: qualityLayers,
        levelsX: levelsX,
        levelsY: levelsY,
        levelsZ: levelsZ
    )

    try context.diagnostic(2, "encoding 3D volume")
    let encoder = try VolumeEncoder(configuration: volEncConfig)
    let result = try await encoder.encode(
        volume,
        options: VolumeEncodeOptions(
            resourceLimits: lim,
            executionPolicy: execPolicy,
            copyPolicy: copyPolicy,
            metadataPolicy: metadataPolicy
        )
    )

    try context.diagnostic(2, "publishing output")
    try publish(result.data, to: outPath, overwrite: options.overwrite)

    let elapsed = ContinuousClock.now - started
    let bitDepth = volume.components.first?.bitDepth ?? 8
    try report([
        "bitDepth": bitDepth,
        "command": "encode3d",
        "components": result.componentCount,
        "depth": result.depth,
        "elapsedSeconds": elapsedSeconds(elapsed),
        "height": result.height,
        "lossless": result.isLossless,
        "outputBytes": result.data.count,
        "totalTiles": result.tileCount,
        "width": result.width
    ], json: options.json, to: .standardError)

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "encode3d completed; output published")
    return 0
}

func runDecode3DCommand(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    guard let inPath = options.values["--input"], let outPath = options.values["--output"] else {
        throw UsageError(message: "decode3d requires --input and --output.")
    }
    let lim = try limits(from: options, command: "decode3d")
    let execPolicy = try parseExecutionPolicy(options.values["--backend"])
    let copyPolicy: CopyPolicy = options.values["--copy-policy"] == "allow-copy" ? .allowCopy : .requireSharedStorage
    let metadataPolicy: MetadataPolicy = options.values["--metadata-policy"] == "discard-ancillary" ? .discardAncillary : .preserve
    let sliceRange = try parseSliceRange(from: options)

    var roiRegion: (x: Int, y: Int, z: Int, w: Int, h: Int, d: Int, xEnd: Int, yEnd: Int, zEnd: Int)? = nil
    if let regText = options.values["--region"] {
        let rawParts = regText.split(separator: ",", omittingEmptySubsequences: false)
        guard rawParts.count == 6 else {
            throw UsageError(message: "--region for decode3d must be X,Y,Z,W,H,D with non-negative origin and positive dimensions.")
        }
        var parts: [Int] = []
        parts.reserveCapacity(6)
        for token in rawParts {
            guard let v = Int(token) else {
                throw UsageError(message: "--region for decode3d contains an invalid or out-of-range integer.")
            }
            parts.append(v)
        }
        guard parts[0] >= 0, parts[1] >= 0, parts[2] >= 0,
              parts[3] > 0, parts[4] > 0, parts[5] > 0 else {
            throw UsageError(message: "--region for decode3d must be X,Y,Z,W,H,D with non-negative origin and positive dimensions.")
        }
        let (xEnd, ovX) = parts[0].addingReportingOverflow(parts[3])
        let (yEnd, ovY) = parts[1].addingReportingOverflow(parts[4])
        let (zEnd, ovZ) = parts[2].addingReportingOverflow(parts[5])
        guard !ovX, !ovY, !ovZ else {
            throw UsageError(message: "--region for decode3d overflows integer coordinate bounds.")
        }
        roiRegion = (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], xEnd, yEnd, zEnd)
    }

    var resolutionLevel = 0
    if let rText = options.values["--resolution-level"] {
        guard let r = Int(rText), (0...32).contains(r) else {
            throw UsageError(message: "--resolution-level/--scale must be 0..32.")
        }
        resolutionLevel = r
    }

    var maxLayers = 0
    if let lText = options.values["--layers"] {
        guard let l = Int(lText), l >= 1 else {
            throw UsageError(message: "--layers/--quality-layers must be >= 1.")
        }
        maxLayers = l
    }

    let declaredOutFmt: CLIUncompressedFormat?
    if let outFmtText = options.values["--output-format"] {
        guard let f = CLIUncompressedFormat(cliName: outFmtText) else {
            throw UsageError(message: "--output-format for decode3d must be nrrd, raw, pgm, ppm, pnm, png or tiff.")
        }
        declaredOutFmt = f
    } else {
        declaredOutFmt = nil
    }

    try context.diagnostic(2, "reading 3D codestream")
    try admitRegularFileSize(inPath, maxCategoryBytes: lim.maximumCompressedBytes, memoryLimit: lim.maximumMemoryBytes)
    let inputData = try readInput(inPath)
    guard inputData.count <= lim.maximumCompressedBytes, inputData.count <= lim.maximumMemoryBytes else {
        throw ExitFailure(status: 5, message: "resource limit: input exceeds compressed byte limit.")
    }

    let volDecConfig = try VolumeDecoderConfiguration(
        maxQualityLayers: maxLayers,
        resolutionLevel: resolutionLevel,
        tolerateTruncation: false
    )
    let volDecoder = try VolumeDecoder(configuration: volDecConfig)
    let baseDecOpts = VolumeDecodeOptions(
        resourceLimits: lim,
        executionPolicy: execPolicy,
        copyPolicy: copyPolicy,
        metadataPolicy: metadataPolicy
    )
    let volInfo = try volDecoder.inspect(inputData, options: baseDecOpts)

    var requestedRegion: JP3DRegion? = nil
    if let roi = roiRegion {
        guard roi.xEnd <= volInfo.width,
              roi.yEnd <= volInfo.height,
              roi.zEnd <= volInfo.depth else {
            throw UsageError(
                message: "--region (\(roi.x),\(roi.y),\(roi.z),\(roi.w),\(roi.h),\(roi.d)) exceeds volume dimensions (\(volInfo.width)x\(volInfo.height)x\(volInfo.depth))."
            )
        }
        requestedRegion = JP3DRegion(
            x: roi.x..<roi.xEnd,
            y: roi.y..<roi.yEnd,
            z: roi.z..<roi.zEnd
        )
    } else if let zRange = sliceRange {
        let (zUpperExclusive, ovZ) = zRange.upperBound.addingReportingOverflow(1)
        guard !ovZ, zRange.lowerBound >= 0, zRange.upperBound < volInfo.depth else {
            throw UsageError(
                message: "--slice-range is out of bounds for volume depth (\(volInfo.depth))."
            )
        }
        requestedRegion = JP3DRegion(
            x: 0..<volInfo.width,
            y: 0..<volInfo.height,
            z: zRange.lowerBound..<zUpperExclusive
        )
    }

    try context.diagnostic(2, "decoding 3D volume")
    let decoded = try await volDecoder.decode(
        inputData,
        options: VolumeDecodeOptions(
            resourceLimits: lim,
            executionPolicy: execPolicy,
            copyPolicy: copyPolicy,
            metadataPolicy: metadataPolicy,
            regionOfInterest: requestedRegion
        )
    )
    let decodedVolume = decoded.volume
    let tilesDecoded: Int
    if let r = requestedRegion {
        let tilingCfg = JP3DTilingConfiguration(
            tileSizeX: volInfo.tileSizeX,
            tileSizeY: volInfo.tileSizeY,
            tileSizeZ: volInfo.tileSizeZ
        )
        tilesDecoded = tilingCfg.tilesIntersecting(
            region: r,
            volumeWidth: volInfo.width,
            volumeHeight: volInfo.height,
            volumeDepth: volInfo.depth
        ).count
    } else {
        tilesDecoded = volInfo.tileCount
    }

    let outExt = (outPath == "-") ? "" : URL(fileURLWithPath: outPath).pathExtension.lowercased()
    let extFmt = CLIUncompressedFormat(cliName: outExt)

    try context.diagnostic(2, "publishing output")
    var writtenBytes = 0
    if outPath == "-" {
        let fmt = declaredOutFmt ?? .nrrd
        let outData = (fmt == .raw) ? try formatRAWVolume(decodedVolume) : try formatNRRDVolume(decodedVolume)
        try publish(outData, to: "-", overwrite: true)
        writtenBytes = outData.count
    } else if (declaredOutFmt == .nrrd && extFmt == .nrrd) || (declaredOutFmt == nil && extFmt == .nrrd) {
        let nrrdData = try formatNRRDVolume(decodedVolume)
        try publish(nrrdData, to: outPath, overwrite: options.overwrite)
        writtenBytes = nrrdData.count
    } else if (declaredOutFmt == .raw && extFmt == .raw) || (declaredOutFmt == nil && extFmt == .raw) {
        let rawData = try formatRAWVolume(decodedVolume)
        try publish(rawData, to: outPath, overwrite: options.overwrite)
        writtenBytes = rawData.count
    } else {
        // Write a directory of 2D slices
        let sliceFmt: CLIUncompressedFormat = declaredOutFmt ?? extFmt ?? (decodedVolume.components.count == 3 ? .ppm : .pgm)
        let dirURL = URL(fileURLWithPath: outPath)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            throw ExitFailure(status: 6, message: "output I/O failure: slice directory could not be created.")
        }
        let pattern = options.values["--slice-naming"] ?? "slice_%04d.\(sliceFmt.rawValue)"
        for z in 0..<decodedVolume.depth {
            let sliceImg = try extractVolumeSliceImage(decodedVolume, sliceIndex: z, limits: lim)
            let sliceData = try formatUncompressedImage(sliceImg, format: sliceFmt)
            let fileName = formatSliceFilename(pattern: pattern, index: z, defaultExt: sliceFmt.rawValue)
            let fileURL = dirURL.appendingPathComponent(fileName)
            try publish(sliceData, to: fileURL.path, overwrite: options.overwrite)
            writtenBytes += sliceData.count
        }
    }

    let elapsed = ContinuousClock.now - started
    let bitDepth = decodedVolume.components.first?.bitDepth ?? 8
    try report([
        "bitDepth": bitDepth,
        "command": "decode3d",
        "components": decodedVolume.components.count,
        "depth": decodedVolume.depth,
        "elapsedSeconds": elapsedSeconds(elapsed),
        "height": decodedVolume.height,
        "inputBytes": inputData.count,
        "outputBytes": writtenBytes,
        "tilesDecoded": tilesDecoded,
        "width": decodedVolume.width
    ], json: options.json, to: .standardError)

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "decode3d completed; output published")
    return 0
}

private func formatSliceFilename(pattern: String, index: Int, defaultExt: String) -> String {
    if let range = pattern.range(of: "%04d") {
        return pattern.replacingCharacters(in: range, with: String(format: "%04d", index))
    } else if let range = pattern.range(of: "%03d") {
        return pattern.replacingCharacters(in: range, with: String(format: "%03d", index))
    } else if let range = pattern.range(of: "%d") {
        return pattern.replacingCharacters(in: range, with: "\(index)")
    } else {
        return String(format: "slice_%04d.%@", index, defaultExt)
    }
}

// MARK: - JPIP Command (`swiftj2k-cli jpip client` / `swiftj2k-cli jpip server`)

func runJPIPCommand(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    guard let role = (options.subcommand ?? options.values["--mode"])?.lowercased() else {
        throw UsageError(message: "jpip requires a subcommand: 'client' or 'server'.")
    }
    switch role {
    case "client":
        return try await runJPIPClient(context, started: started)
    case "server":
        return try await runJPIPServer(context, started: started)
    default:
        throw UsageError(message: "Unknown jpip subcommand '\(role)'; expected 'client' or 'server'.")
    }
}

private func runJPIPClient(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    var limitOpts = options
    limitOpts.values.removeValue(forKey: "--mode")
    let lim = try limits(from: limitOpts, command: "jpip")
    let execPolicy = try parseExecutionPolicy(options.values["--backend"])
    let copyPolicy: CopyPolicy = options.values["--copy-policy"] == "allow-copy" ? .allowCopy : .requireSharedStorage
    let metadataPolicy: MetadataPolicy = options.values["--metadata-policy"] == "discard-ancillary" ? .discardAncillary : .preserve

    let singleFile = options.values["--single-file"] ?? options.values["--input"]
    let dataDir = options.values["--data-dir"]
    var ephemeralPort = 18_492
    if let pText = options.values["--port"] {
        guard let p = Int(pText), (1...65535).contains(p) else {
            throw UsageError(message: "--port must be in 1..65535.")
        }
        ephemeralPort = p
    }

    var regionTuple: (x: Int, y: Int, width: Int, height: Int)? = nil
    if let regText = options.values["--region"] ?? options.values["--roi"] {
        let rawParts = regText.split(separator: ",", omittingEmptySubsequences: false)
        guard rawParts.count == 4 else {
            throw UsageError(message: "--region must be X,Y,W,H with non-negative origin and positive dimensions.")
        }
        var parts: [Int] = []
        parts.reserveCapacity(4)
        for token in rawParts {
            guard let v = Int(token) else {
                throw UsageError(message: "--region contains an invalid or out-of-range integer.")
            }
            parts.append(v)
        }
        guard parts[0] >= 0, parts[1] >= 0, parts[2] > 0, parts[3] > 0 else {
            throw UsageError(message: "--region must be X,Y,W,H with non-negative origin and positive dimensions.")
        }
        let (_, ovX) = parts[0].addingReportingOverflow(parts[2])
        let (_, ovY) = parts[1].addingReportingOverflow(parts[3])
        guard !ovX, !ovY else {
            throw UsageError(message: "--region overflows integer coordinate bounds.")
        }
        regionTuple = (parts[0], parts[1], parts[2], parts[3])
    }

    var resLevel: Int? = nil
    if let rText = options.values["--resolution-level"] {
        guard let r = Int(rText), (0...32).contains(r) else {
            throw UsageError(message: "--resolution-level must be in 0..32.")
        }
        resLevel = r
    }

    var maxLayers: Int? = nil
    if let lText = options.values["--layers"] {
        guard let l = Int(lText), l >= 1 else {
            throw UsageError(message: "--quality-layers/--layers must be >= 1.")
        }
        maxLayers = l
    }

    var compSubset: [Int]? = nil
    if let cText = options.values["--components"] {
        let comps = cText.split(separator: ",").compactMap { Int($0) }
        guard !comps.isEmpty, comps.allSatisfy({ $0 >= 0 }) else {
            throw UsageError(message: "--components for jpip client must be non-negative component indices (e.g. 0 or 0,1,2).")
        }
        compSubset = comps
    }

    let codingPref: JPIPCodingPreference
    switch (options.values["--coding-preference"] ?? "none").lowercased() {
    case "none", "auto": codingPref = .none
    case "htj2k", "jph": codingPref = .htj2k
    case "standard", "legacy", "j2k", "part1": codingPref = .legacy
    default:
        throw UsageError(message: "--coding-preference must be none, htj2k or standard.")
    }

    let resolvedTarget: String
    if let t = options.values["--target"], !t.isEmpty {
        resolvedTarget = t
    } else if let sf = singleFile {
        resolvedTarget = URL(fileURLWithPath: sf).lastPathComponent
    } else {
        throw UsageError(message: "jpip client requires --target <name> (or --single-file <path>).")
    }

    let serverURLString = options.values["--server"] ?? "http://localhost:\(ephemeralPort)"
    guard let serverURL = URL(string: serverURLString),
          let scheme = serverURL.scheme?.lowercased(),
          ["http", "https", "jpip", "ws", "wss"].contains(scheme) else {
        throw UsageError(message: "Invalid JPIP --server URL.")
    }

    var ephemeralServer: JPIPServer? = nil
    if singleFile != nil || dataDir != nil {
        let srv = JPIPServer(port: ephemeralPort)
        let registered = try await registerJPIPTargets(server: srv, singleFile: singleFile, dataDir: dataDir, limits: lim)
        guard !registered.isEmpty else {
            throw ExitFailure(status: 3, message: "malformed input: no JPEG 2000 targets found to register for JPIP.")
        }
        do {
            try await srv.start()
        } catch let error as J2KError {
            throw error.asCodecError
        }
        ephemeralServer = srv
    }

    let sessionConfig = try JPIPSessionConfiguration(codingPreference: codingPref)
    let session: JPIPStreamingSession
    if let srv = ephemeralServer {
        session = JPIPStreamingSession(server: srv, port: ephemeralPort, configuration: sessionConfig)
    } else {
        session = JPIPStreamingSession(serverURL: serverURL, configuration: sessionConfig)
    }

    let viewWindow = try JPIPViewWindow(
        region: regionTuple,
        resolutionLevel: resLevel,
        maxQualityLayers: maxLayers,
        components: compSubset
    )
    let streamingOpts = JPIPStreamingOptions(
        resourceLimits: lim,
        executionPolicy: execPolicy,
        copyPolicy: copyPolicy,
        metadataPolicy: metadataPolicy
    )

    try context.diagnostic(2, "streaming JPIP target")
    let delivered: JPIPDeliveredImage
    do {
        delivered = try await session.deliverImage(
            imageID: resolvedTarget,
            viewWindow: viewWindow,
            options: streamingOpts
        )
        try await session.close()
        if let srv = ephemeralServer {
            try await srv.stop()
        }
    } catch {
        if let srv = ephemeralServer {
            try? await srv.stop()
        }
        throw error
    }

    let d = delivered.image.descriptor
    var outputBytesWritten = 0
    if let outPath = options.values["--output"] {
        let declaredFmt = options.values["--output-format"].flatMap { CLIUncompressedFormat(cliName: $0) }
        let outFmt = declaredFmt ?? CLIUncompressedFormat.fromPathExtension(outPath) ?? .nrrd
        let formatted = try formatUncompressedImage(delivered.image, format: outFmt)
        try publish(formatted, to: outPath, overwrite: options.overwrite)
        outputBytesWritten = formatted.count
    }

    let elapsed = ContinuousClock.now - started
    let reportPayload: [String: Any] = [
        "backend": backendString(delivered.report.backend),
        "cachedBytes": delivered.cachedBytes,
        "cachedDataBins": delivered.cachedDataBins,
        "channelID": delivered.channelID ?? "none",
        "command": "jpip",
        "components": d.components.count,
        "elapsedSeconds": elapsedSeconds(elapsed),
        "fidelity": fidelityString(delivered.report.fidelity),
        "height": d.height,
        "meaningfulBits": d.meaningfulBits,
        "outputBytes": outputBytesWritten,
        "role": "client",
        "target": resolvedTarget,
        "width": d.width
    ]
    if options.json {
        let handle: FileHandle = (options.values["--output"] == "-") ? .standardError : .standardOutput
        try report(reportPayload, json: true, to: handle)
    } else if options.values["--output"] == nil {
        try write(
            "target: \(resolvedTarget)\nwidth: \(d.width)\nheight: \(d.height)\ncomponents: \(d.components.count)\nmeaningful bits: \(d.meaningfulBits)\ncached data bins: \(delivered.cachedDataBins)\ncached bytes: \(delivered.cachedBytes)\n",
            to: .standardOutput
        )
    }

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "jpip client completed")
    return 0
}

private func runJPIPServer(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    let singleFile = options.values["--single-file"] ?? options.values["--input"]
    let dataDir = options.values["--data-dir"]
    guard singleFile != nil || dataDir != nil else {
        throw UsageError(message: "jpip server requires --data-dir <dir> or --single-file <path>.")
    }
    var port = 8080
    if let pText = options.values["--port"] {
        guard let p = Int(pText), (1...65535).contains(p) else {
            throw UsageError(message: "--port must be in 1..65535.")
        }
        port = p
    }
    var maxClients = 32
    if let mcText = options.values["--max-sessions"] {
        guard let mc = Int(mcText), mc >= 1 else {
            throw UsageError(message: "--max-sessions must be >= 1.")
        }
        maxClients = mc
    }
    var sessionTimeout = 300.0
    if let stText = options.values["--session-timeout"] {
        guard let st = Double(stText), st.isFinite, st > 0 else {
            throw UsageError(message: "--session-timeout must be positive seconds.")
        }
        sessionTimeout = st
    }

    var limitOpts = options
    limitOpts.values.removeValue(forKey: "--mode")
    let lim = try limits(from: limitOpts, command: "jpip")

    let host = options.values["--host"] ?? "127.0.0.1"
    let config = JPIPServer.Configuration(
        maxClients: maxClients,
        sessionTimeout: sessionTimeout
    )
    let server = JPIPServer(port: port, configuration: config)
    let registered = try await registerJPIPTargets(server: server, singleFile: singleFile, dataDir: dataDir, limits: lim)
    guard !registered.isEmpty else {
        throw ExitFailure(status: 3, message: "malformed input: no JPEG 2000 targets found to register on JPIP server.")
    }

    do {
        try await server.start()
    } catch let error as J2KError {
        throw error.asCodecError
    }

    try context.diagnostic(2, "jpip server started on port \(port) (\(registered.count) targets)")

    if options.once {
        let firstTarget = registered[0]
        let verifyClient = JPIPClient(server: server)
        let session = try await verifyClient.createSession(target: firstTarget)
        let cid = await session.channelID ?? "verified"
        try await verifyClient.close()
        try await server.stop()
        let elapsed = ContinuousClock.now - started
        if options.json {
            try report([
                "command": "jpip",
                "elapsedSeconds": elapsedSeconds(elapsed),
                "host": host,
                "maxSessions": maxClients,
                "port": port,
                "registeredTargets": registered.count,
                "role": "server",
                "status": "stopped",
                "verifiedChannelID": cid
            ], json: true, to: .standardOutput)
        } else {
            try write("jpip server verified on \(host):\(port) (\(registered.count) targets registered)\n", to: .standardOutput)
        }
        try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
        try context.diagnostic(5, "jpip server once check completed")
        return 0
    }

    if options.json {
        try report([
            "command": "jpip",
            "host": host,
            "maxSessions": maxClients,
            "port": port,
            "registeredTargets": registered.count,
            "role": "server",
            "status": "running"
        ], json: true, to: .standardOutput)
    } else {
        try write("jpip server listening on \(host):\(port) (\(registered.count) targets)\n", to: .standardOutput)
    }

    while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(50))
    }
    try? await server.stop()
    throw CancellationError()
}

private func registerJPIPTargets(
    server: JPIPServer,
    singleFile: String?,
    dataDir: String?,
    limits: ResourceLimits
) async throws -> [String] {
    let validExts: Set<String> = ["j2k", "j2c", "jhc", "htj2k", "jp2", "jph", "jpx"]
    var names: [String] = []
    if let sf = singleFile {
        let url = URL(fileURLWithPath: sf)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExitFailure(status: 6, message: "I/O failure: JPIP target file could not be read.")
        }
        try admitRegularFileSize(
            url.path,
            maxCategoryBytes: limits.maximumCompressedBytes,
            memoryLimit: limits.maximumMemoryBytes
        )
        let name = url.lastPathComponent
        do {
            try await server.registerImage(name: name, at: url)
        } catch let error as J2KError {
            throw error.asCodecError
        }
        names.append(name)
    }
    if let dir = dataDir {
        let dirURL = URL(fileURLWithPath: dir)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ExitFailure(status: 6, message: "I/O failure: JPIP data directory could not be read.")
        }
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if validExts.contains(url.pathExtension.lowercased()) {
                try admitRegularFileSize(
                    url.path,
                    maxCategoryBytes: limits.maximumCompressedBytes,
                    memoryLimit: limits.maximumMemoryBytes
                )
                let name = url.lastPathComponent
                do {
                    try await server.registerImage(name: name, at: url)
                } catch let error as J2KError {
                    throw error.asCodecError
                }
                names.append(name)
            }
        }
    }
    return names
}

// MARK: - Batch Command (`swiftj2k-cli batch`)

struct BatchItemOutcome: Sendable {
    let index: Int
    let succeeded: Bool
    let inputBytes: Int
    let outputBytes: Int
    let error: (any Error)?
}

func runBatchCommand(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    guard let op = (options.subcommand ?? options.values["--op"])?.lowercased() else {
        throw UsageError(message: "batch requires a sub-operation: encode, decode, transcode, encode3d or decode3d.")
    }
    guard ["encode", "decode", "transcode", "encode3d", "decode3d"].contains(op) else {
        throw UsageError(message: "Unsupported batch operation '\(op)'; expected encode, decode, transcode, encode3d or decode3d.")
    }
    guard options.values["--input"] != nil || options.values["--input-list"] != nil else {
        throw UsageError(message: "batch requires --input (-i) or --input-list.")
    }
    guard let outDir = options.values["--output"] else {
        throw UsageError(message: "batch requires --output (-o) or --output-dir specifying the output directory.")
    }

    var limitOpts = options
    limitOpts.values.removeValue(forKey: "--mode")
    limitOpts.values.removeValue(forKey: "--max-error")
    let lim = try limits(from: limitOpts, command: "batch")

    let outDirURL = URL(fileURLWithPath: outDir)
    do {
        try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)
    } catch {
        throw ExitFailure(status: 6, message: "output I/O failure: batch output directory could not be created.")
    }

    let inputURLs = try discoverBatchInputs(options: options, operation: op)
    guard !inputURLs.isEmpty else {
        throw ExitFailure(status: 3, message: "malformed input: no matching input files found for batch operation.")
    }

    let outFormatStr = options.values["--output-format"]?.lowercased()
    let defaultSuffix: String
    switch op {
    case "encode":
        switch outFormatStr {
        case "htj2k": defaultSuffix = ".j2c"
        case "jp2":   defaultSuffix = ".jp2"
        case "jph":   defaultSuffix = ".jph"
        case "jpx":   defaultSuffix = ".jpx"
        default:      defaultSuffix = ".j2k"
        }
    case "decode":
        if let f = outFormatStr, let imgFmt = CLIUncompressedFormat(cliName: f) {
            defaultSuffix = ".\(imgFmt.rawValue)"
        } else {
            defaultSuffix = ".nrrd"
        }
    case "transcode":
        switch outFormatStr {
        case "j2k":   defaultSuffix = ".j2k"
        case "jp2":   defaultSuffix = ".jp2"
        case "jph":   defaultSuffix = ".jph"
        case "jpx":   defaultSuffix = ".jpx"
        default:      defaultSuffix = ".j2c"
        }
    case "encode3d":
        defaultSuffix = ".jp3d"
    case "decode3d":
        if let f = outFormatStr, let imgFmt = CLIUncompressedFormat(cliName: f) {
            defaultSuffix = ".\(imgFmt.rawValue)"
        } else {
            defaultSuffix = ".nrrd"
        }
    default:
        defaultSuffix = ".out"
    }
    let rawSuffix = options.values["--output-suffix"] ?? defaultSuffix
    let normalizedSuffix = rawSuffix.hasPrefix(".") ? rawSuffix : ".\(rawSuffix)"

    let maxConcurrency = max(1, min(8, lim.maximumWorkers))
    let totalCount = inputURLs.count
    try context.diagnostic(2, "processing batch of \(totalCount) items (concurrency=\(maxConcurrency))")

    var outcomes: [BatchItemOutcome] = []
    outcomes.reserveCapacity(totalCount)

    await withTaskGroup(of: BatchItemOutcome.self) { group in
        var nextIndex = 0
        let initialLaunch = min(maxConcurrency, totalCount)
        for _ in 0..<initialLaunch {
            let idx = nextIndex
            let inURL = inputURLs[idx]
            nextIndex += 1
            group.addTask {
                await executeBatchItem(
                    index: idx,
                    inURL: inURL,
                    outDirURL: outDirURL,
                    suffix: normalizedSuffix,
                    operation: op,
                    baseOptions: options
                )
            }
        }

        while let completed = await group.next() {
            outcomes.append(completed)
            if options.progress && !options.quiet {
                try? write("batch progress: \(outcomes.count)/\(totalCount) completed\n", to: .standardError)
            }
            if !completed.succeeded && !options.continueOnError {
                group.cancelAll()
                break
            }
            if nextIndex < totalCount {
                let idx = nextIndex
                let inURL = inputURLs[idx]
                nextIndex += 1
                group.addTask {
                    await executeBatchItem(
                        index: idx,
                        inURL: inURL,
                        outDirURL: outDirURL,
                        suffix: normalizedSuffix,
                        operation: op,
                        baseOptions: options
                    )
                }
            }
        }
    }

    outcomes.sort { $0.index < $1.index }
    let succeededCount = outcomes.filter(\.succeeded).count
    let failedCount = outcomes.count - succeededCount
    let totalInBytes = outcomes.reduce(0) { $0 + $1.inputBytes }
    let totalOutBytes = outcomes.reduce(0) { $0 + $1.outputBytes }
    let elapsed = ContinuousClock.now - started

    if let firstFailure = outcomes.first(where: { !$0.succeeded }), let err = firstFailure.error {
        if !options.continueOnError {
            throw err
        }
    }

    if options.json {
        try report([
            "command": "batch",
            "elapsedSeconds": elapsedSeconds(elapsed),
            "failed": failedCount,
            "operation": op,
            "succeeded": succeededCount,
            "threads": maxConcurrency,
            "total": totalCount,
            "totalInputBytes": totalInBytes,
            "totalOutputBytes": totalOutBytes
        ], json: true, to: .standardOutput)
    } else {
        try write(
            "operation: \(op)\ntotal: \(totalCount)\nsucceeded: \(succeededCount)\nfailed: \(failedCount)\ninput bytes: \(totalInBytes)\noutput bytes: \(totalOutBytes)\n",
            to: .standardOutput
        )
    }

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "batch completed")

    if let firstFailure = outcomes.first(where: { !$0.succeeded }), let err = firstFailure.error {
        throw err
    }
    return 0
}

private func executeBatchItem(
    index: Int,
    inURL: URL,
    outDirURL: URL,
    suffix: String,
    operation: String,
    baseOptions: Options
) async -> BatchItemOutcome {
    let stem = inURL.deletingPathExtension().lastPathComponent
    let outURL = outDirURL.appendingPathComponent(stem + suffix)

    var itemOpts = baseOptions
    itemOpts.command = operation
    itemOpts.subcommand = nil
    itemOpts.values["--input"] = inURL.path
    itemOpts.values["--output"] = outURL.path
    itemOpts.values.removeValue(forKey: "--input-list")
    itemOpts.values.removeValue(forKey: "--filter")
    itemOpts.values.removeValue(forKey: "--exclude")
    itemOpts.values.removeValue(forKey: "--output-suffix")
    itemOpts.values.removeValue(forKey: "--op")
    itemOpts.json = false
    itemOpts.verbosity = 0
    itemOpts.quiet = true

    let itemContext = CodecContext(options: itemOpts, diagnostic: { _, _ in })
    let inBytes = directoryOrFileByteSize(inURL)
    let itemStart = ContinuousClock.now
    do {
        switch operation {
        case "encode", "decode", "transcode":
            _ = try await runCodecCommand(operation, itemContext)
        case "encode3d":
            _ = try await runEncode3DCommand(itemContext, started: itemStart)
        case "decode3d":
            _ = try await runDecode3DCommand(itemContext, started: itemStart)
        default:
            throw UsageError(message: "Unsupported batch operation.")
        }
        let outBytes = directoryOrFileByteSize(outURL)
        return BatchItemOutcome(
            index: index,
            succeeded: true,
            inputBytes: inBytes,
            outputBytes: outBytes,
            error: nil
        )
    } catch {
        return BatchItemOutcome(
            index: index,
            succeeded: false,
            inputBytes: inBytes,
            outputBytes: 0,
            error: error
        )
    }
}

private func directoryOrFileByteSize(_ url: URL) -> Int {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
    guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
        return 0
    }
    return entries.reduce(0) { acc, u in
        acc + ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0)
    }
}

private func discoverBatchInputs(options: Options, operation: String) throws -> [URL] {
    let allowedExts: Set<String>
    switch operation {
    case "encode":
        allowedExts = ["nrrd", "pgm", "ppm", "pnm", "png", "tiff", "tif", "raw"]
    case "decode", "transcode":
        allowedExts = ["j2k", "j2c", "jhc", "htj2k", "jp2", "jph", "jpx"]
    case "encode3d":
        allowedExts = ["nrrd", "raw", "bin"]
    case "decode3d":
        allowedExts = ["jp3d", "j3d", "j2k", "j2c"]
    default:
        allowedExts = []
    }

    var rawSpecs: [String] = []
    if let inp = options.values["--input"] {
        rawSpecs.append(contentsOf: inp.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }
    if let listPath = options.values["--input-list"] {
        let listData = try readInput(listPath)
        guard let text = String(data: listData, encoding: .utf8) else {
            throw ExitFailure(status: 3, message: "malformed input: batch --input-list file is not valid UTF-8.")
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                rawSpecs.append(trimmed)
            }
        }
    }

    var discovered: [URL] = []
    let fm = FileManager.default
    for spec in rawSpecs {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: spec, isDirectory: &isDir) {
            let url = URL(fileURLWithPath: spec)
            if isDir.boolValue {
                if operation == "encode3d" {
                    let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                    let subdirs = children.filter {
                        var subDir: ObjCBool = false
                        return fm.fileExists(atPath: $0.path, isDirectory: &subDir) && subDir.boolValue
                    }
                    let volFiles = children.filter { allowedExts.contains($0.pathExtension.lowercased()) }
                    if !subdirs.isEmpty || !volFiles.isEmpty {
                        discovered.append(contentsOf: (subdirs + volFiles).sorted { $0.lastPathComponent < $1.lastPathComponent })
                    } else {
                        discovered.append(url)
                    }
                } else if options.recursive {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            var subIsDir: ObjCBool = false
                            if fm.fileExists(atPath: fileURL.path, isDirectory: &subIsDir), !subIsDir.boolValue,
                               allowedExts.contains(fileURL.pathExtension.lowercased()) {
                                discovered.append(fileURL)
                            }
                        }
                    }
                } else {
                    let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                    for entry in entries where allowedExts.contains(entry.pathExtension.lowercased()) {
                        discovered.append(entry)
                    }
                }
            } else {
                discovered.append(url)
            }
        } else if spec.contains("*") || spec.contains("?") {
            let dirURL = URL(fileURLWithPath: spec).deletingLastPathComponent()
            let pattern = URL(fileURLWithPath: spec).lastPathComponent
            let entries = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries where matchesGlob(pattern: pattern, text: entry.lastPathComponent) {
                discovered.append(entry)
            }
        } else {
            throw ExitFailure(status: 6, message: "I/O failure: batch input path does not exist.")
        }
    }

    if let filterGlob = options.values["--filter"] {
        discovered = discovered.filter { matchesGlob(pattern: filterGlob, text: $0.lastPathComponent) }
    }
    if let excludeGlob = options.values["--exclude"] {
        discovered = discovered.filter { !matchesGlob(pattern: excludeGlob, text: $0.lastPathComponent) }
    }

    discovered.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    return discovered
}

private func matchesGlob(pattern: String, text: String) -> Bool {
    var regex = "^"
    for ch in pattern {
        switch ch {
        case "*": regex += ".*"
        case "?": regex += "."
        case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
            regex += "\\\(ch)"
        default:
            regex.append(ch)
        }
    }
    regex += "$"
    return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - Benchmark Command (`swiftj2k-cli benchmark`)

func runBenchmarkCommand(_ context: CodecContext, started: ContinuousClock.Instant) async throws -> Int32 {
    let options = context.options
    guard let inPath = options.values["--input"] else {
        throw UsageError(message: "benchmark requires --input (-i).")
    }
    var runs = 5
    if let rStr = options.values["--runs"] ?? options.values["--reference"] {
        guard let r = Int(rStr), (1...1000).contains(r) else {
            throw UsageError(message: "benchmark --runs (-r) must be in 1..1000.")
        }
        runs = r
    }
    var warmup = 1
    if let wStr = options.values["--warmup"] {
        guard let w = Int(wStr), (0...100).contains(w) else {
            throw UsageError(message: "benchmark --warmup must be in 0..100.")
        }
        warmup = w
    }
    if options.encodeOnly && options.decodeOnly {
        throw UsageError(message: "--encode-only and --decode-only cannot be combined.")
    }
    let outFmt = (options.json ? "json" : (options.values["--format"] ?? "text")).lowercased()
    guard ["text", "json", "csv"].contains(outFmt) else {
        throw UsageError(message: "--format for benchmark must be text, json or csv.")
    }

    var limitOpts = options
    limitOpts.values.removeValue(forKey: "--mode")
    limitOpts.values.removeValue(forKey: "--max-error")
    let lim = try limits(from: limitOpts, command: "benchmark")
    let execPolicy = try parseExecutionPolicy(options.values["--backend"])
    let copyPolicy: CopyPolicy = options.values["--copy-policy"] == "allow-copy" ? .allowCopy : .requireSharedStorage
    let metadataPolicy: MetadataPolicy = options.values["--metadata-policy"] == "discard-ancillary" ? .discardAncillary : .preserve
    let rawGeom = try parseRawGeometry(from: options)
    let precision = try parseOptionalPrecision(from: options)

    try context.diagnostic(2, "loading image for benchmark")
    let image = try await load2DImageForAnalysis(
        path: inPath,
        options: options,
        limits: lim,
        executionPolicy: execPolicy,
        precision: precision,
        rawGeometry: rawGeom
    )
    let d = image.descriptor
    let megapixels = Double(d.width * d.height) / 1_000_000.0
    let uncompressedBytes = d.width * d.height * d.components.count * ((d.meaningfulBits + 7) / 8)

    struct BenchPreset {
        let name: String
        let config: EncoderConfiguration
    }

    var presets: [BenchPreset] = []
    if options.compareAll {
        presets.append(BenchPreset(
            name: "j2k-lossless",
            config: try EncoderConfiguration(mode: .lossless, codecOptions: try CodecOptions(blockCoding: .part1))
        ))
        presets.append(BenchPreset(
            name: "htj2k-lossless",
            config: try EncoderConfiguration(mode: .lossless, codecOptions: try CodecOptions(blockCoding: .htj2k))
        ))
        let lossyMCT: CodecOptions.ColourTransform = (d.components.count >= 3) ? .ict : .none
        presets.append(BenchPreset(
            name: "j2k-lossy",
            config: try EncoderConfiguration(
                mode: .lossy,
                codecOptions: try CodecOptions(
                    blockCoding: .part1,
                    wavelet: .irreversible97,
                    colourTransform: lossyMCT,
                    quality: 0.85
                )
            )
        ))
    } else {
        let isHT = options.htj2k || (options.values["--output-format"]?.lowercased() == "htj2k")
        let blockCoding: CodecOptions.BlockCoding = isHT ? .htj2k : .part1
        let cfg = try parseEncodeConfiguration(
            options: options,
            levels: nil,
            blockWidth: 64,
            blockHeight: 64,
            blockCoding: blockCoding,
            containerFormat: .codestream
        )
        let modeName = options.values["--mode"] ?? "lossless"
        let label = (isHT ? "htj2k-" : "j2k-") + modeName
        presets.append(BenchPreset(name: label, config: cfg))
    }

    let clock = ContinuousClock()
    var presetReports: [[String: Any]] = []
    var textLines: [String] = [
        "width: \(d.width)",
        "height: \(d.height)",
        "components: \(d.components.count)",
        "meaningful bits: \(d.meaningfulBits)",
        "runs: \(runs)",
        "warmup: \(warmup)"
    ]
    var csvLines: [String] = [
        "preset,operation,runs,median_ms,mean_ms,min_ms,max_ms,p95_ms,throughput_mpps,compressed_bytes,compression_ratio,backend"
    ]

    for preset in presets {
        let encoder = try Encoder(configuration: preset.config)
        let decoder = try Decoder()
        var lastEncoded: EncodedImage?

        var encodeSamplesMs: [Double] = []
        if !options.decodeOnly {
            for _ in 0..<warmup {
                lastEncoded = try await encoder.encode(
                    image,
                    options: .init(resourceLimits: lim, executionPolicy: execPolicy, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
                )
            }
            for _ in 0..<runs {
                let t0 = clock.now
                let enc = try await encoder.encode(
                    image,
                    options: .init(resourceLimits: lim, executionPolicy: execPolicy, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
                )
                let dt = clock.now - t0
                let ms = elapsedSeconds(dt) * 1000.0
                encodeSamplesMs.append(ms)
                lastEncoded = enc
            }
        } else {
            lastEncoded = try await encoder.encode(
                image,
                options: .init(resourceLimits: lim, executionPolicy: execPolicy, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
            )
        }

        let codestream = lastEncoded!.data
        let backendStr = backendString(lastEncoded!.report.backend)
        let ratio = codestream.isEmpty ? 0.0 : (Double(uncompressedBytes) / Double(codestream.count))

        var decodeSamplesMs: [Double] = []
        if !options.encodeOnly {
            for _ in 0..<warmup {
                _ = try await decoder.decode(
                    codestream,
                    options: .init(resourceLimits: lim, executionPolicy: execPolicy, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
                )
            }
            for _ in 0..<runs {
                let t0 = clock.now
                _ = try await decoder.decode(
                    codestream,
                    options: .init(resourceLimits: lim, executionPolicy: execPolicy, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
                )
                let dt = clock.now - t0
                let ms = elapsedSeconds(dt) * 1000.0
                decodeSamplesMs.append(ms)
            }
        }

        var entry: [String: Any] = [
            "backend": backendStr,
            "compressedBytes": codestream.count,
            "compressionRatio": ratio,
            "preset": preset.name
        ]

        if !encodeSamplesMs.isEmpty {
            let st = computeTimingStats(encodeSamplesMs, megapixels: megapixels)
            entry["encode"] = st
            textLines.append(String(
                format: "%@ encode: median=%.3f ms mean=%.3f ms min=%.3f ms max=%.3f ms throughput=%.2f MP/s bytes=%d ratio=%.2fx backend=%@",
                preset.name,
                st["medianMs"] as? Double ?? 0,
                st["meanMs"] as? Double ?? 0,
                st["minMs"] as? Double ?? 0,
                st["maxMs"] as? Double ?? 0,
                st["throughputMPps"] as? Double ?? 0,
                codestream.count,
                ratio,
                backendStr
            ))
            csvLines.append(String(
                format: "%@,encode,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.4f,%@",
                preset.name, runs,
                st["medianMs"] as? Double ?? 0,
                st["meanMs"] as? Double ?? 0,
                st["minMs"] as? Double ?? 0,
                st["maxMs"] as? Double ?? 0,
                st["p95Ms"] as? Double ?? 0,
                st["throughputMPps"] as? Double ?? 0,
                codestream.count, ratio, backendStr
            ))
        }

        if !decodeSamplesMs.isEmpty {
            let st = computeTimingStats(decodeSamplesMs, megapixels: megapixels)
            entry["decode"] = st
            textLines.append(String(
                format: "%@ decode: median=%.3f ms mean=%.3f ms min=%.3f ms max=%.3f ms throughput=%.2f MP/s backend=%@",
                preset.name,
                st["medianMs"] as? Double ?? 0,
                st["meanMs"] as? Double ?? 0,
                st["minMs"] as? Double ?? 0,
                st["maxMs"] as? Double ?? 0,
                st["throughputMPps"] as? Double ?? 0,
                backendStr
            ))
            csvLines.append(String(
                format: "%@,decode,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.4f,%@",
                preset.name, runs,
                st["medianMs"] as? Double ?? 0,
                st["meanMs"] as? Double ?? 0,
                st["minMs"] as? Double ?? 0,
                st["maxMs"] as? Double ?? 0,
                st["p95Ms"] as? Double ?? 0,
                st["throughputMPps"] as? Double ?? 0,
                codestream.count, ratio, backendStr
            ))
        }

        presetReports.append(entry)
    }

    let elapsed = ContinuousClock.now - started
    let formattedOutput: Data
    switch outFmt {
    case "json":
        let obj: [String: Any] = [
            "command": "benchmark",
            "components": d.components.count,
            "elapsedSeconds": elapsedSeconds(elapsed),
            "height": d.height,
            "meaningfulBits": d.meaningfulBits,
            "presets": presetReports,
            "results": presetReports,
            "runs": runs,
            "warmup": warmup,
            "width": d.width
        ]
        formattedOutput = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) + Data([0x0A])
    case "csv":
        formattedOutput = Data((csvLines.joined(separator: "\n") + "\n").utf8)
    default:
        formattedOutput = Data((textLines.joined(separator: "\n") + "\n").utf8)
    }

    if let outPath = options.values["--output"] {
        try publish(formattedOutput, to: outPath, overwrite: options.overwrite)
    } else {
        try publish(formattedOutput, to: "-", overwrite: true)
    }

    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "benchmark completed")
    return 0
}

private func computeTimingStats(_ samplesMs: [Double], megapixels: Double) -> [String: Any] {
    let sorted = samplesMs.sorted()
    let n = sorted.count
    let median = (n % 2 == 1) ? sorted[n / 2] : ((sorted[n / 2 - 1] + sorted[n / 2]) / 2.0)
    let mean = sorted.reduce(0.0, +) / Double(max(1, n))
    let minVal = sorted.first ?? 0.0
    let maxVal = sorted.last ?? 0.0
    let p95 = sorted[min(n - 1, Int(0.95 * Double(n - 1)))]
    let throughput = (median > 0.0) ? (megapixels / (median / 1000.0)) : 0.0
    return [
        "maxMs": maxVal,
        "meanMs": mean,
        "medianMs": median,
        "minMs": minVal,
        "p95Ms": p95,
        "throughputMPps": throughput
    ]
}

// MARK: - Shell Completions Command (`swiftj2k-cli completions`)

func runCompletionsCommand(_ context: CodecContext, started: ContinuousClock.Instant) throws -> Int32 {
    let options = context.options
    guard !options.json else {
        throw UsageError(message: "--json is not accepted by completions.")
    }
    guard let shell = (options.subcommand ?? options.values["--shell"])?.lowercased() else {
        throw UsageError(message: "completions requires a shell name: bash, zsh or fish.")
    }
    let script: String
    switch shell {
    case "bash":
        script = generateBashCompletions()
    case "zsh":
        script = generateZshCompletions()
    case "fish":
        script = generateFishCompletions()
    default:
        throw UsageError(message: "Unsupported shell '\(shell)'; expected bash, zsh or fish.")
    }
    try write(script, to: .standardOutput)
    let elapsed = ContinuousClock.now - started
    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(elapsed))")
    try context.diagnostic(5, "completions emitted")
    return 0
}

private func generateBashCompletions() -> String {
    """
    # bash completion for \(tool)
    _swiftj2k_cli() {
        local cur prev words cword
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"

        local commands="encode decode transcode inspect validate convert compare batch encode3d decode3d jpip benchmark capabilities completions help version"
        local global_opts="-h --help --version -v -vv -vvv -vvvv -vvvvv --verbose -q --quiet --json"
        local io_opts="-i --input -o --output --input-format --output-format --container --overwrite"
        local codec_opts="--mode --lossy --near-lossless --max-error --quality --bpp --layers --wavelet --mct --progression --tile-size --precincts --roi --guard-bits --qstyle --sop --eph --levels --code-block --precision --bit-depth --dimensions --components --signed --backend --copy-policy --metadata-policy --threads --max-memory --max-metadata --timeout"

        case "${prev}" in
            -i|--input|-o|--output|--reference|-r|--single-file|--data-dir|--output-dir|--input-list)
                COMPREPLY=( $(compgen -f -- "${cur}") )
                return 0
                ;;
            --input-format|--output-format)
                COMPREPLY=( $(compgen -W "j2k htj2k jp2 jph jpx nrrd pgm ppm pnm png tiff raw" -- "${cur}") )
                return 0
                ;;
            --container)
                COMPREPLY=( $(compgen -W "codestream jp2 jph jpx" -- "${cur}") )
                return 0
                ;;
            --mode)
                COMPREPLY=( $(compgen -W "lossless near-lossless lossy 2d 3d" -- "${cur}") )
                return 0
                ;;
            --backend)
                COMPREPLY=( $(compgen -W "auto scalar accelerated" -- "${cur}") )
                return 0
                ;;
            --wavelet)
                COMPREPLY=( $(compgen -W "auto 53 97" -- "${cur}") )
                return 0
                ;;
            --mct)
                COMPREPLY=( $(compgen -W "auto none rct ict" -- "${cur}") )
                return 0
                ;;
            --progression)
                COMPREPLY=( $(compgen -W "lrcp rlcp rpcl pcrl cprl lrcps rlcps pcrs slrcp cprls" -- "${cur}") )
                return 0
                ;;
            completions)
                COMPREPLY=( $(compgen -W "bash zsh fish" -- "${cur}") )
                return 0
                ;;
            batch)
                COMPREPLY=( $(compgen -W "encode decode transcode encode3d decode3d" -- "${cur}") )
                return 0
                ;;
            jpip)
                COMPREPLY=( $(compgen -W "client server" -- "${cur}") )
                return 0
                ;;
        esac

        if [[ ${COMP_CWORD} -eq 1 ]]; then
            COMPREPLY=( $(compgen -W "${commands} ${global_opts}" -- "${cur}") )
            return 0
        fi

        COMPREPLY=( $(compgen -W "${global_opts} ${io_opts} ${codec_opts}" -- "${cur}") )
        return 0
    }
    complete -F _swiftj2k_cli \(tool)
    complete -F _swiftj2k_cli j2k

    """
}

private func generateZshCompletions() -> String {
    """
    #compdef \(tool) j2k

    _swiftj2k_cli() {
        local -a commands
        commands=(
            'encode:Encode an uncompressed image to JPEG 2000 or HTJ2K'
            'decode:Decode a JPEG 2000 or HTJ2K codestream or container'
            'transcode:Losslessly transcode between Part 1 and HTJ2K'
            'inspect:Inspect codestream and container headers'
            'validate:Validate codestream and container integrity'
            'convert:Convert between uncompressed image formats (nrrd, pgm, ppm, png, tiff, raw)'
            'compare:Compute MSE, MAE, MaxError, PSNR, and bit-exactness between two images or volumes'
            'batch:Batch encode, decode, transcode, encode3d, or decode3d multiple inputs'
            'encode3d:Encode a 3D volume or slice directory to JP3D'
            'decode3d:Decode a JP3D volumetric codestream to a volume or slice directory'
            'jpip:Interactive JPIP streaming client and server'
            'benchmark:In-process encode and decode performance benchmark'
            'capabilities:Report codec capabilities and available backends'
            'completions:Generate shell completion scripts (bash, zsh, fish)'
            'help:Show global or command-specific help'
            'version:Show version'
        )

        _arguments -C \\
            '(-h --help)'{-h,--help}'[Show help]' \\
            '--version[Show version]' \\
            '(-q --quiet)'{-q,--quiet}'[Suppress optional diagnostics]' \\
            '--json[Emit structured JSON output]' \\
            '(-i --input)'{-i,--input}'[Input path]:file:_files' \\
            '(-o --output)'{-o,--output}'[Output path]:file:_files' \\
            '(-r --reference)'{-r,--reference}'[Reference path for compare]:file:_files' \\
            '--input-format[Declare input format]:format:(j2k htj2k jp2 jph jpx nrrd pgm ppm pnm png tiff raw)' \\
            '--output-format[Declare output format]:format:(j2k htj2k jp2 jph jpx nrrd pgm ppm pnm png tiff raw)' \\
            '--container[Output container wrapper]:container:(codestream jp2 jph jpx)' \\
            '--mode[Compression or comparison mode]:mode:(lossless near-lossless lossy 2d 3d)' \\
            '--backend[Execution backend]:backend:(auto scalar accelerated)' \\
            '--overwrite[Overwrite existing output file]' \\
            '1:command:->cmds' \\
            '*::arg:->args'

        case "$state" in
            cmds)
                _describe -t commands 'swiftj2k-cli command' commands
                ;;
        esac
    }

    _swiftj2k_cli "$@"

    """
}

private func generateFishCompletions() -> String {
    """
    # fish completion for \(tool)
    set -l commands encode decode transcode inspect validate convert compare batch encode3d decode3d jpip benchmark capabilities completions help version

    complete -c \(tool) -f
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a encode -d "Encode an image to JPEG 2000 or HTJ2K"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a decode -d "Decode a JPEG 2000 or HTJ2K stream"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a transcode -d "Losslessly transcode between Part 1 and HTJ2K"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a inspect -d "Inspect headers without decoding samples"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a validate -d "Validate codestream and container integrity"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a convert -d "Convert between uncompressed image formats"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a compare -d "Compare two 2D or 3D images"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a batch -d "Batch process multiple files"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a encode3d -d "Encode a 3D volume to JP3D"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a decode3d -d "Decode a JP3D volume"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a jpip -d "JPIP streaming client and server"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a benchmark -d "In-process codec performance benchmark"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a capabilities -d "Report library capabilities"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a completions -d "Generate shell completions"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a help -d "Show help"
    complete -c \(tool) -n "not __fish_seen_subcommand_from $commands" -a version -d "Show version"

    complete -c \(tool) -n "__fish_seen_subcommand_from completions" -a "bash zsh fish"
    complete -c \(tool) -n "__fish_seen_subcommand_from batch" -a "encode decode transcode encode3d decode3d"
    complete -c \(tool) -n "__fish_seen_subcommand_from jpip" -a "client server"

    complete -c \(tool) -s h -l help -d "Show help"
    complete -c \(tool) -l version -d "Show version"
    complete -c \(tool) -s q -l quiet -d "Suppress optional diagnostics"
    complete -c \(tool) -l json -d "Emit JSON output"
    complete -c \(tool) -s i -l input -r -F -d "Input path"
    complete -c \(tool) -s o -l output -r -F -d "Output path"
    complete -c \(tool) -s r -l reference -r -F -d "Reference path"
    complete -c \(tool) -l input-format -r -a "j2k htj2k jp2 jph jpx nrrd pgm ppm pnm png tiff raw" -d "Input format"
    complete -c \(tool) -l output-format -r -a "j2k htj2k jp2 jph jpx nrrd pgm ppm pnm png tiff raw" -d "Output format"
    complete -c \(tool) -l container -r -a "codestream jp2 jph jpx" -d "Output container"
    complete -c \(tool) -l mode -r -a "lossless near-lossless lossy 2d 3d" -d "Operation mode"
    complete -c \(tool) -l backend -r -a "auto scalar accelerated" -d "Execution backend"
    complete -c \(tool) -l overwrite -d "Permit replacing an existing output file"

    """
}
