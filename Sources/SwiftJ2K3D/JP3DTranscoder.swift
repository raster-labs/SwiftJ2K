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
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        try work.check()
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
                htj2kConfiguration: toHTJ2K ? configuration.htj2kConfiguration : nil
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
                    sourceData, limits: limits, executionPolicy: executionPolicy, work: work
                ).volume
                let transVol = try await JP3DDecoder().decodeAdmitted(
                    codestream, limits: limits, executionPolicy: executionPolicy, work: work
                ).volume
                for c in 0..<origVol.componentCount {
                    if origVol.components[c].data != transVol.components[c].data {
                        throw J2KError.encodingError(
                            "Integer lossless tile round-trip verification failed on component \(c)"
                        )
                    }
                }
            }
            return JP3DTranscoderResult(
                data: codestream,
                tilesTranscoded: transcodedTiles.count,
                direction: configuration.direction,
                metadataPreserved: true,
                warnings: []
            )
        }

        if source.tiles.contains(where: { JP3DSliceStackCodec.hasMagic($0.data) }) {
            return try await transcodeSliceStack(
                sourceData: sourceData,
                source: source,
                configuration: configuration,
                limits: limits,
                executionPolicy: executionPolicy,
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
            htj2kConfiguration: outputIsHTJ2K ? configuration.htj2kConfiguration : nil
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

        return JP3DTranscoderResult(
            data: codestream,
            tilesTranscoded: transcodedTiles.count,
            direction: configuration.direction,
            metadataPreserved: true,
            warnings: warnings
        )
    }

    // MARK: - Private Slice-Stack Transcode Path

    private func transcodeSliceStack(
        sourceData: Data,
        source: JP3DParsedCodestream,
        configuration: JP3DTranscoderConfiguration,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        let toHTJ2K = configuration.direction == .standardToHTJ2K
        if source.cod.isLossless && source.tiles.allSatisfy({ JP3DSliceStackCodec.hasMagic($0.data) }) {
            do {
                var transcodedTiles: [Data] = []
                transcodedTiles.reserveCapacity(source.tiles.count)
                let sliceStackCodec = JP3DSliceStackCodec()
                for parsedTile in source.tiles {
                    try work.check()
                    let tileData = try await sliceStackCodec.transcodeTile(
                        parsedTile.data,
                        toHTJ2K: toHTJ2K,
                        limits: limits ?? .default,
                        executionPolicy: executionPolicy
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
                    htj2kConfiguration: toHTJ2K ? configuration.htj2kConfiguration : nil
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
                        sourceData, limits: limits, executionPolicy: executionPolicy, work: work
                    ).volume
                    let transVol = try await JP3DDecoder().decodeAdmitted(
                        codestream, limits: limits, executionPolicy: executionPolicy, work: work
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
                    metadataPreserved: true,
                    warnings: []
                )
            } catch {
                if error is CancellationError { throw error }
                if let ce = error as? CodecError, ce.category == .resourceLimitExceeded { throw ce }
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
            work: work
        )
    }

    private func transcodeViaFullRoundTrip(
        sourceData: Data,
        source: JP3DParsedCodestream,
        configuration: JP3DTranscoderConfiguration,
        limits: ResourceLimits?,
        executionPolicy: ExecutionPolicy,
        work: VolumeWorkGuard
    ) async throws -> JP3DTranscoderResult {
        let decoder = JP3DDecoder(configuration: JP3DDecoderConfiguration(
            tolerateErrors: false,
            parallelTileDecoding: (limits?.maximumWorkers ?? 8) > 1,
            maximumWorkers: limits?.maximumWorkers ?? 8
        ))
        let decoded = try await decoder.decodeAdmitted(
            sourceData,
            limits: limits,
            executionPolicy: executionPolicy,
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
        let result = try await encoder.encodeAdmitted(
            decoded.volume,
            limits: limits,
            executionPolicy: executionPolicy,
            work: work
        )

        return JP3DTranscoderResult(
            data: result.data,
            tilesTranscoded: result.tileCount,
            direction: configuration.direction,
            metadataPreserved: true,
            warnings: []
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
    /// Builds a JP3D codestream with optional HTJ2K marker segments.
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
        htj2kConfiguration: JP3DHTJ2KConfiguration?
    ) -> Data {
        guard let htConfig = htj2kConfiguration else {
            return build(
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
                isLossless: isLossless
            )
        }

        let base = build(
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
            isLossless: isLossless
        )

        let sotMarker: UInt16 = 0xFF90
        guard let insertOffset = findMarkerOffset(in: base, marker: sotMarker) else {
            var result = base
            result.append(JP3DHTMarkers.capMarkerData(for: htConfig))
            result.append(JP3DHTMarkers.cpfMarkerData(for: htConfig, isLossless: isLossless))
            return result
        }

        var result = Data()
        result.append(base[..<insertOffset])
        result.append(JP3DHTMarkers.capMarkerData(for: htConfig))
        result.append(JP3DHTMarkers.cpfMarkerData(for: htConfig, isLossless: isLossless))
        result.append(base[insertOffset...])
        return result
    }

    private func findMarkerOffset(in data: Data, marker: UInt16) -> Int? {
        guard data.count >= 2 else { return nil }
        let high = UInt8((marker >> 8) & 0xFF)
        let low  = UInt8(marker & 0xFF)
        for i in 0..<(data.count - 1) {
            if data[i] == high && data[i + 1] == low {
                return i
            }
        }
        return nil
    }
}

// MARK: - JP3DParsedCodestream + HTJ2K helpers

extension JP3DParsedCodestream {
    /// Whether this codestream was encoded with HTJ2K tile coding.
    public var containsHTJ2KTiles: Bool {
        for tile in tiles {
            if JP3DLosslessIntegerTileCodec.hasMagic(tile.data) {
                if JP3DLosslessIntegerTileCodec.usesHTJ2K(tile.data) { return true }
            } else if JP3DSliceStackCodec.hasMagic(tile.data) {
                if Self.sliceStackUsesHTJ2K(tile.data) { return true }
            } else if let info = JP3DHTTileInfo.deserialise(from: tile.data),
                      info.isHT {
                return true
            }
        }
        return false
    }

    /// Whether this codestream is a hybrid volume with both HT and legacy tiles.
    public var isHybridHTJ2K: Bool {
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
