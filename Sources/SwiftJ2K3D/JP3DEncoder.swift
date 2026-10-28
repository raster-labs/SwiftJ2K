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
        zDeltaMode: JP3DZDeltaMode = .auto
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
        zDelta: JP3DZDeltaMode = .auto
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
            zDeltaMode: zDelta
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

        let decomposer = JP3DTileDecomposer(configuration: configuration.tiling)
        let tiles = decomposer.decompose(volume: volume)
        let totalTiles = tiles.count

        reportProgress(.preparation, stageProgress: 1.0, tile: 0, total: totalTiles)

        let encodedTiles: [Data]
        if configuration.parallelEncoding && tiles.count > 1 {
            encodedTiles = try await encodeTilesParallel(tiles: tiles, volume: volume, decomposer: decomposer)
        } else {
            encodedTiles = try await encodeTilesSequential(tiles: tiles, volume: volume, decomposer: decomposer)
        }

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
                htj2kConfiguration: .default
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
                isLossless: configuration.compressionMode.isLossless
            )
        }

        reportProgress(.codestreamGeneration, stageProgress: 1.0, tile: totalTiles, total: totalTiles)

        return JP3DEncoderResult(
            data: codestream,
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            componentCount: volume.componentCount,
            isLossless: configuration.compressionMode.isLossless,
            tileCount: totalTiles,
            originalSize: volume.estimatedMemorySize
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
        decomposer: JP3DTileDecomposer
    ) async throws -> [Data] {
        var encodedTiles: [Data] = []
        encodedTiles.reserveCapacity(tiles.count)

        for (index, tile) in tiles.enumerated() {
            let frac = Double(index) / Double(max(1, tiles.count))
            reportProgress(.waveletTransform, stageProgress: frac, tile: index, total: tiles.count)
            let tileData = try await encodeSingleTile(
                tile: tile, volume: volume, decomposer: decomposer
            )
            reportProgress(.entropyCoding, stageProgress: frac, tile: index + 1, total: tiles.count)
            encodedTiles.append(tileData)
        }

        return encodedTiles
    }

    private func encodeTilesParallel(
        tiles: [JP3DTile],
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer
    ) async throws -> [Data] {
        let config = configuration
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, tile) in tiles.enumerated() {
                group.addTask {
                    let data = try await Self.encodeTileStatic(
                        tile: tile,
                        volume: volume,
                        decomposer: decomposer,
                        configuration: config
                    )
                    return (index, data)
                }
            }

            var results = [(Int, Data)]()
            results.reserveCapacity(tiles.count)
            for try await result in group {
                results.append(result)
                let done = results.count
                reportProgress(
                    .entropyCoding,
                    stageProgress: Double(done) / Double(max(1, tiles.count)),
                    tile: done,
                    total: tiles.count
                )
            }
            results.sort { $0.0 < $1.0 }
            return results.map(\.1)
        }
    }

    private func encodeSingleTile(
        tile: JP3DTile,
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer
    ) async throws -> Data {
        try await Self.encodeTileStatic(
            tile: tile,
            volume: volume,
            decomposer: decomposer,
            configuration: configuration
        )
    }

    private static func encodeTileStatic(
        tile: JP3DTile,
        volume: J2KVolume,
        decomposer: JP3DTileDecomposer,
        configuration: JP3DEncoderConfiguration
    ) async throws -> Data {
        let primaryComp = volume.components[0]
        if JP3DSliceStackCodec.canEncode(
            tileWidth: tile.width,
            tileHeight: tile.height,
            bitDepth: primaryComp.bitDepth
        ) {
            var compSamples: [[Float]] = []
            compSamples.reserveCapacity(volume.componentCount)
            for comp in 0..<volume.componentCount {
                let extracted = try decomposer.extractTileData(
                    from: volume, tile: tile, componentIndex: comp
                )
                compSamples.append(extracted.data)
            }
            let sliceCodec = JP3DSliceStackCodec()
            if let sliceData = try? sliceCodec.encodeTile(
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
                zDeltaPolicy: configuration.zDeltaMode
            ) {
                return sliceData
            }
        }

        let rateController = JP3DRateController(
            mode: configuration.compressionMode,
            qualityLayers: configuration.qualityLayers
        )
        let transformConfig = configuration.transformConfiguration
        let wavelet = JP3DWaveletTransform(configuration: transformConfig)

        var tileBytes = Data()

        for comp in 0..<volume.componentCount {
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

            tileBytes.append(Self.encodeQuantizedCoefficients(quantized))
        }

        return tileBytes
    }

    private static func encodeQuantizedCoefficients(_ quantized: JP3DQuantizedTile) -> Data {
        let coeffs = quantized.coefficients
        let count = coeffs.count
        guard count > 0 else {
            return Data(repeating: 0, count: 4)
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

        var output = Data(capacity: 4 + count * 4)
        output.append(zeroBitPlanes)
        output.append(activeBitPlanes)
        output.append(UInt8(truncatingIfNeeded: nonZeroCount >> 8))
        output.append(UInt8(truncatingIfNeeded: nonZeroCount))

        let baseOffset = output.count
        output.append(Data(count: count * 4))
        output.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let dst = (base + baseOffset).assumingMemoryBound(to: Int32.self)
            for i in 0..<count {
                dst[i] = coeffs[i].bigEndian
            }
        }

        return output
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
        let minVal = signed ? -(1 << (bitDepth - 1)) : 0
        let maxVal = signed ? ((1 << (bitDepth - 1)) - 1) : ((1 << min(30, bitDepth)) - 1)

        data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let dst = base + startOffset
            switch bytesPerSample {
            case 1:
                if signed {
                    for i in 0..<count {
                        let v = max(minVal, min(maxVal, Int(samples[i].rounded())))
                        dst[i] = UInt8(bitPattern: Int8(clamping: v))
                    }
                } else {
                    for i in 0..<count {
                        let v = max(0, min(maxVal, Int(samples[i].rounded())))
                        dst[i] = UInt8(truncatingIfNeeded: v)
                    }
                }
            case 2:
                if signed {
                    for i in 0..<count {
                        let v = max(minVal, min(maxVal, Int(samples[i].rounded())))
                        let u = UInt16(bitPattern: Int16(clamping: v))
                        dst[i * 2] = UInt8(truncatingIfNeeded: u)
                        dst[i * 2 + 1] = UInt8(truncatingIfNeeded: u >> 8)
                    }
                } else {
                    for i in 0..<count {
                        let v = max(0, min(maxVal, Int(samples[i].rounded())))
                        let u = UInt16(clamping: v)
                        dst[i * 2] = UInt8(truncatingIfNeeded: u)
                        dst[i * 2 + 1] = UInt8(truncatingIfNeeded: u >> 8)
                    }
                }
            case 4:
                for i in 0..<count {
                    let v = Int32(samples[i].rounded()).littleEndian
                    withUnsafeBytes(of: v) { src in
                        dst[i * 4] = src[0]
                        dst[i * 4 + 1] = src[1]
                        dst[i * 4 + 2] = src[2]
                        dst[i * 4 + 3] = src[3]
                    }
                }
            default:
                for i in 0..<count {
                    let v = Int(samples[i].rounded())
                    for b in 0..<bytesPerSample {
                        dst[i * bytesPerSample + b] = UInt8(truncatingIfNeeded: v >> (b * 8))
                    }
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
