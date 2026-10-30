// SPDX-License-Identifier: Apache-2.0
//
// JP3DStreamWriter.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DStreamWriter.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.

import Foundation
import SwiftJ2K

/// Progress update for streaming encoding.
public struct JP3DStreamProgress: Sendable {
    /// Number of slices received so far.
    public let slicesReceived: Int

    /// Total number of slices expected.
    public let totalSlices: Int

    /// Number of tiles fully encoded.
    public let tilesEncoded: Int

    /// Total number of tiles.
    public let totalTiles: Int

    /// Progress percentage (0.0 to 1.0).
    public var progress: Double {
        guard totalSlices > 0 else { return 0 }
        return Double(slicesReceived) / Double(totalSlices)
    }

    public init(slicesReceived: Int, totalSlices: Int, tilesEncoded: Int, totalTiles: Int) {
        self.slicesReceived = slicesReceived
        self.totalSlices = totalSlices
        self.tilesEncoded = tilesEncoded
        self.totalTiles = totalTiles
    }
}

/// State of the streaming encoder.
public enum JP3DStreamWriterState: Sendable, Equatable {
    /// Writer is ready to accept slices.
    case ready
    /// Writer is actively receiving slices.
    case encoding
    /// Writer has been finalised and produced output.
    case finalized
    /// Writer was cancelled.
    case cancelled
}

/// Streaming encoder actor for slice-by-slice JP3D encoding.
public actor JP3DStreamWriter {
    // MARK: - Configuration

    /// The encoder configuration.
    public struct Configuration: Sendable {
        /// Volume width.
        public let width: Int

        /// Volume height.
        public let height: Int

        /// Volume depth (total number of slices).
        public let depth: Int

        /// Number of components.
        public let componentCount: Int

        /// Bit depth per component.
        public let bitDepth: Int

        /// Compression mode.
        public let compressionMode: JP3DCompressionMode

        /// Tiling configuration.
        public let tiling: JP3DTilingConfiguration

        /// Progression order.
        public let progressionOrder: JP3DProgressionOrder

        /// Number of quality layers.
        public let qualityLayers: Int

        /// Creates a streaming encoder configuration.
        public init(
            width: Int,
            height: Int,
            depth: Int,
            componentCount: Int = 1,
            bitDepth: Int = 8,
            compressionMode: JP3DCompressionMode = .lossless,
            tiling: JP3DTilingConfiguration = .streaming,
            progressionOrder: JP3DProgressionOrder = .lrcps,
            qualityLayers: Int = 1
        ) {
            self.width = max(1, width)
            self.height = max(1, height)
            self.depth = max(1, depth)
            self.componentCount = max(1, componentCount)
            self.bitDepth = max(1, min(38, bitDepth))
            self.compressionMode = compressionMode
            self.tiling = tiling
            self.progressionOrder = progressionOrder
            self.qualityLayers = max(1, qualityLayers)
        }
    }

    // MARK: - State

    private let config: Configuration
    private var state: JP3DStreamWriterState = .ready
    private var sliceBuffer: [Int: [Float]]
    private var encodedTiles: [Data]
    private var slicesReceived: Int = 0
    private var progressCallback: (@Sendable (JP3DStreamProgress) -> Void)?

    // MARK: - Init

    /// Creates a streaming encoder with the given configuration.
    public init(configuration: Configuration) {
        self.config = configuration
        self.sliceBuffer = [:]
        self.encodedTiles = []
    }

    // MARK: - Public API

    /// The current state of the writer.
    public var writerState: JP3DStreamWriterState { state }

    /// Sets the progress reporting callback.
    public func setProgressCallback(_ callback: @escaping @Sendable (JP3DStreamProgress) -> Void) {
        self.progressCallback = callback
    }

    /// Adds a slice of data to the encoder.
    public func addSlice(_ data: [Float], atIndex index: Int) throws {
        guard state == .ready || state == .encoding else {
            throw J2KError.encodingError("Writer is in state \(state), cannot add slices")
        }

        guard index >= 0, index < config.depth else {
            throw J2KError.invalidParameter(
                "Slice index \(index) out of range [0, \(config.depth))"
            )
        }

        let expectedSize = config.width * config.height * config.componentCount
        guard data.count == expectedSize else {
            throw J2KError.invalidParameter(
                "Slice data count \(data.count) does not match expected \(expectedSize)"
            )
        }

        state = .encoding
        sliceBuffer[index] = data
        slicesReceived += 1

        let tileGrid = config.tiling.tileGrid(
            volumeWidth: config.width,
            volumeHeight: config.height,
            volumeDepth: config.depth
        )
        let totalTiles = tileGrid.tilesX * tileGrid.tilesY * tileGrid.tilesZ
        let progress = JP3DStreamProgress(
            slicesReceived: slicesReceived,
            totalSlices: config.depth,
            tilesEncoded: encodedTiles.count,
            totalTiles: totalTiles
        )
        progressCallback?(progress)

        try flushCompleteTiles()
    }

    /// Finalises the encoding and returns the complete codestream.
    public func finalize() throws -> Data {
        guard state == .encoding || state == .ready else {
            throw J2KError.encodingError("Writer is in state \(state), cannot finalize")
        }

        try flushAllRemainingTiles()

        let builder = JP3DCodestreamBuilder()
        let params = makeStreamingCodingParameters()
        let codestream = builder.buildPreallocated(
            tileData: encodedTiles,
            width: config.width,
            height: config.height,
            depth: config.depth,
            components: config.componentCount,
            bitDepth: config.bitDepth,
            signed: false,
            levelsX: params.cod.levelsX,
            levelsY: params.cod.levelsY,
            levelsZ: params.cod.levelsZ,
            tileSizeX: config.tiling.tileSizeX,
            tileSizeY: config.tiling.tileSizeY,
            tileSizeZ: config.tiling.tileSizeZ,
            isLossless: params.cod.isLossless,
            htj2kConfiguration: params.htConfig,
            capacity: 0,
            codOverride: params.cod,
            qcdOverride: params.qcd
        )

        state = .finalized
        return codestream
    }

    /// Cancels the encoding process.
    public func cancel() {
        state = .cancelled
        sliceBuffer.removeAll()
        encodedTiles.removeAll()
    }

    /// Returns the number of slices received.
    public var receivedSliceCount: Int { slicesReceived }

    // MARK: - Private

    private func flushCompleteTiles() throws {
        let tileGrid = config.tiling.tileGrid(
            volumeWidth: config.width,
            volumeHeight: config.height,
            volumeDepth: config.depth
        )

        for tz in 0..<tileGrid.tilesZ {
            let zStart = tz * config.tiling.tileSizeZ
            let zEnd = min(zStart + config.tiling.tileSizeZ, config.depth)

            var allAvailable = true
            for z in zStart..<zEnd where sliceBuffer[z] == nil {
                allAvailable = false
                break
            }

            guard allAvailable else { continue }

            let expectedPriorTiles = tz * tileGrid.tilesX * tileGrid.tilesY
            guard encodedTiles.count == expectedPriorTiles else { continue }

            try encodeTileRow(tz: tz, tileGrid: tileGrid, zStart: zStart, zEnd: zEnd)

            for z in zStart..<zEnd {
                sliceBuffer.removeValue(forKey: z)
            }
        }
    }

    private func flushAllRemainingTiles() throws {
        let tileGrid = config.tiling.tileGrid(
            volumeWidth: config.width,
            volumeHeight: config.height,
            volumeDepth: config.depth
        )
        let totalExpectedTiles = tileGrid.tilesX * tileGrid.tilesY * tileGrid.tilesZ

        guard encodedTiles.count < totalExpectedTiles else { return }

        for tz in 0..<tileGrid.tilesZ {
            let expectedCount = (tz + 1) * tileGrid.tilesX * tileGrid.tilesY
            guard encodedTiles.count < expectedCount else { continue }
            guard encodedTiles.count == tz * tileGrid.tilesX * tileGrid.tilesY else { continue }

            let zStart = tz * config.tiling.tileSizeZ
            let zEnd = min(zStart + config.tiling.tileSizeZ, config.depth)
            try encodeTileRow(tz: tz, tileGrid: tileGrid, zStart: zStart, zEnd: zEnd)
        }
    }

    private func encodeTileRow(
        tz: Int,
        tileGrid: (tilesX: Int, tilesY: Int, tilesZ: Int),
        zStart: Int,
        zEnd: Int
    ) throws {
        let params = makeStreamingCodingParameters()
        let componentBitDepths = [Int](repeating: config.bitDepth, count: config.componentCount)
        let componentSigned = [Bool](repeating: false, count: config.componentCount)
        let maxVal = (Int64(1) << Int64(max(1, min(38, config.bitDepth)))) - 1

        for ty in 0..<tileGrid.tilesY {
            for tx in 0..<tileGrid.tilesX {
                let tile = config.tiling.tile(
                    atX: tx, y: ty, z: tz,
                    volumeWidth: config.width,
                    volumeHeight: config.height,
                    volumeDepth: config.depth
                )

                var compVoxels: [[Int64]] = []
                compVoxels.reserveCapacity(config.componentCount)
                for comp in 0..<config.componentCount {
                    let tileData = extractTileFromSlices(
                        tile: tile, componentIndex: comp, zStart: zStart, zEnd: zEnd
                    )
                    let ints: [Int64] = tileData.map { val in
                        let d = Double(val).rounded()
                        guard d.isFinite else { return 0 }
                        if d <= 0 { return 0 }
                        if d >= Double(maxVal) { return maxVal }
                        return Int64(d)
                    }
                    compVoxels.append(ints)
                }

                let tileBytes = try JP3DNormativeTileCodec.encodeTile(
                    componentVoxels: compVoxels,
                    componentBitDepths: componentBitDepths,
                    componentSigned: componentSigned,
                    x0: tile.region.x.lowerBound,
                    x1: tile.region.x.upperBound,
                    y0: tile.region.y.lowerBound,
                    y1: tile.region.y.upperBound,
                    z0: tile.region.z.lowerBound,
                    z1: tile.region.z.upperBound,
                    cod: params.cod,
                    qcd: params.qcd,
                    htConfiguration: params.htConfig,
                    targetBitrateBPP: params.targetBitrateBPP.map { Float($0) },
                    cancellation: {
                        if Task.isCancelled { throw CancellationError() }
                    }
                )
                encodedTiles.append(tileBytes)
            }
        }
    }

    private func extractTileFromSlices(
        tile: JP3DTile,
        componentIndex: Int,
        zStart: Int,
        zEnd: Int
    ) -> [Float] {
        let tw = tile.width
        let th = tile.height
        let td = tile.depth
        var data = [Float](repeating: 0, count: tw * th * td)

        let compStride = config.width * config.height

        for z in 0..<td {
            let sliceIndex = tile.region.z.lowerBound + z
            guard let sliceData = sliceBuffer[sliceIndex] else { continue }

            for y in 0..<th {
                let srcY = tile.region.y.lowerBound + y
                guard srcY < config.height else { continue }
                let srcYOffset = componentIndex * compStride + srcY * config.width
                for x in 0..<tw {
                    let srcX = tile.region.x.lowerBound + x
                    guard srcX < config.width else { continue }
                    let srcIdx = srcYOffset + srcX
                    let dstIdx = z * tw * th + y * tw + x
                    if srcIdx < sliceData.count {
                        data[dstIdx] = sliceData[srcIdx]
                    }
                }
            }
        }

        return data
    }

    private func axisDecompositionLevels(dim: Int) -> Int {
        guard dim > 1 else { return 0 }
        var levels = 0
        var d = dim
        while d > 1 {
            d = (d + 1) / 2
            levels += 1
        }
        return min(levels, 3)
    }

    private func makeStreamingCodingParameters() -> (
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        htConfig: JP3DHTJ2KConfiguration?,
        targetBitrateBPP: Double?
    ) {
        let lx = axisDecompositionLevels(dim: min(config.width, config.tiling.tileSizeX))
        let ly = axisDecompositionLevels(dim: min(config.height, config.tiling.tileSizeY))
        let lz = axisDecompositionLevels(dim: min(config.depth, config.tiling.tileSizeZ))
        let encConfig = JP3DEncoderConfiguration(
            compressionMode: config.compressionMode,
            tiling: config.tiling,
            progressionOrder: config.progressionOrder,
            qualityLayers: config.qualityLayers,
            levelsX: lx,
            levelsY: ly,
            levelsZ: lz
        )
        return JP3DEncoder.makeNormativeCodingParameters(
            configuration: encConfig,
            componentBitDepths: [Int](repeating: config.bitDepth, count: config.componentCount),
            componentCount: config.componentCount
        )
    }
}
