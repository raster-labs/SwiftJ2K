// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DTranscoder.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

// MARK: - JP3DTranscodingDirection

/// The direction of a JP3D transcoding operation.
public enum JP3DTranscodingDirection: Sendable, Equatable {
    /// Transcode from standard JP3D (EBCOT) to HTJ2K JP3D (FBCOT).
    case standardToHTJ2K

    /// Transcode from HTJ2K JP3D (FBCOT) to standard JP3D (EBCOT).
    case htj2kToStandard
}

// MARK: - JP3DTranscoderConfiguration

/// Configuration for a JP3D transcoding operation.
public struct JP3DTranscoderConfiguration: Sendable, Equatable {
    /// The transcoding direction.
    public let direction: JP3DTranscodingDirection

    /// HTJ2K configuration to use when transcoding towards HTJ2K.
    public let htj2kConfiguration: JP3DHTJ2KConfiguration

    /// Whether to verify bit-exact round-trip after transcoding.
    public let verifyRoundTrip: Bool

    /// Creates a new transcoder configuration.
    public init(
        direction: JP3DTranscodingDirection = .standardToHTJ2K,
        htj2kConfiguration: JP3DHTJ2KConfiguration = .default,
        verifyRoundTrip: Bool = false
    ) {
        self.direction = direction
        self.htj2kConfiguration = htj2kConfiguration
        self.verifyRoundTrip = verifyRoundTrip
    }

    /// Default forward transcoding configuration (standard -> HTJ2K).
    public static let forwardDefault = JP3DTranscoderConfiguration()

    /// Default reverse transcoding configuration (HTJ2K -> standard).
    public static let reverseDefault = JP3DTranscoderConfiguration(direction: .htj2kToStandard)
}

// MARK: - JP3DTranscoderResult

/// Result of a JP3D transcoding operation.
public struct JP3DTranscoderResult: Sendable {
    /// The transcoded codestream.
    public let data: Data

    /// Number of tiles transcoded.
    public let tilesTranscoded: Int

    /// Transcoding direction that was used.
    public let direction: JP3DTranscodingDirection

    /// Whether quality layers and progression order were preserved.
    public let metadataPreserved: Bool

    /// Warnings encountered during transcoding.
    public let warnings: [String]

    internal let peakWorkspaceBytes: Int
    internal let usedFullRoundTripCopy: Bool
    internal let roundTripPixelBytes: Int
    internal let roundTripComponentCount: Int
    internal let sourceCommentCount: Int
    internal let sourceCommentBytes: Int
    internal let sourceHadVolumeGeometry: Bool
    package let usedAcceleratedKernel: Bool

    public init(
        data: Data,
        tilesTranscoded: Int,
        direction: JP3DTranscodingDirection,
        metadataPreserved: Bool,
        warnings: [String] = []
    ) {
        self.data = data
        self.tilesTranscoded = tilesTranscoded
        self.direction = direction
        self.metadataPreserved = metadataPreserved
        self.warnings = warnings
        self.peakWorkspaceBytes = data.count
        self.usedFullRoundTripCopy = false
        self.roundTripPixelBytes = 0
        self.roundTripComponentCount = 0
        self.sourceCommentCount = 0
        self.sourceCommentBytes = 0
        self.sourceHadVolumeGeometry = false
        self.usedAcceleratedKernel = false
    }

    internal init(
        data: Data,
        tilesTranscoded: Int,
        direction: JP3DTranscodingDirection,
        metadataPreserved: Bool,
        warnings: [String],
        peakWorkspaceBytes: Int,
        usedFullRoundTripCopy: Bool = false,
        roundTripPixelBytes: Int = 0,
        roundTripComponentCount: Int = 0,
        sourceCommentCount: Int = 0,
        sourceCommentBytes: Int = 0,
        sourceHadVolumeGeometry: Bool = false,
        usedAcceleratedKernel: Bool = false
    ) {
        self.data = data
        self.tilesTranscoded = tilesTranscoded
        self.direction = direction
        self.metadataPreserved = metadataPreserved
        self.warnings = warnings
        self.peakWorkspaceBytes = peakWorkspaceBytes
        self.usedFullRoundTripCopy = usedFullRoundTripCopy
        self.roundTripPixelBytes = roundTripPixelBytes
        self.roundTripComponentCount = roundTripComponentCount
        self.sourceCommentCount = sourceCommentCount
        self.sourceCommentBytes = sourceCommentBytes
        self.sourceHadVolumeGeometry = sourceHadVolumeGeometry
        self.usedAcceleratedKernel = usedAcceleratedKernel
    }
}

// MARK: - JP3DTranscoder

/// Transcodes JP3D codestreams between standard (EBCOT) and HTJ2K (FBCOT) encodings.
public actor JP3DTranscoder {
    /// Creates a new transcoder.
    public init() {}

    /// Transcodes a JP3D codestream.
    public func transcode(
        _ sourceData: Data,
        configuration: JP3DTranscoderConfiguration = .forwardDefault
    ) async throws -> JP3DTranscoderResult {
        try await transcodeAdmitted(
            sourceData,
            configuration: configuration,
            limits: nil,
            executionPolicy: .automatic,
            work: VolumeWorkGuard(limits: nil)
        )
    }

    internal func transcodeAdmitted(
        _ sourceData: Data,
        configuration: JP3DTranscoderConfiguration = .forwardDefault,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        copyPolicy: CopyPolicy = .allowCopy,
        metadataPolicy: MetadataPolicy = .preserve,
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        try work.check()
        _ = try AccelerationRuntime.resolve(executionPolicy)
        if let limits {
            guard sourceData.count <= limits.maximumCompressedBytes,
                  sourceData.count <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Source codestream size \(sourceData.count) exceeds compressed or memory limit"
                )
            }
        }

        let parser = JP3DCodestreamParser()
        let source = try parser.parse(sourceData, limits: limits, work: work, copyTilePayloads: true)

        let (estimatedWorkspace, eOv) = source.retainedTileBytes.addingReportingOverflow(max(64, sourceData.count))
        guard !eOv else {
            throw CodecError(.resourceLimitExceeded, "Volume transcoding workspace overflows Int")
        }
        if let limits {
            let maxDim = limits.maximumDimension
            guard source.siz.width <= maxDim,
                  source.siz.height <= maxDim,
                  source.siz.depth <= maxDim else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volume dimensions exceed maximumDimension \(maxDim)"
                )
            }
            guard source.siz.depth <= limits.maximumFrames else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volume depth \(source.siz.depth) exceeds maximumFrames \(limits.maximumFrames)"
                )
            }
            let (wh, o1) = source.siz.width.multipliedReportingOverflow(by: source.siz.height)
            let (vox, o2) = wh.multipliedReportingOverflow(by: source.siz.depth)
            guard !o1, !o2, vox <= limits.maximumPixels else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volume voxel count exceeds maximumPixels \(limits.maximumPixels)"
                )
            }
            let (liveMem, mOv) = sourceData.count.addingReportingOverflow(estimatedWorkspace)
            guard !mOv,
                  estimatedWorkspace <= limits.maximumWorkspaceBytes,
                  liveMem <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volume transcoding workspace exceeds resource limits"
                )
            }
        }

        StorageTelemetry.recordStage("volume-transcode-workspace", bytes: estimatedWorkspace)
        StorageTelemetry.recordWorkspaceAllocation(bytes: estimatedWorkspace)

        let preservedComments: [JP3DCommentSegment] = (metadataPolicy == .preserve) ? source.comments : []

        if !source.tiles.isEmpty && source.tiles.allSatisfy({ JP3DLosslessIntegerTileCodec.hasMagic($0.data) }) {
            let toHTJ2K = configuration.direction == .standardToHTJ2K
            var transcodedTiles: [Data] = []
            transcodedTiles.reserveCapacity(source.tiles.count)
            for parsedTile in source.tiles {
                try work.check()
                let tileData = try JP3DLosslessIntegerTileCodec.transcodeTile(
                    parsedTile.data,
                    toHTJ2K: toHTJ2K
                )
                transcodedTiles.append(tileData)
            }
            let builder = JP3DCodestreamBuilder()
            let codestream = builder.build(
                tileData: transcodedTiles,
                width: source.siz.width,
                height: source.siz.height,
                depth: source.siz.depth,
                components: source.siz.componentCount,
                bitDepth: source.siz.bitDepth,
                signed: source.siz.signed,
                levelsX: source.cod.levelsX,
                levelsY: source.cod.levelsY,
                levelsZ: source.cod.levelsZ,
                tileSizeX: source.siz.tileSizeX,
                tileSizeY: source.siz.tileSizeY,
                tileSizeZ: source.siz.tileSizeZ,
                isLossless: source.cod.isLossless,
                htj2kConfiguration: toHTJ2K ? configuration.htj2kConfiguration : nil,
                comments: preservedComments
            )
            if let limits {
                let (liveMem, mOv) = sourceData.count.addingReportingOverflow(codestream.count)
                guard !mOv,
                      codestream.count <= limits.maximumCompressedBytes,
                      liveMem <= limits.maximumMemoryBytes else {
                    throw CodecError(
                        .resourceLimitExceeded,
                        "Transcoded volume codestream exceeds compressed or memory limit"
                    )
                }
            }
            if configuration.verifyRoundTrip {
                let origVol = try await JP3DDecoder().decodeAdmitted(
                    sourceData, limits: limits, executionPolicy: executionPolicy, metadataPolicy: metadataPolicy, work: work
                ).volume
                let transVol = try await JP3DDecoder().decodeAdmitted(
                    codestream, limits: limits, executionPolicy: executionPolicy, metadataPolicy: metadataPolicy, work: work
                ).volume
                for c in 0..<origVol.componentCount {
                    if origVol.components[c].data != transVol.components[c].data {
                        throw J2KError.encodingError(
                            "Integer lossless tile round-trip verification failed on component \(c)"
                        )
                    }
                }
            }
            let measuredPeak = max(estimatedWorkspace, source.retainedTileBytes + codestream.count)
            return JP3DTranscoderResult(
                data: codestream,
                tilesTranscoded: transcodedTiles.count,
                direction: configuration.direction,
                metadataPreserved: metadataPolicy == .preserve,
                warnings: [],
                peakWorkspaceBytes: measuredPeak,
                sourceCommentCount: source.comments.count,
                sourceCommentBytes: source.commentPayloadBytes,
                sourceHadVolumeGeometry: source.geometry != nil
            )
        }

        if source.tiles.contains(where: { JP3DSliceStackCodec.hasMagic($0.data) }) {
            return try await transcodeSliceStack(
                sourceData: sourceData,
                source: source,
                configuration: configuration,
                limits: limits,
                executionPolicy: executionPolicy,
                copyPolicy: copyPolicy,
                metadataPolicy: metadataPolicy,
                estimatedWorkspace: estimatedWorkspace,
                work: work
            )
        }

        if source.hasNSIMarker {
            return try await transcodeNormative(
                sourceData: sourceData,
                source: source,
                configuration: configuration,
                limits: limits,
                executionPolicy: executionPolicy,
                copyPolicy: copyPolicy,
                metadataPolicy: metadataPolicy,
                estimatedWorkspace: estimatedWorkspace,
                work: work
            )
        }

        let builder = JP3DCodestreamBuilder()
        var warnings: [String] = []
        var transcodedTiles: [Data] = []
        transcodedTiles.reserveCapacity(source.tiles.count)

        for parsedTile in source.tiles {
            try work.check()
            let targetTileData: Data

            switch configuration.direction {
            case .standardToHTJ2K:
                targetTileData = try transcodeToHTJ2K(
                    tileData: parsedTile.data,
                    configuration: configuration.htj2kConfiguration,
                    siz: source.siz,
                    cod: source.cod,
                    tileIndex: parsedTile.tileIndex,
                    warnings: &warnings
                )

            case .htj2kToStandard:
                targetTileData = try transcodeToStandard(
                    tileData: parsedTile.data,
                    siz: source.siz,
                    cod: source.cod,
                    tileIndex: parsedTile.tileIndex,
                    warnings: &warnings
                )
            }

            if configuration.verifyRoundTrip {
                try verifyRoundTrip(
                    original: parsedTile.data,
                    transcoded: targetTileData,
                    direction: configuration.direction,
                    tileIndex: parsedTile.tileIndex,
                    htj2kConfig: configuration.htj2kConfiguration,
                    siz: source.siz,
                    cod: source.cod
                )
            }

            transcodedTiles.append(targetTileData)
        }

        let outputIsHTJ2K = configuration.direction == .standardToHTJ2K

        let codestream = builder.build(
            tileData: transcodedTiles,
            width: source.siz.width,
            height: source.siz.height,
            depth: source.siz.depth,
            components: source.siz.componentCount,
            bitDepth: source.siz.bitDepth,
            signed: source.siz.signed,
            levelsX: source.cod.levelsX,
            levelsY: source.cod.levelsY,
            levelsZ: source.cod.levelsZ,
            tileSizeX: source.siz.tileSizeX,
            tileSizeY: source.siz.tileSizeY,
            tileSizeZ: source.siz.tileSizeZ,
            isLossless: source.cod.isLossless,
            htj2kConfiguration: outputIsHTJ2K ? configuration.htj2kConfiguration : nil,
            comments: preservedComments
        )
        if let limits {
            let (liveMem, mOv) = sourceData.count.addingReportingOverflow(codestream.count)
            guard !mOv,
                  codestream.count <= limits.maximumCompressedBytes,
                  liveMem <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Transcoded volume codestream exceeds compressed or memory limit"
                )
            }
        }

        let measuredPeak = max(estimatedWorkspace, source.retainedTileBytes + codestream.count)
        return JP3DTranscoderResult(
            data: codestream,
            tilesTranscoded: transcodedTiles.count,
            direction: configuration.direction,
            metadataPreserved: metadataPolicy == .preserve,
            warnings: warnings,
            peakWorkspaceBytes: measuredPeak,
            sourceCommentCount: source.comments.count,
            sourceCommentBytes: source.commentPayloadBytes,
            sourceHadVolumeGeometry: source.geometry != nil
        )
    }

    // MARK: - Normative Wavelet-Domain Transcoding Path (ITU-T T.809 <-> Reconciled T.814 HT-in-JP3D)

    private func transcodeNormative(
        sourceData: Data,
        source: JP3DParsedCodestream,
        configuration: JP3DTranscoderConfiguration,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        copyPolicy: CopyPolicy,
        metadataPolicy: MetadataPolicy,
        estimatedWorkspace: Int,
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        guard source.isFullyReversible else {
            return try await transcodeViaFullRoundTrip(
                sourceData: sourceData,
                source: source,
                configuration: configuration,
                limits: limits,
                executionPolicy: executionPolicy,
                copyPolicy: copyPolicy,
                metadataPolicy: metadataPolicy,
                estimatedWorkspace: estimatedWorkspace,
                work: work
            )
        }

        let resolvedExec = try AccelerationRuntime.resolve(executionPolicy)
        let useAccelerated = (resolvedExec.backend == .accelerated)
        let toHTJ2K = configuration.direction == .standardToHTJ2K
        let preservedComments: [JP3DCommentSegment] = (metadataPolicy == .preserve) ? source.comments : []
        let (retainedSourceWorkspace, sourceWorkspaceOverflow) = source.retainedTileBytes.addingReportingOverflow(source.commentPayloadBytes)
        guard !sourceWorkspaceOverflow else {
            throw CodecError(.resourceLimitExceeded, "Retained transcode source workspace overflows Int")
        }

        let maxBitDepth = max(source.siz.bitDepth, source.siz.componentBitDepths.max() ?? source.siz.bitDepth)
        let requiresMixed = toHTJ2K && (configuration.htj2kConfiguration.allowMixedTiles || maxBitDepth > 26)
        let targetCBStyle: UInt8 = toHTJ2K ? (requiresMixed ? 0xC0 : 0x40) : 0x00
        let targetXCB = toHTJ2K ? 6 : 5
        let targetYCB = toHTJ2K ? 6 : 5
        let targetZCB = toHTJ2K ? 0 : 4

        func makeTargetCOD(from base: JP3DCODInfo) -> JP3DCODInfo {
            JP3DCODInfo(
                levelsX: base.levelsX,
                levelsY: base.levelsY,
                levelsZ: base.levelsZ,
                isLossless: true,
                codeBlockStyle: targetCBStyle,
                scod: base.scod & ~0x01,
                progressionOrderByte: base.progressionOrderByte,
                numLayers: base.numLayers,
                multipleComponentTransform: base.multipleComponentTransform,
                codeBlockWidthExponent: targetXCB,
                codeBlockHeightExponent: targetYCB,
                codeBlockDepthExponent: targetZCB,
                dwtX: base.dwtX,
                dwtY: base.dwtY,
                dwtZ: base.dwtZ,
                precinctSizes: []
            )
        }

        let targetCOD = makeTargetCOD(from: source.cod)
        let targetMainCOC = source.mainCOC.mapValues { makeTargetCOD(from: $0) }
        var targetTileOverrides: [Int: JP3DTileHeaderOverrides] = [:]
        for (tIdx, ov) in source.tileOverrides {
            var mapped = ov
            if let tc = ov.cod { mapped.cod = makeTargetCOD(from: tc) }
            mapped.coc = ov.coc.mapValues { makeTargetCOD(from: $0) }
            targetTileOverrides[tIdx] = mapped
        }

        let targetHTConfig: JP3DHTJ2KConfiguration?
        if toHTJ2K {
            let maxTargetLayers = max(
                targetCOD.numLayers,
                max(
                    targetMainCOC.values.map(\.numLayers).max() ?? 1,
                    targetTileOverrides.values.compactMap { $0.cod?.numLayers }.max() ?? 1
                )
            )
            targetHTConfig = JP3DHTJ2KConfiguration(
                blockMode: requiresMixed ? .adaptive : configuration.htj2kConfiguration.blockMode,
                passCount: max(configuration.htj2kConfiguration.passCount, maxTargetLayers >= 2 ? 4 : 1),
                cleanupPassEnabled: configuration.htj2kConfiguration.cleanupPassEnabled,
                allowMixedTiles: requiresMixed
            )
        } else {
            targetHTConfig = nil
        }

        let tilingConfig = JP3DTilingConfiguration(
            tileSizeX: source.siz.tileSizeX,
            tileSizeY: source.siz.tileSizeY,
            tileSizeZ: source.siz.tileSizeZ
        )
        let allTiles = tilingConfig.allTiles(
            volumeWidth: source.siz.width,
            volumeHeight: source.siz.height,
            volumeDepth: source.siz.depth
        )

        var transcodedTiles: [Data] = []
        transcodedTiles.reserveCapacity(source.tiles.count)
        var retainedOutputBytes = 0
        var peakWaveletWorkspace = estimatedWorkspace
        var anyAccelerated = false
        let compCount = source.siz.componentCount

        for parsedTile in source.tiles {
            try work.check()
            guard parsedTile.tileIndex >= 0, parsedTile.tileIndex < allTiles.count else {
                throw CodecError(.malformedInput, "Tile index \(parsedTile.tileIndex) out of bounds in JP3D codestream.")
            }
            let tIdx = parsedTile.tileIndex
            let tile = allTiles[tIdx]
            let (outerWorkspace, wsOverflow) = retainedSourceWorkspace.addingReportingOverflow(retainedOutputBytes)
            let (outerMemory, memOverflow) = sourceData.count.addingReportingOverflow(outerWorkspace)
            guard !wsOverflow, !memOverflow else {
                throw CodecError(.resourceLimitExceeded, "Retained transcode buffers overflow Int")
            }
            let tileLimits = try (limits ?? .default).reserving(
                workspaceBytes: outerWorkspace,
                memoryBytes: outerMemory
            )
            let (voxXY, vOv1) = tile.width.multipliedReportingOverflow(by: tile.height)
            let (voxXYZ, vOv2) = voxXY.multipliedReportingOverflow(by: tile.depth)
            let (planeBytes, vOv3) = voxXYZ.multipliedReportingOverflow(by: MemoryLayout<Int64>.stride * 2)
            guard !vOv1, !vOv2, !vOv3,
                  planeBytes <= tileLimits.maximumWorkspaceBytes,
                  planeBytes <= tileLimits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Wavelet-domain 3D tile transcoding workspace exceeds resource limits")
            }

            let srcTileCOD = source.effectiveTileCOD(tileIndex: tIdx)
            let dstTileCOD = makeTargetCOD(from: srcTileCOD)
            let srcCompCODs = (0..<compCount).map { source.effectiveCOD(tileIndex: tIdx, component: $0) }
            let dstCompCODs = srcCompCODs.map { makeTargetCOD(from: $0) }
            let srcCompQCDs = (0..<compCount).map { source.effectiveQCD(tileIndex: tIdx, component: $0) }
            let srcCompROIs = (0..<compCount).map { source.effectiveROIShift(tileIndex: tIdx, component: $0) }

            let baseWsCap = min(tileLimits.maximumWorkspaceBytes, tileLimits.maximumMemoryBytes)
            var geomBytes = 0
            for c in 0..<compCount {
                let remSrc = max(0, baseWsCap - planeBytes - geomBytes)
                let fpSrc = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: tile.region.x.lowerBound, x1: tile.region.x.upperBound,
                    y0: tile.region.y.lowerBound, y1: tile.region.y.upperBound,
                    z0: tile.region.z.lowerBound, z1: tile.region.z.upperBound,
                    cod: srcCompCODs[c],
                    maximumWorkspaceBytes: remSrc,
                    includeDecodeState: true
                )
                let (g1, o1) = geomBytes.addingReportingOverflow(fpSrc.totalBytes)
                guard !o1, planeBytes + g1 <= baseWsCap else {
                    throw CodecError(.resourceLimitExceeded, "Wavelet-domain 3D source geometry workspace exceeds resource limits")
                }
                let remDst = max(0, baseWsCap - planeBytes - g1)
                let fpDst = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: tile.region.x.lowerBound, x1: tile.region.x.upperBound,
                    y0: tile.region.y.lowerBound, y1: tile.region.y.upperBound,
                    z0: tile.region.z.lowerBound, z1: tile.region.z.upperBound,
                    cod: dstCompCODs[c],
                    maximumWorkspaceBytes: remDst,
                    includeEncodeState: true
                )
                let (g2, o2) = g1.addingReportingOverflow(fpDst.totalBytes)
                guard !o2, planeBytes + g2 <= baseWsCap else {
                    throw CodecError(.resourceLimitExceeded, "Wavelet-domain 3D target geometry workspace exceeds resource limits")
                }
                geomBytes = g2
            }

            let tileOutCap = min(
                max(0, (limits ?? .default).maximumCompressedBytes - retainedOutputBytes),
                max(0, baseWsCap - planeBytes - geomBytes)
            )
            var admittedTileOutBytes = 0

            let tileResult = try JP3DNormativeTileCodec.transcodeTileWaveletDomain(
                tileData: parsedTile.data,
                siz: source.siz,
                sourceCOD: srcTileCOD,
                targetCOD: dstTileCOD,
                qcd: source.qcd,
                sourceComponentCODs: srcCompCODs,
                targetComponentCODs: dstCompCODs,
                componentQCDs: srcCompQCDs,
                roiShifts: srcCompROIs,
                allowSourceMultiHT: source.allowsMultiHTSets,
                htConfiguration: targetHTConfig,
                x0: tile.region.x.lowerBound,
                x1: tile.region.x.upperBound,
                y0: tile.region.y.lowerBound,
                y1: tile.region.y.upperBound,
                z0: tile.region.z.lowerBound,
                z1: tile.region.z.upperBound,
                useAccelerated: useAccelerated,
                remainingOutputLimit: {
                    max(0, tileOutCap - admittedTileOutBytes)
                },
                admitEncodedBytes: { delta in
                    guard delta > 0 else { return }
                    let (nextOut, ov) = admittedTileOutBytes.addingReportingOverflow(delta)
                    guard !ov, nextOut <= tileOutCap else {
                        throw CodecError(.resourceLimitExceeded, "Wavelet-domain 3D transcode output exceeds resource limits")
                    }
                    admittedTileOutBytes = nextOut
                },
                cancellation: { try work.check() }
            )
            if tileResult.usedAccelerated { anyAccelerated = true }
            let (tileInnerPeak, innerOv) = tileResult.peakWorkspaceBytes.addingReportingOverflow(geomBytes)
            let (tilePeak, peakOverflow) = outerWorkspace.addingReportingOverflow(tileInnerPeak)
            let (nextOutputBytes, outputOverflow) = retainedOutputBytes.addingReportingOverflow(tileResult.data.count)
            guard !innerOv, !peakOverflow, !outputOverflow,
                  tileInnerPeak <= tileLimits.maximumWorkspaceBytes,
                  tileResult.data.count <= tileLimits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Wavelet-domain 3D transcode output exceeds resource limits")
            }
            peakWaveletWorkspace = max(peakWaveletWorkspace, tilePeak)
            retainedOutputBytes = nextOutputBytes
            transcodedTiles.append(tileResult.data)
        }

        let publication = try JP3DCodestreamBuilder().buildTranscodePublication(
            sourceDataBytes: sourceData.count,
            source: source,
            tileData: transcodedTiles,
            htj2kConfiguration: targetHTConfig,
            comments: preservedComments,
            limits: limits ?? .default,
            codOverride: targetCOD,
            qcdOverride: source.qcd,
            roiShifts: source.roiShifts,
            mainCOC: targetMainCOC,
            mainQCC: source.mainQCC,
            mainRGNAllComponents: source.mainRGNAllComponents,
            mainRGNByComponent: source.mainRGNByComponent,
            tileOverrides: targetTileOverrides,
            part2BitSplit: source.part2BitSplit
        )
        let codestream = publication.data
        let measuredPeak = max(peakWaveletWorkspace, publication.peakWorkspaceBytes)

        if configuration.verifyRoundTrip {
            let origVol = try await JP3DDecoder().decodeAdmitted(
                sourceData,
                limits: limits,
                executionPolicy: executionPolicy,
                metadataPolicy: metadataPolicy,
                work: work
            ).volume
            let transVol = try await JP3DDecoder().decodeAdmitted(
                codestream,
                limits: limits,
                executionPolicy: executionPolicy,
                metadataPolicy: metadataPolicy,
                work: work
            ).volume
            for c in 0..<origVol.componentCount {
                if origVol.components[c].data != transVol.components[c].data {
                    throw J2KError.encodingError(
                        "Normative wavelet-domain 3D round-trip verification failed on component \(c)"
                    )
                }
            }
        }

        return JP3DTranscoderResult(
            data: codestream,
            tilesTranscoded: transcodedTiles.count,
            direction: configuration.direction,
            metadataPreserved: metadataPolicy == .preserve,
            warnings: [],
            peakWorkspaceBytes: measuredPeak,
            sourceCommentCount: source.comments.count,
            sourceCommentBytes: source.commentPayloadBytes,
            sourceHadVolumeGeometry: source.geometry != nil,
            usedAcceleratedKernel: anyAccelerated
        )
    }

    // MARK: - Private Slice-Stack Transcode Path

    private func transcodeSliceStack(
        sourceData: Data,
        source: JP3DParsedCodestream,
        configuration: JP3DTranscoderConfiguration,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        copyPolicy: CopyPolicy,
        metadataPolicy: MetadataPolicy,
        estimatedWorkspace: Int,
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        let toHTJ2K = configuration.direction == .standardToHTJ2K
        let preservedComments: [JP3DCommentSegment] = (metadataPolicy == .preserve) ? source.comments : []
        let (retainedSourceWorkspace, sourceWorkspaceOverflow) = source.retainedTileBytes.addingReportingOverflow(source.commentPayloadBytes)
        guard !sourceWorkspaceOverflow else {
            throw CodecError(.resourceLimitExceeded, "Retained transcode source workspace overflows Int")
        }
        if source.cod.isLossless && source.tiles.allSatisfy({ JP3DSliceStackCodec.hasMagic($0.data) }) {
            do {
                var transcodedTiles: [Data] = []
                transcodedTiles.reserveCapacity(source.tiles.count)
                let sliceStackCodec = JP3DSliceStackCodec()
                var retainedOutputBytes = 0
                var peakSliceWorkspace = estimatedWorkspace
                for parsedTile in source.tiles {
                    try work.check()
                    let (outerWorkspace, wsOverflow) = retainedSourceWorkspace.addingReportingOverflow(retainedOutputBytes)
                    let (outerMemory, memOverflow) = sourceData.count.addingReportingOverflow(outerWorkspace)
                    guard !wsOverflow, !memOverflow else {
                        throw CodecError(.resourceLimitExceeded, "Retained transcode buffers overflow Int")
                    }
                    let tileLimits = try (limits ?? .default).reserving(
                        workspaceBytes: outerWorkspace, memoryBytes: outerMemory
                    )
                    let tileResult = try await sliceStackCodec.transcodeTile(
                        parsedTile.data,
                        toHTJ2K: toHTJ2K,
                        limits: tileLimits,
                        executionPolicy: executionPolicy
                    )
                    let (tilePeak, peakOverflow) = outerWorkspace.addingReportingOverflow(tileResult.peakWorkspaceBytes)
                    let (nextOutputBytes, outputOverflow) = retainedOutputBytes.addingReportingOverflow(tileResult.data.count)
                    guard !peakOverflow, !outputOverflow else {
                        throw CodecError(.resourceLimitExceeded, "Transcode workspace peak overflows Int")
                    }
                    peakSliceWorkspace = max(peakSliceWorkspace, tilePeak)
                    retainedOutputBytes = nextOutputBytes
                    transcodedTiles.append(tileResult.data)
                }

                let publication = try JP3DCodestreamBuilder().buildTranscodePublication(
                    sourceDataBytes: sourceData.count, source: source,
                    tileData: transcodedTiles,
                    htj2kConfiguration: toHTJ2K ? configuration.htj2kConfiguration : nil,
                    comments: preservedComments, limits: limits ?? .default
                )
                let codestream = publication.data
                let measuredPeak = max(peakSliceWorkspace, publication.peakWorkspaceBytes)

                if configuration.verifyRoundTrip {
                    let origVol = try await JP3DDecoder().decodeAdmitted(
                        sourceData, limits: limits, executionPolicy: executionPolicy, metadataPolicy: metadataPolicy, work: work
                    ).volume
                    let transVol = try await JP3DDecoder().decodeAdmitted(
                        codestream, limits: limits, executionPolicy: executionPolicy, metadataPolicy: metadataPolicy, work: work
                    ).volume
                    for c in 0..<origVol.componentCount {
                        if origVol.components[c].data != transVol.components[c].data {
                            throw J2KError.encodingError(
                                "Slice-stack round-trip verification failed on component \(c)"
                            )
                        }
                    }
                }

                return JP3DTranscoderResult(
                    data: codestream,
                    tilesTranscoded: transcodedTiles.count,
                    direction: configuration.direction,
                    metadataPreserved: metadataPolicy == .preserve,
                    warnings: [],
                    peakWorkspaceBytes: measuredPeak,
                    sourceCommentCount: source.comments.count,
                    sourceCommentBytes: source.commentPayloadBytes,
                    sourceHadVolumeGeometry: source.geometry != nil
                )
            } catch {
                if error is CancellationError { throw error }
                if let ce = error as? CodecError,
                   ce.category == .resourceLimitExceeded || ce.category == .backendUnavailable {
                    throw ce
                }
                // Fall back to full decode + re-encode when per-slice wavelet transcode is not applicable
                // (e.g., lossy sources or multi-layer unsupported options).
            }
        }

        return try await transcodeViaFullRoundTrip(
            sourceData: sourceData,
            source: source,
            configuration: configuration,
            limits: limits,
            executionPolicy: executionPolicy,
            copyPolicy: copyPolicy,
            metadataPolicy: metadataPolicy,
            estimatedWorkspace: estimatedWorkspace,
            work: work
        )
    }

    private func transcodeViaFullRoundTrip(
        sourceData: Data,
        source: JP3DParsedCodestream,
        configuration: JP3DTranscoderConfiguration,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        copyPolicy: CopyPolicy,
        metadataPolicy: MetadataPolicy,
        estimatedWorkspace: Int,
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        guard copyPolicy == .allowCopy else {
            throw CodecError(
                .incompatibleImageLayout,
                "Lossy volumetric transcoding fallback decodes and re-encodes intermediate J2KVolume buffers; pass copyPolicy: .allowCopy."
            )
        }
        // This parsed source remains live while the nested decoder parses its own
        // tile payloads. The shared sourceData is already counted by that decoder.
        let retainedWorkspace = try jp3dDecodeAdd(source.retainedTileBytes, source.commentPayloadBytes)
        let decodeLimits = try limits.map {
            try $0.reserving(workspaceBytes: retainedWorkspace, memoryBytes: retainedWorkspace)
        }
        let decoder = JP3DDecoder(configuration: JP3DDecoderConfiguration(
            tolerateErrors: false,
            parallelTileDecoding: (limits?.maximumWorkers ?? 8) > 1,
            maximumWorkers: limits?.maximumWorkers ?? 8
        ))
        let decoded = try await decoder.decodeAdmitted(
            sourceData,
            limits: decodeLimits,
            executionPolicy: executionPolicy,
            metadataPolicy: metadataPolicy,
            work: work
        )

        let targetMode: JP3DCompressionMode
        switch configuration.direction {
        case .standardToHTJ2K:
            targetMode = source.cod.isLossless ? .losslessHTJ2K : .lossyHTJ2K(psnr: 40)
        case .htj2kToStandard:
            targetMode = source.cod.isLossless ? .lossless : .lossy(psnr: 40)
        }

        let encoder = JP3DEncoder(configuration: JP3DEncoderConfiguration(
            compressionMode: targetMode,
            tiling: JP3DTilingConfiguration(
                tileSizeX: source.siz.tileSizeX,
                tileSizeY: source.siz.tileSizeY,
                tileSizeZ: source.siz.tileSizeZ
            ),
            progressionOrder: .lrcps,
            qualityLayers: 1,
            levelsX: source.cod.levelsX,
            levelsY: source.cod.levelsY,
            levelsZ: source.cod.levelsZ,
            parallelTileEncoding: (limits?.maximumWorkers ?? 8) > 1,
            maximumWorkers: limits?.maximumWorkers ?? 8
        ))
        // The encoder already counts decoded.volume as its input. Reserve the
        // original compressed input and parsed source, which it cannot observe.
        let encodeLimits = try limits.map {
            try $0.reserving(workspaceBytes: retainedWorkspace,
                             memoryBytes: jp3dDecodeAdd(sourceData.count, retainedWorkspace))
        }
        let result = try await encoder.encodeAdmitted(
            decoded.volume,
            limits: encodeLimits,
            executionPolicy: executionPolicy,
            metadataPolicy: metadataPolicy,
            work: work
        )

        let roundTripPixelBytes = (try? decoded.volume.sizeInBytes) ?? decoded.volume.estimatedMemorySize
        let measuredPeak = max(estimatedWorkspace,
            try jp3dDecodeAdd(retainedWorkspace, max(decoded.peakWorkspaceBytes, result.peakWorkspaceBytes)))
        return JP3DTranscoderResult(
            data: result.data,
            tilesTranscoded: result.tileCount,
            direction: configuration.direction,
            metadataPreserved: metadataPolicy == .preserve,
            warnings: [],
            peakWorkspaceBytes: measuredPeak,
            usedFullRoundTripCopy: true,
            roundTripPixelBytes: roundTripPixelBytes,
            roundTripComponentCount: decoded.volume.componentCount,
            sourceCommentCount: source.comments.count,
            sourceCommentBytes: source.commentPayloadBytes,
            sourceHadVolumeGeometry: source.geometry != nil,
            usedAcceleratedKernel: decoded.usedAcceleratedKernel || result.usedAcceleratedKernel
        )
    }

    // MARK: - Private Legacy Tile Transcoding

    private func transcodeToHTJ2K(
        tileData: Data,
        configuration: JP3DHTJ2KConfiguration,
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo,
        tileIndex: Int,
        warnings: inout [String]
    ) throws -> Data {
        _ = cod
        let (tw, th, td) = tileDimensions(tileIndex: tileIndex, siz: siz)
        let voxelsPerComp = tw * th * td
        let expectedBytesPerComp = voxelsPerComp * 4
        let expectedTotal = expectedBytesPerComp * siz.componentCount

        let payloadData: Data
        if let existingInfo = JP3DHTTileInfo.deserialise(from: tileData) {
            if existingInfo.isHT {
                return tileData
            }
            payloadData = Data(tileData.dropFirst(4))
        } else {
            payloadData = tileData
        }

        guard payloadData.count >= expectedTotal else {
            warnings.append(
                "Tile \(tileIndex): data truncated (\(payloadData.count) < \(expectedTotal) bytes)"
            )
            let coefficients = readRawCoefficients(from: payloadData, count: payloadData.count / 4)
            let codec = JP3DHTJ2KCodec(configuration: configuration)
            return codec.encodeTile(
                coefficients: coefficients,
                voxelCount: coefficients.count,
                tileIndex: tileIndex
            )
        }

        let coefficients = readRawCoefficients(from: payloadData, count: min(
            expectedTotal / 4, payloadData.count / 4
        ))

        let codec = JP3DHTJ2KCodec(configuration: configuration)
        return codec.encodeTile(
            coefficients: coefficients,
            voxelCount: coefficients.count,
            tileIndex: tileIndex
        )
    }

    private func transcodeToStandard(
        tileData: Data,
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo,
        tileIndex: Int,
        warnings: inout [String]
    ) throws -> Data {
        _ = cod
        let (tw, th, td) = tileDimensions(tileIndex: tileIndex, siz: siz)
        let voxelsPerComp = tw * th * td
        let expectedVoxelsTotal = voxelsPerComp * siz.componentCount

        if let info = JP3DHTTileInfo.deserialise(from: tileData) {
            if !info.isHT {
                return Data(tileData.dropFirst(4))
            }
            let codec = JP3DHTJ2KCodec(configuration: .default)
            let floatCoeffs = try codec.decodeTile(
                tileData: tileData,
                expectedVoxels: expectedVoxelsTotal
            )
            return encodeRawCoefficients(floatCoeffs)
        }

        warnings.append(
            "Tile \(tileIndex): no JP3DHTTileInfo prefix found; treating as already standard"
        )
        return tileData
    }

    private func verifyRoundTrip(
        original: Data,
        transcoded: Data,
        direction: JP3DTranscodingDirection,
        tileIndex: Int,
        htj2kConfig: JP3DHTJ2KConfiguration,
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo
    ) throws {
        _ = cod
        let (tw, th, td) = tileDimensions(tileIndex: tileIndex, siz: siz)
        let voxelsPerComp = tw * th * td
        let expectedVoxels = voxelsPerComp * siz.componentCount

        let originalCoeffs: [Int32]
        if let info = JP3DHTTileInfo.deserialise(from: original) {
            if info.isHT {
                let codec = JP3DHTJ2KCodec(configuration: htj2kConfig)
                originalCoeffs = try codec.decodeTile(
                    tileData: original,
                    expectedVoxels: expectedVoxels
                ).map { Int32($0) }
            } else {
                let stripped = Data(original.dropFirst(4))
                originalCoeffs = readRawCoefficients(from: stripped, count: min(expectedVoxels, stripped.count / 4))
            }
        } else {
            originalCoeffs = readRawCoefficients(from: original, count: min(expectedVoxels, original.count / 4))
        }

        let transcodedCoeffs: [Int32]
        switch direction {
        case .standardToHTJ2K:
            let codec = JP3DHTJ2KCodec(configuration: htj2kConfig)
            let floatCoeffs = try codec.decodeTile(
                tileData: transcoded,
                expectedVoxels: expectedVoxels
            )
            transcodedCoeffs = floatCoeffs.map { Int32($0) }
        case .htj2kToStandard:
            transcodedCoeffs = readRawCoefficients(
                from: transcoded,
                count: min(expectedVoxels, transcoded.count / 4)
            )
        }

        let count = min(originalCoeffs.count, transcodedCoeffs.count)
        for i in 0..<count where originalCoeffs[i] != transcodedCoeffs[i] {
            throw J2KError.encodingError(
                "Round-trip verification failed for tile \(tileIndex): " +
                "coefficient \(i) original=\(originalCoeffs[i]) " +
                "transcoded=\(transcodedCoeffs[i])"
            )
        }
    }

    private func tileDimensions(
        tileIndex: Int,
        siz: JP3DSIZInfo
    ) -> (Int, Int, Int) {
        let tilesX = max(1, (siz.width + siz.tileSizeX - 1) / siz.tileSizeX)
        let tilesY = max(1, (siz.height + siz.tileSizeY - 1) / siz.tileSizeY)

        let iz = tileIndex / (tilesX * tilesY)
        let rem = tileIndex % (tilesX * tilesY)
        let iy = rem / tilesX
        let ix = rem % tilesX

        let x0 = ix * siz.tileSizeX
        let y0 = iy * siz.tileSizeY
        let z0 = iz * siz.tileSizeZ

        let tw = min(siz.tileSizeX, siz.width - x0)
        let th = min(siz.tileSizeY, siz.height - y0)
        let td = min(siz.tileSizeZ, siz.depth - z0)

        return (max(1, tw), max(1, th), max(1, td))
    }

    private func readRawCoefficients(from data: Data, count: Int) -> [Int32] {
        var out = [Int32](repeating: 0, count: count)
        let base = data.startIndex
        for i in 0..<count {
            let off = base + i * 4
            guard off + 4 <= data.endIndex else { break }
            let b0 = Int32(data[off])
            let b1 = Int32(data[off + 1])
            let b2 = Int32(data[off + 2])
            let b3 = Int32(data[off + 3])
            out[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return out
    }

    private func encodeRawCoefficients(_ values: [Float]) -> Data {
        var data = Data(count: values.count * 4)
        for (i, v) in values.enumerated() {
            var intVal = Int32(v).bigEndian
            withUnsafeBytes(of: &intVal) { src in
                data.replaceSubrange((i * 4)..<(i * 4 + 4), with: src)
            }
        }
        return data
    }
}

// MARK: - JP3DCodestreamBuilder + HTJ2K extension

extension JP3DCodestreamBuilder {
    /// Admit all retained source/output buffers and final serialization before the
    /// output allocation. This path writes HT markers directly into one reserved buffer.
    internal func buildTranscodePublication(
        sourceDataBytes: Int, source: JP3DParsedCodestream, tileData: [Data],
        htj2kConfiguration: JP3DHTJ2KConfiguration?, comments: [JP3DCommentSegment],
        limits: ResourceLimits,
        codOverride: JP3DCODInfo? = nil,
        qcdOverride: JP3DQuantizationParameters? = nil,
        roiShifts: [Int] = [],
        mainCOC: [Int: JP3DCODInfo] = [:],
        mainQCC: [Int: JP3DQuantizationParameters] = [:],
        mainRGNAllComponents: Int? = nil,
        mainRGNByComponent: [Int: Int] = [:],
        tileOverrides: [Int: JP3DTileHeaderOverrides] = [:],
        part2BitSplit: JP3DPart2BitSplitDescriptor? = nil
    ) throws -> (data: Data, peakWorkspaceBytes: Int) {
        let outputBytes = try projectedByteCount(
            tileData: tileData, components: source.siz.componentCount,
            levelsX: source.cod.levelsX, levelsY: source.cod.levelsY, levelsZ: source.cod.levelsZ,
            isLossless: source.cod.isLossless, includesHTMarkers: htj2kConfiguration != nil,
            comments: comments,
            codOverride: codOverride,
            qcdOverride: qcdOverride,
            roiShifts: roiShifts,
            mainCOC: mainCOC,
            mainQCC: mainQCC,
            mainRGNAllComponents: mainRGNAllComponents,
            mainRGNByComponent: mainRGNByComponent,
            tileOverrides: tileOverrides,
            part2BitSplit: part2BitSplit
        )
        func add(_ a: Int, _ b: Int) throws -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard a >= 0, b >= 0, !overflow else {
                throw CodecError(.resourceLimitExceeded, "Transcode publication memory overflows Int")
            }
            return sum
        }
        var retainedBytes = try add(source.retainedTileBytes, source.commentPayloadBytes)
        for tile in tileData { retainedBytes = try add(retainedBytes, tile.count) }
        // Marker append helpers hold at most one four-byte scalar array alongside output.
        let serializationBytes = try add(outputBytes, MemoryLayout<UInt32>.size)
        let peakWorkspaceBytes = try add(retainedBytes, serializationBytes)
        let liveMemoryBytes = try add(sourceDataBytes, peakWorkspaceBytes)
        guard outputBytes <= limits.maximumCompressedBytes,
              peakWorkspaceBytes <= limits.maximumWorkspaceBytes,
              liveMemoryBytes <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcode publication exceeds compressed, workspace, or memory limit")
        }
        StorageTelemetry.recordStage("volume-transcode-publication", bytes: outputBytes)
        StorageTelemetry.recordWorkspaceAllocation(bytes: outputBytes)
        let data = buildPreallocated(
            tileData: tileData, width: source.siz.width, height: source.siz.height, depth: source.siz.depth,
            components: source.siz.componentCount, bitDepth: source.siz.bitDepth, signed: source.siz.signed,
            levelsX: source.cod.levelsX, levelsY: source.cod.levelsY, levelsZ: source.cod.levelsZ,
            tileSizeX: source.siz.tileSizeX, tileSizeY: source.siz.tileSizeY, tileSizeZ: source.siz.tileSizeZ,
            isLossless: source.cod.isLossless, comments: comments,
            htj2kConfiguration: htj2kConfiguration, capacity: outputBytes,
            componentBitDepths: source.siz.componentBitDepths,
            componentSigned: source.siz.componentSigned,
            codOverride: codOverride,
            qcdOverride: qcdOverride,
            roiShifts: roiShifts,
            mainCOC: mainCOC,
            mainQCC: mainQCC,
            mainRGNAllComponents: mainRGNAllComponents,
            mainRGNByComponent: mainRGNByComponent,
            tileOverrides: tileOverrides,
            part2BitSplit: part2BitSplit
        )
        return (data, peakWorkspaceBytes)
    }

    /// Builds a normative Part 10 JP3D codestream with optional reconciled Part 15 HTJ2K `CAP`/`CPF` signalling and `COM` segments.
    public func build(
        tileData: [Data],
        width: Int,
        height: Int,
        depth: Int,
        components: Int,
        bitDepth: Int,
        signed: Bool = false,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        tileSizeX: Int,
        tileSizeY: Int,
        tileSizeZ: Int,
        isLossless: Bool,
        htj2kConfiguration: JP3DHTJ2KConfiguration?,
        geometry: JP3DVolumeGeometry? = nil,
        comments: [JP3DCommentSegment] = []
    ) -> Data {
        buildPreallocated(
            tileData: tileData,
            width: width,
            height: height,
            depth: depth,
            components: components,
            bitDepth: bitDepth,
            signed: signed,
            levelsX: levelsX,
            levelsY: levelsY,
            levelsZ: levelsZ,
            tileSizeX: tileSizeX,
            tileSizeY: tileSizeY,
            tileSizeZ: tileSizeZ,
            isLossless: isLossless,
            geometry: geometry,
            comments: comments,
            htj2kConfiguration: htj2kConfiguration,
            capacity: 0
        )
    }
}

// MARK: - JP3DParsedCodestream + HTJ2K helpers

extension JP3DParsedCodestream {
    /// Whether this codestream was encoded with HTJ2K tile coding.
    public var containsHTJ2KTiles: Bool {
        if hasHTJ2KCAPMarker || (cod.codeBlockStyle & 0x40) != 0 {
            return true
        }
        for tile in tiles {
            if JP3DLosslessIntegerTileCodec.hasMagic(tile.data) {
                if JP3DLosslessIntegerTileCodec.usesHTJ2K(tile.data) { return true }
            } else if JP3DSliceStackCodec.hasMagic(tile.data) {
                if Self.sliceStackUsesHTJ2K(tile.data) { return true }
            } else if !hasNSIMarker,
                      let info = JP3DHTTileInfo.deserialise(from: tile.data),
                      info.isHT {
                return true
            }
        }
        return false
    }

    /// Whether this codestream is a hybrid `HTMIXED` volume permitting both HT and Part 1 EBCOT code-blocks/tiles.
    public var isHybridHTJ2K: Bool {
        let hasLegacyTile = tiles.contains {
            JP3DLosslessIntegerTileCodec.hasMagic($0.data) || JP3DSliceStackCodec.hasMagic($0.data)
        }
        if hasNSIMarker && !hasLegacyTile {
            if let c15 = ccap15 {
                return ((c15 >> 14) & 0x03) == 0x03
            }
            return (cod.codeBlockStyle & 0xC0) == 0xC0
        }
        var hasHT = false
        var hasLegacy = false
        for tile in tiles {
            if JP3DLosslessIntegerTileCodec.hasMagic(tile.data) {
                if JP3DLosslessIntegerTileCodec.usesHTJ2K(tile.data) {
                    hasHT = true
                } else {
                    hasLegacy = true
                }
            } else if JP3DSliceStackCodec.hasMagic(tile.data) {
                if Self.sliceStackUsesHTJ2K(tile.data) {
                    hasHT = true
                } else {
                    hasLegacy = true
                }
            } else if let info = JP3DHTTileInfo.deserialise(from: tile.data) {
                if info.isHT { hasHT = true } else { hasLegacy = true }
            } else {
                hasLegacy = true
            }
            if hasHT && hasLegacy { return true }
        }
        return false
    }

    private static func sliceStackUsesHTJ2K(_ data: Data) -> Bool {
        JP3DSliceStackCodec.usesHTJ2K(data)
    }
}
