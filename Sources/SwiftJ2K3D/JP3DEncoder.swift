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
//   - Implemented full normative ITU-T T.809 (05/2011) | ISO/IEC 15444-10 volumetric tile
//     encoding (separable 3D 5-3 reversible Int64 DWT for 1...38-bit lossless + 3D 9-7
//     irreversible DWT with dead-zone scalar quantisation, Annex C 3D EBCOT Tier-1 coding,
//     3D octree tag-trees, and 3D Tier-2 packet formation across all 5 progression orders)
//     and reconciled ITU-T T.814 HTJ2K-in-JP3D (zcb = 0 planar HT code-blocks), eliminating
//     all private "J3DS"/"J3DI" framing and raw Int32 dumps from normative encoder output.

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

    /// Z-axis predictive coding policy (retained for public API compatibility; normative Part 10 uses 3D DWT along Z).
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

    /// Streaming-optimised configuration with smaller tiles and RPCL progression.
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
    /// 3D Tier-1 EBCOT / Part 15 HTJ2K block entropy coding.
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

    /// Whether an accelerated SIMD/hardware kernel executed on the hot path.
    package let usedAcceleratedKernel: Bool

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
        self.usedAcceleratedKernel = false
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
        peakWorkspaceBytes: Int,
        usedAcceleratedKernel: Bool = false
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
        self.usedAcceleratedKernel = usedAcceleratedKernel
    }
}

// MARK: - Encoder Actor

/// Actor for encoding `J2KVolume` datasets into normative ITU-T T.809 | ISO/IEC 15444-10 (JP3D) codestreams.
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

    /// Encodes a `J2KVolume` into a normative JP3D codestream.
    public func encode(_ volume: J2KVolume) async throws -> JP3DEncoderResult {
        try await encodeAdmitted(
            volume,
            limits: nil,
            executionPolicy: .automatic,
            work: VolumeWorkGuard(limits: nil)
        )
    }

    package static func makeNormativeCodingParameters(
        configuration: JP3DEncoderConfiguration,
        componentBitDepths: [Int],
        componentSigned: [Bool] = [],
        componentCount: Int,
        forceDisableMCT: Bool = false
    ) -> (
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        htConfig: JP3DHTJ2KConfiguration?,
        targetBitrateBPP: Double?
    ) {
        let isLossless = configuration.compressionMode.isLossless
        let isHT = configuration.compressionMode.isHTJ2K
        let maxBitDepth = componentBitDepths.max() ?? 8
        let needsMixedHT = isHT && maxBitDepth > 26
        let htConfig: JP3DHTJ2KConfiguration? = isHT
            ? JP3DHTJ2KConfiguration(
                blockMode: .ht,
                passCount: configuration.qualityLayers >= 2 ? 4 : 1,
                cleanupPassEnabled: true,
                allowMixedTiles: needsMixedHT
            )
            : nil

        let cbStyle: UInt8
        let xcb: Int
        let ycb: Int
        let zcb: Int
        if isHT {
            cbStyle = needsMixedHT ? 0xC0 : 0x40
            xcb = 6
            ycb = 6
            zcb = 0
        } else {
            cbStyle = 0x00
            xcb = 5
            ycb = 5
            zcb = 4 // 32 x 32 x 16 volumetric 3D code-blocks (sum = 14 <= 18)
        }
        let homogeneousRGB = !forceDisableMCT
            && componentCount >= 3
            && componentBitDepths.count >= 3
            && componentBitDepths[0] == componentBitDepths[1]
            && componentBitDepths[0] == componentBitDepths[2]
            && (componentSigned.count < 3 || (componentSigned[0] == componentSigned[1] && componentSigned[0] == componentSigned[2]))
        let mctByte: UInt8 = homogeneousRGB ? 1 : 0
        let dwtByte: UInt8 = isLossless ? 1 : 0
        let cod = JP3DCODInfo(
            levelsX: configuration.levelsX,
            levelsY: configuration.levelsY,
            levelsZ: configuration.levelsZ,
            isLossless: isLossless,
            codeBlockStyle: cbStyle,
            scod: 0,
            progressionOrderByte: JP3DTier2Coder.progressionCode(for: configuration.progressionOrder),
            numLayers: max(1, configuration.qualityLayers),
            multipleComponentTransform: mctByte,
            codeBlockWidthExponent: xcb,
            codeBlockHeightExponent: ycb,
            codeBlockDepthExponent: zcb,
            dwtX: dwtByte,
            dwtY: dwtByte,
            dwtZ: dwtByte,
            precinctSizes: []
        )
        let qcd: JP3DQuantizationParameters
        if isLossless {
            qcd = .makeReversible(
                maxBitDepth: maxBitDepth,
                levelsX: configuration.levelsX,
                levelsY: configuration.levelsY,
                levelsZ: configuration.levelsZ,
                usesReversibleMCT: cod.multipleComponentTransform == 1 && componentCount >= 3
            )
        } else {
            let scale = JP3DQuantizationParameters.baseStepScale(
                for: configuration.compressionMode,
                bitDepth: maxBitDepth
            )
            qcd = .makeIrreversible(
                maxBitDepth: maxBitDepth,
                levelsX: configuration.levelsX,
                levelsY: configuration.levelsY,
                levelsZ: configuration.levelsZ,
                baseStepScale: scale
            )
        }
        let targetBPP: Double?
        if case .targetBitrate(let bpp) = configuration.compressionMode {
            targetBPP = Double(bpp)
        } else {
            targetBPP = nil
        }
        return (cod, qcd, htConfig, targetBPP)
    }

    internal func encodeAdmitted(
        _ volume: J2KVolume,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        metadataPolicy: MetadataPolicy = .preserve,
        work: VolumeWorkGuard
    ) async throws -> JP3DEncoderResult {
        let resolvedExec = try AccelerationRuntime.resolve(executionPolicy)
        let useAccelerated = (resolvedExec.backend == .accelerated)
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

        let logicalBitDepths = volume.components.map(\.bitDepth)
        let logicalSigned = volume.components.map(\.signed)
        let maxLogicalBitDepth = logicalBitDepths.max() ?? 8

        func checkWorkerPoolPreflight(wireComponents: Int, codForPreflight: JP3DCODInfo) throws {
            guard let limits else { return }
            let maxTileVoxels = tiles.map { $0.width * $0.height * $0.depth }.max() ?? 1
            let maxTileDim = tiles.map { max($0.width, max($0.height, $0.depth)) }.max() ?? 1
            var maxGeomPerComp = 0
            for tile in tiles {
                let fp = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: tile.region.x.lowerBound, x1: tile.region.x.upperBound,
                    y0: tile.region.y.lowerBound, y1: tile.region.y.upperBound,
                    z0: tile.region.z.lowerBound, z1: tile.region.z.upperBound,
                    cod: codForPreflight,
                    maximumWorkspaceBytes: nil,
                    includeEncodeState: true
                )
                if fp.totalBytes > maxGeomPerComp {
                    maxGeomPerComp = fp.totalBytes
                }
            }
            let (allCompGeom, gOv) = maxGeomPerComp.multipliedReportingOverflow(by: wireComponents)
            guard !gOv else {
                throw CodecError(.resourceLimitExceeded, "Volumetric encoder 3D geometry workspace overflows Int.")
            }
            let samplesBytes = maxTileVoxels * wireComponents * MemoryLayout<Int64>.stride
            let dwtWorkspaceBytes = (maxTileVoxels * wireComponents * MemoryLayout<Int64>.stride)
                + (maxTileVoxels * MemoryLayout<Int64>.stride)
                + (maxTileDim * 32)
                + 128
            let (basePerWorker, pOv0) = (samplesBytes + dwtWorkspaceBytes).addingReportingOverflow(allCompGeom)
            let (workerPoolWorkspace, ov1) = basePerWorker.multipliedReportingOverflow(by: effectiveWorkers)
            let (totalResident, ov2) = volumeBytes.addingReportingOverflow(workerPoolWorkspace)
            guard !pOv0, !ov1, !ov2,
                  workerPoolWorkspace <= limits.maximumWorkspaceBytes,
                  totalResident <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric encoder simultaneous worker and tile workspace (\(workerPoolWorkspace) B) exceeds operation resource limits."
                )
            }
        }

        var wireComponentCount = volume.componentCount
        var wireBitDepths = logicalBitDepths
        var wireSigned = logicalSigned
        var part2Descriptor: JP3DPart2BitSplitDescriptor? = nil
        var activeParams = Self.makeNormativeCodingParameters(
            configuration: configuration,
            componentBitDepths: wireBitDepths,
            componentSigned: wireSigned,
            componentCount: wireComponentCount
        )
        try checkWorkerPoolPreflight(wireComponents: wireComponentCount, codForPreflight: activeParams.cod)

        var activeBudget = JP3DLiveBudgetTracker(baseBytes: volumeBytes, limits: limits)

        reportProgress(.preparation, stageProgress: 1.0, tile: 0, total: totalTiles)

        func runTilePass(
            params: (cod: JP3DCODInfo, qcd: JP3DQuantizationParameters, htConfig: JP3DHTJ2KConfiguration?, targetBitrateBPP: Double?),
            bitDepths: [Int],
            signedFlags: [Bool],
            useBitSplit: Bool,
            budgetTracker: JP3DLiveBudgetTracker
        ) async throws -> (tiles: [Data], usedAccelerated: Bool) {
            if effectiveWorkers > 1 && tiles.count > 1 {
                return try await encodeTilesParallel(
                    tiles: tiles,
                    volume: volume,
                    decomposer: decomposer,
                    maximumWorkers: effectiveWorkers,
                    cod: params.cod,
                    qcd: params.qcd,
                    htConfig: params.htConfig,
                    targetBitrateBPP: params.targetBitrateBPP,
                    componentBitDepths: bitDepths,
                    componentSigned: signedFlags,
                    usePart2BitSplit: useBitSplit,
                    useAccelerated: useAccelerated,
                    budget: budgetTracker,
                    work: work
                )
            } else {
                return try await encodeTilesSequential(
                    tiles: tiles,
                    volume: volume,
                    decomposer: decomposer,
                    cod: params.cod,
                    qcd: params.qcd,
                    htConfig: params.htConfig,
                    targetBitrateBPP: params.targetBitrateBPP,
                    componentBitDepths: bitDepths,
                    componentSigned: signedFlags,
                    usePart2BitSplit: useBitSplit,
                    useAccelerated: useAccelerated,
                    budget: budgetTracker,
                    work: work
                )
            }
        }

        let encodedTiles: [Data]
        let usedAcceleratedKernel: Bool
        do {
            let passOut = try await runTilePass(
                params: activeParams,
                bitDepths: wireBitDepths,
                signedFlags: wireSigned,
                useBitSplit: false,
                budgetTracker: activeBudget
            )
            encodedTiles = passOut.tiles
            usedAcceleratedKernel = passOut.usedAccelerated
        } catch let error as CodecError
            where configuration.compressionMode.isLossless
                && maxLogicalBitDepth >= 34
                && error.category == .invalidArgument
                && error.message.contains("exceeding band Mb=") {
            // Wire Part 10 QCD/QCC caps G <= 7, eps <= 31 -> Mb <= 37 (|coeff| < 2^37).
            // When a 34...38-bit lossless volume produces wavelet coefficients with |coeff| >= 2^37,
            // fall back normatively to Part 2 component bit-split using signed wire limbs
            // (lo: 20-bit signed holding [0, 2^19 - 1], hi: signed holding v >> 19, zero Part 1 DC shift)
            // signalled via Pcap^2 + CBD + MCT + MCC + MCO markers (ITU-T T.801 Annex I/J, Tmcc = 0x000001).
            let descriptor = try JP3DPart2BitSplitDescriptor.buildMarkerSegments(
                logicalBitDepths: logicalBitDepths,
                logicalSigned: logicalSigned
            )
            part2Descriptor = descriptor
            wireComponentCount = volume.componentCount * 2
            wireBitDepths = []
            wireSigned = []
            let lowSplitBits = JP3DPart2BitSplitDescriptor.defaultSplitLowBits
            for idx in 0..<volume.componentCount {
                // Low limb `lo in [0, 2^19 - 1]` requires 20-bit signed (`[-2^19, 2^19 - 1]`) so zero DC shift applies.
                wireBitDepths.append(lowSplitBits + 1)
                let hiBits = logicalSigned[idx]
                    ? max(2, logicalBitDepths[idx] - lowSplitBits)
                    : max(2, logicalBitDepths[idx] - lowSplitBits + 1)
                wireBitDepths.append(hiBits)
                wireSigned.append(true)
                wireSigned.append(true)
            }
            activeParams = Self.makeNormativeCodingParameters(
                configuration: configuration,
                componentBitDepths: wireBitDepths,
                componentSigned: wireSigned,
                componentCount: wireComponentCount,
                forceDisableMCT: true
            )
            try checkWorkerPoolPreflight(wireComponents: wireComponentCount, codForPreflight: activeParams.cod)
            activeBudget = JP3DLiveBudgetTracker(baseBytes: volumeBytes, limits: limits)
            let splitPass = try await runTilePass(
                params: activeParams,
                bitDepths: wireBitDepths,
                signedFlags: wireSigned,
                useBitSplit: true,
                budgetTracker: activeBudget
            )
            encodedTiles = splitPass.tiles
            usedAcceleratedKernel = splitPass.usedAccelerated
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
        var commentsToEmit: [JP3DCommentSegment] = []
        if let geometryToEmit, geometryToEmit.hasNonDefaultValues {
            if let limits {
                guard JP3DVolumeGeometry.payloadByteCount <= limits.maximumMetadataBytes else {
                    throw CodecError(
                        .resourceLimitExceeded,
                        "Volumetric geometry metadata (\(JP3DVolumeGeometry.payloadByteCount) bytes) exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes))."
                    )
                }
            }
            let geomPayload = try geometryToEmit.encodePayload()
            commentsToEmit.append(JP3DCommentSegment(registration: 0, payload: geomPayload))
        }

        let clampedTiling = decomposer.clampedConfiguration(for: volume)
        let builder = JP3DCodestreamBuilder()
        let exactCodestreamBytes = try builder.projectedByteCount(
            tileData: encodedTiles,
            components: wireComponentCount,
            levelsX: activeParams.cod.levelsX,
            levelsY: activeParams.cod.levelsY,
            levelsZ: activeParams.cod.levelsZ,
            isLossless: activeParams.cod.isLossless,
            includesHTMarkers: activeParams.htConfig != nil,
            comments: commentsToEmit,
            codOverride: activeParams.cod,
            qcdOverride: activeParams.qcd,
            part2BitSplit: part2Descriptor
        )
        let totalTilePayloadBytes = encodedTiles.reduce(0) { $0 + $1.count }
        if let limits {
            let (liveBuildBytes, ov1) = totalTilePayloadBytes.addingReportingOverflow(exactCodestreamBytes)
            let (totalMem, ov2) = volumeBytes.addingReportingOverflow(liveBuildBytes)
            guard !ov1, !ov2,
                  exactCodestreamBytes <= limits.maximumCompressedBytes,
                  liveBuildBytes <= limits.maximumWorkspaceBytes,
                  totalMem <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Encoded volumetric codestream (\(exactCodestreamBytes) bytes) exceeds resource limits."
                )
            }
        }
        StorageTelemetry.recordStage("volume-encode-codestream", bytes: exactCodestreamBytes)
        StorageTelemetry.recordWorkspaceAllocation(bytes: exactCodestreamBytes)

        reportProgress(.codestreamGeneration, stageProgress: 0.5, tile: totalTiles, total: totalTiles)

        let codestream = builder.buildPreallocated(
            tileData: encodedTiles,
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            components: wireComponentCount,
            bitDepth: wireBitDepths[0],
            signed: wireSigned[0],
            levelsX: activeParams.cod.levelsX,
            levelsY: activeParams.cod.levelsY,
            levelsZ: activeParams.cod.levelsZ,
            tileSizeX: clampedTiling.tileSizeX,
            tileSizeY: clampedTiling.tileSizeY,
            tileSizeZ: clampedTiling.tileSizeZ,
            isLossless: activeParams.cod.isLossless,
            geometry: nil,
            comments: commentsToEmit,
            htj2kConfiguration: activeParams.htConfig,
            capacity: exactCodestreamBytes,
            componentBitDepths: wireBitDepths,
            componentSigned: wireSigned,
            codOverride: activeParams.cod,
            qcdOverride: activeParams.qcd,
            part2BitSplit: part2Descriptor
        )

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

        let measuredPeakWorkspace = max(activeBudget.peakWorkspaceBytes, totalTilePayloadBytes + codestream.count)
        return JP3DEncoderResult(
            data: codestream,
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            componentCount: volume.componentCount,
            isLossless: configuration.compressionMode.isLossless,
            tileCount: totalTiles,
            originalSize: volumeBytes,
            peakWorkspaceBytes: measuredPeakWorkspace,
            usedAcceleratedKernel: usedAcceleratedKernel
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
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        htConfig: JP3DHTJ2KConfiguration?,
        targetBitrateBPP: Double?,
        componentBitDepths: [Int],
        componentSigned: [Bool],
        usePart2BitSplit: Bool,
        useAccelerated: Bool,
        budget: JP3DLiveBudgetTracker,
        work: VolumeWorkGuard
    ) async throws -> (tiles: [Data], usedAccelerated: Bool) {
        var encodedTiles: [Data] = []
        encodedTiles.reserveCapacity(tiles.count)
        var anyAccel = false

        for (index, tile) in tiles.enumerated() {
            try work.check()
            let frac = Double(index) / Double(max(1, tiles.count))
            reportProgress(.waveletTransform, stageProgress: frac, tile: index, total: tiles.count)
            let tileOutput = try await Self.encodeTileStatic(
                tileIndex: index,
                tile: tile,
                volume: volume,
                decomposer: decomposer,
                cod: cod,
                qcd: qcd,
                htConfig: htConfig,
                targetBitrateBPP: targetBitrateBPP,
                componentBitDepths: componentBitDepths,
                componentSigned: componentSigned,
                usePart2BitSplit: usePart2BitSplit,
                useAccelerated: useAccelerated,
                budget: budget,
                work: work
            )
            do {
                try work.check()
            } catch {
                tileOutput.reservation.release()
                throw error
            }
            if tileOutput.usedAccelerated { anyAccel = true }
            tileOutput.reservation.promoteToRetained(stage: "jp3d-retained-tile")
            StorageTelemetry.recordStage("volume-encode-tile", bytes: tileOutput.data.count)
            reportProgress(.entropyCoding, stageProgress: frac, tile: index + 1, total: tiles.count)
            encodedTiles.append(tileOutput.data)
        }

        return (encodedTiles, anyAccel)
    }

    private func encodeTilesParallel(
        tiles: [JP3DTile],
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer,
        maximumWorkers: Int,
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        htConfig: JP3DHTJ2KConfiguration?,
        targetBitrateBPP: Double?,
        componentBitDepths: [Int],
        componentSigned: [Bool],
        usePart2BitSplit: Bool,
        useAccelerated: Bool,
        budget: JP3DLiveBudgetTracker,
        work: VolumeWorkGuard
    ) async throws -> (tiles: [Data], usedAccelerated: Bool) {
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
                        cod: cod,
                        qcd: qcd,
                        htConfig: htConfig,
                        targetBitrateBPP: targetBitrateBPP,
                        componentBitDepths: componentBitDepths,
                        componentSigned: componentSigned,
                        usePart2BitSplit: usePart2BitSplit,
                        useAccelerated: useAccelerated,
                        budget: budget,
                        work: work
                    )
                    return (idx, output)
                }
            }

            var results = [(Int, Data)]()
            results.reserveCapacity(tiles.count)
            var anyAccel = false
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
                if tileOutput.usedAccelerated { anyAccel = true }
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
                            cod: cod,
                            qcd: qcd,
                            htConfig: htConfig,
                            targetBitrateBPP: targetBitrateBPP,
                            componentBitDepths: componentBitDepths,
                            componentSigned: componentSigned,
                            usePart2BitSplit: usePart2BitSplit,
                            useAccelerated: useAccelerated,
                            budget: budget,
                            work: work
                        )
                        return (spawnIdx, output)
                    }
                }
            }

            results.sort { $0.0 < $1.0 }
            return (results.map(\.1), anyAccel)
        }
    }

    private static func encodeTileStatic(
        tileIndex: Int,
        tile: JP3DTile,
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer,
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        htConfig: JP3DHTJ2KConfiguration?,
        targetBitrateBPP: Double?,
        componentBitDepths: [Int],
        componentSigned: [Bool],
        usePart2BitSplit: Bool,
        useAccelerated: Bool,
        budget: JP3DLiveBudgetTracker,
        work: VolumeWorkGuard
    ) async throws -> JP3DEncodedTileOutput {
        try work.check()
        try await VolumeConcurrencyTelemetry.recorder?.enter(tileIndex: tileIndex)
        defer { VolumeConcurrencyTelemetry.recorder?.exit(tileIndex: tileIndex) }

        let wireCompCount = componentBitDepths.count
        let geomFootprint = try JP3DGeometryBuilder.preflightTileComponentGeometry(
            x0: tile.region.x.lowerBound, x1: tile.region.x.upperBound,
            y0: tile.region.y.lowerBound, y1: tile.region.y.upperBound,
            z0: tile.region.z.lowerBound, z1: tile.region.z.upperBound,
            cod: cod,
            maximumWorkspaceBytes: nil,
            includeEncodeState: true
        )
        let (allCompGeomBytes, gOv) = geomFootprint.totalBytes.multipliedReportingOverflow(by: wireCompCount)
        guard !gOv else {
            throw CodecError(.resourceLimitExceeded, "Volumetric worker 3D geometry workspace overflows Int.")
        }

        let tileVoxels = tile.width * tile.height * tile.depth
        let maxTileDim = max(tile.width, max(tile.height, tile.depth))
        let samplesBytes = tileVoxels * wireCompCount * MemoryLayout<Int64>.stride
        let dwtWorkspaceBytes = (tileVoxels * wireCompCount * MemoryLayout<Int64>.stride)
            + (tileVoxels * MemoryLayout<Int64>.stride)
            + (maxTileDim * 32)
            + 128
        let (workerWorkspaceBytes, wOv) = (samplesBytes + dwtWorkspaceBytes).addingReportingOverflow(allCompGeomBytes)
        guard !wOv else {
            throw CodecError(.resourceLimitExceeded, "Volumetric worker workspace overflows Int.")
        }
        let workerLease = try budget.reserveTransient(
            workerWorkspaceBytes,
            stage: "jp3d-worker-normative-workspace",
            message: "Volumetric worker 3D DWT and Tier-1/Tier-2 workspace exceeds operation resource limits."
        )
        defer { workerLease.release() }

        var intCompSamples: [[Int64]] = []
        intCompSamples.reserveCapacity(wireCompCount)
        let lowMask: Int64 = (Int64(1) << JP3DPart2BitSplitDescriptor.defaultSplitLowBits) - 1
        let shiftBits = JP3DPart2BitSplitDescriptor.defaultSplitLowBits
        for comp in 0..<volume.componentCount {
            try work.check()
            let extracted = try decomposer.extractIntegerTileData(
                from: volume,
                tile: tile,
                componentIndex: comp
            )
            if usePart2BitSplit {
                var loPlane = [Int64](repeating: 0, count: extracted.count)
                var hiPlane = [Int64](repeating: 0, count: extracted.count)
                for idx in 0..<extracted.count {
                    let v = extracted[idx]
                    loPlane[idx] = v & lowMask
                    hiPlane[idx] = v >> shiftBits
                }
                intCompSamples.append(loPlane)
                intCompSamples.append(hiPlane)
            } else {
                intCompSamples.append(extracted)
            }
        }

        let outReservation = try budget.makeOutputReservation(
            initialBytes: 0,
            checkCompressedLimit: true,
            stage: "jp3d-tile-output",
            message: "Volumetric encoded tile payload exceeds operation resource limits."
        )
        let (entropyBudget, cleanupEntropyScratch) = budget.makeEntropyOutputBudget(
            reservation: outReservation,
            stage: "jp3d-tier12-prealloc-output",
            message: "Volumetric encoded tile payload exceeds operation resource limits."
        )
        defer { cleanupEntropyScratch() }
        do {
            let encoded = try JP3DNormativeTileCodec.encodeTile(
                componentVoxels: intCompSamples,
                componentBitDepths: componentBitDepths,
                componentSigned: componentSigned,
                x0: tile.region.x.lowerBound,
                x1: tile.region.x.upperBound,
                y0: tile.region.y.lowerBound,
                y1: tile.region.y.upperBound,
                z0: tile.region.z.lowerBound,
                z1: tile.region.z.upperBound,
                cod: cod,
                qcd: qcd,
                htConfiguration: htConfig,
                targetBitrateBPP: targetBitrateBPP.map { Float($0) },
                useAccelerated: useAccelerated,
                entropyBudget: entropyBudget,
                remainingOutputLimit: nil,
                admitEncodedBytes: nil,
                cancellation: { try work.check() }
            )
            let packetBytes = encoded.data
            let currentReserved = outReservation.reservedBytes
            if packetBytes.count > currentReserved {
                try outReservation.withGrowth(
                    by: packetBytes.count - currentReserved,
                    extraTransientBytes: 0,
                    checkCompressedLimit: true,
                    stage: "jp3d-tier12-incremental-output",
                    message: "Volumetric encoded tile payload exceeds operation resource limits."
                ) {}
            } else if packetBytes.count < currentReserved {
                outReservation.shrinkTo(packetBytes.count)
            }
            StorageTelemetry.recordParserAllocation(stage: "jp3d-tile-output", bytes: packetBytes.count)
            return JP3DEncodedTileOutput(
                data: packetBytes,
                reservation: outReservation,
                usedAccelerated: encoded.usedAccelerated
            )
        } catch {
            outReservation.shrinkTo(0)
            outReservation.release()
            throw error
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
