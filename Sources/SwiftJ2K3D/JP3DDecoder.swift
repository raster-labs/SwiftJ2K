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

    /// Creates a decoder configuration.
    public init(
        maxQualityLayers: Int = 0,
        resolutionLevel: Int = 0,
        tolerateErrors: Bool = true,
        parallelTileDecoding: Bool = true
    ) {
        self.maxQualityLayers = max(0, maxQualityLayers)
        self.resolutionLevel = max(0, resolutionLevel)
        self.tolerateErrors = tolerateErrors
        self.parallelTileDecoding = parallelTileDecoding
    }

    /// Convenience initialiser accepting optional `maxQualityLayers` and `tolerateTruncation`.
    public init(
        maxQualityLayers: Int?,
        resolutionLevel: Int = 0,
        tolerateTruncation: Bool = true,
        parallelTileDecoding: Bool = true
    ) {
        self.init(
            maxQualityLayers: maxQualityLayers ?? 0,
            resolutionLevel: resolutionLevel,
            tolerateErrors: tolerateTruncation,
            parallelTileDecoding: parallelTileDecoding
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
            parallelTileDecoding: configuration.parallelTileDecoding
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
            parallelTileDecoding: configuration.parallelTileDecoding
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
        guard !data.isEmpty else {
            throw J2KError.decodingError("Cannot decode empty codestream")
        }

        reportProgress(.parsing, stageProgress: 0.0, tilesDone: 0, tilesTotal: 1)

        let parser = JP3DCodestreamParser()
        let codestream = try parser.parse(data)

        let siz = codestream.siz
        let cod = codestream.cod
        let grid = codestream.tileGrid
        let tilesExpected = grid.tilesX * grid.tilesY * grid.tilesZ

        reportProgress(.parsing, stageProgress: 1.0, tilesDone: 0, tilesTotal: codestream.tiles.count)

        let K = max(0, configuration.resolutionLevel)
        let scale = 1 << K
        @inline(__always) func down(_ n: Int) -> Int {
            max(1, (n + scale - 1) / scale)
        }
        let outWidth  = down(siz.width)
        let outHeight = down(siz.height)
        let outDepth  = siz.depth

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

        let outVoxelCount = outWidth * outHeight * outDepth
        var componentBuffers = (0..<siz.componentCount).map { _ in
            [Float](repeating: 0, count: outVoxelCount)
        }

        var tilesDecoded = 0
        var isPartial = false
        var warnings: [String] = []

        let filter: JP3DWaveletFilter = cod.isLossless ? .reversible53 : .irreversible97
        let transformConfig = JP3DTransformConfiguration(
            filter: filter,
            mode: .separable,
            boundary: .symmetric,
            levelsX: max(0, cod.levelsX - K),
            levelsY: max(0, cod.levelsY - K),
            levelsZ: cod.levelsZ
        )

        let maxQLayers: Int? = configuration.maxQualityLayers > 0 ? configuration.maxQualityLayers : nil

        for (seqIdx, parsedTile) in codestream.tiles.enumerated() {
            guard parsedTile.tileIndex >= 0, parsedTile.tileIndex < allTiles.count else {
                isPartial = true
                warnings.append("Tile index \(parsedTile.tileIndex) out of bounds")
                continue
            }
            let tile = allTiles[parsedTile.tileIndex]
            let outX0 = K > 0 ? (tile.region.x.lowerBound + scale - 1) / scale : tile.region.x.lowerBound
            let outY0 = K > 0 ? (tile.region.y.lowerBound + scale - 1) / scale : tile.region.y.lowerBound
            let outZ0 = tile.region.z.lowerBound
            let tileW = max(1, down(tile.region.x.upperBound) - outX0)
            let tileH = max(1, down(tile.region.y.upperBound) - outY0)
            let tileD = tile.depth

            do {
                let samples = try await Self.decodeTilePayloadStatic(
                    parsedTile.data,
                    tile: tile,
                    componentCount: siz.componentCount,
                    tileW: tileW, tileH: tileH, tileD: tileD,
                    isLossless: cod.isLossless,
                    transformConfig: transformConfig,
                    maxQualityLayers: maxQLayers,
                    resolutionLevel: K
                )
                for comp in 0..<siz.componentCount {
                    guard comp < samples.count else { continue }
                    let reconstructed = samples[comp]
                    for z in 0..<tileD {
                        let dstZ = outZ0 + z
                        guard dstZ < outDepth else { continue }
                        for y in 0..<tileH {
                            let dstY = outY0 + y
                            guard dstY < outHeight else { continue }
                            for x in 0..<tileW {
                                let dstX = outX0 + x
                                guard dstX < outWidth else { continue }
                                let srcIdx = z * tileW * tileH + y * tileW + x
                                let dstIdx = dstZ * outWidth * outHeight + dstY * outWidth + dstX
                                if srcIdx < reconstructed.count && dstIdx < outVoxelCount {
                                    componentBuffers[comp][dstIdx] = reconstructed[srcIdx]
                                }
                            }
                        }
                    }
                }
                tilesDecoded += 1
                let tileProgress = Double(seqIdx + 1) / Double(max(1, codestream.tiles.count))
                reportProgress(
                    .tileReconstruction,
                    stageProgress: tileProgress,
                    tilesDone: tilesDecoded,
                    tilesTotal: tilesExpected
                )
            } catch {
                if configuration.tolerateErrors {
                    warnings.append("Tile \(parsedTile.tileIndex) decode failed: \(error)")
                    isPartial = true
                } else {
                    throw error
                }
            }
        }

        if tilesDecoded < tilesExpected {
            isPartial = true
            warnings.append("Decoded \(tilesDecoded) of \(tilesExpected) expected tiles")
        }

        reportProgress(.volumeAssembly, stageProgress: 0.5, tilesDone: tilesDecoded, tilesTotal: tilesExpected)

        let volumeComponents = assembleVolumeComponents(
            buffers: componentBuffers,
            width: outWidth,
            height: outHeight,
            depth: outDepth,
            bitDepth: siz.bitDepth,
            signed: siz.signed
        )

        let volume = J2KVolume(
            width: outWidth,
            height: outHeight,
            depth: outDepth,
            components: volumeComponents
        )

        reportProgress(.volumeAssembly, stageProgress: 1.0, tilesDone: tilesDecoded, tilesTotal: tilesExpected)

        return JP3DDecoderResult(
            volume: volume,
            isPartial: isPartial,
            warnings: warnings,
            tilesDecoded: tilesDecoded,
            tilesTotal: tilesExpected,
            isLossless: cod.isLossless && codestream.isLosslessQuantization
        )
    }

    // MARK: - Internal Helpers

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
        resolutionLevel: Int
    ) async throws -> [[Float]] {
        if JP3DSliceStackCodec.isSliceStackTile(data) {
            let sliceCodec = JP3DSliceStackCodec()
            return try sliceCodec.decodeTile(
                data,
                expectedComponents: componentCount,
                expectedWidth: tile.width,
                expectedHeight: tile.height,
                expectedDepth: tile.depth,
                maxQualityLayers: maxQualityLayers,
                resolutionLevel: resolutionLevel
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
        let bytesPerComponent = headerBytes + voxelsPerComponent * bytesPerCoeff
        var result: [[Float]] = []
        result.reserveCapacity(componentCount)

        for comp in 0..<componentCount {
            let compStart = comp * bytesPerComponent
            guard compStart + headerBytes <= data.count else {
                result.append([Float](repeating: 0, count: voxelsPerComponent))
                continue
            }

            let coeffDataStart = compStart + headerBytes
            let availableBytes = max(0, min(voxelsPerComponent * bytesPerCoeff, data.count - coeffDataStart))
            let availableCoeffs = availableBytes / bytesPerCoeff

            var coeffs = [Float](repeating: 0, count: voxelsPerComponent)
            if availableCoeffs > 0 {
                data.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    let src = (base + coeffDataStart).assumingMemoryBound(to: Int32.self)
                    for i in 0..<availableCoeffs {
                        coeffs[i] = Float(Int32(bigEndian: src[i]))
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
