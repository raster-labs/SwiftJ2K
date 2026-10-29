// SPDX-License-Identifier: Apache-2.0
//
// JPIPDataBinGenerator.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPDataBinGenerator.swift
//
//
// JPIPDataBinGenerator.swift
// J2KSwift
//
/// # JPIPDataBinGenerator
///
/// Generates JPIP data bins from JPEG 2000 codestreams with HTJ2K support.
///
/// Extracts main headers, tile headers, and precinct data from JPEG 2000
/// codestreams (both legacy and HTJ2K) and packages them as JPIP data bins
/// for progressive streaming.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// Generates JPIP data bins from JPEG 2000 codestream data.
///
/// Parses codestream markers to extract structural components and packages
/// them into JPIP data bins suitable for progressive streaming. Supports
/// both legacy JPEG 2000 and HTJ2K codestreams.
///
/// Example:
/// ```swift
/// let generator = JPIPDataBinGenerator()
/// let bins = try generator.generateDataBins(from: codestreamData)
/// ```
public struct JPIPDataBinGenerator: Sendable {
    /// Creates a new data bin generator.
    public init() {}

    /// Generates JPIP data bins from a JPEG 2000 file.
    ///
    /// Reads the file, parses the codestream structure, and produces
    /// data bins for the main header, tile headers, and precinct data.
    ///
    /// - Parameter url: The file URL to read.
    /// - Returns: Array of generated data bins.
    /// - Throws: ``J2KError`` if the file cannot be read or parsed.
    public func generateDataBins(from url: URL) throws -> [JPIPDataBin] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try generateDataBins(from: data)
    }

    /// Generates JPIP data bins from codestream data.
    ///
    /// Parses the codestream structure and produces data bins for the
    /// main header, tile headers, and tile/precinct data.
    ///
    /// - Parameter data: The codestream data.
    /// - Returns: Array of generated data bins.
    /// - Throws: ``J2KError`` if the data cannot be parsed.
    public func generateDataBins(from data: Data) throws -> [JPIPDataBin] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            throw J2KError.invalidParameter("Data too small for JPEG 2000 codestream")
        }

        var bins: [JPIPDataBin] = []

        // Preserve JP2/JPH/JPX container framing (ihdr, colr, pclr, cmap, cdef, rreq, res, xml, uuid)
        // in JPIP metadata bins when streaming container targets.
        let csBytes: [UInt8]
        let trailingContainerBytes: [UInt8]?
        if let span = findContainerCodestreamSpan(in: bytes) {
            if span.boxStart > 0 {
                bins.append(JPIPDataBin(
                    binClass: .metadata,
                    binID: 0,
                    data: Data(bytes[0..<span.boxStart]),
                    isComplete: true
                ))
            }
            csBytes = Array(bytes[span.payloadStart..<span.boxEnd])
            if span.boxEnd < bytes.count {
                trailingContainerBytes = Array(bytes[span.boxEnd..<bytes.count])
            } else {
                trailingContainerBytes = nil
            }
        } else {
            csBytes = bytes
            trailingContainerBytes = nil
        }

        // Extract main header
        let mainHeader = try extractMainHeader(from: csBytes)
        bins.append(JPIPDataBin(
            binClass: .mainHeader,
            binID: 0,
            data: Data(mainHeader),
            isComplete: true
        ))

        // Extract tile parts
        let tileParts = extractTileParts(from: csBytes, headerEnd: mainHeader.count)
        for (index, tilePart) in tileParts.enumerated() {
            // Tile header data bin
            bins.append(JPIPDataBin(
                binClass: .tileHeader,
                binID: index,
                data: Data(tilePart.header),
                isComplete: true
            ))

            // Tile data bin (bitstream data)
            bins.append(JPIPDataBin(
                binClass: .tile,
                binID: index,
                data: Data(tilePart.data),
                isComplete: true
            ))
        }

        // If no tile parts found, package remaining data as tile 0
        if tileParts.isEmpty && csBytes.count > mainHeader.count {
            let remainingData = Array(csBytes[mainHeader.count...])
            bins.append(JPIPDataBin(
                binClass: .tile,
                binID: 0,
                data: Data(remainingData),
                isComplete: true
            ))
        }

        if let trailing = trailingContainerBytes, !trailing.isEmpty {
            bins.append(JPIPDataBin(
                binClass: .metadata,
                binID: 1,
                data: Data(trailing),
                isComplete: true
            ))
        }

        return bins
    }

    /// Checks whether the given data is an HTJ2K codestream.
    ///
    /// - Parameter data: The codestream data to check.
    /// - Returns: `true` if the data contains HTJ2K markers.
    public func isHTJ2KCodestream(_ data: Data) -> Bool {
        let transcoder = J2KTranscoder()
        return (try? transcoder.isHTJ2K(data)) ?? false
    }

    /// Reassembles a JPEG 2000 codestream (or JP2/JPH/JPX container when metadata bins are present)
    /// from an array of JPIP data bins.
    ///
    /// Combines the `.mainHeader` bin, `.tileHeader` bins, `.tile` / `.precinct` bins,
    /// restores `SOD` (`0xFF93`) and `EOC` (`0xFFD9`) markers when needed, and wraps
    /// the codestream back into its container boxes when `.metadata` bin 0 is present.
    ///
    /// - Parameter bins: The JPIP data bins to reassemble.
    /// - Returns: A reassembled JPEG 2000 codestream or container.
    public func reassembleCodestream(from bins: [JPIPDataBin]) -> Data {
        guard !bins.isEmpty else { return Data() }

        var output = Data()
        if let mainHeader = bins.first(where: { $0.binClass == .mainHeader }) {
            output.append(mainHeader.data)
        }

        let tileHeaders = bins
            .filter { $0.binClass == .tileHeader }
            .sorted { $0.binID < $1.binID }
        let tileDataByID = Dictionary(
            bins.filter { $0.binClass == .tile }.map { ($0.binID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var handledTileIDs = Set<Int>()
        for th in tileHeaders {
            output.append(th.data)
            let thBytes = [UInt8](th.data)
            let endsWithSOD = thBytes.count >= 2
                && thBytes[thBytes.count - 2] == 0xFF
                && thBytes[thBytes.count - 1] == 0x93
            if !endsWithSOD {
                output.append(contentsOf: [0xFF, 0x93] as [UInt8])
            }
            if let tileBin = tileDataByID[th.binID] {
                output.append(tileBin.data)
                handledTileIDs.insert(th.binID)
            }
        }

        // Append any remaining tile bins that had no separate tileHeader bin
        let remainingTiles = bins
            .filter { $0.binClass == .tile && !handledTileIDs.contains($0.binID) }
            .sorted { $0.binID < $1.binID }
        for tileBin in remainingTiles {
            output.append(tileBin.data)
        }

        // If we had tile headers/data, ensure the codestream terminates with EOC (0xFFD9)
        if !tileHeaders.isEmpty {
            let outBytes = [UInt8](output.suffix(2))
            if outBytes.count < 2 || outBytes[0] != 0xFF || outBytes[1] != 0xD9 {
                output.append(contentsOf: [0xFF, 0xD9] as [UInt8])
            }
        }

        if let prefixMeta = bins.first(where: { $0.binClass == .metadata && $0.binID == 0 }) {
            var containerData = Data()
            containerData.reserveCapacity(prefixMeta.data.count + 16 + output.count)
            containerData.append(prefixMeta.data)
            if output.count <= Int(UInt32.max) - 8 {
                let boxLen = UInt32(output.count + 8)
                containerData.append(contentsOf: [
                    UInt8((boxLen >> 24) & 0xFF),
                    UInt8((boxLen >> 16) & 0xFF),
                    UInt8((boxLen >> 8) & 0xFF),
                    UInt8(boxLen & 0xFF),
                    0x6A, 0x70, 0x32, 0x63 // "jp2c"
                ])
            } else {
                let xlBoxLen = UInt64(output.count) + 16
                containerData.append(contentsOf: [
                    0x00, 0x00, 0x00, 0x01,
                    0x6A, 0x70, 0x32, 0x63, // "jp2c"
                    UInt8((xlBoxLen >> 56) & 0xFF),
                    UInt8((xlBoxLen >> 48) & 0xFF),
                    UInt8((xlBoxLen >> 40) & 0xFF),
                    UInt8((xlBoxLen >> 32) & 0xFF),
                    UInt8((xlBoxLen >> 24) & 0xFF),
                    UInt8((xlBoxLen >> 16) & 0xFF),
                    UInt8((xlBoxLen >> 8) & 0xFF),
                    UInt8(xlBoxLen & 0xFF)
                ])
            }
            containerData.append(output)
            if let suffixMeta = bins.first(where: { $0.binClass == .metadata && $0.binID == 1 }) {
                containerData.append(suffixMeta.data)
            }
            return containerData
        }

        return output
    }

    // MARK: - Private Helpers

    /// Locates the first `jp2c` contiguous codestream box inside a JP2/JPH/JPX container.
    ///
    /// Returns `nil` for raw codestreams so raw J2K inputs retain their exact three-bin framing.
    private func findContainerCodestreamSpan(
        in bytes: [UInt8]
    ) -> (boxStart: Int, payloadStart: Int, boxEnd: Int)? {
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0x4F {
            return nil
        }
        guard bytes.count >= 12 else { return nil }
        let isJP2 = bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 &&
                    bytes[3] == 0x0C && bytes[4] == 0x6A && bytes[5] == 0x50 &&
                    bytes[6] == 0x20 && bytes[7] == 0x20 && bytes[8] == 0x0D &&
                    bytes[9] == 0x0A && bytes[10] == 0x87 && bytes[11] == 0x0A
        guard isJP2 else { return nil }

        var offset = 0
        while offset <= bytes.count - 8 {
            let boxLenU32 = (UInt32(bytes[offset]) << 24) |
                            (UInt32(bytes[offset + 1]) << 16) |
                            (UInt32(bytes[offset + 2]) << 8) |
                            UInt32(bytes[offset + 3])
            let boxType = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)

            let headerSize: Int
            let boxEnd: Int
            if boxLenU32 == 0 {
                headerSize = 8
                boxEnd = bytes.count
            } else if boxLenU32 == 1 {
                guard offset <= bytes.count - 16 else { break }
                var xl: UInt64 = 0
                for b in 0..<8 {
                    xl = (xl << 8) | UInt64(bytes[offset + 8 + b])
                }
                guard xl >= 16, xl <= UInt64(Int.max) else { break }
                let (end, ov) = offset.addingReportingOverflow(Int(xl))
                guard !ov else { break }
                headerSize = 16
                boxEnd = min(end, bytes.count)
            } else {
                guard boxLenU32 >= 8 else { break }
                let (end, ov) = offset.addingReportingOverflow(Int(boxLenU32))
                guard !ov else { break }
                headerSize = 8
                boxEnd = min(end, bytes.count)
            }

            if boxType == "jp2c" {
                let payloadStart = min(offset + headerSize, boxEnd)
                return (boxStart: offset, payloadStart: payloadStart, boxEnd: boxEnd)
            }
            if boxEnd <= offset { break }
            offset = boxEnd
        }
        return nil
    }

    /// Extracts the main header from a codestream.
    ///
    /// The main header spans from SOC (0xFF4F) to the first SOT (0xFF90)
    /// marker, or to the end of data if no SOT is found.
    ///
    /// - Parameter bytes: The codestream bytes starting at SOC.
    /// - Returns: The main header bytes.
    /// - Throws: ``J2KError`` if the codestream is invalid.
    private func extractMainHeader(from bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0x4F else {
            throw J2KError.invalidParameter("Invalid codestream: missing SOC marker")
        }

        // Scan for SOT marker (0xFF90) which marks end of main header
        var offset = 2
        while offset + 1 < bytes.count {
            if bytes[offset] == 0xFF && bytes[offset + 1] == 0x90 {
                return Array(bytes[0..<offset])
            }

            // If it's a marker with a length field, skip it
            if bytes[offset] == 0xFF && bytes[offset + 1] != 0xFF {
                let marker = bytes[offset + 1]
                // SOC (0x4F), SOD (0x93), EOC (0xD9) have no length
                if marker == 0x4F || marker == 0x93 || marker == 0xD9 {
                    offset += 2
                } else if offset + 3 < bytes.count {
                    let length = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                    guard length >= 2 else {
                        offset += 2
                        continue
                    }
                    let (nextOffset, overflow) = offset.addingReportingOverflow(2 + length)
                    if overflow { break }
                    offset = nextOffset
                } else {
                    offset += 2
                }
            } else {
                offset += 1
            }
        }

        // No SOT found - entire data is the header
        return bytes
    }

    /// Represents a parsed tile part.
    struct TilePart {
        /// The tile header bytes (SOT marker segment).
        let header: [UInt8]

        /// The tile bitstream data (after SOD).
        let data: [UInt8]

        /// The tile index from the SOT marker.
        let tileIndex: Int
    }

    /// Extracts tile parts from a codestream.
    ///
    /// - Parameters:
    ///   - bytes: The codestream bytes starting at SOC.
    ///   - headerEnd: Offset past the main header.
    /// - Returns: Array of tile parts found.
    private func extractTileParts(from bytes: [UInt8], headerEnd: Int) -> [TilePart] {
        var tileParts: [TilePart] = []
        var offset = headerEnd

        while offset + 1 < bytes.count {
            // Look for SOT marker (0xFF90)
            if bytes[offset] == 0xFF && bytes[offset + 1] == 0x90 {
                guard offset + 11 < bytes.count else { break }

                // Parse SOT marker segment
                let sotLength = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                let tileIndex = (Int(bytes[offset + 4]) << 8) | Int(bytes[offset + 5])
                let tilePartLengthU32 = (UInt32(bytes[offset + 6]) << 24) |
                                        (UInt32(bytes[offset + 7]) << 16) |
                                        (UInt32(bytes[offset + 8]) << 8) |
                                        UInt32(bytes[offset + 9])
                let tilePartLength = Int(tilePartLengthU32)

                // Tile header: SOT marker + its length field content
                let (headerEndOffset, hOverflow) = offset.addingReportingOverflow(2 + max(2, sotLength))
                if hOverflow { break }

                // Find SOD marker (0xFF93) to separate header from data
                var sodOffset = min(headerEndOffset, bytes.count)
                while sodOffset + 1 < bytes.count {
                    if bytes[sodOffset] == 0xFF && bytes[sodOffset + 1] == 0x93 {
                        break
                    }
                    // Skip marker segments within tile header
                    if bytes[sodOffset] == 0xFF && bytes[sodOffset + 1] != 0xFF {
                        let m = bytes[sodOffset + 1]
                        if m == 0x4F || m == 0x93 || m == 0xD9 {
                            break
                        } else if sodOffset + 3 < bytes.count {
                            let mLen = (Int(bytes[sodOffset + 2]) << 8) | Int(bytes[sodOffset + 3])
                            guard mLen >= 2 else {
                                sodOffset += 2
                                continue
                            }
                            let (nextSod, mOverflow) = sodOffset.addingReportingOverflow(2 + mLen)
                            if mOverflow { break }
                            sodOffset = nextSod
                        } else {
                            sodOffset += 2
                        }
                    } else {
                        sodOffset += 1
                    }
                }

                let tileHeader = Array(bytes[offset..<min(sodOffset, bytes.count)])

                // Tile data starts after SOD marker
                let dataStart = min(sodOffset + 2, bytes.count)
                let dataEnd: Int
                if tilePartLength > 0 {
                    let (tpEnd, tpOverflow) = offset.addingReportingOverflow(tilePartLength)
                    dataEnd = tpOverflow ? bytes.count : min(tpEnd, bytes.count)
                } else {
                    // Find next SOT or EOC
                    var nextOffset = dataStart
                    while nextOffset + 1 < bytes.count {
                        if bytes[nextOffset] == 0xFF &&
                           (bytes[nextOffset + 1] == 0x90 || bytes[nextOffset + 1] == 0xD9) {
                            break
                        }
                        nextOffset += 1
                    }
                    dataEnd = nextOffset
                }

                let tileData = dataStart < dataEnd ? Array(bytes[dataStart..<dataEnd]) : []

                tileParts.append(TilePart(
                    header: tileHeader,
                    data: tileData,
                    tileIndex: tileIndex
                ))

                offset = dataEnd
            } else if bytes[offset] == 0xFF && bytes[offset + 1] == 0xD9 {
                // EOC marker - end of codestream
                break
            } else {
                offset += 1
            }
        }

        return tileParts
    }
}
