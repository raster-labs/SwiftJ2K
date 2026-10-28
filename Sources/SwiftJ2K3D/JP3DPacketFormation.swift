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
        isLossless: Bool
    ) -> Data {
        var stream = Data()

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

        for (index, data) in tileData.enumerated() {
            appendSOT(&stream, tileIndex: index, tilePartLength: data.count)
            appendMarker(&stream, .sod)
            stream.append(data)
        }

        appendMarker(&stream, .eoc)

        return stream
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
}
