// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DHTJ2K.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca
//
// Changes relative to the predecessor:
//   - Updated JP3DHTMarkers.capMarkerData to emit reconciled ITU-T T.809 + ITU-T T.814 CAP
//     (Lcap = 10, Pcap = 0x0042_0000 = Pcap^10 | Pcap^15, Ccap^10 = 0x0000, Ccap^15 per Table A.2).
//   - Replaced raw Int32 payload dumps in JP3DHTJ2KCodec with real Part 15 FBCOT cleanup-pass
//     coding (HTBlockEncoder / HTBlockDecoder) for HT tiles and real EBCOT MQ bit-plane coding
//     (JP3DBitPlaneCoder) for legacy tiles across arbitrary voxel counts.

import Foundation
import SwiftJ2K

// MARK: - JP3DHTJ2KBlockMode

/// The block-coding algorithm used for individual code-blocks inside a JP3D tile.
public enum JP3DHTJ2KBlockMode: Sendable, Equatable {
    /// High-throughput FBCOT block coding (ISO/IEC 15444-15).
    case ht

    /// Legacy EBCOT block coding (ISO/IEC 15444-1 / 15444-10).
    case legacy

    /// Mixed: each tile or code-block is coded with the algorithm that yields the best throughput
    /// for its content (HT when the block has many non-zeros; legacy otherwise).
    case adaptive
}

// MARK: - JP3DHTJ2KConfiguration

/// Configuration for HTJ2K integration in a JP3D volume.
///
/// Controls which block-coding algorithm is used, the number of coding
/// passes per code-block, and whether the fast cleanup pass is enabled.
public struct JP3DHTJ2KConfiguration: Sendable, Equatable {
    /// The block coding mode for all tiles in the volume.
    public let blockMode: JP3DHTJ2KBlockMode

    /// Maximum coding passes per code-block (>= 1).
    public let passCount: Int

    /// Whether the fast HT cleanup pass is active.
    public let cleanupPassEnabled: Bool

    /// Whether to allow a mix of HT and legacy tiles/code-blocks in the same volume.
    public let allowMixedTiles: Bool

    /// Creates a new HTJ2K configuration.
    public init(
        blockMode: JP3DHTJ2KBlockMode = .ht,
        passCount: Int = 1,
        cleanupPassEnabled: Bool = true,
        allowMixedTiles: Bool = false
    ) {
        self.blockMode = blockMode
        self.passCount = max(1, passCount)
        self.cleanupPassEnabled = cleanupPassEnabled
        self.allowMixedTiles = allowMixedTiles
    }

    /// Default HTJ2K configuration.
    public static let `default` = JP3DHTJ2KConfiguration()

    /// Low-latency HTJ2K configuration.
    public static let lowLatency = JP3DHTJ2KConfiguration(
        blockMode: .ht,
        passCount: 1,
        cleanupPassEnabled: true,
        allowMixedTiles: false
    )

    /// Balanced HTJ2K configuration.
    public static let balanced = JP3DHTJ2KConfiguration(
        blockMode: .ht,
        passCount: 3,
        cleanupPassEnabled: true,
        allowMixedTiles: false
    )

    /// Adaptive configuration that selects HT or legacy coding per tile/code-block.
    public static let adaptive = JP3DHTJ2KConfiguration(
        blockMode: .adaptive,
        passCount: 1,
        cleanupPassEnabled: true,
        allowMixedTiles: true
    )
}

// MARK: - JP3DHTTileInfo

/// Per-tile HTJ2K encoding metadata stored inline in standalone `JP3DHTJ2KCodec` tile buffers.
package struct JP3DHTTileInfo: Sendable, Equatable {
    /// Whether this tile uses HT block coding.
    package let isHT: Bool
    /// Number of coding passes used.
    package let passCount: Int
    /// Whether the cleanup pass was included.
    package let cleanupPassPresent: Bool

    package init(isHT: Bool, passCount: Int, cleanupPassPresent: Bool = true) {
        self.isHT = isHT
        self.passCount = max(1, passCount)
        self.cleanupPassPresent = cleanupPassPresent
    }

    /// Serialises the tile info into a 4-byte prefix.
    package func serialise() -> Data {
        var d = Data(count: 4)
        d[0] = isHT ? 0x01 : 0x00
        d[1] = UInt8(clamping: passCount)
        d[2] = cleanupPassPresent ? 0x01 : 0x00
        d[3] = 0x00
        return d
    }

    /// Alias for ``serialise()``.
    package func encode() -> Data {
        serialise()
    }

    /// Deserialises a tile info from the first 4 bytes of a standalone tile payload.
    package static func deserialise(from data: Data) -> JP3DHTTileInfo? {
        guard data.count >= 4 else { return nil }
        let base = data.startIndex
        let flag = data[base]
        guard flag == 0x00 || flag == 0x01 else { return nil }
        let passes = Int(data[base + 1])
        guard passes >= 1 else { return nil }
        let cleanup = data[base + 2]
        guard cleanup == 0x00 || cleanup == 0x01 else { return nil }
        guard data[base + 3] == 0x00 else { return nil }
        return JP3DHTTileInfo(
            isHT: flag == 0x01,
            passCount: passes,
            cleanupPassPresent: cleanup == 0x01
        )
    }

    /// Alias for ``deserialise(from:)``.
    package static func decode(from data: Data) -> JP3DHTTileInfo? {
        deserialise(from: data)
    }
}

// MARK: - JP3DHTMarkers

/// Utilities for generating and detecting reconciled Part 10 + Part 15 HTJ2K marker segments (`CAP`, `CPF`).
public struct JP3DHTMarkers: Sendable {
    static let capMarkerCode: UInt16 = 0xFF50
    static let cpfMarkerCode: UInt16 = 0xFF59

    /// Generates the reconciled ITU-T T.809 + ITU-T T.814 `CAP` (`0xFF50`) marker segment (`12` bytes:
    /// `Lcap = 10`, `Pcap = 0x0042_0000`, `Ccap^10 = 0x0000`, `Ccap^15` per ITU-T T.814 Table A.2).
    public static func capMarkerData(for configuration: JP3DHTJ2KConfiguration) -> Data {
        capMarkerData(for: configuration, isLossless: true, maxMb: 12)
    }

    package static func capMarkerData(
        for configuration: JP3DHTJ2KConfiguration,
        isLossless: Bool,
        maxMb: Int
    ) -> Data {
        var data = Data(capacity: 12)
        appendUInt16(&data, capMarkerCode)
        // Pcap^10 = 1 << 22 (0x0040_0000) | Pcap^15 = 1 << 17 (0x0002_0000) -> 0x0042_0000
        let pcap: UInt32 = 0x0042_0000
        appendUInt16(&data, 10) // Lcap = 6 + 2 * 2 = 10
        appendUInt32(&data, pcap)
        appendUInt16(&data, 0x0000) // Ccap^10

        // ITU-T T.814 Table A.2 Ccap^15:
        //   bits 14..15: 0 = HTONLY, 3 = HTMIXED (when allowMixedTiles)
        //   bit  5:      0 = HTREV (reversible), 1 = HTIRV (irreversible)
        //   bits 0..4:   MAGB = max(0, min(26, maxMb - 8))
        var ccap15: UInt16 = UInt16(max(0, min(26, maxMb - 8)))
        if configuration.allowMixedTiles {
            ccap15 |= 0xC000 // HTMIXED (bits 14-15 == 3)
        }
        if !isLossless {
            ccap15 |= 0x0020 // HTIRV
        }
        appendUInt16(&data, ccap15)
        return data
    }

    /// Generates the `CPF` (Corresponding Profile, `0xFF59`) marker segment data.
    public static func cpfMarkerData(
        for configuration: JP3DHTJ2KConfiguration,
        isLossless: Bool
    ) -> Data {
        _ = configuration
        var data = Data(capacity: 6)
        appendUInt16(&data, cpfMarkerCode)
        appendUInt16(&data, 4)
        var pcpf: UInt16 = 0x8000
        pcpf |= (isLossless ? 0x0000 : 0x0001)
        appendUInt16(&data, pcpf)
        return data
    }

    /// Returns `true` when a JP3D parsed codestream declares HTJ2K capability via a `COD` coding-style byte.
    public static func isHTJ2KSignalled(codingStyleByte: UInt8) -> Bool {
        (codingStyleByte & 0x40) != 0
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }
}

// MARK: - JP3DHTJ2KCodec

/// Encodes and decodes individual JP3D coefficient blocks using real Part 15 HTJ2K (`HTBlockEncoder`/`HTBlockDecoder`)
/// or Part 10/Part 1 EBCOT (`JP3DBitPlaneCoder`) entropy coding.
public struct JP3DHTJ2KCodec: Sendable {
    /// The HTJ2K configuration used for this codec instance.
    public let configuration: JP3DHTJ2KConfiguration

    /// Creates a new codec with the given configuration.
    public init(configuration: JP3DHTJ2KConfiguration = .default) {
        self.configuration = configuration
    }

    /// Encodes quantised integer tile coefficients into a real FBCOT or EBCOT entropy-coded byte payload.
    public func encodeTile(
        coefficients: [Int32],
        voxelCount: Int,
        tileIndex: Int = 0
    ) -> Data {
        let effectiveCount = min(max(0, voxelCount), coefficients.count)
        let slice = effectiveCount == coefficients.count ? coefficients : Array(coefficients.prefix(effectiveCount))
        let useHT = resolveUseHT(for: slice, tileIndex: tileIndex)

        let info = JP3DHTTileInfo(
            isHT: useHT,
            passCount: configuration.passCount,
            cleanupPassPresent: configuration.cleanupPassEnabled
        )

        var payload = info.serialise()
        if useHT {
            payload.append(encodeHTCoefficients(slice))
        } else {
            payload.append(encodeLegacyCoefficients(slice))
        }
        return payload
    }

    /// Decodes a tile payload previously produced by `encodeTile`.
    public func decodeTile(
        tileData: Data,
        expectedVoxels: Int
    ) throws -> [Float] {
        guard expectedVoxels >= 0 else {
            throw J2KError.decodingError("JP3DHTJ2KCodec: expectedVoxels must be non-negative")
        }
        guard let info = JP3DHTTileInfo.deserialise(from: tileData) else {
            throw J2KError.decodingError(
                "JP3DHTJ2KCodec: tile payload too short to contain tile-info header"
            )
        }

        let payload = tileData.dropFirst(4)
        if info.isHT {
            return try decodeHTPayload(payload, expectedVoxels: expectedVoxels)
        } else {
            return try decodeLegacyPayload(payload, expectedVoxels: expectedVoxels)
        }
    }

    // MARK: - Private Block Partitioning & Entropy Coding

    /// Partitions `totalCount` coefficients into `(width, height)` planar blocks with `1 <= width, height <= 64`.
    private static func planarBlocks(for totalCount: Int) -> [(offset: Int, width: Int, height: Int)] {
        guard totalCount > 0 else { return [] }
        var blocks: [(offset: Int, width: Int, height: Int)] = []
        var pos = 0
        var rem = totalCount
        while rem >= 64 {
            let h = min(64, rem / 64)
            blocks.append((offset: pos, width: 64, height: h))
            pos += 64 * h
            rem -= 64 * h
        }
        if rem > 0 {
            blocks.append((offset: pos, width: rem, height: 1))
        }
        return blocks
    }

    private func resolveUseHT(for coefficients: [Int32], tileIndex: Int) -> Bool {
        _ = tileIndex
        switch configuration.blockMode {
        case .ht:
            return true
        case .legacy:
            return false
        case .adaptive:
            let nonZero = coefficients.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            let density = coefficients.isEmpty ? 0.0
                : Double(nonZero) / Double(coefficients.count)
            return density > 0.25
        }
    }

    private func encodeHTCoefficients(_ coefficients: [Int32]) -> Data {
        var maxMag: UInt32 = 0
        for c in coefficients {
            let m = c.magnitude
            if m > maxMag { maxMag = m }
        }
        // HTBlockDecoder requires kMax in 1...30 (magnitudes < 2^30).
        // If any coefficient has magnitude >= 2^30 (e.g. Int32.max/min), shift high part by 2 bits and append 2-bit remainders.
        let usesWideSplit = maxMag >= (UInt32(1) << 30)
        let working: [Int32]
        var remainders: [Int8] = []
        if usesWideSplit {
            var high = [Int32](repeating: 0, count: coefficients.count)
            remainders = [Int8](repeating: 0, count: coefficients.count)
            for i in 0..<coefficients.count {
                let q = coefficients[i] / 4
                let r = Int8(coefficients[i] - q * 4) // in -3...3
                high[i] = q
                remainders[i] = r
            }
            working = high
        } else {
            working = coefficients
        }

        var effMax: UInt32 = 0
        for c in working {
            let m = c.magnitude
            if m > effMax { effMax = m }
        }
        let kMax = UInt8(max(1, min(30, effMax == 0 ? 1 : (32 - effMax.leadingZeroBitCount))))

        var out = Data()
        Self.appendUInt32BE(&out, UInt32(coefficients.count))
        out.append(kMax)
        out.append(usesWideSplit ? 0x01 : 0x00)

        for blk in Self.planarBlocks(for: working.count) {
            let count = blk.width * blk.height
            let sub = Array(working[blk.offset..<(blk.offset + count)])
            let coded = (try? HTBlockEncoder.encodeCleanup(
                coefficients: sub,
                width: blk.width,
                height: blk.height,
                bandShift: 0
            )) ?? []
            Self.appendUInt16BE(&out, UInt16(coded.count))
            out.append(contentsOf: coded)
        }
        if usesWideSplit {
            for r in remainders {
                out.append(UInt8(bitPattern: r))
            }
        }
        return out
    }

    private func encodeLegacyCoefficients(_ coefficients: [Int32]) -> Data {
        var maxMag: UInt64 = 0
        for c in coefficients {
            let m = UInt64(c.magnitude)
            if m > maxMag { maxMag = m }
        }
        let mb = max(1, min(32, maxMag == 0 ? 1 : (64 - maxMag.leadingZeroBitCount)))

        var out = Data()
        Self.appendUInt32BE(&out, UInt32(coefficients.count))
        out.append(UInt8(mb))

        let style = CodeBlockStyle(bits: 0)
        for blk in Self.planarBlocks(for: coefficients.count) {
            let count = blk.width * blk.height
            let sub64 = coefficients[blk.offset..<(blk.offset + count)].map { Int64($0) }
            let enc = (try? JP3DBitPlaneCoder.encode3D(
                coefficients: sub64,
                width: blk.width,
                height: blk.height,
                depth: 1,
                orientation: .ll,
                magnitudeBitPlanes: mb,
                style: style,
                maxPasses: nil,
                qualityLayers: 1
            )) ?? CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: mb, layerPassCounts: [0])
            out.append(UInt8(clamping: enc.zeroBitPlanes))
            out.append(UInt8(clamping: enc.passCount))
            Self.appendUInt16BE(&out, UInt16(enc.data.count))
            out.append(contentsOf: enc.data)
        }
        return out
    }

    private func decodeHTPayload(_ payload: Data.SubSequence, expectedVoxels: Int) throws -> [Float] {
        guard payload.count >= 6 else {
            throw J2KError.decodingError("JP3DHTJ2KCodec (HT): truncated block header (\(payload.count) < 6 bytes)")
        }
        var idx = payload.startIndex
        let storedCount = Int(Self.readUInt32BE(payload, at: &idx))
        guard storedCount == expectedVoxels else {
            throw J2KError.decodingError(
                "JP3DHTJ2KCodec (HT): stored voxel count \(storedCount) != expected \(expectedVoxels)"
            )
        }
        let kMax = Int(payload[idx]); idx += 1
        let splitFlag = payload[idx]; idx += 1
        guard (1...30).contains(kMax), (splitFlag == 0 || splitFlag == 1) else {
            throw J2KError.decodingError("JP3DHTJ2KCodec (HT): invalid kMax (\(kMax)) or split flag (\(splitFlag))")
        }

        var out = [Float](repeating: 0, count: expectedVoxels)
        for blk in Self.planarBlocks(for: expectedVoxels) {
            guard idx + 2 <= payload.endIndex else {
                throw J2KError.decodingError("JP3DHTJ2KCodec (HT): truncated segment length")
            }
            let segLen = Int(Self.readUInt16BE(payload, at: &idx))
            guard idx + segLen <= payload.endIndex else {
                throw J2KError.decodingError("JP3DHTJ2KCodec (HT): truncated cleanup segment (\(segLen) bytes)")
            }
            let segBytes = [UInt8](payload[idx..<(idx + segLen)])
            idx += segLen
            let decoded: [Int32]
            do {
                decoded = try HTBlockDecoder.decodeCleanup(
                    block: segBytes,
                    width: blk.width,
                    height: blk.height,
                    kMax: kMax,
                    missingMSBs: kMax - 1
                )
            } catch {
                throw J2KError.decodingError("JP3DHTJ2KCodec (HT): cleanup decode failed: \(error)")
            }
            for i in 0..<decoded.count {
                out[blk.offset + i] = Float(decoded[i])
            }
        }
        if splitFlag == 1 {
            guard idx + expectedVoxels <= payload.endIndex else {
                throw J2KError.decodingError("JP3DHTJ2KCodec (HT): truncated wide-coefficient remainder stream")
            }
            for i in 0..<expectedVoxels {
                let rem = Int32(Int8(bitPattern: payload[idx + i]))
                let reconstructed = Int64(out[i]) * 4 + Int64(rem)
                out[i] = Float(reconstructed)
            }
        }
        return out
    }

    private func decodeLegacyPayload(_ payload: Data.SubSequence, expectedVoxels: Int) throws -> [Float] {
        guard payload.count >= 5 else {
            throw J2KError.decodingError("JP3DHTJ2KCodec (legacy): truncated block header (\(payload.count) < 5 bytes)")
        }
        var idx = payload.startIndex
        let storedCount = Int(Self.readUInt32BE(payload, at: &idx))
        guard storedCount == expectedVoxels else {
            throw J2KError.decodingError(
                "JP3DHTJ2KCodec (legacy): stored voxel count \(storedCount) != expected \(expectedVoxels)"
            )
        }
        let mb = Int(payload[idx]); idx += 1
        guard (1...38).contains(mb) else {
            throw J2KError.decodingError("JP3DHTJ2KCodec (legacy): invalid magnitude bit-plane count \(mb)")
        }

        var out = [Float](repeating: 0, count: expectedVoxels)
        let style = CodeBlockStyle(bits: 0)
        for blk in Self.planarBlocks(for: expectedVoxels) {
            guard idx + 4 <= payload.endIndex else {
                throw J2KError.decodingError("JP3DHTJ2KCodec (legacy): truncated EBCOT block descriptor")
            }
            let zbp = Int(payload[idx]); idx += 1
            let passes = Int(payload[idx]); idx += 1
            let segLen = Int(Self.readUInt16BE(payload, at: &idx))
            guard idx + segLen <= payload.endIndex else {
                throw J2KError.decodingError("JP3DHTJ2KCodec (legacy): truncated EBCOT segment (\(segLen) bytes)")
            }
            let segBytes = [UInt8](payload[idx..<(idx + segLen)])
            idx += segLen
            if passes > 0 {
                let decoded: [Int64]
                do {
                    decoded = try JP3DBitPlaneCoder.decode3D(
                        segments: [CodewordSegment(data: segBytes, passes: passes)],
                        width: blk.width,
                        height: blk.height,
                        depth: 1,
                        orientation: .ll,
                        zeroBitPlanes: zbp,
                        passCount: passes,
                        magnitudeBitPlanes: mb,
                        style: style
                    )
                } catch {
                    throw J2KError.decodingError("JP3DHTJ2KCodec (legacy): EBCOT decode failed: \(error)")
                }
                for i in 0..<decoded.count {
                    out[blk.offset + i] = Float(decoded[i])
                }
            }
        }
        return out
    }

    private static func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private static func readUInt16BE(_ slice: Data.SubSequence, at idx: inout Data.Index) -> UInt16 {
        let hi = UInt16(slice[idx])
        let lo = UInt16(slice[idx + 1])
        idx += 2
        return (hi << 8) | lo
    }

    private static func readUInt32BE(_ slice: Data.SubSequence, at idx: inout Data.Index) -> UInt32 {
        let b0 = UInt32(slice[idx])
        let b1 = UInt32(slice[idx + 1])
        let b2 = UInt32(slice[idx + 2])
        let b3 = UInt32(slice[idx + 3])
        idx += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
