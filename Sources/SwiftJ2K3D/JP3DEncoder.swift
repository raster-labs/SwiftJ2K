// SPDX-License-Identifier: Apache-2.0
//
// JP3DEncoder.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DEncoder.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Fixed signed voxel packing in serialiseFloatSamples so negative signed 8-bit
//     and 16-bit samples are serialised in two's-complement instead of unsigned truncation.
//   - Passed component signedness (`signed: volume.components[0].signed`) to
//     JP3DCodestreamBuilder.build so SIZ marker segments preserve `Ssiz` bit 7 (`0x80`).

import Foundation
import SwiftJ2K

// MARK: - Encoder Configuration

/// Configuration for the JP3D volumetric encoder.
public struct JP3DEncoderConfiguration: Sendable, Equatable {
    /// Compression mode strategy.
    public let compressionMode: JP3DCompressionMode

    /// 3D tiling configuration.
    public let tiling: JP3DTilingConfiguration

    /// Progression order for packet sequencing.
    public let progressionOrder: JP3DProgressionOrder

    /// Number of quality layers.
    public let qualityLayers: Int

    /// Decomposition levels along X.
    public let levelsX: Int

    /// Decomposition levels along Y.
    public let levelsY: Int

    /// Decomposition levels along Z.
    public let levelsZ: Int

    /// Enable parallel tile encoding.
    public let parallelEncoding: Bool

    /// Alias for ``parallelEncoding``.
    public var parallelTileEncoding: Bool { parallelEncoding }

    /// Z-axis predictive coding policy for the slice-stack fast path.
    public let zDeltaMode: JP3DZDeltaMode

    /// Alias for ``zDeltaMode``.
    public var zDelta: JP3DZDeltaMode { zDeltaMode }

    /// Maximum concurrent tile worker tasks (`>= 1`).
    public let maximumWorkers: Int

    /// Creates an encoder configuration with full control.
    public init(
        compressionMode: JP3DCompressionMode = .lossless,
        tiling: JP3DTilingConfiguration = .default,
        progressionOrder: JP3DProgressionOrder = .lrcps,
        qualityLayers: Int = 1,
        levelsX: Int = 3,
        levelsY: Int = 3,
        levelsZ: Int = 1,
        parallelEncoding: Bool = true,
        zDeltaMode: JP3DZDeltaMode = .auto,
        maximumWorkers: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8)
    ) {
        self.compressionMode = compressionMode
        self.tiling = tiling
        self.progressionOrder = progressionOrder
        self.qualityLayers = max(1, qualityLayers)
        self.levelsX = max(0, levelsX)
        self.levelsY = max(0, levelsY)
        self.levelsZ = max(0, levelsZ)
        self.parallelEncoding = parallelEncoding
        self.zDeltaMode = zDeltaMode
        self.maximumWorkers = max(1, maximumWorkers)
    }

    /// Convenience overload accepting `parallelTileEncoding` and `zDelta` labels.
    public init(
        compressionMode: JP3DCompressionMode = .lossless,
        tiling: JP3DTilingConfiguration = .default,
        progressionOrder: JP3DProgressionOrder = .lrcps,
        qualityLayers: Int = 1,
        levelsX: Int = 3,
        levelsY: Int = 3,
        levelsZ: Int = 1,
        parallelTileEncoding: Bool,
        zDelta: JP3DZDeltaMode = .auto,
        maximumWorkers: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8)
    ) {
        self.init(
            compressionMode: compressionMode,
            tiling: tiling,
            progressionOrder: progressionOrder,
            qualityLayers: qualityLayers,
            levelsX: levelsX,
            levelsY: levelsY,
            levelsZ: levelsZ,
            parallelEncoding: parallelTileEncoding,
            zDeltaMode: zDelta,
            maximumWorkers: maximumWorkers
        )
    }

    // MARK: - Presets

    /// Mathematically lossless encoding using the 5/3 reversible wavelet.
    public static let lossless = JP3DEncoderConfiguration(
        compressionMode: .lossless,
        tiling: .default,
        progressionOrder: .lrcps,
        qualityLayers: 1,
        levelsX: 3, levelsY: 3, levelsZ: 1
    )

    /// Visually lossless encoding using the 9/7 irreversible wavelet.
    public static let visuallyLossless = JP3DEncoderConfiguration(
        compressionMode: .visuallyLossless,
        tiling: .default,
        progressionOrder: .lrcps,
        qualityLayers: 3,
        levelsX: 3, levelsY: 3, levelsZ: 1
    )

    /// Streaming-optimised configuration with smaller tiles and slice-first progression.
    public static let streaming = JP3DEncoderConfiguration(
        compressionMode: .lossless,
        tiling: .streaming,
        progressionOrder: .slrcp,
        qualityLayers: 1,
        levelsX: 2, levelsY: 2, levelsZ: 1
    )

    /// Lossy encoding with a target PSNR.
    public static func lossy(psnr: Double = 40.0, qualityLayers: Int = 3) -> JP3DEncoderConfiguration {
        JP3DEncoderConfiguration(
            compressionMode: .lossy(psnr: psnr),
            tiling: .default,
            progressionOrder: .lrcps,
            qualityLayers: qualityLayers,
            levelsX: 3, levelsY: 3, levelsZ: 1
        )
    }

    /// High-throughput lossless encoding using HTJ2K.
    public static let htj2kLossless = JP3DEncoderConfiguration(
        compressionMode: .losslessHTJ2K,
        tiling: .default,
        progressionOrder: .lrcps,
        qualityLayers: 1,
        levelsX: 3, levelsY: 3, levelsZ: 1
    )

    /// High-throughput lossy encoding using HTJ2K with a target PSNR.
    public static func htj2kLossy(psnr: Double = 40.0, qualityLayers: Int = 3) -> JP3DEncoderConfiguration {
        JP3DEncoderConfiguration(
            compressionMode: .lossyHTJ2K(psnr: psnr),
            tiling: .default,
            progressionOrder: .lrcps,
            qualityLayers: qualityLayers,
            levelsX: 3, levelsY: 3, levelsZ: 1
        )
    }

    /// Wavelet transform configuration derived from this encoder configuration.
    public var transformConfiguration: JP3DTransformConfiguration {
        let filter: JP3DWaveletFilter = compressionMode.isLossless ? .reversible53 : .irreversible97
        return JP3DTransformConfiguration(
            filter: filter,
            mode: .separable,
            boundary: .symmetric,
            levelsX: levelsX,
            levelsY: levelsY,
            levelsZ: levelsZ
        )
    }
}

// MARK: - Encoder Progress & Result

/// Progress update reported during JP3D encoding.
public struct JP3DEncoderProgress: Sendable {
    /// The encoding stage.
    public let stage: JP3DEncodingStage

    /// Progress within the current stage (0.0 to 1.0).
    public let stageProgress: Double

    /// Overall encoding progress (0.0 to 1.0).
    public let overallProgress: Double

    /// Current tile being encoded (0-based).
    public let currentTile: Int

    /// Total number of tiles.
    public let totalTiles: Int

    /// Alias for ``overallProgress``.
    public var fraction: Double { overallProgress }

    public init(
        stage: JP3DEncodingStage,
        stageProgress: Double,
        overallProgress: Double,
        currentTile: Int,
        totalTiles: Int
    ) {
        self.stage = stage
        self.stageProgress = stageProgress
        self.overallProgress = overallProgress
        self.currentTile = currentTile
        self.totalTiles = totalTiles
    }

    public init(currentTile: Int, totalTiles: Int, stage: JP3DEncodingStage) {
        let stageProgress = 1.0
        let tileProgress = totalTiles > 0 ? Double(currentTile) / Double(totalTiles) : 0
        let weight = stage.progressWeight / Double(max(1, totalTiles))
        self.init(
            stage: stage,
            stageProgress: stageProgress,
            overallProgress: min(1.0, tileProgress + weight),
            currentTile: currentTile,
            totalTiles: totalTiles
        )
    }
}

/// Encoding pipeline stages.
public enum JP3DEncodingStage: String, Sendable {
    /// Validating input and preparing tiles.
    case preparation = "Preparation"
    /// Decomposing volume into tiles (alias value).
    case tiling = "Tiling"
    /// Applying 3D wavelet transform.
    case waveletTransform = "Wavelet Transform"
    /// Quantizing wavelet coefficients.
    case quantization = "Quantization"
    /// Slice-stack entropy coding (per-Z-slice 2D HTJ2K/EBCOT).
    case entropyCoding = "Entropy Coding"
    /// Forming packets and codestream.
    case codestreamGeneration = "Codestream Generation"
    /// Packet formation alias.
    case packetFormation = "Packet Formation"
    /// Encoding complete.
    case complete = "Complete"

    var progressWeight: Double {
        switch self {
        case .preparation, .tiling: return 0.1
        case .waveletTransform: return 0.5
        case .quantization, .entropyCoding: return 0.7
        case .codestreamGeneration, .packetFormation: return 0.9
        case .complete: return 1.0
        }
    }
}

/// Result of a JP3D encoding operation.
public struct JP3DEncoderResult: Sendable {
    /// The encoded JP3D codestream data.
    public let data: Data

    /// Width of the encoded volume.
    public let width: Int

    /// Height of the encoded volume.
    public let height: Int

    /// Depth of the encoded volume.
    public let depth: Int

    /// Number of components.
    public let componentCount: Int

    /// Whether the encoding is mathematically lossless.
    public let isLossless: Bool

    /// Total number of tiles encoded.
    public let tileCount: Int

    /// Original uncompressed size in bytes.
    public let originalSize: Int

    /// Measured peak workspace bytes during encoding.
    internal let peakWorkspaceBytes: Int

    /// Compression ratio (original size / encoded size).
    public var compressionRatio: Double {
        guard !data.isEmpty else { return 0 }
        let denom = originalSize > 0 ? originalSize : (width * height * depth * componentCount * 4)
        return Double(denom) / Double(data.count)
    }

    public init(
        data: Data,
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        isLossless: Bool,
        tileCount: Int,
        originalSize: Int = 0
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.depth = depth
        self.componentCount = componentCount
        self.isLossless = isLossless
        self.tileCount = tileCount
        self.originalSize = originalSize > 0 ? originalSize : (width * height * depth * componentCount * 4)
        self.peakWorkspaceBytes = data.count
    }

    internal init(
        data: Data,
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        isLossless: Bool,
        tileCount: Int,
        originalSize: Int,
        peakWorkspaceBytes: Int
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.depth = depth
        self.componentCount = componentCount
        self.isLossless = isLossless
        self.tileCount = tileCount
        self.originalSize = originalSize > 0 ? originalSize : (width * height * depth * componentCount * 4)
        self.peakWorkspaceBytes = peakWorkspaceBytes
    }
}

// MARK: - Encoder Actor

/// Actor for encoding `J2KVolume` datasets into JP3D codestreams.
public actor JP3DEncoder {
    // MARK: - State

    private let configuration: JP3DEncoderConfiguration
    private var progressCallback: (@Sendable (JP3DEncoderProgress) -> Void)?

    // MARK: - Init

    /// Creates a JP3D encoder with the given configuration.
    public init(configuration: JP3DEncoderConfiguration = .lossless) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Sets a callback for encoding progress updates.
    public func setProgressCallback(
        _ callback: @escaping @Sendable (JP3DEncoderProgress) -> Void
    ) {
        self.progressCallback = callback
    }

    /// Convenience method to encode raw floating-point voxel data directly into a JP3D codestream.
    public func encode(
        data: [Float],
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int = 1,
        bitDepth: Int = 8,
        signed: Bool = false
    ) async throws -> JP3DEncoderResult {
        guard width > 0, height > 0, depth > 0, componentCount > 0 else {
            throw J2KError.invalidDimensions(
                "Invalid dimensions: \(width)x\(height)x\(depth), components: \(componentCount)"
            )
        }
        let (wh, ov1) = width.multipliedReportingOverflow(by: height)
        let (voxelCount, ov2) = wh.multipliedReportingOverflow(by: depth)
        let (expectedCount, ov3) = voxelCount.multipliedReportingOverflow(by: componentCount)
        guard !ov1, !ov2, !ov3, data.count == expectedCount else {
            throw J2KError.invalidParameter(
                "Data count \(data.count) does not match \(width)x\(height)x\(depth)x\(componentCount)"
            )
        }
        let bytesPerSample = max(1, (bitDepth + 7) / 8)
        var components: [J2KVolumeComponent] = []
        components.reserveCapacity(componentCount)
        for c in 0..<componentCount {
            let start = c * voxelCount
            let slice = Array(data[start..<(start + voxelCount)])
            var compBytes = Data()
            Self.serialiseFloatSamples(
                slice,
                into: &compBytes,
                bytesPerSample: bytesPerSample,
                signed: signed,
                bitDepth: bitDepth
            )
            components.append(
                J2KVolumeComponent(
                    index: c,
                    bitDepth: bitDepth,
                    signed: signed,
                    width: width,
                    height: height,
                    depth: depth,
                    data: compBytes
                )
            )
        }
        let volume = J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: components
        )
        return try await encode(volume)
    }

    /// Encodes a `J2KVolume` into a JP3D codestream.
    public func encode(_ volume: J2KVolume) async throws -> JP3DEncoderResult {
        try await encodeAdmitted(
            volume,
            limits: nil,
            executionPolicy: .automatic,
            work: VolumeWorkGuard(limits: nil)
        )
    }

    internal func encodeAdmitted(
        _ volume: J2KVolume,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        metadataPolicy: MetadataPolicy = .preserve,
        work: VolumeWorkGuard
    ) async throws -> JP3DEncoderResult {
        try work.check()
        try volume.validate()
        try configuration.tiling.validate()

        for component in volume.components {
            let expectedBytes = component.width * component.height * component.depth * component.bytesPerSample
            guard component.data.count >= expectedBytes else {
                throw J2KError.invalidParameter(
                    "Component \(component.index) data has \(component.data.count) bytes, expected at least \(expectedBytes)"
                )
            }
        }

        let volumeBytes = try volume.sizeInBytes
        let decomposer = JP3DTileDecomposer(configuration: configuration.tiling)
        let tiles = decomposer.decompose(volume: volume)
        let totalTiles = tiles.count

        let effectiveWorkers = configuration.parallelEncoding
            ? max(1, min(configuration.maximumWorkers, totalTiles))
            : 1
        let budget = JP3DLiveBudgetTracker(baseBytes: volumeBytes, limits: limits)

        if let limits {
            let maxTileVoxels = tiles.map { $0.width * $0.height * $0.depth }.max() ?? 1
            let maxTileSlicePixels = tiles.map { $0.width * $0.height }.max() ?? 1
            let maxTileDim = tiles.map { max($0.width, max($0.height, $0.depth)) }.max() ?? 1
            let primaryBitDepth = volume.components.first?.bitDepth ?? 8
            let compCount = volume.componentCount
            let anyJ3DIFallback = configuration.compressionMode.isLossless && tiles.contains {
                !JP3DSliceStackCodec.canEncode(tileWidth: $0.width, tileHeight: $0.height, bitDepth: primaryBitDepth)
            }

            let perWorkerBytes: Int
            let minRetainedPriorTilesBytes: Int
            if anyJ3DIFallback {
                let coeffStride = primaryBitDepth >= 29 ? 8 : 4
                let samplesBytes = maxTileVoxels * compCount * 8
                let dwtAndCoeffsBytes = (maxTileVoxels * compCount * 8) + (maxTileVoxels * 8) + (maxTileDim * 32) + 128
                let outTileBytes = 25 + maxTileVoxels * compCount * coeffStride
                perWorkerBytes = samplesBytes + dwtAndCoeffsBytes + outTileBytes
                let totalVolumeVoxels = volume.width * volume.height * volume.depth
                let retainedVoxelsBeforeLastWave = max(0, totalVolumeVoxels - effectiveWorkers * maxTileVoxels)
                minRetainedPriorTilesBytes = retainedVoxelsBeforeLastWave * compCount * 4
                let minTotalJ3DIPayload = totalVolumeVoxels * compCount * 4 + tiles.count * 25
                guard minTotalJ3DIPayload <= limits.maximumCompressedBytes else {
                    throw CodecError(
                        .resourceLimitExceeded,
                        "Volumetric J3DI minimum encoded payload (\(minTotalJ3DIPayload) B) exceeds compressed byte limit."
                    )
                }
            } else if configuration.compressionMode.isLossless {
                let samplesBytes = maxTileVoxels * compCount * 8
                let zTransformBytes = maxTileVoxels * compCount * 8
                let sliceScratchBytes = maxTileSlicePixels * 16 + 4096
                perWorkerBytes = samplesBytes + zTransformBytes + sliceScratchBytes
                minRetainedPriorTilesBytes = 0
            } else {
                let samplesBytes = maxTileVoxels * compCount * 4
                let dwtAndQuantBytes = maxTileVoxels * compCount * 8 + maxTileVoxels * 4 + 4096
                perWorkerBytes = samplesBytes + dwtAndQuantBytes
                minRetainedPriorTilesBytes = 0
            }

            let (workerPoolWorkspace, ov1) = perWorkerBytes.multipliedReportingOverflow(by: effectiveWorkers)
            let (peakTilePhaseWorkspace, ov2) = workerPoolWorkspace.addingReportingOverflow(minRetainedPriorTilesBytes)
            let (totalResident, ov3) = volumeBytes.addingReportingOverflow(peakTilePhaseWorkspace)
            guard !ov1, !ov2, !ov3,
                  peakTilePhaseWorkspace <= limits.maximumWorkspaceBytes,
                  totalResident <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric encoder simultaneous worker and tile workspace (\(peakTilePhaseWorkspace) B) exceeds operation resource limits."
                )
            }
        }

        reportProgress(.preparation, stageProgress: 1.0, tile: 0, total: totalTiles)

        let encodedTiles: [Data]
        if effectiveWorkers > 1 && tiles.count > 1 {
            encodedTiles = try await encodeTilesParallel(
                tiles: tiles,
                volume: volume,
                decomposer: decomposer,
                maximumWorkers: effectiveWorkers,
                volumeBytes: volumeBytes,
                budget: budget,
                limits: limits,
                executionPolicy: executionPolicy,
                work: work
            )
        } else {
            encodedTiles = try await encodeTilesSequential(
                tiles: tiles,
                volume: volume,
                decomposer: decomposer,
                volumeBytes: volumeBytes,
                budget: budget,
                limits: limits,
                executionPolicy: executionPolicy,
                work: work
            )
        }

        try work.check()
        let geometryToEmit: JP3DVolumeGeometry? = (metadataPolicy == .preserve && volume.hasExplicitGeometry)
            ? JP3DVolumeGeometry(
                spacingX: volume.spacingX,
                spacingY: volume.spacingY,
                spacingZ: volume.spacingZ,
                originX: volume.originX,
                originY: volume.originY,
                originZ: volume.originZ
            )
            : nil
        if geometryToEmit != nil, let limits {
            guard JP3DVolumeGeometry.payloadByteCount <= limits.maximumMetadataBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric geometry metadata (\(JP3DVolumeGeometry.payloadByteCount) bytes) exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes))."
                )
            }
        }
        let geometryMarkerBytes = geometryToEmit != nil ? (6 + JP3DVolumeGeometry.payloadByteCount) : 0
        let totalTilePayloadBytes = encodedTiles.reduce(0) { $0 + $1.count }
        let estimatedHeaderAndMarkers = 128 + geometryMarkerBytes + encodedTiles.count * 24
        let estimatedCodestreamBytes = totalTilePayloadBytes + estimatedHeaderAndMarkers
        if let limits {
            let (liveBuildBytes, ov1) = totalTilePayloadBytes.addingReportingOverflow(estimatedCodestreamBytes)
            let (totalMem, ov2) = volumeBytes.addingReportingOverflow(liveBuildBytes)
            guard !ov1, !ov2,
                  estimatedCodestreamBytes <= limits.maximumCompressedBytes,
                  liveBuildBytes <= limits.maximumWorkspaceBytes,
                  totalMem <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Encoded volumetric codestream (\(estimatedCodestreamBytes) bytes) exceeds resource limits."
                )
            }
        }
        StorageTelemetry.recordStage("volume-encode-codestream", bytes: estimatedCodestreamBytes)
        StorageTelemetry.recordWorkspaceAllocation(bytes: estimatedCodestreamBytes)

        reportProgress(.codestreamGeneration, stageProgress: 0.5, tile: totalTiles, total: totalTiles)

        let clampedTiling = decomposer.clampedConfiguration(for: volume)
        let builder = JP3DCodestreamBuilder()
        let codestream: Data
        if configuration.compressionMode.isHTJ2K {
            codestream = builder.build(
                tileData: encodedTiles,
                width: volume.width,
                height: volume.height,
                depth: volume.depth,
                components: volume.componentCount,
                bitDepth: volume.components[0].bitDepth,
                signed: volume.components[0].signed,
                levelsX: configuration.levelsX,
                levelsY: configuration.levelsY,
                levelsZ: configuration.levelsZ,
                tileSizeX: clampedTiling.tileSizeX,
                tileSizeY: clampedTiling.tileSizeY,
                tileSizeZ: clampedTiling.tileSizeZ,
                isLossless: configuration.compressionMode.isLossless,
                htj2kConfiguration: .default,
                geometry: geometryToEmit
            )
        } else {
            codestream = builder.build(
                tileData: encodedTiles,
                width: volume.width,
                height: volume.height,
                depth: volume.depth,
                components: volume.componentCount,
                bitDepth: volume.components[0].bitDepth,
                signed: volume.components[0].signed,
                levelsX: configuration.levelsX,
                levelsY: configuration.levelsY,
                levelsZ: configuration.levelsZ,
                tileSizeX: clampedTiling.tileSizeX,
                tileSizeY: clampedTiling.tileSizeY,
                tileSizeZ: clampedTiling.tileSizeZ,
                isLossless: configuration.compressionMode.isLossless,
                geometry: geometryToEmit
            )
        }

        if let limits {
            guard codestream.count <= limits.maximumCompressedBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Encoded volumetric codestream (\(codestream.count) bytes) exceeds maximumCompressedBytes (\(limits.maximumCompressedBytes))."
                )
            }
        }
        try work.check()

        reportProgress(.codestreamGeneration, stageProgress: 1.0, tile: totalTiles, total: totalTiles)

        let measuredPeakWorkspace = max(budget.peakWorkspaceBytes, totalTilePayloadBytes + codestream.count)
        return JP3DEncoderResult(
            data: codestream,
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            componentCount: volume.componentCount,
            isLossless: configuration.compressionMode.isLossless,
            tileCount: totalTiles,
            originalSize: volumeBytes,
            peakWorkspaceBytes: measuredPeakWorkspace
        )
    }

    /// Encodes a volume from raw float slices.
    public func encode(
        slices: [[Float]],
        width: Int,
        height: Int,
        bitDepth: Int = 8,
        signed: Bool = false
    ) async throws -> JP3DEncoderResult {
        guard !slices.isEmpty else {
            throw J2KError.invalidDimensions("Slices array must not be empty")
        }
        let depth = slices.count
        let expectedSliceSize = width * height
        for (i, slice) in slices.enumerated() {
            guard slice.count == expectedSliceSize else {
                throw J2KError.invalidParameter(
                    "Slice \(i) has \(slice.count) elements, expected \(expectedSliceSize)"
                )
            }
        }

        let bytesPerSample = (bitDepth + 7) / 8
        var data = Data(capacity: width * height * depth * bytesPerSample)
        for slice in slices {
            Self.serialiseFloatSamples(
                slice,
                into: &data,
                bytesPerSample: bytesPerSample,
                signed: signed,
                bitDepth: bitDepth
            )
        }

        let component = J2KVolumeComponent(
            index: 0,
            bitDepth: bitDepth,
            signed: signed,
            width: width,
            height: height,
            depth: depth,
            data: data
        )
        let volume = J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [component]
        )

        return try await encode(volume)
    }

    // MARK: - Private Tile Encoding

    private func encodeTilesSequential(
        tiles: [JP3DTile],
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer,
        volumeBytes: Int,
        budget: JP3DLiveBudgetTracker,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        work: VolumeWorkGuard
    ) async throws -> [Data] {
        var encodedTiles: [Data] = []
        encodedTiles.reserveCapacity(tiles.count)

        for (index, tile) in tiles.enumerated() {
            try work.check()
            let frac = Double(index) / Double(max(1, tiles.count))
            reportProgress(.waveletTransform, stageProgress: frac, tile: index, total: tiles.count)
            let tileOutput = try await Self.encodeTileStatic(
                tileIndex: index,
                tile: tile,
                volume: volume,
                decomposer: decomposer,
                configuration: configuration,
                budget: budget,
                limits: limits,
                executionPolicy: executionPolicy,
                work: work
            )
            do {
                try work.check()
            } catch {
                tileOutput.reservation.release()
                throw error
            }
            tileOutput.reservation.promoteToRetained(stage: "jp3d-retained-tile")
            StorageTelemetry.recordStage("volume-encode-tile", bytes: tileOutput.data.count)
            reportProgress(.entropyCoding, stageProgress: frac, tile: index + 1, total: tiles.count)
            encodedTiles.append(tileOutput.data)
        }

        return encodedTiles
    }

    private func encodeTilesParallel(
        tiles: [JP3DTile],
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer,
        maximumWorkers: Int,
        volumeBytes: Int,
        budget: JP3DLiveBudgetTracker,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        work: VolumeWorkGuard
    ) async throws -> [Data] {
        let config = configuration
        let workerCap = max(1, min(maximumWorkers, tiles.count))
        return try await withThrowingTaskGroup(of: (Int, JP3DEncodedTileOutput).self) { group in
            var nextIndex = 0
            while nextIndex < workerCap {
                try work.check()
                let idx = nextIndex
                let tile = tiles[idx]
                nextIndex += 1
                group.addTask {
                    defer { VolumeConcurrencyTelemetry.recorder?.recordChildTaskReturned(tileIndex: idx) }
                    let output = try await Self.encodeTileStatic(
                        tileIndex: idx,
                        tile: tile,
                        volume: volume,
                        decomposer: decomposer,
                        configuration: config,
                        budget: budget,
                        limits: limits,
                        executionPolicy: executionPolicy,
                        work: work
                    )
                    return (idx, output)
                }
            }

            var results = [(Int, Data)]()
            results.reserveCapacity(tiles.count)
            var consumeStep = 0

            while consumeStep < tiles.count {
                try await VolumeConcurrencyTelemetry.recorder?.beforeParentConsume(step: consumeStep)
                guard let (idx, tileOutput) = try await group.next() else {
                    break
                }
                consumeStep += 1
                do {
                    try work.check()
                } catch {
                    tileOutput.reservation.release()
                    group.cancelAll()
                    throw error
                }
                tileOutput.reservation.promoteToRetained(stage: "jp3d-retained-tile")
                StorageTelemetry.recordStage("volume-encode-tile", bytes: tileOutput.data.count)
                results.append((idx, tileOutput.data))
                let done = results.count
                reportProgress(
                    .entropyCoding,
                    stageProgress: Double(done) / Double(max(1, tiles.count)),
                    tile: done,
                    total: tiles.count
                )

                if nextIndex < tiles.count {
                    let spawnIdx = nextIndex
                    let tile = tiles[spawnIdx]
                    nextIndex += 1
                    group.addTask {
                        defer { VolumeConcurrencyTelemetry.recorder?.recordChildTaskReturned(tileIndex: spawnIdx) }
                        let output = try await Self.encodeTileStatic(
                            tileIndex: spawnIdx,
                            tile: tile,
                            volume: volume,
                            decomposer: decomposer,
                            configuration: config,
                            budget: budget,
                            limits: limits,
                            executionPolicy: executionPolicy,
                            work: work
                        )
                        return (spawnIdx, output)
                    }
                }
            }

            results.sort { $0.0 < $1.0 }
            return results.map(\.1)
        }
    }

    private static func encodeTileStatic(
        tileIndex: Int,
        tile: JP3DTile,
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer,
        configuration: JP3DEncoderConfiguration,
        budget: JP3DLiveBudgetTracker,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        work: VolumeWorkGuard
    ) async throws -> JP3DEncodedTileOutput {
        try work.check()
        try await VolumeConcurrencyTelemetry.recorder?.enter(tileIndex: tileIndex)
        defer { VolumeConcurrencyTelemetry.recorder?.exit(tileIndex: tileIndex) }

        let primaryComp = volume.components[0]
        let effectiveLimits = limits ?? .default
        let tileVoxels = tile.width * tile.height * tile.depth

        // Exact integer-preserving lossless path for 1...38-bit signed and unsigned voxels (F02).
        if configuration.compressionMode.isLossless {
            let extractedBytes = tileVoxels * volume.componentCount * MemoryLayout<Int64>.stride
            let extractLease = try budget.reserveTransient(
                extractedBytes,
                stage: "jp3d-worker-tile-samples",
                message: "Volumetric worker tile sample buffer exceeds operation resource limits."
            )
            defer { extractLease.release() }

            var intCompSamples: [[Int64]] = []
            intCompSamples.reserveCapacity(volume.componentCount)
            for comp in 0..<volume.componentCount {
                try work.check()
                let extracted = try decomposer.extractIntegerTileData(
                    from: volume,
                    tile: tile,
                    componentIndex: comp
                )
                intCompSamples.append(extracted)
            }

            if JP3DSliceStackCodec.canEncode(
                tileWidth: tile.width,
                tileHeight: tile.height,
                bitDepth: primaryComp.bitDepth
            ) {
                let sliceWorkspace = tileVoxels * volume.componentCount * MemoryLayout<Int64>.stride + tile.width * tile.height * 16 + 4096
                let sliceLease = try budget.reserveTransient(
                    sliceWorkspace,
                    stage: "jp3d-worker-slice-workspace",
                    message: "Volumetric worker slice-stack workspace exceeds operation resource limits."
                )
                defer { sliceLease.release() }

                let sliceCodec = JP3DSliceStackCodec()
                do {
                    return try sliceCodec.encodeTileInteger(
                        componentSamples: intCompSamples,
                        tileWidth: tile.width,
                        tileHeight: tile.height,
                        tileDepth: tile.depth,
                        bitDepth: primaryComp.bitDepth,
                        signed: primaryComp.signed,
                        levelsX: configuration.levelsX,
                        levelsY: configuration.levelsY,
                        levelsZ: configuration.levelsZ,
                        compressionMode: configuration.compressionMode,
                        qualityLayers: configuration.qualityLayers,
                        zDeltaPolicy: configuration.zDeltaMode,
                        budget: budget,
                        limits: effectiveLimits,
                        executionPolicy: executionPolicy
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CodecError where error.category == .resourceLimitExceeded || error.category == .backendUnavailable {
                    throw error
                } catch {
                    // Fall through to exact 3D integer wavelet tile codec if 2D slice bridge rejects layout.
                }
            }

            return try JP3DLosslessIntegerTileCodec.encodeTile(
                componentSamples: intCompSamples,
                tileWidth: tile.width,
                tileHeight: tile.height,
                tileDepth: tile.depth,
                bitDepth: primaryComp.bitDepth,
                signed: primaryComp.signed,
                levelsX: configuration.levelsX,
                levelsY: configuration.levelsY,
                levelsZ: configuration.levelsZ,
                isHTJ2K: configuration.compressionMode.isHTJ2K,
                budget: budget,
                work: work
            )
        }

        let floatSamplesBytes = tileVoxels * volume.componentCount * MemoryLayout<Float>.stride
        let floatExtractLease = try budget.reserveTransient(
            floatSamplesBytes,
            stage: "jp3d-worker-float-samples",
            message: "Volumetric lossy worker sample buffer exceeds operation resource limits."
        )
        defer { floatExtractLease.release() }

        if JP3DSliceStackCodec.canEncode(
            tileWidth: tile.width,
            tileHeight: tile.height,
            bitDepth: primaryComp.bitDepth
        ) {
            let lossySliceWorkspace = tileVoxels * volume.componentCount * MemoryLayout<Int32>.stride + tile.width * tile.height * 16 + 4096
            let lossySliceLease = try budget.reserveTransient(
                lossySliceWorkspace,
                stage: "jp3d-worker-lossy-slice-workspace",
                message: "Volumetric lossy slice-stack workspace exceeds operation resource limits."
            )
            defer { lossySliceLease.release() }

            var compSamples: [[Float]] = []
            compSamples.reserveCapacity(volume.componentCount)
            for comp in 0..<volume.componentCount {
                try work.check()
                let extracted = try decomposer.extractTileData(
                    from: volume, tile: tile, componentIndex: comp
                )
                compSamples.append(extracted.data)
            }
            let sliceCodec = JP3DSliceStackCodec()
            do {
                return try sliceCodec.encodeTile(
                    componentSamples: compSamples,
                    tileWidth: tile.width,
                    tileHeight: tile.height,
                    tileDepth: tile.depth,
                    bitDepth: primaryComp.bitDepth,
                    signed: primaryComp.signed,
                    levelsX: configuration.levelsX,
                    levelsY: configuration.levelsY,
                    levelsZ: configuration.levelsZ,
                    compressionMode: configuration.compressionMode,
                    qualityLayers: configuration.qualityLayers,
                    zDeltaPolicy: configuration.zDeltaMode,
                    budget: budget,
                    limits: effectiveLimits,
                    executionPolicy: executionPolicy
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodecError where error.category == .resourceLimitExceeded || error.category == .backendUnavailable {
                throw error
            } catch {
                // Fall through to 3D wavelet + rate-control path.
            }
        }

        let lossyDwtWorkspace = tileVoxels * MemoryLayout<Double>.stride + tileVoxels * MemoryLayout<Int32>.stride + 4096
        let lossyDwtLease = try budget.reserveTransient(
            lossyDwtWorkspace,
            stage: "jp3d-lossy-dwt-workspace",
            message: "Volumetric lossy 3D wavelet workspace exceeds operation resource limits."
        )
        defer { lossyDwtLease.release() }

        let rateController = JP3DRateController(
            mode: configuration.compressionMode,
            qualityLayers: configuration.qualityLayers
        )
        let transformConfig = configuration.transformConfiguration
        let wavelet = JP3DWaveletTransform(configuration: transformConfig)

        let outReservation = try budget.makeOutputReservation(
            initialBytes: 0,
            checkCompressedLimit: true,
            stage: "jp3d-lossy-tile-output",
            message: "Volumetric lossy encoded tile payload exceeds operation resource limits."
        )
        var tileBytes = Data()

        do {
            for comp in 0..<volume.componentCount {
                try work.check()
                let extracted = try decomposer.extractTileData(
                    from: volume, tile: tile, componentIndex: comp
                )

                let decomposition = try await wavelet.forward(
                    data: extracted.data,
                    width: tile.width,
                    height: tile.height,
                    depth: tile.depth
                )

                let maxLevel = max(
                    decomposition.levelsX,
                    max(decomposition.levelsY, decomposition.levelsZ)
                )
                let quantized = rateController.quantize(
                    coefficients: decomposition.coefficients.data,
                    tile: tile,
                    componentIndex: comp,
                    bitDepth: volume.components[comp].bitDepth,
                    decompositionLevels: maxLevel
                )

                let compPayloadBytes = 4 + max(0, quantized.coefficients.count) * 4
                let oldCount = tileBytes.count
                try outReservation.withGrowth(
                    by: compPayloadBytes,
                    extraTransientBytes: oldCount,
                    checkCompressedLimit: true,
                    stage: "jp3d-lossy-tile-output",
                    message: "Volumetric lossy encoded tile payload exceeds operation resource limits."
                ) {
                    var grown = Data(capacity: oldCount + compPayloadBytes)
                    if oldCount > 0 {
                        grown.append(tileBytes)
                    }
                    Self.appendEncodedQuantizedCoefficients(quantized, into: &grown)
                    tileBytes = grown
                }
            }
        } catch {
            outReservation.release()
            throw error
        }

        return JP3DEncodedTileOutput(data: tileBytes, reservation: outReservation)
    }

    private static func appendEncodedQuantizedCoefficients(_ quantized: JP3DQuantizedTile, into output: inout Data) {
        let coeffs = quantized.coefficients
        let count = coeffs.count
        let startOffset = output.count
        guard count > 0 else {
            output.count = startOffset + 4
            return
        }

        var maxMag: UInt32 = 0
        for c in coeffs {
            let mag = c < 0 ? UInt32(bitPattern: -c) : UInt32(bitPattern: c)
            if mag > maxMag { maxMag = mag }
        }

        var activeBitPlanes: UInt8 = 0
        var temp = maxMag
        while temp > 0 {
            activeBitPlanes += 1
            temp >>= 1
        }
        let zeroBitPlanes = 31 - activeBitPlanes

        var nonZeroCount: UInt16 = 0
        for c in coeffs where c != 0 {
            nonZeroCount = nonZeroCount &+ 1
        }

        output.count = startOffset + 4 + count * 4
        output.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            base[startOffset] = zeroBitPlanes
            base[startOffset + 1] = activeBitPlanes
            base[startOffset + 2] = UInt8(truncatingIfNeeded: nonZeroCount >> 8)
            base[startOffset + 3] = UInt8(truncatingIfNeeded: nonZeroCount)
            var bytePos = startOffset + 4
            for i in 0..<count {
                let u = UInt32(bitPattern: coeffs[i])
                base[bytePos] = UInt8(truncatingIfNeeded: u >> 24)
                base[bytePos + 1] = UInt8(truncatingIfNeeded: u >> 16)
                base[bytePos + 2] = UInt8(truncatingIfNeeded: u >> 8)
                base[bytePos + 3] = UInt8(truncatingIfNeeded: u)
                bytePos += 4
            }
        }
    }

    internal static func serialiseFloatSamples(
        _ samples: [Float],
        into data: inout Data,
        bytesPerSample: Int,
        signed: Bool = false,
        bitDepth: Int = 16
    ) {
        let count = samples.count
        guard count > 0, bytesPerSample > 0 else { return }
        let startOffset = data.count
        data.append(Data(count: count * bytesPerSample))
        let safeBits = max(1, min(38, bitDepth))
        let minVal: Int64 = signed ? -(Int64(1) << (safeBits - 1)) : 0
        let maxVal: Int64 = signed ? ((Int64(1) << (safeBits - 1)) - 1) : ((Int64(1) << safeBits) - 1)

        data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let dst = base + startOffset
            for i in 0..<count {
                let dVal = Double(samples[i]).rounded()
                let clamped: Int64
                if !dVal.isFinite {
                    clamped = 0
                } else if dVal <= Double(minVal) {
                    clamped = minVal
                } else if dVal >= Double(maxVal) {
                    clamped = maxVal
                } else {
                    clamped = Int64(dVal)
                }
                let raw = UInt64(bitPattern: clamped)
                for b in 0..<bytesPerSample {
                    dst[i * bytesPerSample + b] = UInt8(truncatingIfNeeded: raw >> (b * 8))
                }
            }
        }
    }

    private func reportProgress(
        _ stage: JP3DEncodingStage,
        stageProgress: Double,
        tile: Int,
        total: Int
    ) {
        let baseWeight: Double
        let spanWeight: Double
        switch stage {
        case .preparation, .tiling:
            baseWeight = 0.0; spanWeight = 0.05
        case .waveletTransform:
            baseWeight = 0.05; spanWeight = 0.40
        case .quantization, .entropyCoding:
            baseWeight = 0.05; spanWeight = 0.85
        case .codestreamGeneration, .packetFormation:
            baseWeight = 0.90; spanWeight = 0.10
        case .complete:
            baseWeight = 1.0; spanWeight = 0.0
        }
        let overall = min(1.0, baseWeight + spanWeight * stageProgress)
        let progress = JP3DEncoderProgress(
            stage: stage,
            stageProgress: stageProgress,
            overallProgress: overall,
            currentTile: tile,
            totalTiles: total
        )
        progressCallback?(progress)
    }
}
