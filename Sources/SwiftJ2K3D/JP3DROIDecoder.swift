// SPDX-License-Identifier: Apache-2.0
//
// JP3DROIDecoder.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DROIDecoder.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Fixed signed voxel clamping in assembleROIComponents: previously
//     `let clamped = max(0, min(maxVal, buffer[i]))` clamped negative voxels to 0.
//     Now clamps to `[minVal, maxVal]` and packs two's-complement bytes for signed volumes.

import Foundation
import SwiftJ2K

// MARK: - ROI Decode Result

/// Result of a JP3D ROI decode operation.
public struct JP3DROIDecoderResult: Sendable {
    /// The decoded sub-volume for the requested (clamped) region.
    public let volume: J2KVolume

    /// The actual decoded region (clamped to valid volume bounds).
    public let decodedRegion: JP3DRegion

    /// Whether the decoded region equals the entire volume (`ROI == full volume`).
    public let isFullVolume: Bool

    /// Tiles skipped because they did not intersect the ROI.
    public let tilesSkipped: Int

    /// Tiles decoded.
    public let tilesDecoded: Int

    /// Any warnings encountered during decoding.
    public let warnings: [String]

    /// Total tiles in the codestream.
    public var totalTiles: Int { tilesDecoded + tilesSkipped }

    /// Fraction of tiles skipped (`0.0` to `1.0`).
    public var tileSkipRatio: Double {
        let total = totalTiles
        guard total > 0 else { return 0 }
        return Double(tilesSkipped) / Double(total)
    }

    internal let peakWorkspaceBytes: Int
    internal let commentCount: Int
    internal let commentPayloadBytes: Int
    internal let hadVolumeGeometry: Bool
    package let usedAcceleratedKernel: Bool

    public init(
        volume: J2KVolume,
        decodedRegion: JP3DRegion,
        isFullVolume: Bool,
        tilesSkipped: Int,
        tilesDecoded: Int,
        warnings: [String] = []
    ) {
        self.volume = volume
        self.decodedRegion = decodedRegion
        self.isFullVolume = isFullVolume
        self.tilesSkipped = tilesSkipped
        self.tilesDecoded = tilesDecoded
        self.warnings = warnings
        self.peakWorkspaceBytes = 0
        self.commentCount = 0
        self.commentPayloadBytes = 0
        self.hadVolumeGeometry = false
        self.usedAcceleratedKernel = false
    }

    internal init(
        volume: J2KVolume,
        decodedRegion: JP3DRegion,
        isFullVolume: Bool,
        tilesSkipped: Int,
        tilesDecoded: Int,
        warnings: [String],
        peakWorkspaceBytes: Int,
        commentCount: Int,
        commentPayloadBytes: Int,
        hadVolumeGeometry: Bool,
        usedAcceleratedKernel: Bool = false
    ) {
        self.volume = volume
        self.decodedRegion = decodedRegion
        self.isFullVolume = isFullVolume
        self.tilesSkipped = tilesSkipped
        self.tilesDecoded = tilesDecoded
        self.warnings = warnings
        self.peakWorkspaceBytes = peakWorkspaceBytes
        self.commentCount = commentCount
        self.commentPayloadBytes = commentPayloadBytes
        self.hadVolumeGeometry = hadVolumeGeometry
        self.usedAcceleratedKernel = usedAcceleratedKernel
    }
}

/// Alias for ``JP3DROIDecoderResult``.
public typealias JP3DROIDecodeResult = JP3DROIDecoderResult

// MARK: - ROI Decoder Actor

/// Actor for region-of-interest decoding of JP3D volumetric codestreams.
public actor JP3DROIDecoder {
    // MARK: - State

    private let configuration: JP3DDecoderConfiguration
    private var progressCallback: (@Sendable (JP3DDecoderProgress) -> Void)?

    // MARK: - Init

    /// Creates an ROI decoder with the given configuration.
    public init(configuration: JP3DDecoderConfiguration = .default) {
        self.configuration = configuration
    }

    /// Creates an ROI decoder with explicit quality, resolution, and error-tolerance parameters.
    public init(
        maxQualityLayers: Int = 0,
        resolutionLevel: Int = 0,
        tolerateErrors: Bool = false
    ) {
        self.configuration = JP3DDecoderConfiguration(
            maxQualityLayers: maxQualityLayers,
            resolutionLevel: resolutionLevel,
            tolerateErrors: tolerateErrors
        )
    }

    // MARK: - Pre-warm

    /// Warms the shared acceleration runtime before the first JP3D ROI decode in a process.
    public static func preWarm(includeWarmupDispatch: Bool = false) async {
        await JP3DDecoder.preWarm(includeWarmupDispatch: includeWarmupDispatch)
    }

    // MARK: - Public API

    /// Sets the progress reporting callback.
    public func setProgressCallback(
        _ callback: @escaping @Sendable (JP3DDecoderProgress) -> Void
    ) {
        self.progressCallback = callback
    }

    /// Decodes a specific 3D region from a JP3D codestream.
    public func decode(
        _ data: Data,
        region requestedRegion: JP3DRegion
    ) async throws -> JP3DROIDecoderResult {
        try await decode(
            data,
            region: requestedRegion,
            maxQualityLayers: configuration.maxQualityLayers > 0 ? configuration.maxQualityLayers : nil,
            resolutionLevel: configuration.resolutionLevel
        )
    }

    /// Decodes a 3D region of interest with explicit quality layer and resolution overrides.
    public func decode(
        _ data: Data,
        region requestedRegion: JP3DRegion,
        maxQualityLayers: Int?,
        resolutionLevel: Int
    ) async throws -> JP3DROIDecoderResult {
        try await decodeAdmitted(
            data,
            region: requestedRegion,
            maxQualityLayers: maxQualityLayers,
            resolutionLevel: resolutionLevel,
            limits: nil,
            executionPolicy: .automatic,
            work: VolumeWorkGuard(limits: nil)
        )
    }

    internal func decodeAdmitted(
        _ data: Data,
        region requestedRegion: JP3DRegion,
        maxQualityLayers: Int?,
        resolutionLevel: Int,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        metadataPolicy: MetadataPolicy = .preserve,
        work: VolumeWorkGuard
    ) async throws -> JP3DROIDecoderResult {
        try work.check()
        try jp3dValidateResolutionLevel(resolutionLevel)

        guard !data.isEmpty else {
            throw J2KError.decodingError("Cannot decode ROI from empty codestream")
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
        }

        reportProgress(.parsing, stageProgress: 1.0, tilesDone: 0, tilesTotal: codestream.tiles.count)

        let clampedXLower = max(0, requestedRegion.x.lowerBound)
        let clampedXUpper = min(siz.width, requestedRegion.x.upperBound)
        let clampedYLower = max(0, requestedRegion.y.lowerBound)
        let clampedYUpper = min(siz.height, requestedRegion.y.upperBound)
        let clampedZLower = max(0, requestedRegion.z.lowerBound)
        let clampedZUpper = min(siz.depth, requestedRegion.z.upperBound)

        if clampedXLower >= clampedXUpper || clampedYLower >= clampedYUpper || clampedZLower >= clampedZUpper {
            let logicalC = codestream.logicalComponentCount
            let logicalDepth0 = codestream.logicalBitDepth(forComponent: 0)
            let logicalSigned0 = codestream.logicalIsSigned(forComponent: 0)
            if let limits {
                let bytesPerSample = (logicalDepth0 + 7) / 8
                let (wh, o1) = siz.width.multipliedReportingOverflow(by: siz.height)
                let (vox, o2) = wh.multipliedReportingOverflow(by: siz.depth)
                let (cb, o3) = vox.multipliedReportingOverflow(by: bytesPerSample)
                let (tb, o4) = cb.multipliedReportingOverflow(by: logicalC)
                let (totMem, o5) = data.count.addingReportingOverflow(tb)
                guard !o1, !o2, !o3, !o4, !o5,
                      vox <= limits.maximumPixels,
                      tb <= limits.maximumDecodedBytes,
                      totMem <= limits.maximumMemoryBytes else {
                    throw CodecError(
                        .resourceLimitExceeded,
                        "Empty-ROI fallback volume exceeds resource limits"
                    )
                }
            }
            let blankVolume = J2KVolume(
                width: siz.width, height: siz.height, depth: siz.depth,
                componentCount: logicalC, bitDepth: logicalDepth0, signed: logicalSigned0
            )
            // Preserve the existing partial/full-canvas empty-ROI result, including
            // its canvas geometry; it must not silently reset physical coordinates.
            let geometry = metadataPolicy == .preserve ? codestream.geometry : nil
            let emptyVolume = J2KVolume(
                width: siz.width, height: siz.height, depth: siz.depth,
                components: blankVolume.components,
                spacingX: geometry?.spacingX ?? 0, spacingY: geometry?.spacingY ?? 0,
                spacingZ: geometry?.spacingZ ?? 0, originX: geometry?.originX ?? 0,
                originY: geometry?.originY ?? 0, originZ: geometry?.originZ ?? 0
            )
            let emptyRegion = JP3DRegion(x: 0..<0, y: 0..<0, z: 0..<0)
            return JP3DROIDecoderResult(
                volume: emptyVolume,
                decodedRegion: emptyRegion,
                isFullVolume: false,
                tilesSkipped: codestream.tiles.count,
                tilesDecoded: 0,
                warnings: ["Requested region does not intersect the volume"],
                peakWorkspaceBytes: codestream.retainedTileBytes,
                commentCount: codestream.comments.count,
                commentPayloadBytes: codestream.commentPayloadBytes,
                hadVolumeGeometry: codestream.geometry != nil
            )
        }

        let clampedX = clampedXLower..<clampedXUpper
        let clampedY = clampedYLower..<clampedYUpper
        let clampedZ = clampedZLower..<clampedZUpper
        let roiRegion = JP3DRegion(x: clampedX, y: clampedY, z: clampedZ)
        let roiW = clampedX.count
        let roiH = clampedY.count
        let roiD = clampedZ.count

        let isFullVol = (roiW == siz.width && roiH == siz.height && roiD == siz.depth)
        if isFullVol {
            let effectiveConfig = JP3DDecoderConfiguration(
                maxQualityLayers: maxQualityLayers ?? 0,
                resolutionLevel: resolutionLevel,
                tolerateErrors: configuration.tolerateErrors,
                parallelTileDecoding: configuration.parallelTileDecoding,
                maximumWorkers: configuration.maximumWorkers
            )
            let decoder = JP3DDecoder(configuration: effectiveConfig)
            let result = try await decoder.decodeAdmitted(
                data,
                limits: limits,
                executionPolicy: executionPolicy,
                metadataPolicy: metadataPolicy,
                work: work
            )
            return JP3DROIDecoderResult(
                volume: result.volume,
                decodedRegion: roiRegion,
                isFullVolume: true,
                tilesSkipped: 0,
                tilesDecoded: result.tilesDecoded,
                warnings: result.warnings,
                peakWorkspaceBytes: result.peakWorkspaceBytes,
                commentCount: result.commentCount,
                commentPayloadBytes: result.commentPayloadBytes,
                hadVolumeGeometry: result.hadVolumeGeometry,
                usedAcceleratedKernel: result.usedAcceleratedKernel
            )
        }

        let K = resolutionLevel

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
        let intersectingTiles = tilingConfig.tilesIntersecting(
            region: roiRegion,
            volumeWidth: siz.width,
            volumeHeight: siz.height,
            volumeDepth: siz.depth
        )
        let intersectingIndices = Set(intersectingTiles.map {
            $0.linearIndex(
                tilesX: codestream.tileGrid.tilesX,
                tilesY: codestream.tileGrid.tilesY
            )
        })

        // ROI bounds select points of the same grid used by full-volume reduction.
        let reducedX0 = jp3dDownsampleOrigin(clampedXLower, resolutionLevel: K, roundUp: true)
        let reducedX1 = jp3dDownsampleOrigin(clampedXUpper, resolutionLevel: K, roundUp: true)
        let reducedY0 = jp3dDownsampleOrigin(clampedYLower, resolutionLevel: K, roundUp: true)
        let reducedY1 = jp3dDownsampleOrigin(clampedYUpper, resolutionLevel: K, roundUp: true)
        let outW = reducedX1 - reducedX0
        let outH = reducedY1 - reducedY0
        guard outW > 0, outH > 0 else {
            throw CodecError(.invalidArgument, "Requested ROI contains no samples at the requested resolution level")
        }
        let outD = roiD
        let (outWH, vOv1) = outW.multipliedReportingOverflow(by: outH)
        let (outVoxels, vOv2) = outWH.multipliedReportingOverflow(by: outD)
        var totalBytesPerVoxel = 0
        var bOv1 = false
        let logicalCompCount = codestream.logicalComponentCount
        for comp in 0..<logicalCompCount {
            let compBytes = (codestream.logicalBitDepth(forComponent: comp) + 7) / 8
            let (next, ov) = totalBytesPerVoxel.addingReportingOverflow(compBytes)
            if ov { bOv1 = true }
            totalBytesPerVoxel = next
        }
        let (outDecodedBytes, bOv2) = outVoxels.multipliedReportingOverflow(by: totalBytesPerVoxel)
        guard !vOv1, !vOv2, !bOv1, !bOv2 else {
            throw J2KError.decodingError("ROI output volume dimensions overflow integer arithmetic")
        }

        let isStreamLossless = codestream.isFullyReversible
        let hasLegacyTilePayload = codestream.tiles.contains {
            JP3DLosslessIntegerTileCodec.hasMagic($0.data) || JP3DSliceStackCodec.isSliceStackTile($0.data)
        }
        let isNormativeCodestream = codestream.hasNSIMarker && !hasLegacyTilePayload
        let useExactIntegerPath = isNormativeCodestream || (isStreamLossless && !codestream.tiles.isEmpty && codestream.tiles.allSatisfy {
            JP3DLosslessIntegerTileCodec.hasMagic($0.data) || JP3DSliceStackCodec.isSliceStackTile($0.data)
        })
        let normativeContext: JP3DDecoder.NormativeDecodeContext? = isNormativeCodestream
            ? JP3DDecoder.NormativeDecodeContext(
                parsed: codestream,
                tolerateTruncation: configuration.tolerateErrors
            )
            : nil
        let elementStride = useExactIntegerPath ? MemoryLayout<Int64>.stride : MemoryLayout<Float>.stride
        let (totalSamples, sOv1) = outVoxels.multipliedReportingOverflow(by: siz.componentCount)
        let (bufferWorkspaceBytes, sOv2) = totalSamples.multipliedReportingOverflow(by: elementStride)
        guard !sOv1, !sOv2 else {
            throw J2KError.decodingError("ROI workspace size overflows integer arithmetic")
        }

        var maxROIGeomBytes = 0
        if let ctx = normativeContext {
            let geomCap = limits?.maximumWorkspaceBytes
            for parsedTile in codestream.tiles where intersectingIndices.contains(parsedTile.tileIndex) && parsedTile.tileIndex < allTiles.count {
                let tile = allTiles[parsedTile.tileIndex]
                var tileGeom = 0
                for c in 0..<siz.componentCount {
                    let remCap = geomCap.map { max(0, $0 - tileGeom) }
                    let fp = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                        x0: tile.region.x.lowerBound, x1: tile.region.x.upperBound,
                        y0: tile.region.y.lowerBound, y1: tile.region.y.upperBound,
                        z0: tile.region.z.lowerBound, z1: tile.region.z.upperBound,
                        cod: ctx.effectiveCOD(tileIndex: parsedTile.tileIndex, component: c),
                        maximumWorkspaceBytes: remCap,
                        includeDecodeState: true
                    )
                    let (nextG, gOv) = tileGeom.addingReportingOverflow(fp.totalBytes)
                    guard !gOv else {
                        throw CodecError(.resourceLimitExceeded, "ROI 3D tile geometry workspace overflows Int.")
                    }
                    tileGeom = nextG
                }
                if tileGeom > maxROIGeomBytes {
                    maxROIGeomBytes = tileGeom
                }
            }
        }

        let (tWH0, tOv1) = min(siz.width, siz.tileSizeX).multipliedReportingOverflow(by: min(siz.height, siz.tileSizeY))
        let (maxTileVox0, tOv2) = tWH0.multipliedReportingOverflow(by: min(siz.depth, siz.tileSizeZ))
        let (tileSamples0, tOv3) = maxTileVox0.multipliedReportingOverflow(by: siz.componentCount)
        let (tileSampleScratch0, tOv4) = tileSamples0.multipliedReportingOverflow(by: max(elementStride * 2, MemoryLayout<Int64>.stride + MemoryLayout<Float>.stride))
        let (tileScratch0, tOv5) = tileSampleScratch0.addingReportingOverflow(maxROIGeomBytes)
        let retainedSourceBytes = try jp3dDecodeAdd(codestream.retainedTileBytes, codestream.commentPayloadBytes)
        let (ws10, wOv1) = retainedSourceBytes.addingReportingOverflow(bufferWorkspaceBytes)
        let (computedPeakROIWorkspace, wOv2) = ws10.addingReportingOverflow(tileScratch0)
        guard !tOv1, !tOv2, !tOv3, !tOv4, !tOv5, !wOv1, !wOv2 else {
            throw J2KError.decodingError("ROI workspace size overflows integer arithmetic")
        }

        if let limits {
            guard outVoxels <= limits.maximumPixels else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "ROI voxel count \(outVoxels) exceeds pixel limit \(limits.maximumPixels)"
                )
            }
            guard outDecodedBytes <= limits.maximumDecodedBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "ROI decoded byte count \(outDecodedBytes) exceeds decoded-byte limit \(limits.maximumDecodedBytes)"
                )
            }
            guard computedPeakROIWorkspace <= limits.maximumWorkspaceBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "ROI workspace \(computedPeakROIWorkspace) exceeds workspace limit \(limits.maximumWorkspaceBytes)"
                )
            }
            let (mem1, mOv1) = data.count.addingReportingOverflow(outDecodedBytes)
            let (totalLiveMem, mOv2) = mem1.addingReportingOverflow(computedPeakROIWorkspace)
            guard !mOv1, !mOv2, totalLiveMem <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "ROI decode memory \(totalLiveMem) exceeds memory limit \(limits.maximumMemoryBytes)"
                )
            }
        }

        let workerLimits = try limits.map {
            try jp3dDecodeWorkerLimits($0, retainedWorkspace: ws10,
                retainedMemory: jp3dDecodeAdd(jp3dDecodeAdd(data.count, outDecodedBytes), ws10), workers: 1)
        }
        let decodeWorkspace = JP3DDecodeWorkspace()

        StorageTelemetry.recordStage("volume-roi-decode-buffers", bytes: bufferWorkspaceBytes)
        StorageTelemetry.recordWorkspaceAllocation(bytes: bufferWorkspaceBytes)

        var intComponentBuffers: [[Int64]] = useExactIntegerPath
            ? (0..<siz.componentCount).map { _ in [Int64](repeating: 0, count: outVoxels) }
            : []
        var componentBuffers: [[Float]] = useExactIntegerPath
            ? []
            : (0..<siz.componentCount).map { _ in [Float](repeating: 0, count: outVoxels) }

        let filter: JP3DWaveletFilter = cod.isLossless ? .reversible53 : .irreversible97
        let transformConfig = JP3DTransformConfiguration(
            filter: filter,
            mode: .separable,
            boundary: .symmetric,
            levelsX: cod.levelsX,
            levelsY: cod.levelsY,
            levelsZ: cod.levelsZ
        )

        var tilesDecoded = 0
        var tilesSkipped = 0
        var warnings: [String] = []
        var anyAccelerated = false

        for parsedTile in codestream.tiles {
            try work.check()
            guard intersectingIndices.contains(parsedTile.tileIndex),
                  parsedTile.tileIndex < allTiles.count else {
                tilesSkipped += 1
                continue
            }

            let tile = allTiles[parsedTile.tileIndex]
            let tileX0 = jp3dDownsampleOrigin(tile.region.x.lowerBound, resolutionLevel: K, roundUp: true)
            let tileY0 = jp3dDownsampleOrigin(tile.region.y.lowerBound, resolutionLevel: K, roundUp: true)
            let tileW = jp3dDownsampleOrigin(tile.region.x.upperBound, resolutionLevel: K, roundUp: true) - tileX0
            let tileH = jp3dDownsampleOrigin(tile.region.y.upperBound, resolutionLevel: K, roundUp: true) - tileY0
            let tileD = tile.depth

            let overlapZ0 = max(tile.region.z.lowerBound, roiRegion.z.lowerBound)
            let overlapZ1 = min(tile.region.z.upperBound, roiRegion.z.upperBound)
            let localZStart = overlapZ0 - tile.region.z.lowerBound
            let localZEnd = overlapZ1 - tile.region.z.lowerBound

            let overlapX0 = max(tile.region.x.lowerBound, roiRegion.x.lowerBound)
            let overlapX1 = min(tile.region.x.upperBound, roiRegion.x.upperBound)
            let overlapY0 = max(tile.region.y.lowerBound, roiRegion.y.lowerBound)
            let overlapY1 = min(tile.region.y.upperBound, roiRegion.y.upperBound)
            let localXRange = (overlapX0 - tile.region.x.lowerBound)..<(overlapX1 - tile.region.x.lowerBound)
            let localYRange = (overlapY0 - tile.region.y.lowerBound)..<(overlapY1 - tile.region.y.lowerBound)
            let isSubTileXY = K == 0
                && (localXRange.count < tile.width || localYRange.count < tile.height)

            let decodedZOffset: Int
            let decodedXOffset: Int
            let decodedYOffset: Int
            let decodedStrideW: Int
            let decodedStrideH: Int

            let tStartX = tileX0
            let tStartY = tileY0
            let tStartZ = tile.region.z.lowerBound

            let rStartX = reducedX0
            let rStartY = reducedY0
            let rStartZ = roiRegion.z.lowerBound

            if useExactIntegerPath {
                let reconstructedPerCompInt: [[Int64]]
                do {
                    if K == 0
                        && JP3DSliceStackCodec.isSliceStackTile(parsedTile.data)
                        && (localZEnd - localZStart < tile.depth || isSubTileXY) {
                        let sliceCodec = JP3DSliceStackCodec()
                        reconstructedPerCompInt = try sliceCodec.decodeTileInteger(
                            parsedTile.data,
                            expectedComponents: siz.componentCount,
                            expectedWidth: tile.width,
                            expectedHeight: tile.height,
                            expectedDepth: tile.depth,
                            maxQualityLayers: maxQualityLayers,
                            resolutionLevel: 0,
                            zRange: localZStart..<localZEnd,
                            xyROI: isSubTileXY ? (x: localXRange, y: localYRange) : nil,
                            limits: workerLimits ?? .default,
                            executionPolicy: executionPolicy,
                            workspace: decodeWorkspace
                        )
                        decodedZOffset = localZStart
                        decodedXOffset = isSubTileXY ? localXRange.lowerBound : 0
                        decodedYOffset = isSubTileXY ? localYRange.lowerBound : 0
                        decodedStrideW = isSubTileXY ? max(1, localXRange.count) : tileW
                        decodedStrideH = isSubTileXY ? max(1, localYRange.count) : tileH
                    } else {
                        let (samples, wasTrunc, usedAccel) = try JP3DDecoder.decodeTilePayloadIntegerWithStatusStatic(
                            parsedTile.data,
                            tile: tile,
                            tileIndex: parsedTile.tileIndex,
                            componentCount: siz.componentCount,
                            maxQualityLayers: maxQualityLayers,
                            resolutionLevel: K,
                            normativeContext: normativeContext,
                            limits: workerLimits,
                            executionPolicy: executionPolicy,
                            workspace: decodeWorkspace,
                            work: work
                        )
                        if usedAccel { anyAccelerated = true }
                        reconstructedPerCompInt = samples
                        if wasTrunc {
                            warnings.append("Tile \(parsedTile.tileIndex) packet stream truncated")
                        }
                        decodedZOffset = 0
                        decodedXOffset = 0
                        decodedYOffset = 0
                        decodedStrideW = tileW
                        decodedStrideH = tileH
                    }
                } catch {
                    if error is CancellationError { throw error }
                    if let ce = error as? CodecError, ce.category == .resourceLimitExceeded { throw ce }
                    if configuration.tolerateErrors {
                        warnings.append("Tile \(parsedTile.tileIndex) decode failed: \(error)")
                        continue
                    }
                    throw error
                }

                let zLoopStart = decodedZOffset
                let zLoopEnd = (decodedZOffset > 0) ? localZEnd : tileD
                for comp in 0..<siz.componentCount {
                    guard comp < reconstructedPerCompInt.count else { continue }
                    let reconstructed = reconstructedPerCompInt[comp]
                    for z in zLoopStart..<zLoopEnd {
                        let volZ = tStartZ + z
                        let roiZ = volZ - rStartZ
                        guard roiZ >= 0 && roiZ < outD else { continue }
                        let localBufZ = z - decodedZOffset

                        let yLoopStart = decodedYOffset
                        let yLoopEnd = decodedYOffset + decodedStrideH
                        for y in yLoopStart..<yLoopEnd {
                            let volY = tStartY + y
                            let roiY = volY - rStartY
                            guard roiY >= 0 && roiY < outH else { continue }
                            let localBufY = y - decodedYOffset

                            let xLoopStart = decodedXOffset
                            let xLoopEnd = decodedXOffset + decodedStrideW
                            for x in xLoopStart..<xLoopEnd {
                                let volX = tStartX + x
                                let roiX = volX - rStartX
                                guard roiX >= 0 && roiX < outW else { continue }
                                let localBufX = x - decodedXOffset

                                let srcIdx = localBufZ * decodedStrideW * decodedStrideH
                                    + localBufY * decodedStrideW + localBufX
                                let dstIdx = roiZ * outW * outH + roiY * outW + roiX
                                if srcIdx < reconstructed.count && dstIdx < outVoxels {
                                    intComponentBuffers[comp][dstIdx] = reconstructed[srcIdx]
                                }
                            }
                        }
                    }
                }
            } else {
                let reconstructedPerComp: [[Float]]
                do {
                    if K == 0
                        && JP3DSliceStackCodec.isSliceStackTile(parsedTile.data)
                        && (localZEnd - localZStart < tile.depth || isSubTileXY) {
                        let sliceCodec = JP3DSliceStackCodec()
                        reconstructedPerComp = try sliceCodec.decodeTile(
                            parsedTile.data,
                            expectedComponents: siz.componentCount,
                            expectedWidth: tile.width,
                            expectedHeight: tile.height,
                            expectedDepth: tile.depth,
                            maxQualityLayers: maxQualityLayers,
                            resolutionLevel: 0,
                            zRange: localZStart..<localZEnd,
                            xyROI: isSubTileXY ? (x: localXRange, y: localYRange) : nil,
                            limits: workerLimits ?? .default,
                            executionPolicy: executionPolicy,
                            workspace: decodeWorkspace
                        )
                        decodedZOffset = localZStart
                        decodedXOffset = isSubTileXY ? localXRange.lowerBound : 0
                        decodedYOffset = isSubTileXY ? localYRange.lowerBound : 0
                        decodedStrideW = isSubTileXY ? max(1, localXRange.count) : tileW
                        decodedStrideH = isSubTileXY ? max(1, localYRange.count) : tileH
                    } else {
                        reconstructedPerComp = try await JP3DDecoder.decodeTilePayloadStatic(
                            parsedTile.data,
                            tile: tile,
                            componentCount: siz.componentCount,
                            tileW: tileW,
                            tileH: tileH,
                            tileD: tileD,
                            isLossless: cod.isLossless,
                            transformConfig: transformConfig,
                            maxQualityLayers: maxQualityLayers,
                            resolutionLevel: K,
                            limits: workerLimits,
                            executionPolicy: executionPolicy,
                            workspace: decodeWorkspace
                        )
                        decodedZOffset = 0
                        decodedXOffset = 0
                        decodedYOffset = 0
                        decodedStrideW = tileW
                        decodedStrideH = tileH
                    }
                } catch {
                    if error is CancellationError { throw error }
                    if let ce = error as? CodecError, ce.category == .resourceLimitExceeded { throw ce }
                    if configuration.tolerateErrors {
                        warnings.append("Tile \(parsedTile.tileIndex) decode failed: \(error)")
                        continue
                    }
                    throw error
                }

                let zLoopStart = decodedZOffset
                let zLoopEnd = (decodedZOffset > 0) ? localZEnd : tileD
                for comp in 0..<siz.componentCount {
                    guard comp < reconstructedPerComp.count else { continue }
                    let reconstructed = reconstructedPerComp[comp]
                    for z in zLoopStart..<zLoopEnd {
                        let volZ = tStartZ + z
                        let roiZ = volZ - rStartZ
                        guard roiZ >= 0 && roiZ < outD else { continue }
                        let localBufZ = z - decodedZOffset

                        let yLoopStart = decodedYOffset
                        let yLoopEnd = decodedYOffset + decodedStrideH
                        for y in yLoopStart..<yLoopEnd {
                            let volY = tStartY + y
                            let roiY = volY - rStartY
                            guard roiY >= 0 && roiY < outH else { continue }
                            let localBufY = y - decodedYOffset

                            let xLoopStart = decodedXOffset
                            let xLoopEnd = decodedXOffset + decodedStrideW
                            for x in xLoopStart..<xLoopEnd {
                                let volX = tStartX + x
                                let roiX = volX - rStartX
                                guard roiX >= 0 && roiX < outW else { continue }
                                let localBufX = x - decodedXOffset

                                let srcIdx = localBufZ * decodedStrideW * decodedStrideH
                                    + localBufY * decodedStrideW + localBufX
                                let dstIdx = roiZ * outW * outH + roiY * outW + roiX
                                if srcIdx < reconstructed.count && dstIdx < outVoxels {
                                    componentBuffers[comp][dstIdx] = reconstructed[srcIdx]
                                }
                            }
                        }
                    }
                }
            }

            tilesDecoded += 1
            let prog = Double(tilesDecoded) / Double(max(1, intersectingIndices.count))
            reportProgress(
                .tileReconstruction,
                stageProgress: prog,
                tilesDone: tilesDecoded,
                tilesTotal: intersectingIndices.count
            )
        }

        try work.check()
        reportProgress(.volumeAssembly, stageProgress: 0.5, tilesDone: tilesDecoded, tilesTotal: intersectingIndices.count)

        for comp in 0..<logicalCompCount {
            let compBytes = (outW * outH * outD) * ((codestream.logicalBitDepth(forComponent: comp) + 7) / 8)
            StorageTelemetry.recordPixelAllocation(bytes: compBytes)
        }
        let components: [J2KVolumeComponent]
        if useExactIntegerPath {
            if let split = codestream.part2BitSplit,
               intComponentBuffers.count == split.logicalComponentCount * 2 {
                components = jp3dAssemblePart2BitSplitVolumeComponentsInteger(
                    wireBuffers: &intComponentBuffers,
                    split: split,
                    width: outW,
                    height: outH,
                    depth: outD
                )
            } else {
                components = jp3dAssembleVolumeComponentsInteger(
                    buffers: intComponentBuffers,
                    width: outW, height: outH, depth: outD,
                    bitDepth: siz.componentBitDepths.first ?? siz.bitDepth,
                    signed: siz.componentSigned.first ?? siz.signed,
                    componentBitDepths: siz.componentBitDepths,
                    componentSigned: siz.componentSigned
                )
            }
        } else {
            components = assembleROIComponents(
                buffers: componentBuffers,
                width: outW, height: outH, depth: outD,
                bitDepth: siz.bitDepth, signed: siz.signed
            )
        }
        let restoredGeometry: JP3DVolumeGeometry? = (metadataPolicy == .preserve) ? codestream.geometry : nil
        let outSpacingX = restoredGeometry.map { $0.spacingX > 0 ? scalbn($0.spacingX, K) : 0 } ?? 0
        let outSpacingY = restoredGeometry.map { $0.spacingY > 0 ? scalbn($0.spacingY, K) : 0 } ?? 0
        let outSpacingZ = restoredGeometry?.spacingZ ?? 0
        let outOriginX = restoredGeometry.map { $0.originX + ($0.spacingX > 0 ? Double(reducedX0) * outSpacingX : 0) } ?? 0
        let outOriginY = restoredGeometry.map { $0.originY + ($0.spacingY > 0 ? Double(reducedY0) * outSpacingY : 0) } ?? 0
        let outOriginZ = restoredGeometry.map { $0.originZ + ($0.spacingZ > 0 ? Double(clampedZLower) * $0.spacingZ : 0) } ?? 0

        let roiVolume = J2KVolume(
            width: outW, height: outH, depth: outD,
            components: components,
            spacingX: outSpacingX,
            spacingY: outSpacingY,
            spacingZ: outSpacingZ,
            originX: outOriginX,
            originY: outOriginY,
            originZ: outOriginZ
        )
        try roiVolume.validate()

        try work.check()
        reportProgress(.volumeAssembly, stageProgress: 1.0, tilesDone: tilesDecoded, tilesTotal: intersectingIndices.count)

        return JP3DROIDecoderResult(
            volume: roiVolume,
            decodedRegion: roiRegion,
            isFullVolume: false,
            tilesSkipped: tilesSkipped,
            tilesDecoded: tilesDecoded,
            warnings: warnings,
            peakWorkspaceBytes: max(computedPeakROIWorkspace, try jp3dDecodeAdd(ws10, decodeWorkspace.peak)),
            commentCount: codestream.comments.count,
            commentPayloadBytes: codestream.commentPayloadBytes,
            hadVolumeGeometry: codestream.geometry != nil,
            usedAcceleratedKernel: anyAccelerated
        )
    }

    // MARK: - Private Helpers

    private func assembleROIComponents(
        buffers: [[Float]],
        width: Int, height: Int, depth: Int,
        bitDepth: Int, signed: Bool
    ) -> [J2KVolumeComponent] {
        jp3dAssembleVolumeComponentsFloat(
            buffers: buffers,
            width: width, height: height, depth: depth,
            bitDepth: bitDepth, signed: signed
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
