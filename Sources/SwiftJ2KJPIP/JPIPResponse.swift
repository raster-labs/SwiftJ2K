// SPDX-License-Identifier: Apache-2.0
//
// JPIPResponse.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPResponse.swift
//
// Extended in Phase R3 (F04) with normative ITU-T Rec. T.808 (12/2022) V2 |
// ISO/IEC 15444-9 Annex A.2 VBAS data-bin framing, Table A.2 wire class
// identifiers, and Clause D.3 End of Response (EOR) signalling.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Represents a JPIP response from the server.
public struct JPIPResponse: Sendable {
    /// The channel ID (cid) from JPIP-cnew header, if present.
    public let channelID: String?

    /// The response data.
    public let data: Data

    /// HTTP status code.
    public let statusCode: Int

    /// All HTTP headers.
    public let headers: [String: String]

    /// Creates a new JPIP response.
    ///
    /// - Parameters:
    ///   - channelID: Optional channel ID from JPIP-cnew header.
    ///   - data: The response data.
    ///   - statusCode: HTTP status code.
    ///   - headers: HTTP headers.
    public init(channelID: String?, data: Data, statusCode: Int, headers: [String: String]) {
        self.channelID = channelID
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Normative ITU-T Rec. T.808 (12/2022) Table D.2 End of Response (EOR) reason codes.
public enum JPIPEORReason: UInt8, Sendable, Equatable {
    case imageDone = 0x01
    case windowDone = 0x02
    case windowChange = 0x03
    case byteLimit = 0x04
    case qualityLimit = 0x05
    case sessionLimit = 0x06
    case responseLimit = 0x07
    case nonSpecified = 0xFF

    /// Alias for ``byteLimit`` (`0x04`, Table D.2 byte-limit reached).
    public static let byteLimitReached: JPIPEORReason = .byteLimit

    /// Alias for ``qualityLimit`` (`0x05`, Table D.2 quality-limit reached).
    public static let qualityLimitReached: JPIPEORReason = .qualityLimit
}

/// Normative ITU-T Rec. T.808 Clause D.3 End of Response (EOR) message.
public struct JPIPEORMessage: Sendable, Equatable {
    public let reason: JPIPEORReason
    public let body: Data

    public init(reason: JPIPEORReason, body: Data = Data()) {
        self.reason = reason
        self.body = body
    }
}

/// Decoded JPIP message stream (`image/jpp-stream` or `image/jpt-stream`).
public struct JPIPParsedStream: Sendable {
    public let bins: [JPIPDataBin]
    public let eorReason: JPIPEORReason?
    public let eorReasonRawValue: UInt8?
    public let eorBody: Data?

    /// Structured EOR message when an End of Response marker was present.
    public var eor: JPIPEORMessage? {
        eorReason.map { JPIPEORMessage(reason: $0, body: eorBody ?? Data()) }
    }

    public init(
        bins: [JPIPDataBin],
        eorReason: JPIPEORReason? = nil,
        eorReasonRawValue: UInt8? = nil,
        eorBody: Data? = nil
    ) {
        self.bins = bins
        self.eorReason = eorReason
        self.eorReasonRawValue = eorReasonRawValue ?? eorReason?.rawValue
        self.eorBody = eorBody
    }
}

/// Parser for JPIP response headers and normative VBAS data-bin streams.
public struct JPIPResponseParser: Sendable {
    /// Parses the JPIP-cnew header to extract channel ID.
    ///
    /// Example header: `"cid=1942302,path=/jp2,transport=http"`
    public static func parseChannelID(from header: String) -> String? {
        parseCNewParameters(from: header)["cid"]
    }

    /// Parses all comma-separated `key=value` parameters from a `JPIP-cnew` header.
    public static func parseCNewParameters(from header: String) -> [String: String] {
        var result: [String: String] = [:]
        let fields = header.split(separator: ",")
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    /// Parses HTTP headers from URLResponse.
    public static func parseHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                headers[keyString] = valueString
            }
        }
        return headers
    }

    /// Extracts channel ID from response headers.
    public static func extractChannelID(from headers: [String: String]) -> String? {
        for (key, value) in headers where key.lowercased() == "jpip-cnew" {
            return parseChannelID(from: value)
        }
        return nil
    }

    /// Extracts optional channel request `path` from a `JPIP-cnew` response header.
    public static func extractChannelPath(from headers: [String: String]) -> String? {
        for (key, value) in headers where key.lowercased() == "jpip-cnew" {
            return parseCNewParameters(from: value)["path"]
        }
        return nil
    }

    /// Extracts optional target ID (`JPIP-tid`) from response headers.
    public static func extractTargetID(from headers: [String: String]) -> String? {
        for (key, value) in headers where key.lowercased() == "jpip-tid" {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Parses a normative `image/jpp-stream` or `image/jpt-stream` response body.
    public static func parseStream(
        from data: Data,
        maxPayloadBytes: Int = 128 * 1024 * 1024
    ) throws -> JPIPParsedStream {
        try JPIPWireCodec.decodeStream(data, maxPayloadBytes: maxPayloadBytes)
    }

    /// Parses data-bins from a normative JPIP VBAS stream.
    public static func parseDataBins(
        from data: Data,
        maxPayloadBytes: Int = 128 * 1024 * 1024
    ) throws -> [JPIPDataBin] {
        try JPIPWireCodec.decodeStream(data, maxPayloadBytes: maxPayloadBytes).bins
    }
}

/// Represents a JPIP data bin class.
///
/// Note: Swift `rawValue`s preserve local enum compatibility (`0...6`), while
/// ``wireClassID`` and ``init(wireClassID:)`` map strictly to normative
/// ITU-T Rec. T.808 (12/2022) Table A.2 class identifiers on the wire.
public enum JPIPDataBinClass: Int, Sendable {
    /// Main header data bin (ITU-T T.808 Table A.2 wire class `6`).
    case mainHeader = 0

    /// Tile header data bin (ITU-T T.808 Table A.2 wire class `2`).
    case tileHeader = 1

    /// Precinct data bin (ITU-T T.808 Table A.2 wire class `0`).
    case precinct = 2

    /// Tile data bin (ITU-T T.808 Table A.2 wire class `4`).
    case tile = 3

    /// Extended precinct data bin (ITU-T T.808 Table A.2 wire class `1`).
    case extendedPrecinct = 4

    /// Metadata data bin (ITU-T T.808 Table A.2 wire class `8`).
    case metadata = 5

    /// Extended tile data bin (ITU-T T.808 Table A.2 wire class `5`).
    case extendedTile = 6

    /// Normative ITU-T Rec. T.808 Table A.2 wire class identifier.
    public var wireClassID: Int {
        switch self {
        case .precinct: return 0
        case .extendedPrecinct: return 1
        case .tileHeader: return 2
        case .tile: return 4
        case .extendedTile: return 5
        case .mainHeader: return 6
        case .metadata: return 8
        }
    }

    /// Initializes from a normative ITU-T Rec. T.808 Table A.2 wire class identifier.
    public init?(wireClassID: Int) {
        switch wireClassID {
        case 0: self = .precinct
        case 1: self = .extendedPrecinct
        case 2: self = .tileHeader
        case 4: self = .tile
        case 5: self = .extendedTile
        case 6: self = .mainHeader
        case 8: self = .metadata
        default: return nil
        }
    }

    /// Normative ITU-T Rec. T.808 Clause C.8.1.2 cache-model descriptor prefix.
    public var cacheModelPrefix: String {
        switch self {
        case .mainHeader: return "Hm"
        case .tileHeader: return "H"
        case .precinct, .extendedPrecinct: return "P"
        case .tile, .extendedTile: return "T"
        case .metadata: return "M"
        }
    }

    /// Canonical ITU-T Rec. T.808 Clause A.2.2 / Table A.2 data-bin class unifying
    /// normal and extended wire formats (`Class 1` -> `Class 0` precinct; `Class 5` -> `Class 4` tile).
    public var canonicalClass: JPIPDataBinClass {
        switch self {
        case .precinct, .extendedPrecinct: return .precinct
        case .tile, .extendedTile: return .tile
        case .mainHeader: return .mainHeader
        case .tileHeader: return .tileHeader
        case .metadata: return .metadata
        }
    }
}

/// Represents a JPIP data bin (or partial message segment at `msgOffset`).
public struct JPIPDataBin: Sendable, Equatable {
    /// The data bin class.
    public let binClass: JPIPDataBinClass

    /// Class identifier (for compatibility).
    public var classID: JPIPDataBinClass { binClass }

    /// The in-class data-bin identifier (`In-Class-ID`).
    public let binID: Int

    /// Codestream index (`CSn`, default `0`).
    public let codestreamID: Int

    /// Byte offset (`Msg-Offset`) within the logical data-bin.
    public let msgOffset: Int

    /// Optional auxiliary value (`Aux`, present on odd wire class IDs `1`, `5`).
    public let aux: Int?

    /// The message payload bytes starting at ``msgOffset``.
    public var data: Data

    /// Whether this message contains the final byte of the data-bin (`c == 1`).
    public let isComplete: Bool

    /// Quality layer for precinct data bins.
    public var qualityLayer: Int

    /// Tile index for tile-based data bins.
    public var tileIndex: Int

    /// Creates a new data bin.
    public init(
        binClass: JPIPDataBinClass,
        binID: Int,
        data: Data,
        isComplete: Bool,
        qualityLayer: Int = 0,
        tileIndex: Int = 0,
        codestreamID: Int = 0,
        msgOffset: Int = 0,
        aux: Int? = nil
    ) {
        self.binClass = binClass
        self.binID = binID
        self.data = data
        self.isComplete = isComplete
        self.qualityLayer = qualityLayer
        self.tileIndex = tileIndex
        self.codestreamID = codestreamID
        self.msgOffset = msgOffset
        self.aux = aux
    }

    /// Convenience initializer accepting explicit `codestreamID` before `data`.
    public init(
        binClass: JPIPDataBinClass,
        binID: Int,
        codestreamID: Int,
        data: Data,
        isComplete: Bool,
        qualityLayer: Int = 0,
        tileIndex: Int = 0,
        msgOffset: Int = 0,
        aux: Int? = nil
    ) {
        self.init(
            binClass: binClass,
            binID: binID,
            data: data,
            isComplete: isComplete,
            qualityLayer: qualityLayer,
            tileIndex: tileIndex,
            codestreamID: codestreamID,
            msgOffset: msgOffset,
            aux: aux
        )
    }
}

// MARK: - Normative ITU-T T.808 Annex A.2 VBAS & Clause D.3 EOR Codec

/// Normative ITU-T Rec. T.808 (12/2022) Annex A.1 Variable-length Byte-Aligned Segment (VBAS)
/// and Annex A.2 / Clause D.3 JPIP message stream encoder and decoder.
public enum JPIPWireCodec {
    /// Encodes a non-negative 64-bit integer as an Annex A.1 VBAS (big-endian 7-bit groups,
    /// bit 7 = `1` on all bytes except the final byte).
    public static func encodeVBAS(_ value: UInt64) -> [UInt8] {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var rem = value >> 7
        while rem > 0 {
            groups.append(0x80 | UInt8(rem & 0x7F))
            rem >>= 7
        }
        groups.reverse()
        return groups
    }

    /// Encodes the Annex A.2.1 `Bin-ID` VBAS (`[more(1) | bb(2) | c(1) | id_hi(4)]` followed
    /// by zero or more `[more(1) | id_lo(7)]` continuation bytes).
    public static func encodeBinIDVBAS(bb: UInt8, isComplete: Bool, inClassID: UInt64) -> [UInt8] {
        let flags: UInt8 = ((bb & 0x03) << 5) | ((isComplete ? 1 : 0) << 4)
        if inClassID <= 0x0F {
            return [flags | UInt8(inClassID & 0x0F)]
        }
        // Determine byte length k >= 2 such that 7*(k-1) + 4 >= bitWidth(inClassID).
        var k = 1
        var tmp = inClassID >> 4
        while tmp > 0 {
            k += 1
            tmp >>= 7
        }
        var out = [UInt8]()
        out.reserveCapacity(k)
        let topShift = UInt64(7 * (k - 1))
        let top4 = topShift >= 64 ? 0 : UInt8((inClassID >> topShift) & 0x0F)
        out.append(0x80 | flags | top4)
        for n in stride(from: k - 2, through: 0, by: -1) {
            let seg = UInt8((inClassID >> UInt64(7 * n)) & 0x7F)
            out.append(n > 0 ? (0x80 | seg) : seg)
        }
        return out
    }

    /// Decodes an Annex A.1 VBAS with checked 64-bit overflow protection.
    public static func decodeVBAS(from bytes: [UInt8], offset: inout Int) throws -> UInt64 {
        guard offset < bytes.count else {
            throw J2KError.invalidData("Truncated JPIP VBAS at end of stream.")
        }
        var value: UInt64 = 0
        var count = 0
        while true {
            guard offset < bytes.count else {
                throw J2KError.invalidData("Truncated multi-byte JPIP VBAS.")
            }
            let byte = bytes[offset]
            offset += 1
            count += 1
            // Prevent 64-bit left-shift overflow (> 9 full 7-bit groups with non-zero top bits).
            if count > 10 || (count == 10 && (value >> 57) != 0) {
                throw J2KError.invalidData("JPIP VBAS exceeds 64-bit integer range.")
            }
            value = (value << 7) | UInt64(byte & 0x7F)
            if (byte & 0x80) == 0 {
                return value
            }
        }
    }

    /// Encodes a sequence of ``JPIPDataBin`` messages (and optional Clause D.3 `>=3`-byte EOR)
    /// into a normative `image/jpp-stream` or `image/jpt-stream` byte sequence.
    public static func encodeStream(
        bins: [JPIPDataBin],
        includeEOR: Bool = true,
        eorReason: JPIPEORReason = .windowDone,
        eorBody: Data = Data()
    ) -> Data {
        var out = Data()
        var approx = bins.reduce(0) { $0 + $1.data.count + 12 } + (includeEOR ? (3 + eorBody.count) : 0)
        approx = max(approx, 4)
        out.reserveCapacity(approx)

        var prevClassID: Int?
        var prevCSn: Int?

        for bin in bins {
            let wireClass = bin.binClass.wireClassID
            let csn = max(0, bin.codestreamID)
            let bb: UInt8
            if prevCSn == nil {
                // Always emit explicit Class and CSn on the first message (`bb = 3`) for unambiguous
                // interoperability with both Kakadu and OpenJPEG `libopenjpip`.
                bb = 3
            } else if prevCSn != csn {
                bb = 3
            } else if prevClassID != wireClass {
                bb = 2
            } else {
                bb = 1
            }
            prevClassID = wireClass
            prevCSn = csn

            out.append(contentsOf: encodeBinIDVBAS(
                bb: bb,
                isComplete: bin.isComplete,
                inClassID: UInt64(max(0, bin.binID))
            ))
            if bb >= 2 {
                out.append(contentsOf: encodeVBAS(UInt64(wireClass)))
            }
            if bb == 3 {
                out.append(contentsOf: encodeVBAS(UInt64(csn)))
            }
            out.append(contentsOf: encodeVBAS(UInt64(max(0, bin.msgOffset))))
            out.append(contentsOf: encodeVBAS(UInt64(bin.data.count)))
            if (wireClass & 1) == 1 {
                out.append(contentsOf: encodeVBAS(UInt64(max(0, bin.aux ?? 0))))
            }
            out.append(bin.data)
        }

        if includeEOR {
            out.append(encodeEOR(reason: eorReason, body: eorBody))
        }
        return out
    }

    /// Convenience overload encoding a ``JPIPDataBin`` stream with an explicit ``JPIPEORMessage``.
    public static func encodeStream(
        bins: [JPIPDataBin],
        eor: JPIPEORMessage?
    ) -> Data {
        if let eor {
            return encodeStream(bins: bins, includeEOR: true, eorReason: eor.reason, eorBody: eor.body)
        } else {
            return encodeStream(bins: bins, includeEOR: false)
        }
    }

    /// Encodes a normative ITU-T Rec. T.808 Clause D.3 End of Response (EOR) message:
    /// `[0x00, reason(1 byte), Msg-Length(VBAS), body]`. Minimum length is 3 bytes.
    public static func encodeEOR(reason: JPIPEORReason, body: Data = Data()) -> Data {
        var out = Data([0x00, reason.rawValue])
        out.append(contentsOf: encodeVBAS(UInt64(body.count)))
        if !body.isEmpty {
            out.append(body)
        }
        return out
    }

    /// Decodes a normative `image/jpp-stream` or `image/jpt-stream` byte sequence with
    /// checked arithmetic and `maxPayloadBytes` resource enforcement.
    public static func decodeStream(
        _ data: Data,
        maxPayloadBytes: Int = 128 * 1024 * 1024
    ) throws -> JPIPParsedStream {
        guard data.count <= maxPayloadBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP stream (\(data.count) bytes) exceeds limit (\(maxPayloadBytes) bytes).")
        }
        let bytes = [UInt8](data)
        var offset = 0
        // Per ITU-T Rec. T.808 Annex A.2.1, initial default Class is 0 (precinct) and CSn is 0.
        var currentWireClass = 0
        var currentCSn = 0
        var bins: [JPIPDataBin] = []
        var totalDecodedPayload = 0
        var parsedEORReason: JPIPEORReason?
        var parsedEORRaw: UInt8?
        var parsedEORBody: Data?

        while offset < bytes.count {
            let b0 = bytes[offset]

            // Clause D.3 End of Response (EOR): single-byte `0x00` followed by 1-byte reason
            // and VBAS `Msg-Length` + optional body (minimum 3 bytes total).
            if b0 == 0x00 {
                guard offset + 3 <= bytes.count else {
                    throw J2KError.invalidData("Truncated JPIP EOR message (must be at least 3 bytes per ITU-T T.808 Clause D.3).")
                }
                offset += 1
                let reasonByte = bytes[offset]
                offset += 1
                let bodyLenU64 = try decodeVBAS(from: bytes, offset: &offset)
                guard bodyLenU64 <= UInt64(bytes.count - offset) else {
                    throw J2KError.invalidData("Truncated JPIP EOR body (\(bodyLenU64) bytes declared, \(bytes.count - offset) available).")
                }
                let bodyLen = Int(bodyLenU64)
                parsedEORRaw = reasonByte
                parsedEORReason = JPIPEORReason(rawValue: reasonByte) ?? .nonSpecified
                parsedEORBody = bodyLen > 0 ? Data(bytes[offset..<(offset + bodyLen)]) : Data()
                offset += bodyLen
                guard offset == bytes.count else {
                    throw J2KError.invalidData("Unexpected trailing bytes after JPIP EOR message.")
                }
                break
            }

            let bb = (b0 >> 5) & 0x03
            guard bb != 0 else {
                throw J2KError.invalidData("Invalid JPIP Bin-ID VBAS indicator bb=0 on non-EOR byte 0x\(String(b0, radix: 16)).")
            }
            let isComplete = ((b0 >> 4) & 0x01) == 1
            var inClassU64 = UInt64(b0 & 0x0F)
            offset += 1
            if (b0 & 0x80) != 0 {
                var contCount = 0
                while true {
                    guard offset < bytes.count else {
                        throw J2KError.invalidData("Truncated JPIP Bin-ID VBAS continuation.")
                    }
                    let cb = bytes[offset]
                    offset += 1
                    contCount += 1
                    if contCount > 9 || (inClassU64 >> 57) != 0 {
                        throw J2KError.invalidData("JPIP Bin-ID VBAS overflows 64-bit integer.")
                    }
                    inClassU64 = (inClassU64 << 7) | UInt64(cb & 0x7F)
                    if (cb & 0x80) == 0 { break }
                }
            }
            guard inClassU64 <= UInt64(Int.max) else {
                throw J2KError.invalidData("JPIP In-Class-ID overflows Int.")
            }

            if bb >= 2 {
                let clsU64 = try decodeVBAS(from: bytes, offset: &offset)
                guard clsU64 <= UInt64(Int.max) else {
                    throw J2KError.invalidData("JPIP Class VBAS overflows Int.")
                }
                currentWireClass = Int(clsU64)
            }
            if bb == 3 {
                let csnU64 = try decodeVBAS(from: bytes, offset: &offset)
                guard csnU64 <= UInt64(Int.max) else {
                    throw J2KError.invalidData("JPIP CSn VBAS overflows Int.")
                }
                currentCSn = Int(csnU64)
            }

            let msgOffsetU64 = try decodeVBAS(from: bytes, offset: &offset)
            let msgLenU64 = try decodeVBAS(from: bytes, offset: &offset)
            guard msgOffsetU64 <= UInt64(Int.max), msgLenU64 <= UInt64(Int.max) else {
                throw J2KError.invalidData("JPIP Msg-Offset or Msg-Length overflows Int.")
            }
            let msgOffset = Int(msgOffsetU64)
            let msgLen = Int(msgLenU64)

            var auxVal: Int?
            if (currentWireClass & 1) == 1 {
                let auxU64 = try decodeVBAS(from: bytes, offset: &offset)
                guard auxU64 <= UInt64(Int.max) else {
                    throw J2KError.invalidData("JPIP Aux VBAS overflows Int.")
                }
                auxVal = Int(auxU64)
            }

            guard msgLen <= (bytes.count - offset) else {
                throw J2KError.invalidData("Truncated JPIP message payload (\(msgLen) bytes declared, \(bytes.count - offset) remaining).")
            }
            let (nextPayload, ov) = totalDecodedPayload.addingReportingOverflow(msgLen)
            guard !ov, nextPayload <= maxPayloadBytes else {
                throw CodecError(.resourceLimitExceeded, "Cumulative JPIP message payloads exceed limit (\(maxPayloadBytes) bytes).")
            }
            totalDecodedPayload = nextPayload

            let payload = msgLen > 0 ? Data(bytes[offset..<(offset + msgLen)]) : Data()
            offset += msgLen

            guard let binClass = JPIPDataBinClass(wireClassID: currentWireClass) else {
                throw J2KError.invalidData("Unknown JPIP data-bin wire class identifier \(currentWireClass) (ITU-T T.808 Table A.2).")
            }

            let tileIdx = (binClass == .tile || binClass == .extendedTile || binClass == .tileHeader)
                ? Int(inClassU64) : 0

            bins.append(
                JPIPDataBin(
                    binClass: binClass,
                    binID: Int(inClassU64),
                    data: payload,
                    isComplete: isComplete,
                    qualityLayer: 0,
                    tileIndex: tileIdx,
                    codestreamID: currentCSn,
                    msgOffset: msgOffset,
                    aux: auxVal
                )
            )
        }

        return JPIPParsedStream(
            bins: bins,
            eorReason: parsedEORReason,
            eorReasonRawValue: parsedEORRaw,
            eorBody: parsedEORBody
        )
    }
}
