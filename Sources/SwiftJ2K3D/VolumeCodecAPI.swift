// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Contract API-13 Volumetric Extension Surface for SwiftJ2K3D
// Predecessor reference: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

// MARK: - API-13 Volumetric Extension Rationale

/// Contract **API-13** Volumetric Extension Surface (`SwiftJ2K3D`).
///
/// The common single-image contract (`SwiftJ2K.Encoder` / `SwiftJ2K.Decoder`) models
/// 2D planar and interleaved images (`ImageDescriptor` with `width` and `height`).
/// Volumetric JPEG 2000 (ISO/IEC 15444-10 / JP3D) operates on 3D voxel grids
/// (`width × height × depth`), 3D tile decompositions (`tileSizeX × tileSizeY × tileSizeZ`),
/// 3D wavelet transforms (`levelsX, levelsY, levelsZ`), 3D regions of interest (`JP3DRegion`),
/// and Z-axis residual prediction (`JP3DZDeltaMode`), which cannot be represented by a 2D
/// `ImageDescriptor` without losing volumetric geometry and 3D tile/subband semantics.
///
/// Per **API-13**, `VolumeEncoder`, `VolumeDecoder`, and `VolumeTranscoder` provide
/// the contract-aligned immutable configuration/options/report pattern for 3D volumes
/// alongside the retained `JP3DEncoder`/`JP3DDecoder` compatibility actors required by `DICOMKit`.

// MARK: - VolumeInfo

/// Bounded structural inspection result for a JP3D volumetric codestream.
public struct VolumeInfo: Sendable, Equatable {
    /// Volume width in voxels along the X axis.
    public let width: Int
    /// Volume height in voxels along the Y axis.
    public let height: Int
    /// Volume depth in slices along the Z axis.
    public let depth: Int
    /// Number of voxel components.
    public let componentCount: Int
    /// Bit depth per component sample.
    public let bitDepth: Int
    /// Whether component samples are signed integers.
    public let signed: Bool
    /// Tile width along X.
    public let tileSizeX: Int
    /// Tile height along Y.
    public let tileSizeY: Int
    /// Tile depth along Z.
    public let tileSizeZ: Int
    /// Decomposition levels along X.
    public let levelsX: Int
    /// Decomposition levels along Y.
    public let levelsY: Int
    /// Decomposition levels along Z.
    public let levelsZ: Int
    /// Number of quality layers.
    public let qualityLayers: Int
    /// Whether the codestream uses lossless reversible coding.
    public let isLossless: Bool
    /// Whether the codestream contains HTJ2K (Part 15) tiles.
    public let isHTJ2K: Bool
    /// Total number of tiles in the codestream.
    public let tileCount: Int
    /// Physical voxel spacing along X (`0` when unset or discarded by metadata policy).
    public let spacingX: Double
    /// Physical voxel spacing along Y (`0` when unset or discarded by metadata policy).
    public let spacingY: Double
    /// Physical voxel spacing along Z (`0` when unset or discarded by metadata policy).
    public let spacingZ: Double
    /// Physical origin X coordinate (`0` when unset or discarded by metadata policy).
    public let originX: Double
    /// Physical origin Y coordinate (`0` when unset or discarded by metadata policy).
    public let originY: Double
    /// Physical origin Z coordinate (`0` when unset or discarded by metadata policy).
    public let originZ: Double

    public init(
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        bitDepth: Int,
        signed: Bool,
        tileSizeX: Int,
        tileSizeY: Int,
        tileSizeZ: Int,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        qualityLayers: Int,
        isLossless: Bool,
        isHTJ2K: Bool,
        tileCount: Int,
        spacingX: Double = 0,
        spacingY: Double = 0,
        spacingZ: Double = 0,
        originX: Double = 0,
        originY: Double = 0,
        originZ: Double = 0
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.componentCount = componentCount
        self.bitDepth = bitDepth
        self.signed = signed
        self.tileSizeX = tileSizeX
        self.tileSizeY = tileSizeY
        self.tileSizeZ = tileSizeZ
        self.levelsX = levelsX
        self.levelsY = levelsY
        self.levelsZ = levelsZ
        self.qualityLayers = qualityLayers
        self.isLossless = isLossless
        self.isHTJ2K = isHTJ2K
        self.tileCount = tileCount
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.spacingZ = spacingZ
        self.originX = originX
        self.originY = originY
        self.originZ = originZ
    }
}

// MARK: - VolumeEncoderConfiguration & VolumeEncodeOptions

/// Validated, immutable configuration for ``VolumeEncoder``.
public struct VolumeEncoderConfiguration: Sendable, Equatable {
    /// Underlying JP3D compression mode.
    public let compressionMode: JP3DCompressionMode
    /// 3D tiling geometry.
    public let tiling: JP3DTilingConfiguration
    /// Progression order.
    public let progressionOrder: JP3DProgressionOrder
    /// Quality layer count.
    public let qualityLayers: Int
    /// Wavelet decomposition levels along X.
    public let levelsX: Int
    /// Wavelet decomposition levels along Y.
    public let levelsY: Int
    /// Wavelet decomposition levels along Z.
    public let levelsZ: Int
    /// Optional Z-axis delta prediction mode.
    public let zDelta: JP3DZDeltaMode

    /// Creates and validates a volumetric encoder configuration.
    public init(
        compressionMode: JP3DCompressionMode = .lossless,
        tiling: JP3DTilingConfiguration = .default,
        progressionOrder: JP3DProgressionOrder = .lrcp,
        qualityLayers: Int = 1,
        levelsX: Int = 3,
        levelsY: Int = 3,
        levelsZ: Int = 2,
        zDelta: JP3DZDeltaMode = .disabled
    ) throws {
        guard qualityLayers >= 1 else {
            throw CodecError(
                .invalidArgument,
                "VolumeEncoderConfiguration: qualityLayers must be >= 1"
            )
        }
        guard levelsX >= 0, levelsY >= 0, levelsZ >= 0 else {
            throw CodecError(
                .invalidArgument,
                "VolumeEncoderConfiguration: decomposition levels must be non-negative"
            )
        }
        if case .lossy(let psnr) = compressionMode, (!psnr.isFinite || psnr <= 0) {
            throw CodecError(
                .invalidArgument,
                "VolumeEncoderConfiguration: lossy PSNR must be finite and positive"
            )
        }
        if case .lossyHTJ2K(let psnr) = compressionMode, (!psnr.isFinite || psnr <= 0) {
            throw CodecError(
                .invalidArgument,
                "VolumeEncoderConfiguration: lossyHTJ2K PSNR must be finite and positive"
            )
        }
        if case .targetBitrate(let bpp) = compressionMode, (!bpp.isFinite || bpp <= 0) {
            throw CodecError(
                .invalidArgument,
                "VolumeEncoderConfiguration: targetBitrate must be finite and positive"
            )
        }
        self.compressionMode = compressionMode
        self.tiling = tiling
        self.progressionOrder = progressionOrder
        self.qualityLayers = qualityLayers
        self.levelsX = levelsX
        self.levelsY = levelsY
        self.levelsZ = levelsZ
        self.zDelta = zDelta
    }
}

/// Per-operation options for ``VolumeEncoder/encode(_:options:)``.
public struct VolumeEncodeOptions: Sendable {
    /// Resource limits for the volumetric encode operation.
    public var resourceLimits: ResourceLimits
    /// Execution policy for acceleration vs. scalar CPU reference.
    public var executionPolicy: ExecutionPolicy
    /// Copy policy.
    public var copyPolicy: CopyPolicy
    /// Metadata preservation policy.
    public var metadataPolicy: MetadataPolicy
    /// Optional progress callback.
    public var progress: (@Sendable (ProgressUpdate) -> Void)?

    public init(
        resourceLimits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic,
        copyPolicy: CopyPolicy = .allowCopy,
        metadataPolicy: MetadataPolicy = .preserve,
        progress: (@Sendable (ProgressUpdate) -> Void)? = nil
    ) {
        self.resourceLimits = resourceLimits
        self.executionPolicy = executionPolicy
        self.copyPolicy = copyPolicy
        self.metadataPolicy = metadataPolicy
        self.progress = progress
    }
}

/// Result of a contract-aligned volumetric encode operation.
public struct EncodedVolume: Sendable, Equatable {
    /// Encoded JP3D codestream bytes.
    public let data: Data
    /// Width of the encoded volume.
    public let width: Int
    /// Height of the encoded volume.
    public let height: Int
    /// Depth of the encoded volume.
    public let depth: Int
    /// Number of components.
    public let componentCount: Int
    /// Number of tiles in the encoded volume.
    public let tileCount: Int
    /// Whether the encoding is lossless.
    public let isLossless: Bool
    /// Operation report detailing backend, fidelity, and memory usage.
    public let report: OperationReport

    public init(
        data: Data,
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        tileCount: Int,
        isLossless: Bool,
        report: OperationReport
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.depth = depth
        self.componentCount = componentCount
        self.tileCount = tileCount
        self.isLossless = isLossless
        self.report = report
    }
}

// MARK: - VolumeDecoderConfiguration & VolumeDecodeOptions

/// Validated, immutable configuration for ``VolumeDecoder``.
public struct VolumeDecoderConfiguration: Sendable, Equatable {
    /// Maximum quality layers to decode (`0` = all layers).
    public let maxQualityLayers: Int
    /// Reduced resolution level (`0` = full resolution).
    public let resolutionLevel: Int
    /// Whether to tolerate truncated tile payloads.
    public let tolerateTruncation: Bool

    public init(
        maxQualityLayers: Int = 0,
        resolutionLevel: Int = 0,
        tolerateTruncation: Bool = false
    ) throws {
        guard maxQualityLayers >= 0 else {
            throw CodecError(
                .invalidArgument,
                "VolumeDecoderConfiguration: maxQualityLayers must be >= 0"
            )
        }
        guard (0...32).contains(resolutionLevel) else {
            throw CodecError(
                .invalidArgument,
                "VolumeDecoderConfiguration: resolutionLevel \(resolutionLevel) must be in 0...32"
            )
        }
        self.maxQualityLayers = maxQualityLayers
        self.resolutionLevel = resolutionLevel
        self.tolerateTruncation = tolerateTruncation
    }
}

/// Per-operation options for ``VolumeDecoder/decode(_:options:)``.
public struct VolumeDecodeOptions: Sendable {
    /// Resource limits for the volumetric decode operation.
    public var resourceLimits: ResourceLimits
    /// Execution policy for acceleration vs. scalar CPU reference.
    public var executionPolicy: ExecutionPolicy
    /// Copy policy.
    public var copyPolicy: CopyPolicy
    /// Metadata preservation policy.
    public var metadataPolicy: MetadataPolicy
    /// Optional 3D region of interest to decode.
    public var regionOfInterest: JP3DRegion?
    /// Optional progress callback.
    public var progress: (@Sendable (ProgressUpdate) -> Void)?

    public init(
        resourceLimits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic,
        copyPolicy: CopyPolicy = .allowCopy,
        metadataPolicy: MetadataPolicy = .preserve,
        regionOfInterest: JP3DRegion? = nil,
        progress: (@Sendable (ProgressUpdate) -> Void)? = nil
    ) {
        self.resourceLimits = resourceLimits
        self.executionPolicy = executionPolicy
        self.copyPolicy = copyPolicy
        self.metadataPolicy = metadataPolicy
        self.regionOfInterest = regionOfInterest
        self.progress = progress
    }
}

/// Result of a contract-aligned volumetric decode operation.
public struct DecodedVolume: Sendable, Equatable {
    /// Reconstructed 3D volume.
    public let volume: J2KVolume
    /// Whether any tiles were skipped or truncated.
    public let isPartial: Bool
    /// Operation report detailing backend, fidelity, and memory usage.
    public let report: OperationReport

    public init(
        volume: J2KVolume,
        isPartial: Bool,
        report: OperationReport
    ) {
        self.volume = volume
        self.isPartial = isPartial
        self.report = report
    }
}

// MARK: - VolumeEncoder

/// Immutable, reusable volumetric JPEG 2000 encoder conforming to Contract **API-13**.
public struct VolumeEncoder: Sendable {
    /// Validated encoder configuration.
    public let configuration: VolumeEncoderConfiguration

    /// Creates a volumetric encoder with the given configuration.
    public init(configuration: VolumeEncoderConfiguration = try! VolumeEncoderConfiguration()) throws {
        self.configuration = configuration
    }

    /// Encodes a `J2KVolume` into a JP3D codestream with resource limits, cancellation, and reporting.
    public func encode(
        _ volume: J2KVolume,
        options: VolumeEncodeOptions = VolumeEncodeOptions()
    ) async throws -> EncodedVolume {
        let startedAt = ContinuousClock.now
        let work = VolumeWorkGuard(limits: options.resourceLimits)
        try work.check()
        guard options.copyPolicy == .allowCopy else {
            throw CodecError(
                .incompatibleImageLayout,
                "VolumeEncoder extracts tile sample buffers from J2KVolumeComponent.data (Foundation.Data), requiring a buffer copy; pass copyPolicy: .allowCopy."
            )
        }
        do {
            try volume.validate()
        } catch let error as J2KError {
            throw error.asCodecError
        }

        let maxDim = options.resourceLimits.maximumDimension
        guard volume.width <= maxDim, volume.height <= maxDim, volume.depth <= maxDim else {
            throw CodecError(
                .resourceLimitExceeded,
                "Volume dimensions (\(volume.width)x\(volume.height)x\(volume.depth)) exceed limit \(maxDim)"
            )
        }
        guard volume.depth <= options.resourceLimits.maximumFrames else {
            throw CodecError(
                .resourceLimitExceeded,
                "Volume depth \(volume.depth) exceeds frame limit \(options.resourceLimits.maximumFrames)"
            )
        }
        guard volume.voxelCount <= options.resourceLimits.maximumPixels else {
            throw CodecError(
                .resourceLimitExceeded,
                "Volume voxel count \(volume.voxelCount) exceeds limit \(options.resourceLimits.maximumPixels)"
            )
        }
        let volumeByteCount: Int
        do {
            volumeByteCount = try volume.sizeInBytes
        } catch let error as J2KError {
            throw error.asCodecError
        }
        guard volumeByteCount <= options.resourceLimits.maximumDecodedBytes,
              volumeByteCount <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "Volume byte count \(volumeByteCount) exceeds memory limit"
            )
        }

        let resolvedExec = try AccelerationRuntime.resolve(options.executionPolicy)

        if let p = try? ProgressUpdate(phase: .inspecting, completedUnits: 0, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let jp3dConfig = JP3DEncoderConfiguration(
            compressionMode: configuration.compressionMode,
            tiling: configuration.tiling,
            progressionOrder: configuration.progressionOrder,
            qualityLayers: configuration.qualityLayers,
            levelsX: configuration.levelsX,
            levelsY: configuration.levelsY,
            levelsZ: configuration.levelsZ,
            parallelTileEncoding: options.resourceLimits.maximumWorkers > 1,
            zDelta: configuration.zDelta,
            maximumWorkers: options.resourceLimits.maximumWorkers
        )
        let actorEncoder = JP3DEncoder(configuration: jp3dConfig)

        if let p = try? ProgressUpdate(phase: .processing, completedUnits: 1, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let result: JP3DEncoderResult
        do {
            result = try await actorEncoder.encodeAdmitted(
                volume,
                limits: options.resourceLimits,
                executionPolicy: options.executionPolicy,
                metadataPolicy: options.metadataPolicy,
                work: work
            )
        } catch let error as J2KError {
            throw error.asCodecError
        }

        try work.check()
        if let p = try? ProgressUpdate(phase: .completed, completedUnits: 3, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let fidelity: Fidelity = result.isLossless ? .exactSamples : .lossy
        let discardedGeometry = (options.metadataPolicy == .discardAncillary && volume.hasExplicitGeometry)
        let copyEvent = try CopyEvent(
            reason: "extract tile sample buffers from J2KVolume Data components",
            bytesMoved: volumeByteCount,
            sourceLayout: "j2kvolume-component-data",
            destinationLayout: "jp3d-tile-sample-buffers"
        )
        let report = OperationReport(
            backend: resolvedExec.backend,
            fallbackReason: resolvedExec.fallbackReason,
            fidelity: fidelity,
            copyEvents: [copyEvent],
            pixelAllocationCount: 0,
            peakPixelBytes: volumeByteCount,
            peakWorkspaceBytes: result.peakWorkspaceBytes,
            elapsedSeconds: elapsedSeconds,
            discardedMetadataCount: discardedGeometry ? 1 : 0,
            discardedMetadataBytes: discardedGeometry ? JP3DVolumeGeometry.payloadByteCount : 0,
            discardedMetadataKinds: discardedGeometry ? ["volumeGeometry"] : []
        )

        return EncodedVolume(
            data: result.data,
            width: result.width,
            height: result.height,
            depth: result.depth,
            componentCount: volume.componentCount,
            tileCount: result.tileCount,
            isLossless: result.isLossless,
            report: report
        )
    }
}

// MARK: - VolumeDecoder

/// Immutable, reusable volumetric JPEG 2000 decoder conforming to Contract **API-13**.
public struct VolumeDecoder: Sendable {
    /// Validated decoder configuration.
    public let configuration: VolumeDecoderConfiguration

    /// Creates a volumetric decoder with the given configuration.
    public init(configuration: VolumeDecoderConfiguration = try! VolumeDecoderConfiguration()) throws {
        self.configuration = configuration
    }

    /// Performs bounded structural inspection of a JP3D codestream without decoding voxel payloads.
    public func inspect(
        _ data: Data,
        options: VolumeDecodeOptions = VolumeDecodeOptions()
    ) throws -> VolumeInfo {
        let work = VolumeWorkGuard(limits: options.resourceLimits)
        try work.check()
        guard data.count <= options.resourceLimits.maximumCompressedBytes,
              data.count <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "Codestream size \(data.count) exceeds compressed or memory limit"
            )
        }
        let parsed: JP3DParsedCodestream
        do {
            parsed = try JP3DCodestreamParser().parse(
                data,
                limits: options.resourceLimits,
                work: work,
                copyTilePayloads: false
            )
        } catch let error as J2KError {
            throw error.asCodecError
        }
        let siz = parsed.siz
        let cod = parsed.cod
        let maxDim = options.resourceLimits.maximumDimension
        guard siz.width <= maxDim, siz.height <= maxDim, siz.depth <= maxDim else {
            throw CodecError(
                .resourceLimitExceeded,
                "Codestream dimensions (\(siz.width)x\(siz.height)x\(siz.depth)) exceed limit \(maxDim)"
            )
        }
        guard siz.depth <= options.resourceLimits.maximumFrames else {
            throw CodecError(
                .resourceLimitExceeded,
                "Codestream depth \(siz.depth) exceeds frame limit \(options.resourceLimits.maximumFrames)"
            )
        }
        let (wh, ov1) = siz.width.multipliedReportingOverflow(by: siz.height)
        let (voxels, ov2) = wh.multipliedReportingOverflow(by: siz.depth)
        guard !ov1, !ov2 else {
            throw CodecError(
                .malformedInput,
                "Volumetric dimensions overflow integer arithmetic"
            )
        }
        guard voxels <= options.resourceLimits.maximumPixels else {
            throw CodecError(
                .resourceLimitExceeded,
                "Volumetric voxel count \(voxels) exceeds limit \(options.resourceLimits.maximumPixels)"
            )
        }

        let detectedLayers = parsed.tiles.first.flatMap { JP3DSliceStackCodec.peekQualityLayers($0.data) } ?? 1
        let inspectedGeometry: JP3DVolumeGeometry? = (options.metadataPolicy == .preserve) ? parsed.geometry : nil

        return VolumeInfo(
            width: siz.width,
            height: siz.height,
            depth: siz.depth,
            componentCount: siz.componentCount,
            bitDepth: siz.bitDepth,
            signed: siz.signed,
            tileSizeX: siz.tileSizeX,
            tileSizeY: siz.tileSizeY,
            tileSizeZ: siz.tileSizeZ,
            levelsX: cod.levelsX,
            levelsY: cod.levelsY,
            levelsZ: cod.levelsZ,
            qualityLayers: detectedLayers,
            isLossless: cod.isLossless && parsed.isLosslessQuantization,
            isHTJ2K: parsed.containsHTJ2KTiles,
            tileCount: parsed.tiles.count,
            spacingX: inspectedGeometry?.spacingX ?? 0,
            spacingY: inspectedGeometry?.spacingY ?? 0,
            spacingZ: inspectedGeometry?.spacingZ ?? 0,
            originX: inspectedGeometry?.originX ?? 0,
            originY: inspectedGeometry?.originY ?? 0,
            originZ: inspectedGeometry?.originZ ?? 0
        )
    }

    /// Decodes a JP3D codestream (or 3D region of interest) into a `DecodedVolume`.
    public func decode(
        _ data: Data,
        options: VolumeDecodeOptions = VolumeDecodeOptions()
    ) async throws -> DecodedVolume {
        let startedAt = ContinuousClock.now
        let work = VolumeWorkGuard(limits: options.resourceLimits)
        try work.check()
        guard options.copyPolicy == .allowCopy else {
            throw CodecError(
                .incompatibleImageLayout,
                "VolumeDecoder assembles decoded tile buffers into J2KVolumeComponent.data (Foundation.Data), requiring a buffer copy; pass copyPolicy: .allowCopy."
            )
        }
        let info = try inspect(data, options: options)

        let outW: Int
        let outH: Int
        let outD: Int
        if let roi = options.regionOfInterest {
            let cx0 = max(0, roi.x.lowerBound)
            let cx1 = min(info.width, roi.x.upperBound)
            let cy0 = max(0, roi.y.lowerBound)
            let cy1 = min(info.height, roi.y.upperBound)
            let cz0 = max(0, roi.z.lowerBound)
            let cz1 = min(info.depth, roi.z.upperBound)
            if cx0 < cx1 && cy0 < cy1 && cz0 < cz1 {
                outW = jp3dDownsampleDimension(cx1 - cx0, resolutionLevel: configuration.resolutionLevel)
                outH = jp3dDownsampleDimension(cy1 - cy0, resolutionLevel: configuration.resolutionLevel)
                outD = cz1 - cz0
            } else {
                outW = info.width
                outH = info.height
                outD = info.depth
            }
        } else {
            outW = jp3dDownsampleDimension(info.width, resolutionLevel: configuration.resolutionLevel)
            outH = jp3dDownsampleDimension(info.height, resolutionLevel: configuration.resolutionLevel)
            outD = info.depth
        }

        let bytesPerSample = (info.bitDepth + 7) / 8
        let (outWH, o1) = outW.multipliedReportingOverflow(by: outH)
        let (voxels, o2) = outWH.multipliedReportingOverflow(by: outD)
        let (compBytes, o3) = voxels.multipliedReportingOverflow(by: bytesPerSample)
        let (totalBytes, o4) = compBytes.multipliedReportingOverflow(by: info.componentCount)
        let (liveMemMin, o5) = data.count.addingReportingOverflow(totalBytes)
        guard !o1, !o2, !o3, !o4, !o5 else {
            throw CodecError(.malformedInput, "Decoded volume byte count overflows integer arithmetic")
        }
        guard totalBytes <= options.resourceLimits.maximumDecodedBytes,
              liveMemMin <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "Decoded volume byte count \(totalBytes) exceeds decoded or memory limit"
            )
        }

        let resolvedExec = try AccelerationRuntime.resolve(options.executionPolicy)

        if let p = try? ProgressUpdate(phase: .inspecting, completedUnits: 0, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let volume: J2KVolume
        let isPartial: Bool
        let resultIsLossless: Bool
        let measuredPeakWorkspace: Int
        let sourceCommentCount: Int
        let sourceCommentBytes: Int
        let sourceHadGeometry: Bool
        do {
            if let roi = options.regionOfInterest {
                let roiConfig = JP3DDecoderConfiguration(
                    maxQualityLayers: configuration.maxQualityLayers,
                    resolutionLevel: configuration.resolutionLevel,
                    tolerateErrors: configuration.tolerateTruncation,
                    parallelTileDecoding: options.resourceLimits.maximumWorkers > 1,
                    maximumWorkers: options.resourceLimits.maximumWorkers
                )
                let roiDecoder = JP3DROIDecoder(configuration: roiConfig)
                if let p = try? ProgressUpdate(phase: .processing, completedUnits: 1, totalUnits: 3) {
                    options.progress?(p)
                }
                try work.check()
                let roiResult = try await roiDecoder.decodeAdmitted(
                    data,
                    region: roi,
                    maxQualityLayers: configuration.maxQualityLayers > 0 ? configuration.maxQualityLayers : nil,
                    resolutionLevel: configuration.resolutionLevel,
                    limits: options.resourceLimits,
                    executionPolicy: options.executionPolicy,
                    metadataPolicy: options.metadataPolicy,
                    work: work
                )
                volume = roiResult.volume
                isPartial = !roiResult.warnings.isEmpty
                resultIsLossless = info.isLossless
                measuredPeakWorkspace = roiResult.peakWorkspaceBytes
                sourceCommentCount = roiResult.commentCount
                sourceCommentBytes = roiResult.commentPayloadBytes
                sourceHadGeometry = roiResult.hadVolumeGeometry
            } else {
                let jp3dConfig = JP3DDecoderConfiguration(
                    maxQualityLayers: configuration.maxQualityLayers,
                    resolutionLevel: configuration.resolutionLevel,
                    tolerateTruncation: configuration.tolerateTruncation,
                    parallelTileDecoding: options.resourceLimits.maximumWorkers > 1,
                    maximumWorkers: options.resourceLimits.maximumWorkers
                )
                let actorDecoder = JP3DDecoder(configuration: jp3dConfig)
                if let p = try? ProgressUpdate(phase: .processing, completedUnits: 1, totalUnits: 3) {
                    options.progress?(p)
                }
                try work.check()
                let result = try await actorDecoder.decodeAdmitted(
                    data,
                    limits: options.resourceLimits,
                    executionPolicy: options.executionPolicy,
                    metadataPolicy: options.metadataPolicy,
                    work: work
                )
                volume = result.volume
                isPartial = result.isPartial
                resultIsLossless = result.isLossless
                measuredPeakWorkspace = result.peakWorkspaceBytes
                sourceCommentCount = result.commentCount
                sourceCommentBytes = result.commentPayloadBytes
                sourceHadGeometry = result.hadVolumeGeometry
            }
        } catch let error as J2KError {
            throw error.asCodecError
        }

        try work.check()
        if let p = try? ProgressUpdate(phase: .completed, completedUnits: 3, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let reducedResolution = configuration.resolutionLevel > 0
        let reducedQualityLayers = configuration.maxQualityLayers > 0
            && configuration.maxQualityLayers < info.qualityLayers
        let isExact = info.isLossless
            && resultIsLossless
            && !isPartial
            && !reducedResolution
            && !reducedQualityLayers
        let fidelity: Fidelity = isExact ? .exactSamples : .lossy

        let decodedPixelBytes = (try? volume.sizeInBytes) ?? volume.estimatedMemorySize
        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let discardedCount = (options.metadataPolicy == .discardAncillary) ? sourceCommentCount : 0
        let discardedBytes = (options.metadataPolicy == .discardAncillary) ? sourceCommentBytes : 0
        let discardedKinds: [String]
        if discardedCount == 0 {
            discardedKinds = []
        } else if sourceHadGeometry {
            discardedKinds = discardedCount > 1 ? ["COM", "volumeGeometry"] : ["volumeGeometry"]
        } else {
            discardedKinds = ["COM"]
        }
        let copyEvent = try CopyEvent(
            reason: "pack reconstructed voxel buffers into J2KVolume Data components",
            bytesMoved: decodedPixelBytes,
            sourceLayout: "jp3d-decoded-tile-buffers",
            destinationLayout: "j2kvolume-component-data"
        )

        let report = OperationReport(
            backend: resolvedExec.backend,
            fallbackReason: resolvedExec.fallbackReason,
            fidelity: fidelity,
            copyEvents: [copyEvent],
            pixelAllocationCount: volume.componentCount,
            peakPixelBytes: decodedPixelBytes,
            peakWorkspaceBytes: measuredPeakWorkspace,
            elapsedSeconds: elapsedSeconds,
            discardedMetadataCount: discardedCount,
            discardedMetadataBytes: discardedBytes,
            discardedMetadataKinds: discardedKinds
        )

        return DecodedVolume(
            volume: volume,
            isPartial: isPartial,
            report: report
        )
    }
}

// MARK: - VolumeTranscoder

/// Immutable, reusable volumetric transcoder between Part 1 (EBCOT) and Part 15 (HTJ2K) JP3D codestreams.
public struct VolumeTranscoder: Sendable {
    /// Validated transcoder configuration.
    public let configuration: TranscoderConfiguration

    public init(configuration: TranscoderConfiguration = .default) throws {
        self.configuration = configuration
    }

    /// Transcodes a JP3D volumetric codestream to the target block-coding format (`jpeg2000` or `htj2k`).
    public func transcode(
        _ data: Data,
        to target: TranscodeTarget,
        options: TranscodeOptions = .init()
    ) async throws -> EncodedVolume {
        let startedAt = ContinuousClock.now
        let work = VolumeWorkGuard(limits: options.resourceLimits)
        try work.check()
        let info = try VolumeDecoder().inspect(
            data,
            options: VolumeDecodeOptions(
                resourceLimits: options.resourceLimits,
                executionPolicy: options.executionPolicy,
                copyPolicy: options.copyPolicy,
                metadataPolicy: options.metadataPolicy
            )
        )

        let resolvedExec = try AccelerationRuntime.resolve(options.executionPolicy)

        if let p = try? ProgressUpdate(phase: .inspecting, completedUnits: 0, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let direction: JP3DTranscodingDirection
        switch target {
        case .htj2k:
            direction = .standardToHTJ2K
        case .jpeg2000:
            direction = .htj2kToStandard
        }

        if let p = try? ProgressUpdate(phase: .processing, completedUnits: 1, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let jp3dTranscoder = JP3DTranscoder()
        let result: JP3DTranscoderResult
        do {
            result = try await jp3dTranscoder.transcodeAdmitted(
                data,
                configuration: JP3DTranscoderConfiguration(
                    direction: direction,
                    verifyRoundTrip: false
                ),
                limits: options.resourceLimits,
                executionPolicy: options.executionPolicy,
                copyPolicy: options.copyPolicy,
                metadataPolicy: options.metadataPolicy,
                work: work
            )
        } catch let error as J2KError {
            throw error.asCodecError
        }

        try work.check()
        if let p = try? ProgressUpdate(phase: .completed, completedUnits: 3, totalUnits: 3) {
            options.progress?(p)
        }
        try work.check()

        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let isExact = info.isLossless && result.warnings.isEmpty
        let copyEvents: [CopyEvent] = result.usedFullRoundTripCopy
            ? [
                try CopyEvent(
                    reason: "lossy volumetric transcoding fallback decoded and re-encoded transient J2KVolume buffers",
                    bytesMoved: result.roundTripPixelBytes * 2,
                    sourceLayout: "jp3d-source-tiles",
                    destinationLayout: "jp3d-reencoded-tiles"
                )
            ]
            : []
        let discardedCount = (options.metadataPolicy == .discardAncillary) ? result.sourceCommentCount : 0
        let discardedBytes = (options.metadataPolicy == .discardAncillary) ? result.sourceCommentBytes : 0
        let discardedKinds: [String]
        if discardedCount == 0 {
            discardedKinds = []
        } else if result.sourceHadVolumeGeometry {
            discardedKinds = discardedCount > 1 ? ["COM", "volumeGeometry"] : ["volumeGeometry"]
        } else {
            discardedKinds = ["COM"]
        }
        let report = OperationReport(
            backend: resolvedExec.backend,
            fallbackReason: resolvedExec.fallbackReason,
            fidelity: isExact ? .exactSamples : .lossy,
            copyEvents: copyEvents,
            pixelAllocationCount: result.usedFullRoundTripCopy ? result.roundTripComponentCount : 0,
            peakPixelBytes: result.usedFullRoundTripCopy ? result.roundTripPixelBytes : 0,
            peakWorkspaceBytes: result.peakWorkspaceBytes,
            elapsedSeconds: elapsedSeconds,
            discardedMetadataCount: discardedCount,
            discardedMetadataBytes: discardedBytes,
            discardedMetadataKinds: discardedKinds
        )

        return EncodedVolume(
            data: result.data,
            width: info.width,
            height: info.height,
            depth: info.depth,
            componentCount: info.componentCount,
            tileCount: result.tilesTranscoded,
            isLossless: isExact,
            report: report
        )
    }
}
