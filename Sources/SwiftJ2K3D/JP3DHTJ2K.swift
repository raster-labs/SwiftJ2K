// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DHTJ2K.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

// MARK: - JP3DHTJ2KBlockMode

/// The block-coding algorithm used for individual code-blocks inside a JP3D tile.
public enum JP3DHTJ2KBlockMode: Sendable, Equatable {
    /// High-throughput FBCOT block coding (ISO/IEC 15444-15).
    case ht

    /// Legacy EBCOT block coding (ISO/IEC 15444-1).
    case legacy

    /// Mixed: each tile is coded with the algorithm that yields the best throughput
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

    /// Whether to allow a mix of HT and legacy tiles in the same volume.
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

    /// Adaptive configuration that selects HT or legacy coding per tile.
    public static let adaptive = JP3DHTJ2KConfiguration(
        blockMode: .adaptive,
        passCount: 1,
        cleanupPassEnabled: true,
        allowMixedTiles: true
    )
}

// MARK: - JP3DHTTileInfo

/// Per-tile HTJ2K encoding metadata stored inline in the tile data.
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

    /// Deserialises a tile info from the first 4 bytes of a tile payload.
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

/// Utilities for generating and detecting HTJ2K marker segments (CAP, CPF).
public struct JP3DHTMarkers: Sendable {
    static let capMarkerCode: UInt16 = 0xFF50
    static let cpfMarkerCode: UInt16 = 0xFF59

    /// Generates the CAP (Capabilities) marker segment data.
    public static func capMarkerData(for configuration: JP3DHTJ2KConfiguration) -> Data {
        var data = Data()
        appendUInt16(&data, capMarkerCode)
        let pcap: UInt32 = 1 << 14
        appendUInt16(&data, 8)
        appendUInt32(&data, pcap)
        var ccap: UInt16 = 0x0001
        if configuration.allowMixedTiles {
            ccap |= 0x0002
        }
        appendUInt16(&data, ccap)
        return data
    }

    /// Generates the CPF (Corresponding Profile) marker segment data.
    public static func cpfMarkerData(
        for configuration: JP3DHTJ2KConfiguration,
        isLossless: Bool
    ) -> Data {
        var data = Data()
        appendUInt16(&data, cpfMarkerCode)
        appendUInt16(&data, 4)
        var pcpf: UInt16 = 0x8000
        pcpf |= (isLossless ? 0x0000 : 0x0001)
        appendUInt16(&data, pcpf)
        return data
    }

    /// Returns `true` when a JP3D parsed codestream declares HTJ2K capability via a COD coding-style byte.
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

/// Encodes and decodes individual JP3D tiles using HTJ2K or legacy coding.
public struct JP3DHTJ2KCodec: Sendable {
    /// The HTJ2K configuration used for this codec instance.
    public let configuration: JP3DHTJ2KConfiguration

    /// Creates a new codec with the given configuration.
    public init(configuration: JP3DHTJ2KConfiguration = .default) {
        self.configuration = configuration
    }

    /// Encodes quantized integer tile coefficients to a byte payload.
    public func encodeTile(
        coefficients: [Int32],
        voxelCount: Int,
        tileIndex: Int = 0
    ) -> Data {
        let useHT = resolveUseHT(for: coefficients, tileIndex: tileIndex)

        let info = JP3DHTTileInfo(
            isHT: useHT,
            passCount: configuration.passCount,
            cleanupPassPresent: configuration.cleanupPassEnabled
        )

        var payload = info.serialise()

        if useHT {
            payload.append(encodeHTCoefficients(coefficients))
        } else {
            payload.append(encodeLegacyCoefficients(coefficients))
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

    // MARK: - Private Helpers

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
        var data = Data()
        data.reserveCapacity(4 + coefficients.count * 4)

        let maxMag = coefficients.map { $0 == Int32.min ? Int32.max : abs($0) }.max() ?? 0
        let zbp: UInt32 = maxMag > 0 ? UInt32(31 - maxMag.leadingZeroBitCount) : 0
        var zbpBE = zbp.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &zbpBE) { Array($0) })

        for coeff in coefficients {
            var v = coeff.bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
        }

        return data
    }

    private func encodeLegacyCoefficients(_ coefficients: [Int32]) -> Data {
        var data = Data(count: coefficients.count * 4)
        for (i, coeff) in coefficients.enumerated() {
            var v = coeff.bigEndian
            withUnsafeBytes(of: &v) { src in
                data.replaceSubrange(
                    (i * 4)..<(i * 4 + 4),
                    with: src
                )
            }
        }
        return data
    }

    private func decodeHTPayload(_ payload: Data.SubSequence, expectedVoxels: Int) throws -> [Float] {
        let (voxelBytes, overflow1) = expectedVoxels.multipliedReportingOverflow(by: 4)
        let (minimumBytes, overflow2) = voxelBytes.addingReportingOverflow(4)
        guard !overflow1, !overflow2, payload.count >= minimumBytes else {
            throw J2KError.decodingError(
                "JP3DHTJ2KCodec (HT): payload \(payload.count) bytes < expected \(minimumBytes)"
            )
        }

        let coeffStart = payload.startIndex + 4
        return readInt32Coefficients(from: payload[coeffStart...], count: expectedVoxels)
    }

    private func decodeLegacyPayload(
        _ payload: Data.SubSequence,
        expectedVoxels: Int
    ) throws -> [Float] {
        let (minimumBytes, overflow) = expectedVoxels.multipliedReportingOverflow(by: 4)
        guard !overflow, payload.count >= minimumBytes else {
            throw J2KError.decodingError(
                "JP3DHTJ2KCodec (legacy): payload \(payload.count) bytes < expected \(minimumBytes)"
            )
        }
        return readInt32Coefficients(from: payload, count: expectedVoxels)
    }

    private func readInt32Coefficients(
        from slice: Data.SubSequence,
        count: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let base = slice.startIndex
        for i in 0..<count {
            let off = base + i * 4
            guard off + 4 <= slice.endIndex else { break }
            let b0 = Int32(slice[off])
            let b1 = Int32(slice[off + 1])
            let b2 = Int32(slice[off + 2])
            let b3 = Int32(slice[off + 3])
            out[i] = Float((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        }
        return out
    }
}
