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
        guard !data.isEmpty else {
            throw J2KError.decodingError("Cannot decode ROI from empty codestream")
        }

        reportProgress(.parsing, stageProgress: 0.0, tilesDone: 0, tilesTotal: 1)

        let parser = JP3DCodestreamParser()
        let codestream = try parser.parse(data)
        let siz = codestream.siz
        let cod = codestream.cod

        reportProgress(.parsing, stageProgress: 1.0, tilesDone: 0, tilesTotal: codestream.tiles.count)

        let clampedXLower = max(0, requestedRegion.x.lowerBound)
        let clampedXUpper = min(siz.width, requestedRegion.x.upperBound)
        let clampedYLower = max(0, requestedRegion.y.lowerBound)
        let clampedYUpper = min(siz.height, requestedRegion.y.upperBound)
        let clampedZLower = max(0, requestedRegion.z.lowerBound)
        let clampedZUpper = min(siz.depth, requestedRegion.z.upperBound)

        if clampedXLower >= clampedXUpper || clampedYLower >= clampedYUpper || clampedZLower >= clampedZUpper {
            let emptyVolume = J2KVolume(
                width: siz.width, height: siz.height, depth: siz.depth,
                componentCount: siz.componentCount, bitDepth: siz.bitDepth, signed: siz.signed
            )
            let emptyRegion = JP3DRegion(x: 0..<0, y: 0..<0, z: 0..<0)
            return JP3DROIDecoderResult(
                volume: emptyVolume,
                decodedRegion: emptyRegion,
                isFullVolume: false,
                tilesSkipped: codestream.tiles.count,
                tilesDecoded: 0,
                warnings: ["Requested region does not intersect the volume"]
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
                tolerateErrors: configuration.tolerateErrors
            )
            let decoder = JP3DDecoder(configuration: effectiveConfig)
            let result = try await decoder.decode(data)
            return JP3DROIDecoderResult(
                volume: result.volume,
                decodedRegion: roiRegion,
                isFullVolume: true,
                tilesSkipped: 0,
                tilesDecoded: result.tilesDecoded,
                warnings: result.warnings
            )
        }

        let K = max(0, resolutionLevel)
        let f = K > 0 ? (1 << K) : 1

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

        let outW = K > 0 ? max(1, (roiW + f - 1) / f) : roiW
        let outH = K > 0 ? max(1, (roiH + f - 1) / f) : roiH
        let outD = roiD
        let outVoxels = outW * outH * outD

        var componentBuffers = (0..<siz.componentCount).map { _ in
            [Float](repeating: 0, count: outVoxels)
        }

        let filter: JP3DWaveletFilter = cod.isLossless ? .reversible53 : .irreversible97
        let transformConfig = JP3DTransformConfiguration(
            filter: filter,
            mode: .separable,
            boundary: .symmetric,
            levelsX: max(0, cod.levelsX - K),
            levelsY: max(0, cod.levelsY - K),
            levelsZ: cod.levelsZ
        )

        var tilesDecoded = 0
        var tilesSkipped = 0
        var warnings: [String] = []

        for parsedTile in codestream.tiles {
            guard intersectingIndices.contains(parsedTile.tileIndex),
                  parsedTile.tileIndex < allTiles.count else {
                tilesSkipped += 1
                continue
            }

            let tile = allTiles[parsedTile.tileIndex]
            let tileW = K > 0 ? max(1, (tile.width  + f - 1) / f) : tile.width
            let tileH = K > 0 ? max(1, (tile.height + f - 1) / f) : tile.height
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

            let reconstructedPerComp: [[Float]]
            let decodedZOffset: Int
            let decodedXOffset: Int
            let decodedYOffset: Int
            let decodedStrideW: Int
            let decodedStrideH: Int

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
                        xyROI: isSubTileXY ? (x: localXRange, y: localYRange) : nil
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
                        resolutionLevel: K
                    )
                    decodedZOffset = 0
                    decodedXOffset = 0
                    decodedYOffset = 0
                    decodedStrideW = tileW
                    decodedStrideH = tileH
                }
            } catch {
                if configuration.tolerateErrors {
                    warnings.append("Tile \(parsedTile.tileIndex) decode failed: \(error)")
                    continue
                }
                throw error
            }

            for comp in 0..<siz.componentCount {
                let reconstructed = reconstructedPerComp[comp]

                let tStartX = K > 0 ? tile.region.x.lowerBound / f : tile.region.x.lowerBound
                let tStartY = K > 0 ? tile.region.y.lowerBound / f : tile.region.y.lowerBound
                let tStartZ = tile.region.z.lowerBound

                let rStartX = K > 0 ? roiRegion.x.lowerBound / f : roiRegion.x.lowerBound
                let rStartY = K > 0 ? roiRegion.y.lowerBound / f : roiRegion.y.lowerBound
                let rStartZ = roiRegion.z.lowerBound

                let zLoopStart = decodedZOffset
                let zLoopEnd = (decodedZOffset > 0) ? localZEnd : tileD

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

            tilesDecoded += 1
            let prog = Double(tilesDecoded) / Double(max(1, intersectingIndices.count))
            reportProgress(
                .tileReconstruction,
                stageProgress: prog,
                tilesDone: tilesDecoded,
                tilesTotal: intersectingIndices.count
            )
        }

        reportProgress(.volumeAssembly, stageProgress: 0.5, tilesDone: tilesDecoded, tilesTotal: intersectingIndices.count)

        let components = assembleROIComponents(
            buffers: componentBuffers,
            width: outW, height: outH, depth: outD,
            bitDepth: siz.bitDepth, signed: siz.signed
        )
        let roiVolume = J2KVolume(
            width: outW, height: outH, depth: outD,
            components: components
        )

        reportProgress(.volumeAssembly, stageProgress: 1.0, tilesDone: tilesDecoded, tilesTotal: intersectingIndices.count)

        return JP3DROIDecoderResult(
            volume: roiVolume,
            decodedRegion: roiRegion,
            isFullVolume: false,
            tilesSkipped: tilesSkipped,
            tilesDecoded: tilesDecoded,
            warnings: warnings
        )
    }

    // MARK: - Private Helpers

    private func assembleROIComponents(
        buffers: [[Float]],
        width: Int, height: Int, depth: Int,
        bitDepth: Int, signed: Bool
    ) -> [J2KVolumeComponent] {
        let bytesPerSample = (bitDepth + 7) / 8
        let minVal: Float = signed ? -Float(1 << (bitDepth - 1)) : 0
        let maxVal: Float = signed
            ? Float((1 << (bitDepth - 1)) - 1)
            : Float((1 << min(30, bitDepth)) - 1)

        return buffers.enumerated().map { index, buffer in
            let count = buffer.count
            var data = Data(count: count * bytesPerSample)
            data.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                switch bytesPerSample {
                case 1:
                    if signed {
                        for i in 0..<count {
                            let clamped = max(minVal, min(maxVal, buffer[i]))
                            let intVal = Int8(clamping: Int(clamped.rounded()))
                            base[i] = UInt8(bitPattern: intVal)
                        }
                    } else {
                        for i in 0..<count {
                            let clamped = max(0, min(maxVal, buffer[i]))
                            base[i] = UInt8(truncatingIfNeeded: Int(clamped.rounded()))
                        }
                    }
                case 2:
                    if signed {
                        for i in 0..<count {
                            let clamped = max(minVal, min(maxVal, buffer[i]))
                            let intVal = Int16(clamping: Int(clamped.rounded()))
                            let u = UInt16(bitPattern: intVal)
                            base[i * 2] = UInt8(truncatingIfNeeded: u)
                            base[i * 2 + 1] = UInt8(truncatingIfNeeded: u >> 8)
                        }
                    } else {
                        for i in 0..<count {
                            let clamped = max(0, min(maxVal, buffer[i]))
                            let intVal = UInt16(clamping: Int(clamped.rounded()))
                            base[i * 2] = UInt8(truncatingIfNeeded: intVal)
                            base[i * 2 + 1] = UInt8(truncatingIfNeeded: intVal >> 8)
                        }
                    }
                case 4:
                    for i in 0..<count {
                        let clamped = max(minVal, min(maxVal, buffer[i]))
                        let intVal = Int32(clamped.rounded())
                        let u = UInt32(bitPattern: intVal)
                        base[i * 4] = UInt8(truncatingIfNeeded: u)
                        base[i * 4 + 1] = UInt8(truncatingIfNeeded: u >> 8)
                        base[i * 4 + 2] = UInt8(truncatingIfNeeded: u >> 16)
                        base[i * 4 + 3] = UInt8(truncatingIfNeeded: u >> 24)
                    }
                default:
                    for i in 0..<count {
                        let clamped = max(minVal, min(maxVal, buffer[i]))
                        let intVal = Int(clamped.rounded())
                        for b in 0..<bytesPerSample {
                            base[i * bytesPerSample + b] = UInt8(truncatingIfNeeded: intVal >> (b * 8))
                        }
                    }
                }
            }
            return J2KVolumeComponent(
                index: index,
                bitDepth: bitDepth,
                signed: signed,
                width: width,
                height: height,
                depth: depth,
                data: data
            )
        }
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
