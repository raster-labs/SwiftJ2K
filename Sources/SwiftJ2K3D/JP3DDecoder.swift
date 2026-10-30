// SPDX-License-Identifier: Apache-2.0
//
// JP3DDecoder.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DDecoder.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Fixed signed voxel clamping in assembleVolumeComponents: previously
//     `let clamped = max(0, min(maxVal, buffer[i]))` clamped negative voxels to 0,
//     destroying negative Hounsfield units in signed CT volumes. Now clamps to
//     `[minVal, maxVal]` where `minVal = signed ? -(1 << (bitDepth - 1)) : 0`.

import Foundation
import SwiftJ2K

// MARK: - Decoder Configuration

/// Configuration for the JP3D volumetric decoder.
public struct JP3DDecoderConfiguration: Sendable, Equatable {
    /// Maximum number of quality layers to decode (`0` = all available).
    public let maxQualityLayers: Int

    /// Resolution level reduction (`0` = full resolution, `k` = in-plane XY reduced by `2^k`).
    public let resolutionLevel: Int

    /// Whether to tolerate recoverable codestream truncation or tile errors.
    public let tolerateErrors: Bool

    /// Alias for ``tolerateErrors``.
    public var tolerateTruncation: Bool { tolerateErrors }

    /// Enable parallel tile decoding (`true` by default).
    public let parallelTileDecoding: Bool

    /// Maximum concurrent tile-decoding worker tasks (`>= 1`).
    public let maximumWorkers: Int

    /// Creates a decoder configuration.
    public init(
        maxQualityLayers: Int = 0,
        resolutionLevel: Int = 0,
        tolerateErrors: Bool = true,
        parallelTileDecoding: Bool = true,
        maximumWorkers: Int = 8
    ) {
        self.maxQualityLayers = max(0, maxQualityLayers)
        self.resolutionLevel = max(0, resolutionLevel)
        self.tolerateErrors = tolerateErrors
        self.parallelTileDecoding = parallelTileDecoding
        self.maximumWorkers = max(1, maximumWorkers)
    }

    /// Convenience initialiser accepting optional `maxQualityLayers` and `tolerateTruncation`.
    public init(
        maxQualityLayers: Int?,
        resolutionLevel: Int = 0,
        tolerateTruncation: Bool = true,
        parallelTileDecoding: Bool = true,
        maximumWorkers: Int = 8
    ) {
        self.init(
            maxQualityLayers: maxQualityLayers ?? 0,
            resolutionLevel: resolutionLevel,
            tolerateErrors: tolerateTruncation,
            parallelTileDecoding: parallelTileDecoding,
            maximumWorkers: maximumWorkers
        )
    }

    /// Default configuration: decode all quality layers at full resolution.
    public static let `default` = JP3DDecoderConfiguration()

    /// Thumbnail decode at 1/4 resolution (`resolutionLevel = 2`).
    public static let thumbnail = JP3DDecoderConfiguration(resolutionLevel: 2)
}

// MARK: - Decoder Progress & Result

/// Progress update reported during JP3D decoding.
public struct JP3DDecoderProgress: Sendable {
    /// Current decoding stage.
    public let stage: JP3DDecodingStage

    /// Progress within the stage (0.0 to 1.0).
    public let stageProgress: Double

    /// Overall decode progress (0.0 to 1.0).
    public let overallProgress: Double

    /// Tiles decoded so far.
    public let tilesDecoded: Int

    /// Total tiles to decode.
    public let totalTiles: Int

    /// Alias for ``tilesDecoded``.
    public var currentTile: Int { tilesDecoded }

    /// Alias for ``overallProgress``.
    public var fraction: Double { overallProgress }

    public init(
        stage: JP3DDecodingStage,
        stageProgress: Double,
        overallProgress: Double,
        tilesDecoded: Int,
        totalTiles: Int
    ) {
        self.stage = stage
        self.stageProgress = stageProgress
        self.overallProgress = overallProgress
        self.tilesDecoded = tilesDecoded
        self.totalTiles = totalTiles
    }
}

/// Stages of the JP3D decoding pipeline.
public enum JP3DDecodingStage: String, Sendable {
    /// Parsing marker segments from the codestream.
    case parsing = "Parsing"
    /// Reconstructing tiles from quantized coefficients.
    case tileReconstruction = "Tile Reconstruction"
    /// Dequantizing coefficients for each tile (alias).
    case dequantization = "Dequantization"
    /// Applying inverse 3D wavelet transform (alias).
    case inverseWavelet = "Inverse Wavelet Transform"
    /// Assembling decoded tiles into the output volume.
    case volumeAssembly = "Volume Assembly"
    /// Assembly alias.
    case assembly = "Assembly"
    /// Decoding complete.
    case complete = "Complete"
}

/// Result of a JP3D decoding operation.
public struct JP3DDecoderResult: Sendable {
    /// The reconstructed volumetric dataset.
    public let volume: J2KVolume

    /// Whether any tiles were skipped or truncated during decoding.
    public let isPartial: Bool

    /// Warnings encountered during decoding.
    public let warnings: [String]

    /// Total number of tiles decoded.
    public let tilesDecoded: Int

    /// Total number of tiles expected in the volume.
    public let tilesTotal: Int

    /// Alias for ``tilesTotal``.
    public var totalTiles: Int { tilesTotal }

    /// Whether the decoded data was losslessly encoded.
    public let isLossless: Bool

    internal let peakWorkspaceBytes: Int
    internal let commentCount: Int
    internal let commentPayloadBytes: Int
    internal let hadVolumeGeometry: Bool

    public init(
        volume: J2KVolume,
        isPartial: Bool,
        warnings: [String] = [],
        tilesDecoded: Int,
        tilesTotal: Int,
        isLossless: Bool = true
    ) {
        self.volume = volume
        self.isPartial = isPartial
        self.warnings = warnings
        self.tilesDecoded = tilesDecoded
        self.tilesTotal = tilesTotal
        self.isLossless = isLossless
        self.peakWorkspaceBytes = 0
        self.commentCount = 0
        self.commentPayloadBytes = 0
        self.hadVolumeGeometry = false
    }

    internal init(
        volume: J2KVolume,
        isPartial: Bool,
        warnings: [String],
        tilesDecoded: Int,
        tilesTotal: Int,
        isLossless: Bool,
        peakWorkspaceBytes: Int,
        commentCount: Int,
        commentPayloadBytes: Int,
        hadVolumeGeometry: Bool
    ) {
        self.volume = volume
        self.isPartial = isPartial
        self.warnings = warnings
        self.tilesDecoded = tilesDecoded
        self.tilesTotal = tilesTotal
        self.isLossless = isLossless
        self.peakWorkspaceBytes = peakWorkspaceBytes
        self.commentCount = commentCount
        self.commentPayloadBytes = commentPayloadBytes
        self.hadVolumeGeometry = hadVolumeGeometry
    }
}

// MARK: - Decoder Actor

/// Actor for decoding JP3D volumetric JPEG 2000 codestreams into `J2KVolume` datasets.
public actor JP3DDecoder {
    // MARK: - State

    private let configuration: JP3DDecoderConfiguration
    private var progressCallback: (@Sendable (JP3DDecoderProgress) -> Void)?

    // MARK: - Init

    /// Creates a JP3D decoder with the given configuration.
    public init(configuration: JP3DDecoderConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Pre-warm

    /// Warms the shared acceleration runtime before the first JP3D decode in a process.
    public static func preWarm(includeWarmupDispatch: Bool = false) async {
        if includeWarmupDispatch {
            let samples = [Int32](repeating: 0, count: 64)
            if let encoded = try? Slice2DBridge.encodeSlice(
                samples: samples, width: 8, height: 8, bitDepth: 8, signed: false,
                levels: 1, qualityLayers: 1, useHTJ2K: false, lossless: true,
                quality: nil, targetBitsPerPixel: nil, useReversibleWavelet: true
            ) {
                _ = try? Slice2DBridge.decodeSlice(data: encoded)
            }
        }
    }

    // MARK: - Public API

    /// Sets a callback for decoding progress updates.
    public func setProgressCallback(
        _ callback: @escaping @Sendable (JP3DDecoderProgress) -> Void
    ) {
        self.progressCallback = callback
    }

    /// Decodes a JP3D codestream at a reduced resolution level (`0` = full resolution, `k` = 1/2^k).
    public func decode(_ data: Data, resolutionLevel: Int) async throws -> JP3DDecoderResult {
        let subConfig = JP3DDecoderConfiguration(
            maxQualityLayers: configuration.maxQualityLayers,
            resolutionLevel: max(0, resolutionLevel),
            tolerateErrors: configuration.tolerateErrors,
            parallelTileDecoding: configuration.parallelTileDecoding,
            maximumWorkers: configuration.maximumWorkers
        )
        return try await JP3DDecoder(configuration: subConfig).decode(data)
    }

    /// Decodes a 3D region of interest from a JP3D codestream.
    public func decode(_ data: Data, region: JP3DRegion) async throws -> JP3DROIDecoderResult {
        try await JP3DROIDecoder(configuration: configuration).decode(data, region: region)
    }

    /// Decodes a 3D region of interest at a reduced resolution level from a JP3D codestream.
    public func decode(
        _ data: Data,
        region: JP3DRegion,
        resolutionLevel: Int
    ) async throws -> JP3DROIDecoderResult {
        let subConfig = JP3DDecoderConfiguration(
            maxQualityLayers: configuration.maxQualityLayers,
            resolutionLevel: max(0, resolutionLevel),
            tolerateErrors: configuration.tolerateErrors,
            parallelTileDecoding: configuration.parallelTileDecoding,
            maximumWorkers: configuration.maximumWorkers
        )
        return try await JP3DROIDecoder(configuration: subConfig).decode(data, region: region)
    }

    /// Decodes only the volume dimensions and metadata without reconstructing voxel data.
    public func peekMetadata(_ data: Data) throws -> JP3DSIZInfo {
        let parser = JP3DCodestreamParser()
        let codestream = try parser.parse(data)
        return codestream.siz
    }

    /// Decodes a JP3D codestream into a `J2KVolume`.
    public func decode(_ data: Data) async throws -> JP3DDecoderResult {
        try await decodeAdmitted(
            data,
            limits: nil,
            executionPolicy: .automatic,
            work: VolumeWorkGuard(limits: nil)
        )
    }

    internal enum DecodedTileSamples: Sendable {
        case integer([[Int64]])
        case float([[Float]])
    }

    internal struct TileTaskOutcome: Sendable {
        let seqIdx: Int
        let tileIndex: Int
        let outX0: Int
        let outY0: Int
        let outZ0: Int
        let tileW: Int
        let tileH: Int
        let tileD: Int
        let wasTruncated: Bool
        let result: Result<DecodedTileSamples, any Error>
    }

    internal struct NormativeDecodeContext: Sendable {
        let siz: JP3DSIZInfo
        let cod: JP3DCODInfo
        let qcd: JP3DQuantizationParameters
        let roiShifts: [Int]
        let tolerateTruncation: Bool
    }

    internal func decodeAdmitted(
        _ data: Data,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        metadataPolicy: MetadataPolicy = .preserve,
        work: VolumeWorkGuard
    ) async throws -> JP3DDecoderResult {
        try work.check()
        try jp3dValidateResolutionLevel(configuration.resolutionLevel)

        guard !data.isEmpty else {
            throw J2KError.decodingError("Cannot decode empty codestream")
        }

        if let limits {
            guard data.count <= limits.maximumCompressedBytes,
                  data.count <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Codestream size \(data.count) exceeds compressed or memory limit"
                )
            }
        }

        reportProgress(.parsing, stageProgress: 0.0, tilesDone: 0, tilesTotal: 1)

        let parser = JP3DCodestreamParser()
        let codestream = try parser.parse(data, limits: limits, work: work, copyTilePayloads: true)

        let siz = codestream.siz
        let cod = codestream.cod
        let grid = codestream.tileGrid
        let (txy, gOv1) = grid.tilesX.multipliedReportingOverflow(by: grid.tilesY)
        let (_, gOv2) = txy.multipliedReportingOverflow(by: grid.tilesZ)
        guard !gOv1, !gOv2 else {
            throw J2KError.decodingError("Tile grid dimensions overflow integer arithmetic")
        }

        let K = configuration.resolutionLevel
        let outWidth = jp3dDownsampleDimension(siz.width, resolutionLevel: K)
        let outHeight = jp3dDownsampleDimension(siz.height, resolutionLevel: K)
        let outDepth = siz.depth

        let (outWH, vOv1) = outWidth.multipliedReportingOverflow(by: outHeight)
        let (outVoxelCount, vOv2) = outWH.multipliedReportingOverflow(by: outDepth)
        var totalBytesPerVoxel = 0
        var bOv1 = false
        for comp in 0..<siz.componentCount {
            let compBytes = (siz.bitDepth(forComponent: comp) + 7) / 8
            let (next, ov) = totalBytesPerVoxel.addingReportingOverflow(compBytes)
            if ov { bOv1 = true }
            totalBytesPerVoxel = next
        }
        let (outDecodedBytes, bOv2) = outVoxelCount.multipliedReportingOverflow(by: totalBytesPerVoxel)
        guard !vOv1, !vOv2, !bOv1, !bOv2 else {
            throw J2KError.decodingError("Decoded volume dimensions overflow integer arithmetic")
        }

        let isStreamLossless = cod.isLossless && codestream.isLosslessQuantization
        let hasLegacyTilePayload = codestream.tiles.contains {
            JP3DLosslessIntegerTileCodec.hasMagic($0.data) || JP3DSliceStackCodec.isSliceStackTile($0.data)
        }
        let isNormativeCodestream = codestream.hasNSIMarker && !hasLegacyTilePayload
        let useExactIntegerPath = isNormativeCodestream || (isStreamLossless && !codestream.tiles.isEmpty && codestream.tiles.allSatisfy {
            JP3DLosslessIntegerTileCodec.hasMagic($0.data) || JP3DSliceStackCodec.isSliceStackTile($0.data)
        })
        let normativeContext: NormativeDecodeContext? = isNormativeCodestream
            ? NormativeDecodeContext(
                siz: siz,
                cod: cod,
                qcd: codestream.qcd,
                roiShifts: codestream.roiShifts,
                tolerateTruncation: configuration.tolerateErrors
            )
            : nil
        let elementStride = useExactIntegerPath ? MemoryLayout<Int64>.stride : MemoryLayout<Float>.stride
        let (totalSamples, sOv1) = outVoxelCount.multipliedReportingOverflow(by: siz.componentCount)
        let (bufferWorkspaceBytes, sOv2) = totalSamples.multipliedReportingOverflow(by: elementStride)
        guard !sOv1, !sOv2 else {
            throw J2KError.decodingError("Decode workspace size overflows integer arithmetic")
        }

        let configuredWorkersPreflight = limits.map { min(configuration.maximumWorkers, $0.maximumWorkers) }
            ?? configuration.maximumWorkers
        let activeDecodeWorkers = configuration.parallelTileDecoding
            ? max(1, min(configuredWorkersPreflight, codestream.tiles.count))
            : 1
        let maxTileW = min(siz.width, siz.tileSizeX)
        let maxTileH = min(siz.height, siz.tileSizeY)
        let maxTileD = min(siz.depth, siz.tileSizeZ)
        let (tWH, tOv1) = maxTileW.multipliedReportingOverflow(by: maxTileH)
        let (maxTileVox, tOv2) = tWH.multipliedReportingOverflow(by: maxTileD)
        let (perTileSamples, tOv3) = maxTileVox.multipliedReportingOverflow(by: siz.componentCount)
        let (perWorkerTileBuf, tOv4) = perTileSamples.multipliedReportingOverflow(by: max(elementStride * 2, MemoryLayout<Int64>.stride + MemoryLayout<Float>.stride))
        let (allWorkersBuf, tOv5) = perWorkerTileBuf.multipliedReportingOverflow(by: activeDecodeWorkers)
        let retainedSourceBytes = try jp3dDecodeAdd(codestream.retainedTileBytes, codestream.commentPayloadBytes)
        let (ws1, tOv6) = retainedSourceBytes.addingReportingOverflow(bufferWorkspaceBytes)
        let (peakDecodeWorkspace, tOv7) = ws1.addingReportingOverflow(allWorkersBuf)
        guard !tOv1, !tOv2, !tOv3, !tOv4, !tOv5, !tOv6, !tOv7 else {
            throw J2KError.decodingError("Decode worker workspace overflows integer arithmetic")
        }

        if let limits {
            let maxDim = limits.maximumDimension
            guard siz.width <= maxDim, siz.height <= maxDim, siz.depth <= maxDim else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Codestream dimensions (\(siz.width)x\(siz.height)x\(siz.depth)) exceed limit \(maxDim)"
                )
            }
            guard siz.depth <= limits.maximumFrames else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Codestream depth \(siz.depth) exceeds frame limit \(limits.maximumFrames)"
                )
            }
            let (fullWH, fOv1) = siz.width.multipliedReportingOverflow(by: siz.height)
            let (fullVoxels, fOv2) = fullWH.multipliedReportingOverflow(by: siz.depth)
            guard !fOv1, !fOv2, fullVoxels <= limits.maximumPixels, outVoxelCount <= limits.maximumPixels else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric voxel count exceeds pixel limit \(limits.maximumPixels)"
                )
            }
            guard outDecodedBytes <= limits.maximumDecodedBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Decoded volume byte count \(outDecodedBytes) exceeds decoded-byte limit \(limits.maximumDecodedBytes)"
                )
            }
            guard peakDecodeWorkspace <= limits.maximumWorkspaceBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric decode workspace \(peakDecodeWorkspace) exceeds workspace limit \(limits.maximumWorkspaceBytes)"
                )
            }
            let (mem1, mOv1) = data.count.addingReportingOverflow(outDecodedBytes)
            let (totalLiveMem, mOv2) = mem1.addingReportingOverflow(peakDecodeWorkspace)
            guard !mOv1, !mOv2, totalLiveMem <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric decode memory \(totalLiveMem) exceeds memory limit \(limits.maximumMemoryBytes)"
                )
            }
        }

        let workerLimits = try limits.map {
            try jp3dDecodeWorkerLimits($0, retainedWorkspace: ws1,
                retainedMemory: jp3dDecodeAdd(jp3dDecodeAdd(data.count, outDecodedBytes), ws1),
                workers: activeDecodeWorkers)
        }
        let decodeWorkspace = JP3DDecodeWorkspace()

        try work.check()
        reportProgress(.parsing, stageProgress: 1.0, tilesDone: 0, tilesTotal: codestream.tiles.count)

        let tilingConfig = JP3DTilingConfiguration(
            tileSizeX: siz.tileSizeX,
            tileSizeY: siz.tileSizeY,
            tileSizeZ: siz.tileSizeZ
        )
        let allTiles = tilingConfig.allTiles(
            volumeWidth: siz.width,
            volumeHeight: siz.height,
            volumeDepth: siz.depth
        )

        StorageTelemetry.recordStage("volume-decode-buffers", bytes: bufferWorkspaceBytes)
        StorageTelemetry.recordWorkspaceAllocation(bytes: bufferWorkspaceBytes)

        var intComponentBuffers: [[Int64]] = useExactIntegerPath
            ? (0..<siz.componentCount).map { _ in [Int64](repeating: 0, count: outVoxelCount) }
            : []
        var floatComponentBuffers: [[Float]] = useExactIntegerPath
            ? []
            : (0..<siz.componentCount).map { _ in [Float](repeating: 0, count: outVoxelCount) }

        let tilesExpected = allTiles.count
        var tilesDecoded = 0
        var isPartial = false
        var warnings: [String] = []

        let filter: JP3DWaveletFilter = cod.isLossless ? .reversible53 : .irreversible97
        let transformConfig = JP3DTransformConfiguration(
            filter: filter,
            mode: .separable,
            boundary: .symmetric,
            levelsX: cod.levelsX,
            levelsY: cod.levelsY,
            levelsZ: cod.levelsZ
        )

        let maxQLayers: Int? = configuration.maxQualityLayers > 0 ? configuration.maxQualityLayers : nil
        let configuredWorkers = limits.map { min(configuration.maximumWorkers, $0.maximumWorkers) }
            ?? configuration.maximumWorkers
        let workerBudget = configuration.parallelTileDecoding ? max(1, configuredWorkers) : 1

        struct ValidTileJob: Sendable {
            let seqIdx: Int
            let parsedTile: JP3DParsedTile
            let tile: JP3DTile
            let outX0: Int
            let outY0: Int
            let outZ0: Int
            let tileW: Int
            let tileH: Int
            let tileD: Int
        }

        var jobs: [ValidTileJob] = []
        jobs.reserveCapacity(codestream.tiles.count)
        for (seqIdx, parsedTile) in codestream.tiles.enumerated() {
            guard parsedTile.tileIndex >= 0, parsedTile.tileIndex < allTiles.count else {
                isPartial = true
                warnings.append("Tile index \(parsedTile.tileIndex) out of bounds")
                continue
            }
            let tile = allTiles[parsedTile.tileIndex]
            let outX0 = jp3dDownsampleOrigin(tile.region.x.lowerBound, resolutionLevel: K, roundUp: true)
            let outY0 = jp3dDownsampleOrigin(tile.region.y.lowerBound, resolutionLevel: K, roundUp: true)
            let outZ0 = tile.region.z.lowerBound
            let tileW = jp3dDownsampleOrigin(tile.region.x.upperBound, resolutionLevel: K, roundUp: true) - outX0
            let tileH = jp3dDownsampleOrigin(tile.region.y.upperBound, resolutionLevel: K, roundUp: true) - outY0
            let tileD = tile.depth
            jobs.append(ValidTileJob(
                seqIdx: seqIdx,
                parsedTile: parsedTile,
                tile: tile,
                outX0: outX0,
                outY0: outY0,
                outZ0: outZ0,
                tileW: tileW,
                tileH: tileH,
                tileD: tileD
            ))
        }

        func scatterOutcome(
            _ outcome: TileTaskOutcome,
            intBuffers: inout [[Int64]],
            floatBuffers: inout [[Float]],
            decodedCount: inout Int,
            partialFlag: inout Bool,
            warningList: inout [String]
        ) throws {
            switch outcome.result {
            case .success(let decodedSamples):
                switch decodedSamples {
                case .integer(let samples):
                    for comp in 0..<siz.componentCount {
                        guard comp < samples.count else { continue }
                        let reconstructed = samples[comp]
                        for z in 0..<outcome.tileD {
                            let dstZ = outcome.outZ0 + z
                            guard dstZ < outDepth else { continue }
                            for y in 0..<outcome.tileH {
                                let dstY = outcome.outY0 + y
                                guard dstY < outHeight else { continue }
                                for x in 0..<outcome.tileW {
                                    let dstX = outcome.outX0 + x
                                    guard dstX < outWidth else { continue }
                                    let srcIdx = z * outcome.tileW * outcome.tileH + y * outcome.tileW + x
                                    let dstIdx = dstZ * outWidth * outHeight + dstY * outWidth + dstX
                                    if srcIdx < reconstructed.count && dstIdx < outVoxelCount {
                                        intBuffers[comp][dstIdx] = reconstructed[srcIdx]
                                    }
                                }
                            }
                        }
                    }
                case .float(let samples):
                    for comp in 0..<siz.componentCount {
                        guard comp < samples.count else { continue }
                        let reconstructed = samples[comp]
                        for z in 0..<outcome.tileD {
                            let dstZ = outcome.outZ0 + z
                            guard dstZ < outDepth else { continue }
                            for y in 0..<outcome.tileH {
                                let dstY = outcome.outY0 + y
                                guard dstY < outHeight else { continue }
                                for x in 0..<outcome.tileW {
                                    let dstX = outcome.outX0 + x
                                    guard dstX < outWidth else { continue }
                                    let srcIdx = z * outcome.tileW * outcome.tileH + y * outcome.tileW + x
                                    let dstIdx = dstZ * outWidth * outHeight + dstY * outWidth + dstX
                                    if srcIdx < reconstructed.count && dstIdx < outVoxelCount {
                                        floatBuffers[comp][dstIdx] = reconstructed[srcIdx]
                                    }
                                }
                            }
                        }
                    }
                }
                decodedCount += 1
                if outcome.wasTruncated {
                    partialFlag = true
                    warningList.append("Tile \(outcome.tileIndex) packet stream truncated")
                }
                let tileProgress = Double(decodedCount) / Double(max(1, codestream.tiles.count))
                reportProgress(
                    .tileReconstruction,
                    stageProgress: tileProgress,
                    tilesDone: decodedCount,
                    tilesTotal: tilesExpected
                )
            case .failure(let error):
                if error is CancellationError {
                    throw error
                }
                if let codecError = error as? CodecError, codecError.category == .resourceLimitExceeded {
                    throw codecError
                }
                if configuration.tolerateErrors {
                    warningList.append("Tile \(outcome.tileIndex) decode failed: \(error)")
                    partialFlag = true
                } else {
                    throw error
                }
            }
        }

        let compCount = siz.componentCount
        let isLosslessFlag = cod.isLossless

        if workerBudget > 1 && jobs.count > 1 {
            try await withThrowingTaskGroup(of: TileTaskOutcome.self) { group in
                var nextJobIndex = 0
                let initialBatch = min(workerBudget, jobs.count)

                func enqueue(_ job: ValidTileJob) {
                    group.addTask {
                        try work.check()
                        if let rec = VolumeConcurrencyTelemetry.recorder {
                            try await rec.enter()
                        }
                        defer {
                            VolumeConcurrencyTelemetry.recorder?.exit()
                        }
                        do {
                            let decoded: DecodedTileSamples
                            var wasTruncated = false
                            if useExactIntegerPath {
                                let (ints, trunc) = try Self.decodeTilePayloadIntegerWithStatusStatic(
                                    job.parsedTile.data,
                                    tile: job.tile,
                                    componentCount: compCount,
                                    maxQualityLayers: maxQLayers,
                                    resolutionLevel: K,
                                    normativeContext: normativeContext,
                                    limits: workerLimits,
                                    executionPolicy: executionPolicy,
                                    workspace: decodeWorkspace,
                                    work: work
                                )
                                decoded = .integer(ints)
                                wasTruncated = trunc
                            } else {
                                let floats = try await Self.decodeTilePayloadStatic(
                                    job.parsedTile.data,
                                    tile: job.tile,
                                    componentCount: compCount,
                                    tileW: job.tileW,
                                    tileH: job.tileH,
                                    tileD: job.tileD,
                                    isLossless: isLosslessFlag,
                                    transformConfig: transformConfig,
                                    maxQualityLayers: maxQLayers,
                                    resolutionLevel: K,
                                    limits: workerLimits,
                                    executionPolicy: executionPolicy,
                                    workspace: decodeWorkspace
                                )
                                decoded = .float(floats)
                            }
                            return TileTaskOutcome(
                                seqIdx: job.seqIdx,
                                tileIndex: job.parsedTile.tileIndex,
                                outX0: job.outX0,
                                outY0: job.outY0,
                                outZ0: job.outZ0,
                                tileW: job.tileW,
                                tileH: job.tileH,
                                tileD: job.tileD,
                                wasTruncated: wasTruncated,
                                result: .success(decoded)
                            )
                        } catch {
                            return TileTaskOutcome(
                                seqIdx: job.seqIdx,
                                tileIndex: job.parsedTile.tileIndex,
                                outX0: job.outX0,
                                outY0: job.outY0,
                                outZ0: job.outZ0,
                                tileW: job.tileW,
                                tileH: job.tileH,
                                tileD: job.tileD,
                                wasTruncated: false,
                                result: .failure(error)
                            )
                        }
                    }
                }

                while nextJobIndex < initialBatch {
                    try work.check()
                    enqueue(jobs[nextJobIndex])
                    nextJobIndex += 1
                }

                while let completed = try await group.next() {
                    try work.check()
                    do {
                        try scatterOutcome(
                            completed,
                            intBuffers: &intComponentBuffers,
                            floatBuffers: &floatComponentBuffers,
                            decodedCount: &tilesDecoded,
                            partialFlag: &isPartial,
                            warningList: &warnings
                        )
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                    if nextJobIndex < jobs.count {
                        enqueue(jobs[nextJobIndex])
                        nextJobIndex += 1
                    }
                }
            }
        } else {
            for job in jobs {
                try work.check()
                if let rec = VolumeConcurrencyTelemetry.recorder {
                    try await rec.enter()
                }
                let result: Result<DecodedTileSamples, any Error>
                var wasTruncated = false
                do {
                    if useExactIntegerPath {
                        let (ints, trunc) = try Self.decodeTilePayloadIntegerWithStatusStatic(
                            job.parsedTile.data,
                            tile: job.tile,
                            componentCount: compCount,
                            maxQualityLayers: maxQLayers,
                            resolutionLevel: K,
                            normativeContext: normativeContext,
                            limits: workerLimits,
                            executionPolicy: executionPolicy,
                            workspace: decodeWorkspace,
                            work: work
                        )
                        result = .success(.integer(ints))
                        wasTruncated = trunc
                    } else {
                        let floats = try await Self.decodeTilePayloadStatic(
                            job.parsedTile.data,
                            tile: job.tile,
                            componentCount: compCount,
                            tileW: job.tileW,
                            tileH: job.tileH,
                            tileD: job.tileD,
                            isLossless: isLosslessFlag,
                            transformConfig: transformConfig,
                            maxQualityLayers: maxQLayers,
                            resolutionLevel: K,
                            limits: workerLimits,
                            executionPolicy: executionPolicy,
                            workspace: decodeWorkspace
                        )
                        result = .success(.float(floats))
                    }
                } catch {
                    result = .failure(error)
                }
                VolumeConcurrencyTelemetry.recorder?.exit()
                try scatterOutcome(
                    TileTaskOutcome(
                        seqIdx: job.seqIdx,
                        tileIndex: job.parsedTile.tileIndex,
                        outX0: job.outX0,
                        outY0: job.outY0,
                        outZ0: job.outZ0,
                        tileW: job.tileW,
                        tileH: job.tileH,
                        tileD: job.tileD,
                        wasTruncated: wasTruncated,
                        result: result
                    ),
                    intBuffers: &intComponentBuffers,
                    floatBuffers: &floatComponentBuffers,
                    decodedCount: &tilesDecoded,
                    partialFlag: &isPartial,
                    warningList: &warnings
                )
            }
        }

        if tilesDecoded < tilesExpected {
            isPartial = true
            warnings.append("Decoded \(tilesDecoded) of \(tilesExpected) expected tiles")
        }

        try work.check()
        reportProgress(.volumeAssembly, stageProgress: 0.5, tilesDone: tilesDecoded, tilesTotal: tilesExpected)

        for comp in 0..<siz.componentCount {
            let compBytes = outVoxelCount * ((siz.bitDepth(forComponent: comp) + 7) / 8)
            StorageTelemetry.recordPixelAllocation(bytes: compBytes)
        }
        let volumeComponents: [J2KVolumeComponent]
        if useExactIntegerPath {
            volumeComponents = jp3dAssembleVolumeComponentsInteger(
                buffers: intComponentBuffers,
                width: outWidth,
                height: outHeight,
                depth: outDepth,
                bitDepth: siz.bitDepth,
                signed: siz.signed,
                componentBitDepths: siz.componentBitDepths,
                componentSigned: siz.componentSigned
            )
        } else {
            volumeComponents = assembleVolumeComponents(
                buffers: floatComponentBuffers,
                width: outWidth,
                height: outHeight,
                depth: outDepth,
                bitDepth: siz.bitDepth,
                signed: siz.signed
            )
        }

        let restoredGeometry: JP3DVolumeGeometry? = (metadataPolicy == .preserve) ? codestream.geometry : nil
        let outSpacingX = restoredGeometry.map { $0.spacingX > 0 ? scalbn($0.spacingX, K) : 0 } ?? 0
        let outSpacingY = restoredGeometry.map { $0.spacingY > 0 ? scalbn($0.spacingY, K) : 0 } ?? 0
        let outSpacingZ = restoredGeometry?.spacingZ ?? 0
        let outOriginX = restoredGeometry?.originX ?? 0
        let outOriginY = restoredGeometry?.originY ?? 0
        let outOriginZ = restoredGeometry?.originZ ?? 0

        let volume = J2KVolume(
            width: outWidth,
            height: outHeight,
            depth: outDepth,
            components: volumeComponents,
            spacingX: outSpacingX,
            spacingY: outSpacingY,
            spacingZ: outSpacingZ,
            originX: outOriginX,
            originY: outOriginY,
            originZ: outOriginZ
        )
        try volume.validate()

        try work.check()
        reportProgress(.volumeAssembly, stageProgress: 1.0, tilesDone: tilesDecoded, tilesTotal: tilesExpected)

        return JP3DDecoderResult(
            volume: volume,
            isPartial: isPartial,
            warnings: warnings,
            tilesDecoded: tilesDecoded,
            tilesTotal: tilesExpected,
            isLossless: isStreamLossless && !isPartial && K == 0 && maxQLayers == nil,
            peakWorkspaceBytes: max(peakDecodeWorkspace, try jp3dDecodeAdd(ws1,
                jp3dDecodeMultiply(decodeWorkspace.peak, activeDecodeWorkers))),
            commentCount: codestream.comments.count,
            commentPayloadBytes: codestream.commentPayloadBytes,
            hadVolumeGeometry: codestream.geometry != nil
        )
    }

    // MARK: - Internal Helpers

    internal static func decodeTilePayloadIntegerStatic(
        _ data: Data,
        tile: JP3DTile,
        componentCount: Int,
        maxQualityLayers: Int?,
        resolutionLevel: Int,
        normativeContext: NormativeDecodeContext? = nil,
        limits: ResourceLimits? = nil,
        executionPolicy: ExecutionPolicy = .automatic,
        workspace: JP3DDecodeWorkspace? = nil,
        work: VolumeWorkGuard? = nil
    ) throws -> [[Int64]] {
        try decodeTilePayloadIntegerWithStatusStatic(
            data,
            tile: tile,
            componentCount: componentCount,
            maxQualityLayers: maxQualityLayers,
            resolutionLevel: resolutionLevel,
            normativeContext: normativeContext,
            limits: limits,
            executionPolicy: executionPolicy,
            workspace: workspace,
            work: work
        ).samples
    }

    internal static func decodeTilePayloadIntegerWithStatusStatic(
        _ data: Data,
        tile: JP3DTile,
        componentCount: Int,
        maxQualityLayers: Int?,
        resolutionLevel: Int,
        normativeContext: NormativeDecodeContext? = nil,
        limits: ResourceLimits? = nil,
        executionPolicy: ExecutionPolicy = .automatic,
        workspace: JP3DDecodeWorkspace? = nil,
        work: VolumeWorkGuard? = nil
    ) throws -> (samples: [[Int64]], wasTruncated: Bool) {
        let sampleCount = try jp3dDecodeMultiply(jp3dDecodeMultiply(
            jp3dDecodeMultiply(tile.width, tile.height), tile.depth), componentCount)
        let tileBuffers = try jp3dDecodeMultiply(sampleCount, MemoryLayout<Int64>.stride * 2)
        if let limits {
            guard tileBuffers <= limits.maximumWorkspaceBytes, tileBuffers <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Decoded tile buffers exceed worker limits")
            }
        }
        workspace?.record(tileBuffers)
        if resolutionLevel > 0 {
            // Reconstruct before selecting the volume-wide grid. Reducing each tile
            // from its local origin misaligns tiles whose origins are odd.
            let (full, trunc) = try decodeTilePayloadIntegerWithStatusStatic(
                data, tile: tile, componentCount: componentCount,
                maxQualityLayers: maxQualityLayers, resolutionLevel: 0,
                normativeContext: normativeContext,
                limits: limits, executionPolicy: executionPolicy, workspace: workspace, work: work
            )
            let reduced = try jp3dSampleReducedTile(
                full, xRange: tile.region.x, yRange: tile.region.y, depth: tile.depth,
                resolutionLevel: resolutionLevel
            )
            return (reduced, trunc)
        }
        if JP3DLosslessIntegerTileCodec.hasMagic(data) {
            let ints = try JP3DLosslessIntegerTileCodec.decodeTileInteger(
                data,
                expectedComponents: componentCount,
                resolutionLevel: resolutionLevel
            )
            return (ints, false)
        }
        if JP3DSliceStackCodec.isSliceStackTile(data) {
            let sliceCodec = JP3DSliceStackCodec()
            let ints = try sliceCodec.decodeTileInteger(
                data,
                expectedComponents: componentCount,
                expectedWidth: tile.width,
                expectedHeight: tile.height,
                expectedDepth: tile.depth,
                maxQualityLayers: maxQualityLayers,
                resolutionLevel: resolutionLevel,
                limits: limits ?? .default,
                executionPolicy: executionPolicy, workspace: workspace
            )
            return (ints, false)
        }
        if let ctx = normativeContext {
            _ = try AccelerationRuntime.resolve(executionPolicy)
            let decoded = try JP3DNormativeTileCodec.decodeTile(
                tileData: data,
                siz: ctx.siz,
                cod: ctx.cod,
                qcd: ctx.qcd,
                roiShifts: ctx.roiShifts,
                x0: tile.region.x.lowerBound,
                x1: tile.region.x.upperBound,
                y0: tile.region.y.lowerBound,
                y1: tile.region.y.upperBound,
                z0: tile.region.z.lowerBound,
                z1: tile.region.z.upperBound,
                maxQualityLayers: maxQualityLayers,
                resolutionLevel: 0,
                tolerateTruncation: ctx.tolerateTruncation,
                cancellation: {
                    if let work {
                        try work.check()
                    } else if Task.isCancelled {
                        throw CancellationError()
                    }
                }
            )
            return (decoded.components, decoded.wasTruncated)
        }
        throw J2KError.decodingError("Unsupported integer lossless tile payload format")
    }

    internal static func decodeTilePayloadStatic(
        _ data: Data,
        tile: JP3DTile,
        componentCount: Int,
        tileW: Int,
        tileH: Int,
        tileD: Int,
        isLossless: Bool,
        transformConfig: JP3DTransformConfiguration,
        maxQualityLayers: Int?,
        resolutionLevel: Int,
        limits: ResourceLimits? = nil,
        executionPolicy: ExecutionPolicy = .automatic,
        workspace: JP3DDecodeWorkspace? = nil
    ) async throws -> [[Float]] {
        let sampleCount = try jp3dDecodeMultiply(jp3dDecodeMultiply(
            jp3dDecodeMultiply(tile.width, tile.height), tile.depth), componentCount)
        let tileBuffers = try jp3dDecodeMultiply(sampleCount, MemoryLayout<Int64>.stride + MemoryLayout<Float>.stride)
        if let limits {
            guard tileBuffers <= limits.maximumWorkspaceBytes, tileBuffers <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Decoded tile buffers exceed worker limits")
            }
        }
        workspace?.record(tileBuffers)
        if resolutionLevel > 0 {
            let full = try await decodeTilePayloadStatic(
                data, tile: tile, componentCount: componentCount,
                tileW: tile.width, tileH: tile.height, tileD: tile.depth,
                isLossless: isLossless, transformConfig: transformConfig,
                maxQualityLayers: maxQualityLayers, resolutionLevel: 0,
                limits: limits, executionPolicy: executionPolicy, workspace: workspace
            )
            return try jp3dSampleReducedTile(
                full, xRange: tile.region.x, yRange: tile.region.y, depth: tile.depth,
                resolutionLevel: resolutionLevel
            )
        }
        if JP3DLosslessIntegerTileCodec.hasMagic(data) {
            let ints = try JP3DLosslessIntegerTileCodec.decodeTileInteger(
                data,
                expectedComponents: componentCount,
                resolutionLevel: resolutionLevel
            )
            return ints.map { $0.map { Float($0) } }
        }
        if JP3DSliceStackCodec.isSliceStackTile(data) {
            let sliceCodec = JP3DSliceStackCodec()
            return try sliceCodec.decodeTile(
                data,
                expectedComponents: componentCount,
                expectedWidth: tile.width,
                expectedHeight: tile.height,
                expectedDepth: tile.depth,
                maxQualityLayers: maxQualityLayers,
                resolutionLevel: resolutionLevel,
                limits: limits ?? .default,
                executionPolicy: executionPolicy, workspace: workspace
            )
        }

        if data.count >= 4, let htInfo = JP3DHTTileInfo.decode(from: data),
           data.count == 4 + (htInfo.isHT ? 4 : 0) + componentCount * tile.width * tile.height * tile.depth * 4 {
            let codec = JP3DHTJ2KCodec()
            let voxelsPerComp = tile.width * tile.height * tile.depth
            let decodedAll = try codec.decodeTile(
                tileData: data,
                expectedVoxels: voxelsPerComp * componentCount
            )
            let wavelet = JP3DWaveletTransform(configuration: transformConfig)
            var out: [[Float]] = []
            out.reserveCapacity(componentCount)
            for comp in 0..<componentCount {
                let slice = Array(decodedAll[(comp * voxelsPerComp)..<((comp + 1) * voxelsPerComp)])
                let decomp = JP3DSubbandDecomposition(
                    width: tile.width, height: tile.height, depth: tile.depth,
                    levelsX: transformConfig.levelsX,
                    levelsY: transformConfig.levelsY,
                    levelsZ: transformConfig.levelsZ,
                    coefficients: J2K3DCoefficients(
                        width: tile.width, height: tile.height, depth: tile.depth,
                        decompositionLevels: max(
                            transformConfig.levelsX,
                            max(transformConfig.levelsY, transformConfig.levelsZ)
                        ),
                        data: slice
                    ),
                    originalWidth: tile.width,
                    originalHeight: tile.height,
                    originalDepth: tile.depth
                )
                let reconstructed = try await wavelet.inverse(decomposition: decomp)
                out.append(reconstructed)
            }
            return out
        }

        let tileCoeffs = try decodeTilePayload(
            data,
            componentCount: componentCount,
            voxelsPerComponent: tileW * tileH * tileD,
            isLossless: isLossless
        )
        let wavelet = JP3DWaveletTransform(configuration: transformConfig)
        let lx = transformConfig.levelsX
        let ly = transformConfig.levelsY
        let lz = transformConfig.levelsZ
        var out: [[Float]] = []
        out.reserveCapacity(componentCount)
        for comp in 0..<componentCount {
            let floatCoeffs = tileCoeffs[comp]
            let decomp = JP3DSubbandDecomposition(
                width: tileW, height: tileH, depth: tileD,
                levelsX: lx, levelsY: ly, levelsZ: lz,
                coefficients: J2K3DCoefficients(
                    width: tileW, height: tileH, depth: tileD,
                    decompositionLevels: max(lx, max(ly, lz)),
                    data: floatCoeffs
                ),
                originalWidth: tileW,
                originalHeight: tileH,
                originalDepth: tileD
            )
            let reconstructed = try await wavelet.inverse(decomposition: decomp)
            out.append(reconstructed)
        }
        return out
    }

    internal static func decodeTilePayload(
        _ data: Data,
        componentCount: Int,
        voxelsPerComponent: Int,
        isLossless: Bool
    ) throws -> [[Float]] {
        let headerBytes = 4
        let bytesPerCoeff = 4
        let (compCoeffBytes, ov1) = voxelsPerComponent.multipliedReportingOverflow(by: bytesPerCoeff)
        let (bytesPerComponent, ov2) = compCoeffBytes.addingReportingOverflow(headerBytes)
        let (requiredTotal, ov3) = bytesPerComponent.multipliedReportingOverflow(by: componentCount)
        guard !ov1, !ov2, !ov3, data.count >= requiredTotal else {
            throw J2KError.decodingError(
                "Truncated tile coefficient payload (\(data.count) bytes, expected \(requiredTotal))"
            )
        }
        var result: [[Float]] = []
        result.reserveCapacity(componentCount)

        for comp in 0..<componentCount {
            let compStart = comp * bytesPerComponent
            let coeffDataStart = compStart + headerBytes
            var coeffs = [Float](repeating: 0, count: voxelsPerComponent)
            if voxelsPerComponent > 0 {
                data.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    for i in 0..<voxelsPerComponent {
                        let bytePos = coeffDataStart + i * 4
                        let b0 = UInt32(base.load(fromByteOffset: bytePos, as: UInt8.self))
                        let b1 = UInt32(base.load(fromByteOffset: bytePos + 1, as: UInt8.self))
                        let b2 = UInt32(base.load(fromByteOffset: bytePos + 2, as: UInt8.self))
                        let b3 = UInt32(base.load(fromByteOffset: bytePos + 3, as: UInt8.self))
                        let word = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
                        coeffs[i] = Float(Int32(bitPattern: word))
                    }
                }
            }
            result.append(coeffs)
        }

        return result
    }

    internal func assembleVolumeComponents(
        buffers: [[Float]],
        width: Int,
        height: Int,
        depth: Int,
        bitDepth: Int,
        signed: Bool
    ) -> [J2KVolumeComponent] {
        jp3dAssembleVolumeComponentsFloat(
            buffers: buffers,
            width: width,
            height: height,
            depth: depth,
            bitDepth: bitDepth,
            signed: signed
        )
    }

    private func reportProgress(
        _ stage: JP3DDecodingStage,
        stageProgress: Double,
        tilesDone: Int,
        tilesTotal: Int
    ) {
        let baseWeight: Double
        let spanWeight: Double
        switch stage {
        case .parsing:
            baseWeight = 0.0; spanWeight = 0.1
        case .tileReconstruction, .dequantization, .inverseWavelet:
            baseWeight = 0.1; spanWeight = 0.8
        case .volumeAssembly, .assembly:
            baseWeight = 0.9; spanWeight = 0.1
        case .complete:
            baseWeight = 1.0; spanWeight = 0.0
        }
        let overall = min(1.0, baseWeight + spanWeight * stageProgress)
        let progress = JP3DDecoderProgress(
            stage: stage,
            stageProgress: stageProgress,
            overallProgress: overall,
            tilesDecoded: tilesDone,
            totalTiles: tilesTotal
        )
        progressCallback?(progress)
    }
}

internal func jp3dAssembleVolumeComponentsInteger(
    buffers: [[Int64]],
    width: Int,
    height: Int,
    depth: Int,
    bitDepth: Int,
    signed: Bool,
    componentBitDepths: [Int]? = nil,
    componentSigned: [Bool]? = nil
) -> [J2KVolumeComponent] {
    return buffers.enumerated().map { index, buffer in
        let compBitDepth = (componentBitDepths != nil && index < componentBitDepths!.count)
            ? componentBitDepths![index]
            : bitDepth
        let compSigned = (componentSigned != nil && index < componentSigned!.count)
            ? componentSigned![index]
            : signed
        let clampedDepth = max(1, min(38, compBitDepth))
        let bytesPerSample = (clampedDepth + 7) / 8
        let minVal: Int64 = compSigned ? -(Int64(1) << (clampedDepth - 1)) : 0
        let maxVal: Int64 = compSigned
            ? ((Int64(1) << (clampedDepth - 1)) - 1)
            : ((Int64(1) << clampedDepth) - 1)

        let count = buffer.count
        var data = Data(count: count * bytesPerSample)
        data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            switch bytesPerSample {
            case 1:
                for i in 0..<count {
                    let clamped = max(minVal, min(maxVal, buffer[i]))
                    base[i] = UInt8(truncatingIfNeeded: UInt64(bitPattern: clamped))
                }
            case 2:
                for i in 0..<count {
                    let clamped = max(minVal, min(maxVal, buffer[i]))
                    let rawWord = UInt64(bitPattern: clamped)
                    base[i * 2] = UInt8(truncatingIfNeeded: rawWord)
                    base[i * 2 + 1] = UInt8(truncatingIfNeeded: rawWord >> 8)
                }
            case 4:
                for i in 0..<count {
                    let clamped = max(minVal, min(maxVal, buffer[i]))
                    let rawWord = UInt64(bitPattern: clamped)
                    base[i * 4] = UInt8(truncatingIfNeeded: rawWord)
                    base[i * 4 + 1] = UInt8(truncatingIfNeeded: rawWord >> 8)
                    base[i * 4 + 2] = UInt8(truncatingIfNeeded: rawWord >> 16)
                    base[i * 4 + 3] = UInt8(truncatingIfNeeded: rawWord >> 24)
                }
            default:
                for i in 0..<count {
                    let clamped = max(minVal, min(maxVal, buffer[i]))
                    let rawWord = UInt64(bitPattern: clamped)
                    for b in 0..<bytesPerSample {
                        base[i * bytesPerSample + b] = UInt8(truncatingIfNeeded: rawWord >> (b * 8))
                    }
                }
            }
        }
        return J2KVolumeComponent(
            index: index,
            bitDepth: compBitDepth,
            signed: compSigned,
            width: width,
            height: height,
            depth: depth,
            data: data
        )
    }
}

internal func jp3dAssembleVolumeComponentsFloat(
    buffers: [[Float]],
    width: Int,
    height: Int,
    depth: Int,
    bitDepth: Int,
    signed: Bool
) -> [J2KVolumeComponent] {
    let clampedDepth = max(1, min(38, bitDepth))
    let minValI64: Int64 = signed ? -(Int64(1) << (clampedDepth - 1)) : 0
    let maxValI64: Int64 = signed
        ? ((Int64(1) << (clampedDepth - 1)) - 1)
        : ((Int64(1) << clampedDepth) - 1)
    let minValD = Double(minValI64)
    let maxValD = Double(maxValI64)

    var intBuffers: [[Int64]] = []
    intBuffers.reserveCapacity(buffers.count)
    for buffer in buffers {
        var ints = [Int64](repeating: 0, count: buffer.count)
        for i in 0..<buffer.count {
            let v = Double(buffer[i])
            if !v.isFinite {
                ints[i] = 0
            } else {
                let clamped = max(minValD, min(maxValD, v.rounded()))
                ints[i] = max(minValI64, min(maxValI64, Int64(clamped)))
            }
        }
        intBuffers.append(ints)
    }
    return jp3dAssembleVolumeComponentsInteger(
        buffers: intBuffers,
        width: width,
        height: height,
        depth: depth,
        bitDepth: bitDepth,
        signed: signed
    )
}
