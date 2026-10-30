// SPDX-License-Identifier: Apache-2.0
//
// JP3DPacketFormation.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DPacketFormation.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Added optional `signed: Bool = false` parameter to JP3DCodestreamBuilder.build
//     so SIZ marker segments encode bit 7 of Ssiz (`0x80`) when voxel components are signed.

import Foundation
import SwiftJ2K

/// A single packet in the JP3D codestream.
public struct JP3DPacket: Sendable {
    /// Quality layer index.
    public let layer: Int

    /// Resolution level (0 = coarsest).
    public let resolutionLevel: Int

    /// Component index.
    public let componentIndex: Int

    /// Precinct position (linearised).
    public let precinctIndex: Int

    /// Slice index (Z position for slice-based progression).
    public let sliceIndex: Int

    /// The encoded data for this packet.
    public let data: Data

    /// Whether this packet contains any non-zero contributions.
    public var isEmpty: Bool { data.isEmpty }

    public init(
        layer: Int,
        resolutionLevel: Int,
        componentIndex: Int,
        precinctIndex: Int,
        sliceIndex: Int,
        data: Data
    ) {
        self.layer = layer
        self.resolutionLevel = resolutionLevel
        self.componentIndex = componentIndex
        self.precinctIndex = precinctIndex
        self.sliceIndex = sliceIndex
        self.data = data
    }
}

/// Generates the packet ordering for a 3D codestream.
public struct JP3DPacketSequencer: Sendable {
    /// The progression order.
    public let progressionOrder: JP3DProgressionOrder

    /// Creates a packet sequencer with the given progression order.
    public init(progressionOrder: JP3DProgressionOrder = .lrcps) {
        self.progressionOrder = progressionOrder
    }

    /// A single entry in the packet ordering sequence.
    public struct PacketIndex: Sendable, Equatable {
        /// Quality layer index.
        public let layer: Int
        /// Resolution level.
        public let resolution: Int
        /// Component index.
        public let component: Int
        /// Precinct index (spatial position).
        public let precinct: Int
        /// Slice index.
        public let slice: Int

        public init(layer: Int, resolution: Int, component: Int, precinct: Int, slice: Int) {
            self.layer = layer
            self.resolution = resolution
            self.component = component
            self.precinct = precinct
            self.slice = slice
        }
    }

    /// Computes the full packet ordering for the given codestream parameters.
    public func packetOrder(
        layers: Int,
        resolutions: Int,
        components: Int,
        precinctsPerResolution: [Int],
        slices: Int
    ) -> [PacketIndex] {
        let maxPrecincts = precinctsPerResolution.max() ?? 1

        switch progressionOrder {
        case .lrcps:
            return orderLRCPS(
                layers: layers, resolutions: resolutions, components: components,
                maxPrecincts: maxPrecincts, slices: slices,
                precinctsPerResolution: precinctsPerResolution
            )
        case .rlcps:
            return orderRLCPS(
                layers: layers, resolutions: resolutions, components: components,
                maxPrecincts: maxPrecincts, slices: slices,
                precinctsPerResolution: precinctsPerResolution
            )
        case .pcrls:
            return orderPCRLS(
                layers: layers, resolutions: resolutions, components: components,
                maxPrecincts: maxPrecincts, slices: slices,
                precinctsPerResolution: precinctsPerResolution
            )
        case .slrcp:
            return orderSLRCP(
                layers: layers, resolutions: resolutions, components: components,
                maxPrecincts: maxPrecincts, slices: slices,
                precinctsPerResolution: precinctsPerResolution
            )
        case .cprls:
            return orderCPRLS(
                layers: layers, resolutions: resolutions, components: components,
                maxPrecincts: maxPrecincts, slices: slices,
                precinctsPerResolution: precinctsPerResolution
            )
        }
    }

    // MARK: - Progression Orders

    private func orderLRCPS(
        layers: Int, resolutions: Int, components: Int,
        maxPrecincts: Int, slices: Int,
        precinctsPerResolution: [Int]
    ) -> [PacketIndex] {
        var indices: [PacketIndex] = []
        for l in 0..<layers {
            for r in 0..<resolutions {
                let pCount = r < precinctsPerResolution.count ? precinctsPerResolution[r] : 1
                for c in 0..<components {
                    for p in 0..<pCount {
                        for s in 0..<slices {
                            indices.append(PacketIndex(
                                layer: l, resolution: r, component: c,
                                precinct: p, slice: s
                            ))
                        }
                    }
                }
            }
        }
        return indices
    }

    private func orderRLCPS(
        layers: Int, resolutions: Int, components: Int,
        maxPrecincts: Int, slices: Int,
        precinctsPerResolution: [Int]
    ) -> [PacketIndex] {
        var indices: [PacketIndex] = []
        for r in 0..<resolutions {
            let pCount = r < precinctsPerResolution.count ? precinctsPerResolution[r] : 1
            for l in 0..<layers {
                for c in 0..<components {
                    for p in 0..<pCount {
                        for s in 0..<slices {
                            indices.append(PacketIndex(
                                layer: l, resolution: r, component: c,
                                precinct: p, slice: s
                            ))
                        }
                    }
                }
            }
        }
        return indices
    }

    private func orderPCRLS(
        layers: Int, resolutions: Int, components: Int,
        maxPrecincts: Int, slices: Int,
        precinctsPerResolution: [Int]
    ) -> [PacketIndex] {
        var indices: [PacketIndex] = []
        for p in 0..<maxPrecincts {
            for c in 0..<components {
                for r in 0..<resolutions {
                    let pCount = r < precinctsPerResolution.count ? precinctsPerResolution[r] : 1
                    guard p < pCount else { continue }
                    for l in 0..<layers {
                        for s in 0..<slices {
                            indices.append(PacketIndex(
                                layer: l, resolution: r, component: c,
                                precinct: p, slice: s
                            ))
                        }
                    }
                }
            }
        }
        return indices
    }

    private func orderSLRCP(
        layers: Int, resolutions: Int, components: Int,
        maxPrecincts: Int, slices: Int,
        precinctsPerResolution: [Int]
    ) -> [PacketIndex] {
        var indices: [PacketIndex] = []
        for s in 0..<slices {
            for l in 0..<layers {
                for r in 0..<resolutions {
                    let pCount = r < precinctsPerResolution.count ? precinctsPerResolution[r] : 1
                    for c in 0..<components {
                        for p in 0..<pCount {
                            indices.append(PacketIndex(
                                layer: l, resolution: r, component: c,
                                precinct: p, slice: s
                            ))
                        }
                    }
                }
            }
        }
        return indices
    }

    private func orderCPRLS(
        layers: Int, resolutions: Int, components: Int,
        maxPrecincts: Int, slices: Int,
        precinctsPerResolution: [Int]
    ) -> [PacketIndex] {
        var indices: [PacketIndex] = []
        for c in 0..<components {
            for p in 0..<maxPrecincts {
                for r in 0..<resolutions {
                    let pCount = r < precinctsPerResolution.count ? precinctsPerResolution[r] : 1
                    guard p < pCount else { continue }
                    for l in 0..<layers {
                        for s in 0..<slices {
                            indices.append(PacketIndex(
                                layer: l, resolution: r, component: c,
                                precinct: p, slice: s
                            ))
                        }
                    }
                }
            }
        }
        return indices
    }
}

/// Physical voxel spacing and origin coordinates stored in a JP3D main-header `COM` (`0xFF64`) marker segment.
public struct JP3DVolumeGeometry: Sendable, Equatable {
    /// 14-byte ASCII magic `"SJ2K3D_GEOM_V1"`.
    public static let magicBytes: [UInt8] = Array("SJ2K3D_GEOM_V1".utf8)
    /// Binary `COM` payload byte count (`14` magic bytes + `6 * 8 = 48` IEEE-754 bytes = `62` bytes).
    public static let payloadByteCount: Int = 62

    /// Voxel spacing along X (`0` indicates unset/unknown).
    public let spacingX: Double
    /// Voxel spacing along Y (`0` indicates unset/unknown).
    public let spacingY: Double
    /// Voxel spacing along Z (`0` indicates unset/unknown).
    public let spacingZ: Double
    /// Physical origin X coordinate.
    public let originX: Double
    /// Physical origin Y coordinate.
    public let originY: Double
    /// Physical origin Z coordinate.
    public let originZ: Double

    public init(
        spacingX: Double,
        spacingY: Double,
        spacingZ: Double,
        originX: Double,
        originY: Double,
        originZ: Double
    ) {
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.spacingZ = spacingZ
        self.originX = originX
        self.originY = originY
        self.originZ = originZ
    }

    /// Returns `true` when any spacing or origin coordinate differs from default `0`.
    public var hasNonDefaultValues: Bool {
        spacingX != 0 || spacingY != 0 || spacingZ != 0
            || originX != 0 || originY != 0 || originZ != 0
    }

    /// Serialises this geometry into a 62-byte binary `COM` payload (`"SJ2K3D_GEOM_V1"` + 6 big-endian IEEE-754 `UInt64` words).
    public func encodePayload() throws -> Data {
        guard spacingX.isFinite, spacingY.isFinite, spacingZ.isFinite,
              originX.isFinite, originY.isFinite, originZ.isFinite,
              spacingX >= 0, spacingY >= 0, spacingZ >= 0 else {
            throw J2KError.invalidParameter(
                "Volume geometry must have finite origin and finite non-negative spacing"
            )
        }
        var out = Data(capacity: Self.payloadByteCount)
        out.append(contentsOf: Self.magicBytes)
        for value in [spacingX, spacingY, spacingZ, originX, originY, originZ] {
            // Normalise -0.0 to +0.0 for deterministic canonical representation.
            let canonical = (value == 0) ? 0.0 : value
            var bits = canonical.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Decodes a binary `COM` payload if it carries the `"SJ2K3D_GEOM_V1"` prefix; throws on truncated or invalid geometry.
    public static func decodePayload(_ payload: Data) throws -> JP3DVolumeGeometry? {
        guard payload.count >= Self.magicBytes.count else { return nil }
        guard payload.prefix(Self.magicBytes.count).elementsEqual(Self.magicBytes) else {
            return nil
        }
        guard payload.count == Self.payloadByteCount else {
            throw J2KError.decodingError(
                "Truncated or malformed SJ2K3D_GEOM_V1 COM payload (\(payload.count) bytes, expected \(Self.payloadByteCount))"
            )
        }
        var values: [Double] = []
        values.reserveCapacity(6)
        let baseIdx = payload.startIndex + Self.magicBytes.count
        for i in 0..<6 {
            let off = baseIdx + i * 8
            var word: UInt64 = 0
            for b in 0..<8 {
                word = (word << 8) | UInt64(payload[off + b])
            }
            values.append(Double(bitPattern: word))
        }
        let geom = JP3DVolumeGeometry(
            spacingX: values[0],
            spacingY: values[1],
            spacingZ: values[2],
            originX: values[3],
            originY: values[4],
            originZ: values[5]
        )
        guard geom.spacingX.isFinite, geom.spacingY.isFinite, geom.spacingZ.isFinite,
              geom.originX.isFinite, geom.originY.isFinite, geom.originZ.isFinite,
              geom.spacingX >= 0, geom.spacingY >= 0, geom.spacingZ >= 0 else {
            throw J2KError.decodingError(
                "Invalid non-finite or negative spacing in SJ2K3D_GEOM_V1 COM payload"
            )
        }
        return geom
    }
}

/// A parsed or serialisable JPEG 2000 `COM` (`0xFF64`) marker segment (`Rcom` + payload bytes).
public struct JP3DCommentSegment: Sendable, Equatable {
    /// Registration value (`0` = binary data, `1` = ISO/IEC 8859-15 text).
    public let registration: UInt16
    /// Raw comment payload bytes following `Rcom`.
    public let payload: Data

    public init(registration: UInt16, payload: Data) {
        self.registration = registration
        self.payload = payload
    }

    /// Whether this `COM` segment carries `"SJ2K3D_GEOM_V1"` volume geometry.
    public var isVolumeGeometry: Bool {
        registration == 0
            && payload.count >= JP3DVolumeGeometry.magicBytes.count
            && payload.prefix(JP3DVolumeGeometry.magicBytes.count).elementsEqual(JP3DVolumeGeometry.magicBytes)
    }
}

/// Builds a JP3D codestream from packets.
public struct JP3DCodestreamBuilder: Sendable {
    /// JP3D marker segment identifiers.
    public enum Marker: UInt16, Sendable {
        /// Start of codestream.
        case soc = 0xFF4F
        /// End of codestream.
        case eoc = 0xFFD9
        /// Start of tile-part.
        case sot = 0xFF90
        /// Start of data.
        case sod = 0xFF93
        /// Image and tile size (SIZ marker).
        case siz = 0xFF51
        /// Coding style default (COD marker).
        case cod = 0xFF52
        /// Quantization default (QCD marker).
        case qcd = 0xFF5C
        /// Comment (COM marker).
        case com = 0xFF64
    }

    /// Creates a new codestream builder.
    public init() {}

    /// Builds a JP3D codestream from encoded tile data.
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
        geometry: JP3DVolumeGeometry? = nil,
        comments: [JP3DCommentSegment] = []
    ) -> Data {
        buildPreallocated(
            tileData: tileData, width: width, height: height, depth: depth,
            components: components, bitDepth: bitDepth, signed: signed,
            levelsX: levelsX, levelsY: levelsY, levelsZ: levelsZ,
            tileSizeX: tileSizeX, tileSizeY: tileSizeY, tileSizeZ: tileSizeZ,
            isLossless: isLossless, geometry: geometry, comments: comments,
            htj2kConfiguration: nil, capacity: 0
        )
    }

    /// The caller admits `capacity` before allocating this single output buffer.
    /// HT markers are emitted in place, avoiding a second full codestream copy.
    internal func buildPreallocated(
        tileData: [Data], width: Int, height: Int, depth: Int,
        components: Int, bitDepth: Int, signed: Bool,
        levelsX: Int, levelsY: Int, levelsZ: Int,
        tileSizeX: Int, tileSizeY: Int, tileSizeZ: Int, isLossless: Bool,
        geometry: JP3DVolumeGeometry? = nil, comments: [JP3DCommentSegment],
        htj2kConfiguration: JP3DHTJ2KConfiguration?, capacity: Int
    ) -> Data {
        var stream = Data(capacity: capacity)

        appendMarker(&stream, .soc)
        appendSIZ(
            &stream,
            width: width, height: height, depth: depth,
            components: components, bitDepth: bitDepth, signed: signed,
            tileSizeX: tileSizeX, tileSizeY: tileSizeY, tileSizeZ: tileSizeZ
        )
        appendCOD(&stream, levelsX: levelsX, levelsY: levelsY, levelsZ: levelsZ, isLossless: isLossless)

        let maxLevels = max(levelsX, max(levelsY, levelsZ))
        appendQCD(&stream, bitDepth: bitDepth, levels: maxLevels, isLossless: isLossless)

        if let htj2kConfiguration {
            // CAP (10 bytes) and CPF (6 bytes), as in JP3DHTMarkers.
            appendUInt16BE(&stream, JP3DHTMarkers.capMarkerCode)
            appendUInt16BE(&stream, 8)
            appendUInt32BE(&stream, 1 << 14)
            appendUInt16BE(&stream, htj2kConfiguration.allowMixedTiles ? 3 : 1)
            appendUInt16BE(&stream, JP3DHTMarkers.cpfMarkerCode)
            appendUInt16BE(&stream, 4)
            appendUInt16BE(&stream, isLossless ? 0x8000 : 0x8001)
        }

        var emittedGeometry = false
        if let geometry, geometry.hasNonDefaultValues, let payload = try? geometry.encodePayload() {
            appendCOM(&stream, registration: 0, payload: payload)
            emittedGeometry = true
        }
        for comment in comments {
            if emittedGeometry && comment.isVolumeGeometry {
                continue
            }
            appendCOM(&stream, registration: comment.registration, payload: comment.payload)
        }

        for (index, data) in tileData.enumerated() {
            appendSOT(&stream, tileIndex: index, tilePartLength: data.count)
            appendMarker(&stream, .sod)
            stream.append(data)
        }

        appendMarker(&stream, .eoc)

        return stream
    }

    /// Exact serialized size for an existing stream's comments and replacement tiles.
    /// This route preserves geometry through its existing COM payload, so it does not
    /// allocate or re-encode a separate geometry payload during publication.
    internal func projectedByteCount(
        tileData: [Data], components: Int, levelsX: Int, levelsY: Int, levelsZ: Int,
        isLossless: Bool, includesHTMarkers: Bool, comments: [JP3DCommentSegment]
    ) throws -> Int {
        guard components > 0, components <= (Int(UInt16.max) - 46) / 3,
              (0...255).contains(levelsX), (0...255).contains(levelsY),
              (0...255).contains(levelsZ), tileData.count <= Int(UInt16.max) + 1 else {
            throw CodecError(.resourceLimitExceeded, "Codestream marker dimensions exceed their serialized range")
        }
        // SOC + SIZ + COD + QCD fixed fields + EOC; variable SIZ/QCD follow.
        var count = 73 + 3 * components
        func add(_ bytes: Int) throws {
            let (next, overflow) = count.addingReportingOverflow(bytes)
            guard bytes >= 0, !overflow else {
                throw CodecError(.resourceLimitExceeded, "Codestream publication size overflows Int")
            }
            count = next
        }
        try add((3 * max(levelsX, max(levelsY, levelsZ)) + 1) * (isLossless ? 1 : 2))
        if includesHTMarkers { try add(16) }
        for comment in comments {
            guard comment.payload.count <= 65_531 else {
                throw CodecError(.resourceLimitExceeded, "Comment exceeds COM marker capacity")
            }
            try add(6 + comment.payload.count)
        }
        for tile in tileData {
            guard tile.count <= Int(UInt32.max) - 14 else {
                throw CodecError(.resourceLimitExceeded, "Tile exceeds SOT marker capacity")
            }
            try add(14 + tile.count)
        }
        return count
    }

    // MARK: - Private Helpers

    private func appendMarker(_ stream: inout Data, _ marker: Marker) {
        var value = marker.rawValue.bigEndian
        stream.append(contentsOf: withUnsafeBytes(of: &value) { Array($0) })
    }

    private func appendUInt16BE(_ stream: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        stream.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private func appendUInt32BE(_ stream: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        stream.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private func appendSIZ(
        _ stream: inout Data,
        width: Int, height: Int, depth: Int,
        components: Int, bitDepth: Int, signed: Bool,
        tileSizeX: Int, tileSizeY: Int, tileSizeZ: Int
    ) {
        appendMarker(&stream, .siz)
        let segmentLength = UInt16(38 + 3 * components + 8)
        appendUInt16BE(&stream, segmentLength)
        appendUInt16BE(&stream, 0)
        appendUInt32BE(&stream, UInt32(width))
        appendUInt32BE(&stream, UInt32(height))
        appendUInt32BE(&stream, 0)
        appendUInt32BE(&stream, 0)
        appendUInt32BE(&stream, UInt32(tileSizeX))
        appendUInt32BE(&stream, UInt32(tileSizeY))
        appendUInt32BE(&stream, 0)
        appendUInt32BE(&stream, 0)
        appendUInt16BE(&stream, UInt16(components))
        let ssizBase = UInt8(max(0, min(127, bitDepth - 1)))
        let ssiz: UInt8 = signed ? (ssizBase | 0x80) : ssizBase
        for _ in 0..<components {
            stream.append(ssiz)
            stream.append(UInt8(1))
            stream.append(UInt8(1))
        }
        appendUInt32BE(&stream, UInt32(depth))
        appendUInt32BE(&stream, UInt32(tileSizeZ))
    }

    private func appendCOD(_ stream: inout Data, levelsX: Int, levelsY: Int, levelsZ: Int, isLossless: Bool) {
        appendMarker(&stream, .cod)
        let segmentLength: UInt16 = 14
        appendUInt16BE(&stream, segmentLength)
        stream.append(UInt8(0))
        stream.append(UInt8(0))
        appendUInt16BE(&stream, 1)
        stream.append(UInt8(0))
        stream.append(UInt8(levelsX))
        stream.append(UInt8(levelsY))
        stream.append(UInt8(levelsZ))
        stream.append(UInt8(4))
        stream.append(UInt8(4))
        stream.append(UInt8(0))
        stream.append(isLossless ? UInt8(1) : UInt8(0))
    }

    private func appendQCD(_ stream: inout Data, bitDepth: Int, levels: Int, isLossless: Bool) {
        appendMarker(&stream, .qcd)
        let numSubbands = 3 * levels + 1
        let segmentLength = UInt16(3 + numSubbands * (isLossless ? 1 : 2))
        appendUInt16BE(&stream, segmentLength)
        if isLossless {
            stream.append(UInt8(0))
            for _ in 0..<numSubbands {
                stream.append(UInt8((3 << 5) | (bitDepth & 0x1F)))
            }
        } else {
            stream.append(UInt8(2))
            for _ in 0..<numSubbands {
                appendUInt16BE(&stream, UInt16((3 << 11) | ((bitDepth & 0x1F) << 6)))
            }
        }
    }

    private func appendSOT(_ stream: inout Data, tileIndex: Int, tilePartLength: Int) {
        appendMarker(&stream, .sot)
        let segmentLength: UInt16 = 10
        appendUInt16BE(&stream, segmentLength)
        appendUInt16BE(&stream, UInt16(tileIndex))
        let totalLength = UInt32(12 + 2 + tilePartLength)
        appendUInt32BE(&stream, totalLength)
        stream.append(UInt8(0))
        stream.append(UInt8(1))
    }

    private func appendCOM(_ stream: inout Data, registration: UInt16, payload: Data) {
        guard payload.count <= 65_531 else { return }
        appendMarker(&stream, .com)
        appendUInt16BE(&stream, UInt16(4 + payload.count))
        appendUInt16BE(&stream, registration)
        stream.append(payload)
    }
}
