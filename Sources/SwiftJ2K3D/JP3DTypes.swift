// SPDX-License-Identifier: Apache-2.0
//
// JP3DTypes.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DTypes.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Re-exported SwiftJ2K (@_exported import SwiftJ2K) so consumers importing
//     SwiftJ2K3D gain access to J2KVolume, J2KVolumeComponent, J2KVolumeMetadata,
//     J2KError, CodecError, ExecutionPolicy, ResourceLimits, and OperationReport.

import Foundation
@_exported import SwiftJ2K

/// Represents a three-dimensional region of interest within a volume.
///
/// A `JP3DRegion` defines a rectangular cuboid region specified by
/// start and end coordinates along each axis. Regions are used for
/// ROI specification in encoding, decoding, and streaming operations.
public struct JP3DRegion: Sendable, Equatable {
    /// The range along the X-axis.
    public let x: Range<Int>

    /// The range along the Y-axis.
    public let y: Range<Int>

    /// The range along the Z-axis.
    public let z: Range<Int>

    /// Creates a region with the specified ranges.
    public init(x: Range<Int>, y: Range<Int>, z: Range<Int>) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Creates a region from origin coordinates and dimensions.
    public init(originX: Int, originY: Int, originZ: Int, width: Int, height: Int, depth: Int) {
        let safeW = max(0, width)
        let safeH = max(0, height)
        let safeD = max(0, depth)
        let (endX, ovX) = originX.addingReportingOverflow(safeW)
        let (endY, ovY) = originY.addingReportingOverflow(safeH)
        let (endZ, ovZ) = originZ.addingReportingOverflow(safeD)
        self.x = originX..<(ovX ? Int.max : max(originX, endX))
        self.y = originY..<(ovY ? Int.max : max(originY, endY))
        self.z = originZ..<(ovZ ? Int.max : max(originZ, endZ))
    }

    /// Creates a region starting at the origin with the given dimensions.
    public init(width: Int, height: Int, depth: Int) {
        self.x = 0..<max(0, width)
        self.y = 0..<max(0, height)
        self.z = 0..<max(0, depth)
    }

    // MARK: - Properties

    /// The width of the region (extent along X).
    public var width: Int { x.count }

    /// The height of the region (extent along Y).
    public var height: Int { y.count }

    /// The depth of the region (extent along Z).
    public var depth: Int { z.count }

    /// The total number of voxels in this region.
    public var volume: Int {
        let (wh, ov1) = width.multipliedReportingOverflow(by: height)
        if ov1 { return Int.max }
        let (whd, ov2) = wh.multipliedReportingOverflow(by: depth)
        return ov2 ? Int.max : whd
    }

    /// Alias for ``volume`` (total number of voxels in this region).
    public var voxelCount: Int { volume }

    /// Returns true if the region is empty (zero volume).
    public var isEmpty: Bool { width <= 0 || height <= 0 || depth <= 0 }

    /// Returns the intersection of this region with another region.
    public func intersection(_ other: JP3DRegion) -> JP3DRegion? {
        let xStart = max(x.lowerBound, other.x.lowerBound)
        let xEnd = min(x.upperBound, other.x.upperBound)
        let yStart = max(y.lowerBound, other.y.lowerBound)
        let yEnd = min(y.upperBound, other.y.upperBound)
        let zStart = max(z.lowerBound, other.z.lowerBound)
        let zEnd = min(z.upperBound, other.z.upperBound)

        guard xStart < xEnd && yStart < yEnd && zStart < zEnd else {
            return nil
        }

        return JP3DRegion(x: xStart..<xEnd, y: yStart..<yEnd, z: zStart..<zEnd)
    }

    /// Returns true if this region contains the specified point.
    public func contains(x px: Int, y py: Int, z pz: Int) -> Bool {
        x.contains(px) && y.contains(py) && z.contains(pz)
    }

    /// Returns a region clamped to the given volume dimensions.
    public func clamped(toWidth width: Int, height: Int, depth: Int) -> JP3DRegion {
        let clampedX = max(0, x.lowerBound)..<min(width, x.upperBound)
        let clampedY = max(0, y.lowerBound)..<min(height, y.upperBound)
        let clampedZ = max(0, z.lowerBound)..<min(depth, z.upperBound)
        return JP3DRegion(x: clampedX, y: clampedY, z: clampedZ)
    }
}

/// Represents a three-dimensional tile in a JP3D volume.
public struct JP3DTile: Sendable, Equatable {
    /// The tile index along the X-axis.
    public let indexX: Int

    /// The tile index along the Y-axis.
    public let indexY: Int

    /// The tile index along the Z-axis.
    public let indexZ: Int

    /// The region of the volume covered by this tile.
    public let region: JP3DRegion

    /// Creates a new 3D tile.
    public init(indexX: Int, indexY: Int, indexZ: Int, region: JP3DRegion) {
        self.indexX = indexX
        self.indexY = indexY
        self.indexZ = indexZ
        self.region = region
    }

    /// The linear index of this tile in a tile grid.
    public func linearIndex(tilesX: Int, tilesY: Int) -> Int {
        indexZ * tilesX * tilesY + indexY * tilesX + indexX
    }

    /// The width of this tile in voxels.
    public var width: Int { region.width }

    /// The height of this tile in voxels.
    public var height: Int { region.height }

    /// The depth of this tile in voxels.
    public var depth: Int { region.depth }
}

/// Represents a three-dimensional precinct in the wavelet decomposition.
public struct JP3DPrecinct: Sendable, Equatable {
    /// The precinct index along the X-axis.
    public let indexX: Int

    /// The precinct index along the Y-axis.
    public let indexY: Int

    /// The precinct index along the Z-axis.
    public let indexZ: Int

    /// The resolution level of this precinct.
    public let resolutionLevel: Int

    /// The component index.
    public let componentIndex: Int

    /// The spatial region covered by this precinct.
    public let region: JP3DRegion

    /// Creates a new 3D precinct.
    public init(
        indexX: Int,
        indexY: Int,
        indexZ: Int,
        resolutionLevel: Int,
        componentIndex: Int = 0,
        region: JP3DRegion
    ) {
        self.indexX = indexX
        self.indexY = indexY
        self.indexZ = indexZ
        self.resolutionLevel = resolutionLevel
        self.componentIndex = componentIndex
        self.region = region
    }

    /// The linear index of this precinct in a precinct grid.
    public func linearIndex(precinctsX: Int, precinctsY: Int) -> Int {
        indexZ * precinctsX * precinctsY + indexY * precinctsX + indexX
    }
}
