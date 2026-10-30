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
//   - Implemented normative ITU-T T.809 (05/2011) | ISO/IEC 15444-10 codestream serialization:
//     SIZ (Lsiz = 38 + 3*Csiz, Rsiz = 0x4000, heterogeneous per-component Ssiz^i),
//     mandatory CAP (0xFF50) immediately after SIZ (Pcap = 0x0040_0000, or reconciled
//     Pcap = 0x0042_0000 + CPF 0xFF59 when HTJ2K is active), NSI (0xFF54, Lnsi = 19 + Csiz,
//     Ndim = 3), 3D COD (0xFF52, Lcod = 17 [+ 2*(NL+1)], shift=0 xcb/ycb/zcb, dwtX/Y/Z),
//     Morton-order 3D QCD (0xFF5C), optional RGN (0xFF5E), COM (0xFF64), SOT/SOD, and EOC.

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
    ///
    /// Note: For normative ITU-T T.809 3D precincts (where Z is part of the 3D `(pz, py, px)` precinct index, `slices == 1`),
    /// `.slrcp` corresponds to normative progression order `2` (`RPCL`: resolution-precinct(Z,Y,X)-component-layer).
    /// When `slices > 1`, `.slrcp` retains its multi-slice outer-Z ordering for backward API compatibility.
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
            if slices <= 1 {
                return orderRPCL(
                    layers: layers, resolutions: resolutions, components: components,
                    slices: max(1, slices), precinctsPerResolution: precinctsPerResolution
                )
            }
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
        _ = maxPrecincts
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
        _ = maxPrecincts
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

    private func orderRPCL(
        layers: Int, resolutions: Int, components: Int,
        slices: Int, precinctsPerResolution: [Int]
    ) -> [PacketIndex] {
        var indices: [PacketIndex] = []
        for r in 0..<resolutions {
            let pCount = r < precinctsPerResolution.count ? precinctsPerResolution[r] : 1
            for p in 0..<pCount {
                for c in 0..<components {
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
        _ = maxPrecincts
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

/// Builds an ITU-T T.809 | ISO/IEC 15444-10 (JP3D) codestream from encoded tile-part bitstreams.
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
        /// Extended capabilities (`CAP`, mandatory in Part 10 with `Pcap^10 = 0x0040_0000`).
        case cap = 0xFF50
        /// Image and tile size (`SIZ`, `Lsiz = 38 + 3*Csiz`).
        case siz = 0xFF51
        /// Coding style default (`COD`, `Lcod = 17 [+ 2*(NL+1)]`).
        case cod = 0xFF52
        /// N-dimensional size and tile information (`NSI`, `Lnsi = 19 + Csiz`).
        case nsi = 0xFF54
        /// Corresponding profile (`CPF`).
        case cpf = 0xFF59
        /// Quantisation default (`QCD`).
        case qcd = 0xFF5C
        /// Region of interest (`RGN`).
        case rgn = 0xFF5E
        /// Comment (`COM`).
        case com = 0xFF64
    }

    /// Creates a new codestream builder.
    public init() {}

    /// Builds a normative ITU-T T.809 JP3D codestream from encoded tile data.
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
    /// Normative `SIZ`, `CAP` (+ `CPF` when HTJ2K is active), `NSI`, `COD`, `QCD`, `RGN`, `COM`, `SOT`/`SOD`, and `EOC`
    /// are emitted directly in place without intermediate copies.
    package func buildPreallocated(
        tileData: [Data], width: Int, height: Int, depth: Int,
        components: Int, bitDepth: Int, signed: Bool,
        levelsX: Int, levelsY: Int, levelsZ: Int,
        tileSizeX: Int, tileSizeY: Int, tileSizeZ: Int, isLossless: Bool,
        geometry: JP3DVolumeGeometry? = nil, comments: [JP3DCommentSegment] = [],
        htj2kConfiguration: JP3DHTJ2KConfiguration?, capacity: Int,
        componentBitDepths: [Int]? = nil,
        componentSigned: [Bool]? = nil,
        codOverride: JP3DCODInfo? = nil,
        qcdOverride: JP3DQuantizationParameters? = nil,
        roiShifts: [Int] = []
    ) -> Data {
        var stream = Data(capacity: max(0, capacity))

        let effectiveCOD: JP3DCODInfo
        if let codOverride {
            effectiveCOD = codOverride
        } else {
            let htStyle: UInt8
            if let htCfg = htj2kConfiguration {
                htStyle = htCfg.allowMixedTiles ? 0xC0 : 0x40
            } else {
                htStyle = 0x00
            }
            let zcb = (htj2kConfiguration != nil) ? 0 : 2
            let w: UInt8 = isLossless ? 1 : 0
            effectiveCOD = JP3DCODInfo(
                levelsX: levelsX,
                levelsY: levelsY,
                levelsZ: levelsZ,
                isLossless: isLossless,
                codeBlockStyle: htStyle,
                scod: 0,
                progressionOrderByte: 0,
                numLayers: 1,
                multipleComponentTransform: 0,
                codeBlockWidthExponent: 6,
                codeBlockHeightExponent: 6,
                codeBlockDepthExponent: zcb,
                dwtX: w,
                dwtY: w,
                dwtZ: w,
                precinctSizes: []
            )
        }

        let maxCompBitDepth = max(bitDepth, componentBitDepths?.max() ?? bitDepth)
        let usesMCT = effectiveCOD.multipleComponentTransform == 1 && components >= 3
        let effectiveQCD: JP3DQuantizationParameters
        if let qcdOverride {
            effectiveQCD = qcdOverride
        } else if effectiveCOD.isLossless {
            effectiveQCD = .makeReversible(
                maxBitDepth: maxCompBitDepth,
                levelsX: effectiveCOD.levelsX,
                levelsY: effectiveCOD.levelsY,
                levelsZ: effectiveCOD.levelsZ,
                usesReversibleMCT: usesMCT
            )
        } else {
            effectiveQCD = .makeIrreversible(
                maxBitDepth: maxCompBitDepth,
                levelsX: effectiveCOD.levelsX,
                levelsY: effectiveCOD.levelsY,
                levelsZ: effectiveCOD.levelsZ
            )
        }

        // 1. SOC (0xFF4F)
        appendMarker(&stream, .soc)

        // 2. SIZ (0xFF51, Lsiz = 38 + 3*Csiz, Rsiz = 0x4000)
        appendSIZ(
            &stream,
            width: width, height: height,
            components: components, bitDepth: bitDepth, signed: signed,
            componentBitDepths: componentBitDepths, componentSigned: componentSigned,
            tileSizeX: tileSizeX, tileSizeY: tileSizeY
        )

        // 3. Mandatory CAP (0xFF50) immediately after SIZ (ITU-T T.809 Table A.2), plus CPF (0xFF59) when HTJ2K is active.
        if let htj2kConfiguration {
            let maxExp = effectiveQCD.steps.map(\.exponent).max() ?? maxCompBitDepth
            let maxMb = max(8, effectiveQCD.guardBits + maxExp - 1)
            stream.append(JP3DHTMarkers.capMarkerData(
                for: htj2kConfiguration,
                isLossless: effectiveCOD.isLossless,
                maxMb: maxMb
            ))
            stream.append(JP3DHTMarkers.cpfMarkerData(
                for: htj2kConfiguration,
                isLossless: effectiveCOD.isLossless
            ))
        } else {
            appendMarker(&stream, .cap)
            appendUInt16BE(&stream, 8)              // Lcap = 8 (1 Pcap bit set)
            appendUInt32BE(&stream, 0x0040_0000)    // Pcap^10 (ITU-T T.809 | ISO/IEC 15444-10)
            appendUInt16BE(&stream, 0x0000)         // Ccap^10
        }

        // 4. Mandatory NSI (0xFF54, Lnsi = 19 + Csiz, Ndim = 3)
        appendNSI(&stream, depth: depth, tileSizeZ: tileSizeZ, components: components)

        // 5. Normative 3D COD (0xFF52, Lcod = 17 [+ 2*(NL+1)])
        appendCOD(&stream, cod: effectiveCOD)

        // 6. Normative Morton-order 3D QCD (0xFF5C)
        appendQCD(&stream, qcd: effectiveQCD)

        // 7. Optional RGN (0xFF5E) Maxshift ROI segments
        for (compIdx, shift) in roiShifts.enumerated() where shift > 0 && compIdx < components {
            appendRGN(&stream, component: compIdx, totalComponents: components, shift: shift)
        }

        // 8. Optional COM (0xFF64) segments
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

        // 9. Tile-parts: SOT (0xFF90) + SOD (0xFF93) + packet bitstream
        for (index, data) in tileData.enumerated() {
            appendSOT(&stream, tileIndex: index, tilePartLength: data.count)
            appendMarker(&stream, .sod)
            stream.append(data)
        }

        // 10. EOC (0xFFD9)
        appendMarker(&stream, .eoc)

        return stream
    }

    /// Exact serialised byte count for preallocated publication admission.
    package func projectedByteCount(
        tileData: [Data], components: Int, levelsX: Int, levelsY: Int, levelsZ: Int,
        isLossless: Bool, includesHTMarkers: Bool, comments: [JP3DCommentSegment],
        codOverride: JP3DCODInfo? = nil,
        qcdOverride: JP3DQuantizationParameters? = nil,
        roiShifts: [Int] = []
    ) throws -> Int {
        guard components > 0, components <= (Int(UInt16.max) - 38) / 3,
              (0...32).contains(levelsX), (0...32).contains(levelsY),
              (0...32).contains(levelsZ), tileData.count <= Int(UInt16.max) + 1 else {
            throw CodecError(.resourceLimitExceeded, "Codestream marker dimensions exceed their serialized range")
        }
        // Base fixed bytes: SOC(2) + SIZ_fixed(40) + CAP_Part10(10) + NSI_fixed(21) + COD_fixed(19) + QCD_fixed(5) + EOC(2) = 99
        // Variable component bytes: SIZ(3*C) + NSI(1*C) = 4*C
        var count = 99 + 4 * components
        func add(_ bytes: Int) throws {
            let (next, overflow) = count.addingReportingOverflow(bytes)
            guard bytes >= 0, !overflow else {
                throw CodecError(.resourceLimitExceeded, "Codestream publication size overflows Int")
            }
            count = next
        }

        if let codOverride, codOverride.usesCustomPrecincts {
            let nl = max(codOverride.levelsX, max(codOverride.levelsY, codOverride.levelsZ))
            try add(2 * (nl + 1))
        }

        let qcdPayloadBytes: Int
        if let qcdOverride {
            switch qcdOverride.style {
            case 0:
                qcdPayloadBytes = qcdOverride.steps.count
            case 1:
                qcdPayloadBytes = 2
            default:
                qcdPayloadBytes = 2 * qcdOverride.steps.count
            }
        } else {
            let totalSubbands = JP3DQuantizationParameters.totalSubbandCount(
                levelsX: levelsX, levelsY: levelsY, levelsZ: levelsZ
            )
            qcdPayloadBytes = totalSubbands * (isLossless ? 1 : 2)
        }
        try add(qcdPayloadBytes)

        // HT adds +2 bytes to CAP (12 vs 10) and +6 bytes for CPF = +8 bytes.
        if includesHTMarkers { try add(8) }

        let rgnEach = components < 257 ? 7 : 8
        for (compIdx, shift) in roiShifts.enumerated() where shift > 0 && compIdx < components {
            try add(rgnEach)
        }

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
        width: Int, height: Int,
        components: Int, bitDepth: Int, signed: Bool,
        componentBitDepths: [Int]?, componentSigned: [Bool]?,
        tileSizeX: Int, tileSizeY: Int
    ) {
        appendMarker(&stream, .siz)
        let segmentLength = UInt16(38 + 3 * components)
        appendUInt16BE(&stream, segmentLength)
        appendUInt16BE(&stream, 0x4000) // Rsiz bit 14 signals extended capabilities (CAP)
        appendUInt32BE(&stream, UInt32(width))
        appendUInt32BE(&stream, UInt32(height))
        appendUInt32BE(&stream, 0)
        appendUInt32BE(&stream, 0)
        appendUInt32BE(&stream, UInt32(max(1, tileSizeX)))
        appendUInt32BE(&stream, UInt32(max(1, tileSizeY)))
        appendUInt32BE(&stream, 0)
        appendUInt32BE(&stream, 0)
        appendUInt16BE(&stream, UInt16(components))
        for c in 0..<components {
            let bd = (componentBitDepths != nil && c < componentBitDepths!.count) ? componentBitDepths![c] : bitDepth
            let sg = (componentSigned != nil && c < componentSigned!.count) ? componentSigned![c] : signed
            let ssizBase = UInt8(max(0, min(37, bd - 1)))
            let ssiz: UInt8 = sg ? (ssizBase | 0x80) : ssizBase
            stream.append(ssiz)
            stream.append(UInt8(1))
            stream.append(UInt8(1))
        }
    }

    private func appendNSI(_ stream: inout Data, depth: Int, tileSizeZ: Int, components: Int) {
        appendMarker(&stream, .nsi)
        let segmentLength = UInt16(19 + components)
        appendUInt16BE(&stream, segmentLength)
        stream.append(UInt8(3)) // Ndim = 3
        appendUInt32BE(&stream, UInt32(max(1, depth)))
        appendUInt32BE(&stream, 0) // ZOsiz
        appendUInt32BE(&stream, UInt32(max(1, tileSizeZ)))
        appendUInt32BE(&stream, 0) // ZTOsiz
        for _ in 0..<components {
            stream.append(UInt8(1)) // ZRsiz^i = 1
        }
    }

    private func appendCOD(_ stream: inout Data, cod: JP3DCODInfo) {
        appendMarker(&stream, .cod)
        let maxLevels = max(cod.levelsX, max(cod.levelsY, cod.levelsZ))
        let hasPrecincts = cod.usesCustomPrecincts
        let segmentLength = UInt16(17 + (hasPrecincts ? 2 * (maxLevels + 1) : 0))
        appendUInt16BE(&stream, segmentLength)
        stream.append(cod.scod)
        stream.append(cod.progressionOrderByte)
        appendUInt16BE(&stream, UInt16(max(1, min(65535, cod.numLayers))))
        stream.append(cod.multipleComponentTransform)
        stream.append(UInt8(max(0, min(32, cod.levelsX))))
        stream.append(UInt8(max(0, min(32, cod.levelsY))))
        stream.append(UInt8(max(0, min(32, cod.levelsZ))))
        stream.append(UInt8(max(0, min(10, cod.codeBlockWidthExponent))))
        stream.append(UInt8(max(0, min(10, cod.codeBlockHeightExponent))))
        stream.append(UInt8(max(0, min(10, cod.codeBlockDepthExponent))))
        stream.append(cod.codeBlockStyle)
        stream.append(cod.dwtX)
        stream.append(cod.dwtY)
        stream.append(cod.dwtZ)
        if hasPrecincts {
            for r in 0...maxLevels {
                let p = cod.precinctExponents(forResolution: r)
                let word = UInt16(((p.ppz & 0x0F) << 8) | ((p.ppy & 0x0F) << 4) | (p.ppx & 0x0F))
                appendUInt16BE(&stream, word)
            }
        }
    }

    private func appendQCD(_ stream: inout Data, qcd: JP3DQuantizationParameters) {
        appendMarker(&stream, .qcd)
        let sqcd = UInt8(((qcd.guardBits & 0x07) << 5)) | (qcd.style & 0x1F)
        switch qcd.style {
        case 0:
            let segmentLength = UInt16(3 + qcd.steps.count)
            appendUInt16BE(&stream, segmentLength)
            stream.append(sqcd)
            for s in qcd.steps {
                stream.append(UInt8((max(0, min(31, s.exponent)) & 0x1F) << 3))
            }
        case 1:
            appendUInt16BE(&stream, 5)
            stream.append(sqcd)
            let base = qcd.steps.first ?? (exponent: 8, mantissa: 0)
            let word = UInt16(((max(0, min(31, base.exponent)) & 0x1F) << 11) | (max(0, min(2047, base.mantissa)) & 0x07FF))
            appendUInt16BE(&stream, word)
        default:
            let segmentLength = UInt16(3 + 2 * qcd.steps.count)
            appendUInt16BE(&stream, segmentLength)
            stream.append(sqcd)
            for s in qcd.steps {
                let word = UInt16(((max(0, min(31, s.exponent)) & 0x1F) << 11) | (max(0, min(2047, s.mantissa)) & 0x07FF))
                appendUInt16BE(&stream, word)
            }
        }
    }

    private func appendRGN(_ stream: inout Data, component: Int, totalComponents: Int, shift: Int) {
        appendMarker(&stream, .rgn)
        if totalComponents < 257 {
            appendUInt16BE(&stream, 5)
            stream.append(UInt8(component))
        } else {
            appendUInt16BE(&stream, 6)
            appendUInt16BE(&stream, UInt16(component))
        }
        stream.append(UInt8(0)) // Srgn = 0 (Maxshift)
        stream.append(UInt8(max(0, min(37, shift))))
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
