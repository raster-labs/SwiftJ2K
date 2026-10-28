// SPDX-License-Identifier: Apache-2.0
//
// JP3DConfiguration.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DConfiguration.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Added checked integer arithmetic in J2K3DCoefficients allocation to prevent
//     overflow traps on untrusted dimensions.

import Foundation
import SwiftJ2K

/// Configuration for 3D tile decomposition in JP3D.
public struct JP3DTilingConfiguration: Sendable, Equatable {
    /// The tile size along the X-axis in voxels.
    public let tileSizeX: Int

    /// The tile size along the Y-axis in voxels.
    public let tileSizeY: Int

    /// The tile size along the Z-axis in voxels.
    public let tileSizeZ: Int

    /// Creates a tiling configuration with the specified tile sizes.
    public init(tileSizeX: Int = 256, tileSizeY: Int = 256, tileSizeZ: Int = 16) {
        self.tileSizeX = max(1, tileSizeX)
        self.tileSizeY = max(1, tileSizeY)
        self.tileSizeZ = max(1, tileSizeZ)
    }

    /// Internal/testing initialiser that preserves raw dimensions for validation tests.
    public init(uncheckedTileSizeX: Int, tileSizeY: Int, tileSizeZ: Int) {
        self.tileSizeX = uncheckedTileSizeX
        self.tileSizeY = tileSizeY
        self.tileSizeZ = tileSizeZ
    }

    // MARK: - Presets

    /// Default tiling configuration (256×256×16).
    public static let `default` = JP3DTilingConfiguration(
        tileSizeX: 256, tileSizeY: 256, tileSizeZ: 16
    )

    /// Streaming-optimised tiling configuration (128×128×8).
    public static let streaming = JP3DTilingConfiguration(
        tileSizeX: 128, tileSizeY: 128, tileSizeZ: 8
    )

    /// Batch processing tiling configuration (512×512×32).
    public static let batch = JP3DTilingConfiguration(
        tileSizeX: 512, tileSizeY: 512, tileSizeZ: 32
    )

    // MARK: - Tile Grid Computation

    /// Computes the number of tiles along each axis for the given volume dimensions.
    public func tileGrid(
        volumeWidth: Int, volumeHeight: Int, volumeDepth: Int
    ) -> (tilesX: Int, tilesY: Int, tilesZ: Int) {
        let tx = max(1, (volumeWidth + tileSizeX - 1) / tileSizeX)
        let ty = max(1, (volumeHeight + tileSizeY - 1) / tileSizeY)
        let tz = max(1, (volumeDepth + tileSizeZ - 1) / tileSizeZ)
        return (tx, ty, tz)
    }

    /// Returns the total number of tiles for the given volume dimensions.
    public func totalTiles(
        volumeWidth: Int, volumeHeight: Int, volumeDepth: Int
    ) -> Int {
        let grid = tileGrid(
            volumeWidth: volumeWidth, volumeHeight: volumeHeight, volumeDepth: volumeDepth
        )
        return grid.tilesX * grid.tilesY * grid.tilesZ
    }

    /// Computes the tile at the given grid indices for the specified volume.
    public func tile(
        atX indexX: Int, y indexY: Int, z indexZ: Int,
        volumeWidth: Int, volumeHeight: Int, volumeDepth: Int
    ) -> JP3DTile {
        let startX = indexX * tileSizeX
        let startY = indexY * tileSizeY
        let startZ = indexZ * tileSizeZ
        let endX = min(startX + tileSizeX, volumeWidth)
        let endY = min(startY + tileSizeY, volumeHeight)
        let endZ = min(startZ + tileSizeZ, volumeDepth)

        let region = JP3DRegion(
            x: startX..<endX,
            y: startY..<endY,
            z: startZ..<endZ
        )

        return JP3DTile(indexX: indexX, indexY: indexY, indexZ: indexZ, region: region)
    }

    /// Computes all tiles for the given volume dimensions.
    public func allTiles(
        volumeWidth: Int, volumeHeight: Int, volumeDepth: Int
    ) -> [JP3DTile] {
        let grid = tileGrid(
            volumeWidth: volumeWidth, volumeHeight: volumeHeight, volumeDepth: volumeDepth
        )
        var tiles: [JP3DTile] = []
        tiles.reserveCapacity(grid.tilesX * grid.tilesY * grid.tilesZ)

        for iz in 0..<grid.tilesZ {
            for iy in 0..<grid.tilesY {
                for ix in 0..<grid.tilesX {
                    tiles.append(
                        tile(
                            atX: ix, y: iy, z: iz,
                            volumeWidth: volumeWidth,
                            volumeHeight: volumeHeight,
                            volumeDepth: volumeDepth
                        )
                    )
                }
            }
        }

        return tiles
    }

    /// Returns tiles that intersect with the given region.
    public func tilesIntersecting(
        region: JP3DRegion,
        volumeWidth: Int, volumeHeight: Int, volumeDepth: Int
    ) -> [JP3DTile] {
        let startTileX = max(0, region.x.lowerBound / tileSizeX)
        let startTileY = max(0, region.y.lowerBound / tileSizeY)
        let startTileZ = max(0, region.z.lowerBound / tileSizeZ)

        let grid = tileGrid(
            volumeWidth: volumeWidth, volumeHeight: volumeHeight, volumeDepth: volumeDepth
        )
        let endTileX = min(grid.tilesX, (region.x.upperBound + tileSizeX - 1) / tileSizeX)
        let endTileY = min(grid.tilesY, (region.y.upperBound + tileSizeY - 1) / tileSizeY)
        let endTileZ = min(grid.tilesZ, (region.z.upperBound + tileSizeZ - 1) / tileSizeZ)

        var result: [JP3DTile] = []

        for iz in startTileZ..<endTileZ {
            for iy in startTileY..<endTileY {
                for ix in startTileX..<endTileX {
                    result.append(
                        tile(
                            atX: ix, y: iy, z: iz,
                            volumeWidth: volumeWidth,
                            volumeHeight: volumeHeight,
                            volumeDepth: volumeDepth
                        )
                    )
                }
            }
        }

        return result
    }

    /// Validates the tiling configuration.
    public func validate() throws {
        guard tileSizeX > 0 && tileSizeY > 0 && tileSizeZ > 0 else {
            throw J2KError.invalidTileConfiguration(
                "Tile dimensions must be positive: \(tileSizeX)×\(tileSizeY)×\(tileSizeZ)"
            )
        }
    }
}

/// Progression order for JP3D encoding.
public enum JP3DProgressionOrder: String, Sendable, Equatable, CaseIterable {
    /// Layer-Resolution-Component-Position-Slice.
    case lrcps = "LRCPS"

    /// Resolution-Layer-Component-Position-Slice.
    case rlcps = "RLCPS"

    /// Position-Component-Resolution-Layer-Slice.
    case pcrls = "PCRLS"

    /// Slice-Layer-Resolution-Component-Position.
    case slrcp = "SLRCP"

    /// Component-Position-Resolution-Layer-Slice.
    case cprls = "CPRLS"

    /// Convenience alias for ``lrcps``.
    public static let lrcp: JP3DProgressionOrder = .lrcps
}

/// Compression mode for JP3D encoding.
public enum JP3DCompressionMode: Sendable, Equatable {
    /// Mathematically lossless compression using 5/3 reversible wavelet.
    case lossless

    /// Lossy compression using 9/7 irreversible wavelet with target PSNR.
    case lossy(psnr: Double)

    /// Lossy compression with target bitrate.
    case targetBitrate(bitsPerVoxel: Double)

    /// Visually lossless compression.
    case visuallyLossless

    /// Lossless compression using HTJ2K for high throughput.
    case losslessHTJ2K

    /// Lossy compression using HTJ2K for high throughput.
    case lossyHTJ2K(psnr: Double)

    /// Whether this mode produces mathematically lossless output.
    public var isLossless: Bool {
        switch self {
        case .lossless, .losslessHTJ2K:
            return true
        default:
            return false
        }
    }

    /// Whether this mode uses HTJ2K encoding.
    public var isHTJ2K: Bool {
        switch self {
        case .losslessHTJ2K, .lossyHTJ2K:
            return true
        default:
            return false
        }
    }
}

/// Z-axis predictive coding policy for the slice-stack codec.
public enum JP3DZDeltaMode: Sendable, Equatable {
    /// Per-tile auto-decision: engage when the L1 probe accepts AND
    /// the slice area is large enough that the probe overhead can be amortised.
    case auto

    /// Engage Z-delta whenever the L1 probe accepts, ignoring the slice-area heuristic.
    case always

    /// Skip Z-delta entirely.
    case never

    /// Convenience alias for ``never``.
    public static let disabled: JP3DZDeltaMode = .never
}

/// Storage for 3D wavelet coefficients.
public struct J2K3DCoefficients: Sendable, Equatable {
    /// The width of the coefficient array.
    public let width: Int

    /// The height of the coefficient array.
    public let height: Int

    /// The depth of the coefficient array.
    public let depth: Int

    /// The number of decomposition levels.
    public let decompositionLevels: Int

    /// The coefficient data stored as Float values.
    public var data: [Float]

    /// Creates a coefficient storage with the specified dimensions.
    public init(width: Int, height: Int, depth: Int, decompositionLevels: Int = 0) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.depth = max(1, depth)
        self.decompositionLevels = max(0, decompositionLevels)
        let (wh, o1) = self.width.multipliedReportingOverflow(by: self.height)
        let (total, o2) = wh.multipliedReportingOverflow(by: self.depth)
        let safeCount = (o1 || o2) ? 0 : total
        self.data = [Float](repeating: 0, count: safeCount)
    }

    /// Creates a coefficient storage with pre-populated data.
    public init(width: Int, height: Int, depth: Int, decompositionLevels: Int = 0, data: [Float]) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.depth = max(1, depth)
        self.decompositionLevels = max(0, decompositionLevels)
        self.data = data
    }

    /// The total number of coefficients.
    public var count: Int {
        width * height * depth
    }

    /// Accesses a coefficient at the given 3D coordinates.
    public subscript(x: Int, y: Int, z: Int) -> Float {
        get {
            data[z * width * height + y * width + x]
        }
        set {
            data[z * width * height + y * width + x] = newValue
        }
    }
}

/// 3D subband identifier for volumetric wavelet decomposition.
public enum JP3DSubband: String, Sendable, Equatable, CaseIterable {
    /// Low-Low-Low (approximation).
    case lll = "LLL"

    /// High-Low-Low (X detail).
    case hll = "HLL"

    /// Low-High-Low (Y detail).
    case lhl = "LHL"

    /// High-High-Low (XY detail).
    case hhl = "HHL"

    /// Low-Low-High (Z detail).
    case llh = "LLH"

    /// High-Low-High (XZ detail).
    case hlh = "HLH"

    /// Low-High-High (YZ detail).
    case lhh = "LHH"

    /// High-High-High (XYZ detail).
    case hhh = "HHH"
}
