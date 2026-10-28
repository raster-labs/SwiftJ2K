// SPDX-License-Identifier: Apache-2.0
//
// JP3DCodestreamParser.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DCodestreamParser.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Hardened marker segment bounds and tile-part length validation with checked
//     integer arithmetic so crafted or truncated SIZ, COD, QCD, COM, CAP, CPF,
//     or SOT segments throw J2KError.decodingError instead of trapping.

import Foundation
import SwiftJ2K

/// Metadata parsed from a JP3D SIZ marker segment.
public struct JP3DSIZInfo: Sendable {
    /// Volume width.
    public let width: Int
    /// Volume height.
    public let height: Int
    /// Volume depth.
    public let depth: Int
    /// Tile width.
    public let tileSizeX: Int
    /// Tile height.
    public let tileSizeY: Int
    /// Tile depth.
    public let tileSizeZ: Int
    /// Number of components.
    public let componentCount: Int
    /// Bit depth per component (1-based, as stored: `Ssiz + 1`).
    public let bitDepth: Int
    /// Whether components are signed.
    public let signed: Bool

    public init(
        width: Int,
        height: Int,
        depth: Int,
        tileSizeX: Int,
        tileSizeY: Int,
        tileSizeZ: Int,
        componentCount: Int,
        bitDepth: Int,
        signed: Bool
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.tileSizeX = tileSizeX
        self.tileSizeY = tileSizeY
        self.tileSizeZ = tileSizeZ
        self.componentCount = componentCount
        self.bitDepth = bitDepth
        self.signed = signed
    }
}

/// Coding parameters parsed from a JP3D COD marker segment.
public struct JP3DCODInfo: Sendable {
    /// Decomposition levels along X.
    public let levelsX: Int
    /// Decomposition levels along Y.
    public let levelsY: Int
    /// Decomposition levels along Z.
    public let levelsZ: Int
    /// Whether lossless encoding was used (filter byte = 1).
    public let isLossless: Bool
    /// Code-block style byte (bit 6 `0x40` indicates HTJ2K block coding).
    public let codeBlockStyle: UInt8

    public init(
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        isLossless: Bool,
        codeBlockStyle: UInt8 = 0
    ) {
        self.levelsX = levelsX
        self.levelsY = levelsY
        self.levelsZ = levelsZ
        self.isLossless = isLossless
        self.codeBlockStyle = codeBlockStyle
    }
}

/// Encoded data for a single tile parsed from the codestream.
public struct JP3DParsedTile: Sendable {
    /// The tile index (as written in the SOT marker).
    public let tileIndex: Int
    /// Raw encoded data for this tile (after the SOD marker).
    public let data: Data

    public init(tileIndex: Int, data: Data) {
        self.tileIndex = tileIndex
        self.data = data
    }
}

/// Complete parsed representation of a JP3D codestream.
public struct JP3DParsedCodestream: Sendable {
    /// Volume and tile geometry from the SIZ marker.
    public let siz: JP3DSIZInfo
    /// Coding parameters from the COD marker.
    public let cod: JP3DCODInfo
    /// Whether quantization is lossless (QCD style = 0).
    public let isLosslessQuantization: Bool
    /// Per-tile encoded data, ordered by tile index.
    public let tiles: [JP3DParsedTile]
    /// Whether a main-header CAP (`0xFF50`) marker with Part 15 HTJ2K signalling was present.
    public let hasCAPMarker: Bool

    public init(
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo,
        isLosslessQuantization: Bool,
        tiles: [JP3DParsedTile],
        hasCAPMarker: Bool = false
    ) {
        self.siz = siz
        self.cod = cod
        self.isLosslessQuantization = isLosslessQuantization
        self.tiles = tiles
        self.hasCAPMarker = hasCAPMarker
    }

    /// Compute the tile grid for this codestream.
    public var tileGrid: (tilesX: Int, tilesY: Int, tilesZ: Int) {
        let tx = max(1, (siz.width + siz.tileSizeX - 1) / siz.tileSizeX)
        let ty = max(1, (siz.height + siz.tileSizeY - 1) / siz.tileSizeY)
        let tz = max(1, (siz.depth + siz.tileSizeZ - 1) / siz.tileSizeZ)
        return (tx, ty, tz)
    }
}

/// Parses a JP3D codestream written by `JP3DCodestreamBuilder`.
public struct JP3DCodestreamParser: Sendable {
    /// Creates a new codestream parser.
    public init() {}

    // MARK: - Public API

    /// Parses a JP3D codestream from raw data.
    public func parse(_ data: Data) throws -> JP3DParsedCodestream {
        var offset = 0

        let socMarker = try readUInt16BE(data, at: &offset)
        guard socMarker == 0xFF4F else {
            throw J2KError.decodingError(
                "Missing SOC marker at start of codestream (got 0x\(String(socMarker, radix: 16)))"
            )
        }

        var sizInfo: JP3DSIZInfo?
        var codInfo: JP3DCODInfo?
        var isLosslessQuan = true
        var hasCAP = false
        var parsedTiles: [JP3DParsedTile] = []
        var foundEOC = false

        while offset < data.count {
            guard offset + 2 <= data.count else { break }
            let marker = try readUInt16BE(data, at: &offset)

            switch marker {
            case 0xFF51: // SIZ
                sizInfo = try parseSIZ(data, at: &offset)
            case 0xFF52: // COD
                codInfo = try parseCOD(data, at: &offset)
            case 0xFF5C: // QCD
                isLosslessQuan = try parseQCD(data, at: &offset)
            case 0xFF50: // CAP (HTJ2K extended capabilities)
                let len = Int(try readUInt16BE(data, at: &offset))
                guard len >= 2, offset + (len - 2) <= data.count else {
                    throw J2KError.decodingError("CAP marker has invalid length \(len)")
                }
                hasCAP = true
                offset += len - 2
            case 0xFF59, 0xFF64: // CPF or COM – skip
                let len = Int(try readUInt16BE(data, at: &offset))
                guard len >= 2, offset + (len - 2) <= data.count else {
                    throw J2KError.decodingError("Marker 0x\(String(marker, radix: 16)) has invalid length \(len)")
                }
                offset += len - 2
            case 0xFF90: // SOT
                let tile = try parseSOTAndData(data, at: &offset)
                parsedTiles.append(tile)
            case 0xFFD9: // EOC
                foundEOC = true
            default:
                if marker >= 0xFF00 {
                    if offset + 2 <= data.count {
                        let len = Int(try readUInt16BE(data, at: &offset))
                        if len >= 2, offset + (len - 2) <= data.count {
                            offset += len - 2
                            continue
                        }
                    }
                }
                throw J2KError.decodingError("Unexpected or truncated marker 0x\(String(marker, radix: 16))")
            }

            if foundEOC { break }
        }

        guard let siz = sizInfo else {
            throw J2KError.decodingError("Codestream missing SIZ marker")
        }
        guard let cod = codInfo else {
            throw J2KError.decodingError("Codestream missing COD marker")
        }
        if parsedTiles.isEmpty {
            throw J2KError.decodingError("Codestream contains no tile data")
        }

        return JP3DParsedCodestream(
            siz: siz,
            cod: cod,
            isLosslessQuantization: isLosslessQuan,
            tiles: parsedTiles.sorted { $0.tileIndex < $1.tileIndex },
            hasCAPMarker: hasCAP
        )
    }

    // MARK: - Private Marker Parsers

    private func parseSIZ(_ data: Data, at offset: inout Int) throws -> JP3DSIZInfo {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 38 else {
            throw J2KError.decodingError("SIZ segment length \(len) too small (min 38)")
        }
        let segEnd = offset + len - 2
        guard segEnd <= data.count else {
            throw J2KError.decodingError("SIZ segment length \(len) exceeds codestream size")
        }

        offset += 2
        let width  = Int(try readUInt32BE(data, at: &offset))
        let height = Int(try readUInt32BE(data, at: &offset))
        offset += 8
        let tileW = Int(try readUInt32BE(data, at: &offset))
        let tileH = Int(try readUInt32BE(data, at: &offset))
        offset += 8
        let numComponents = Int(try readUInt16BE(data, at: &offset))
        guard numComponents > 0, numComponents <= 16384 else {
            throw J2KError.decodingError("SIZ: invalid component count \(numComponents)")
        }
        guard width > 0, height > 0 else {
            throw J2KError.decodingError("SIZ: non-positive dimensions \(width)×\(height)")
        }

        var bitDepth = 8
        var isSigned = false
        for _ in 0..<numComponents {
            guard offset + 3 <= segEnd else {
                throw J2KError.decodingError("SIZ: truncated component info")
            }
            let ssiz = data[data.startIndex + offset]
            offset += 3
            isSigned = (ssiz & 0x80) != 0
            bitDepth = Int(ssiz & 0x7F) + 1
        }
        guard bitDepth >= 1 && bitDepth <= 38 else {
            throw J2KError.decodingError("SIZ: invalid bit depth \(bitDepth)")
        }

        var depth = 1
        var tileSizeZ = 1
        if offset + 4 <= segEnd {
            depth = Int(try readUInt32BE(data, at: &offset))
        }
        if offset + 4 <= segEnd {
            tileSizeZ = Int(try readUInt32BE(data, at: &offset))
        }
        if offset < segEnd { offset = segEnd }

        let (wh, o1) = max(1, width).multipliedReportingOverflow(by: max(1, height))
        let (_, o2) = wh.multipliedReportingOverflow(by: max(1, depth))
        guard !o1 && !o2 else {
            throw J2KError.decodingError("SIZ: volume dimensions overflow Int")
        }

        let effectiveTileW = tileW > 0 ? tileW : width
        let effectiveTileH = tileH > 0 ? tileH : height
        let effectiveTileZ = tileSizeZ > 0 ? tileSizeZ : depth

        return JP3DSIZInfo(
            width: max(1, width),
            height: max(1, height),
            depth: max(1, depth),
            tileSizeX: max(1, effectiveTileW),
            tileSizeY: max(1, effectiveTileH),
            tileSizeZ: max(1, effectiveTileZ),
            componentCount: numComponents,
            bitDepth: max(1, bitDepth),
            signed: isSigned
        )
    }

    private func parseCOD(_ data: Data, at offset: inout Int) throws -> JP3DCODInfo {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 12 else {
            throw J2KError.decodingError("COD segment length \(len) too small (min 12)")
        }
        let segEnd = offset + len - 2
        guard segEnd <= data.count else {
            throw J2KError.decodingError("COD segment length \(len) exceeds codestream size")
        }

        offset += 1
        offset += 1
        offset += 2
        offset += 1

        var levelsX = 1
        var levelsY = 1
        var levelsZ = 1

        guard offset < segEnd else {
            throw J2KError.decodingError("COD: truncated levels field")
        }
        levelsX = Int(data[data.startIndex + offset]); offset += 1

        if len >= 14 {
            guard offset + 1 < segEnd else {
                throw J2KError.decodingError("COD: truncated JP3D levels field")
            }
            levelsY = Int(data[data.startIndex + offset]); offset += 1
            levelsZ = Int(data[data.startIndex + offset]); offset += 1
        } else {
            levelsY = levelsX
            levelsZ = levelsX
        }
        guard levelsX <= 32, levelsY <= 32, levelsZ <= 32 else {
            throw J2KError.decodingError("COD: decomposition levels exceed maximum (32)")
        }

        var cbStyle: UInt8 = 0
        if offset + 3 <= segEnd {
            cbStyle = data[data.startIndex + offset + 2]
        }
        offset = min(segEnd - 1, offset + 3)

        var isLossless = true
        if offset < segEnd {
            isLossless = data[data.startIndex + min(offset, data.count - 1)] == 1
            offset += 1
        }

        if offset < segEnd { offset = segEnd }

        return JP3DCODInfo(
            levelsX: max(0, levelsX),
            levelsY: max(0, levelsY),
            levelsZ: max(0, levelsZ),
            isLossless: isLossless,
            codeBlockStyle: cbStyle
        )
    }

    private func parseQCD(_ data: Data, at offset: inout Int) throws -> Bool {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 3 else {
            throw J2KError.decodingError("QCD segment length \(len) too small (min 3)")
        }
        let segEnd = offset + len - 2
        guard segEnd <= data.count, offset < data.count else {
            throw J2KError.decodingError("QCD: truncated")
        }
        let style = data[data.startIndex + offset]
        offset = segEnd
        return (style & 0x1F) == 0
    }

    private func parseSOTAndData(_ data: Data, at offset: inout Int) throws -> JP3DParsedTile {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 10 else {
            throw J2KError.decodingError("SOT segment length \(len) too small (min 10)")
        }
        guard offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("SOT segment truncated")
        }
        let tileIndex = Int(try readUInt16BE(data, at: &offset))
        let tilePartLength = Int(try readUInt32BE(data, at: &offset))
        offset += 2
        let sotConsumed = 10
        if len > sotConsumed {
            offset += len - sotConsumed
        }

        guard offset + 2 <= data.count else {
            throw J2KError.decodingError("SOT[\(tileIndex)]: truncated before SOD")
        }
        let sodMarker = try readUInt16BE(data, at: &offset)
        guard sodMarker == 0xFF93 else {
            throw J2KError.decodingError(
                "SOT[\(tileIndex)]: expected SOD (0xFF93) got 0x\(String(sodMarker, radix: 16))"
            )
        }

        let dataLength: Int
        if tilePartLength > 14 {
            dataLength = tilePartLength - 14
        } else {
            dataLength = nextMarkerOffset(in: data, from: offset) - offset
        }

        let (endOffset, overflow) = offset.addingReportingOverflow(dataLength)
        guard !overflow, dataLength >= 0, endOffset <= data.count else {
            throw J2KError.decodingError(
                "SOT[\(tileIndex)]: declared data length \(dataLength) exceeds available bytes"
            )
        }

        let tileData = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + endOffset))
        offset = endOffset

        return JP3DParsedTile(tileIndex: tileIndex, data: tileData)
    }

    private func nextMarkerOffset(in data: Data, from start: Int) -> Int {
        var i = start
        while i < data.count - 1 {
            if data[data.startIndex + i] == 0xFF && data[data.startIndex + i + 1] != 0xFF {
                return i
            }
            i += 1
        }
        return data.count
    }

    // MARK: - Byte Reading Helpers

    private func readUInt16BE(_ data: Data, at offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw J2KError.decodingError("Codestream truncated reading UInt16 at offset \(offset)")
        }
        let hi = UInt16(data[data.startIndex + offset])
        let lo = UInt16(data[data.startIndex + offset + 1])
        offset += 2
        return (hi << 8) | lo
    }

    private func readUInt32BE(_ data: Data, at offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw J2KError.decodingError("Codestream truncated reading UInt32 at offset \(offset)")
        }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
