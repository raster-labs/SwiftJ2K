// SPDX-License-Identifier: Apache-2.0
//
// JP3DTiling.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DTiling.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.

import Foundation
import SwiftJ2K

/// Data extracted from a single 3D tile.
public struct JP3DTileData: Sendable {
    /// The tile this data belongs to.
    public let tile: JP3DTile

    /// The component index.
    public let componentIndex: Int

    /// Voxel data as Float values in row-major order: index = `z * width * height + y * width + x`.
    public let data: [Float]

    /// The width of this tile's data.
    public var width: Int { tile.width }

    /// The height of this tile's data.
    public var height: Int { tile.height }

    /// The depth of this tile's data.
    public var depth: Int { tile.depth }

    public init(tile: JP3DTile, componentIndex: Int, data: [Float]) {
        self.tile = tile
        self.componentIndex = componentIndex
        self.data = data
    }
}

/// Decomposes a volume into tiles and extracts tile data.
public struct JP3DTileDecomposer: Sendable {
    /// The tiling configuration.
    public let configuration: JP3DTilingConfiguration

    /// Creates a tile decomposer with the given configuration.
    public init(configuration: JP3DTilingConfiguration = .default) {
        self.configuration = configuration
    }

    /// Decomposes a volume into tiles.
    public func decompose(volume: J2KVolume) -> [JP3DTile] {
        let effectiveConfig = clampedConfiguration(for: volume)
        return effectiveConfig.allTiles(
            volumeWidth: volume.width,
            volumeHeight: volume.height,
            volumeDepth: volume.depth
        )
    }

    /// Extracts voxel data for a specific tile and component.
    public func extractTileData(
        from volume: J2KVolume,
        tile: JP3DTile,
        componentIndex: Int
    ) throws -> JP3DTileData {
        guard componentIndex >= 0, componentIndex < volume.components.count else {
            throw J2KError.invalidParameter(
                "Component index \(componentIndex) out of range [0, \(volume.components.count))"
            )
        }

        let component = volume.components[componentIndex]
        let tw = tile.width
        let th = tile.height
        let td = tile.depth
        let bytesPerSample = component.bytesPerSample
        var data = [Float](repeating: 0, count: tw * th * td)

        let region = tile.region
        let srcStride = component.width
        let srcSliceStride = component.width * component.height
        let signed = component.signed
        let dataCount = component.data.count
        component.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            data.withUnsafeMutableBufferPointer { dst in
                for z in 0..<td {
                    let srcZ = region.z.lowerBound + z
                    guard srcZ < component.depth else { continue }
                    let srcZOffset = srcZ * srcSliceStride
                    for y in 0..<th {
                        let srcY = region.y.lowerBound + y
                        guard srcY < component.height else { continue }
                        let srcYOffset = srcZOffset + srcY * srcStride
                        for x in 0..<tw {
                            let srcX = region.x.lowerBound + x
                            guard srcX < component.width else { continue }
                            let srcIdx = srcYOffset + srcX
                            let byteOffset = srcIdx * bytesPerSample
                            let dstIdx = z * tw * th + y * tw + x
                            if byteOffset + bytesPerSample <= dataCount {
                                var value = 0
                                for b in 0..<bytesPerSample {
                                    value |= Int(bytes[byteOffset + b]) << (b * 8)
                                }
                                if signed && bytesPerSample > 0 {
                                    let signBit = 1 << (bytesPerSample * 8 - 1)
                                    if value & signBit != 0 {
                                        value -= (signBit << 1)
                                    }
                                }
                                dst[dstIdx] = Float(value)
                            }
                        }
                    }
                }
            }
        }

        return JP3DTileData(tile: tile, componentIndex: componentIndex, data: data)
    }

    /// Returns a tiling configuration clamped to volume dimensions.
    public func clampedConfiguration(for volume: J2KVolume) -> JP3DTilingConfiguration {
        JP3DTilingConfiguration(
            tileSizeX: min(configuration.tileSizeX, max(1, volume.width)),
            tileSizeY: min(configuration.tileSizeY, max(1, volume.height)),
            tileSizeZ: min(configuration.tileSizeZ, max(1, volume.depth))
        )
    }

    /// Returns the tile grid dimensions for a volume.
    public func tileGrid(for volume: J2KVolume) -> (tilesX: Int, tilesY: Int, tilesZ: Int) {
        configuration.tileGrid(
            volumeWidth: volume.width,
            volumeHeight: volume.height,
            volumeDepth: volume.depth
        )
    }
}
