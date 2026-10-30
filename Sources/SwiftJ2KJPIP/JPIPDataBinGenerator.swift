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
        try generateDataBins(from: data, limits: .default, retainedBytes: 0).bins
    }

    package struct BoundedGeneration: Sendable {
        package let bins: [JPIPDataBin]
        /// Computed upper bound from bin payload/descriptor counts, retained external
        /// workspace and reserved cache entries. Excludes allocator/hash capacity overhead.
        package let peakWorkspaceBytes: Int
    }

    /// Borrows the compressed input and scans ranges without making raw/extracted byte copies.
    /// The first pass validates and admits every final payload and descriptor before allocation.
    package func generateDataBins(
        from data: Data, limits: ResourceLimits, retainedBytes: Int,
        maximumAdditionalCacheEntries: Int = 0
    ) throws -> BoundedGeneration {
        guard data.count >= 2 else {
            throw CodecError(.malformedInput, "Data too small for JPEG 2000 codestream")
        }
        guard retainedBytes >= 0, maximumAdditionalCacheEntries >= 0,
              data.count <= limits.maximumCompressedBytes,
              try Self.add(data.count, retainedBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP generator input and retained cache exceed memory limits.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(limits.deadlineSeconds))
        func checkWork() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now <= deadline else {
                throw CodecError(.resourceLimitExceeded, "JPIP data-bin generation deadline elapsed.")
            }
        }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var binCount = 0
            var payloadBytes = 0
            try enumerateBinRanges(bytes, checkWork: checkWork) { _, _, range in
                binCount = try Self.add(binCount, 1)
                payloadBytes = try Self.add(payloadBytes, range.count)
            }
            let (descriptorBytes, overflow) = binCount.multipliedReportingOverflow(by: MemoryLayout<JPIPDataBin>.stride)
            guard !overflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP bin descriptor storage overflows Int.")
            }
            let (cacheDescriptorBytes, cacheOverflow) = min(binCount, maximumAdditionalCacheEntries)
                .multipliedReportingOverflow(by: MemoryLayout<JPIPCacheModel.CacheEntry>.stride)
            guard !cacheOverflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP cache descriptor storage overflows Int.")
            }
            let workspace = try Self.add(retainedBytes, Self.add(payloadBytes, Self.add(descriptorBytes, cacheDescriptorBytes)))
            guard workspace <= limits.maximumWorkspaceBytes,
                  try Self.add(data.count, workspace) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "JPIP bin payloads, descriptors and retained cache exceed combined limits.")
            }
            try checkWork()
            let bins = try Array<JPIPDataBin>(unsafeUninitializedCapacity: binCount) { buffer, initialisedCount in
                guard let destination = buffer.baseAddress, let source = bytes.baseAddress else {
                    throw CodecError(.internalFailure, "Missing admitted JPIP buffer storage.")
                }
                try enumerateBinRanges(bytes, checkWork: checkWork) { kind, id, range in
                    guard initialisedCount < binCount else {
                        throw CodecError(.internalFailure, "JPIP bin scan count changed between passes.")
                    }
                    let payload = Data(bytes: source.advanced(by: range.lowerBound), count: range.count)
                    destination.advanced(by: initialisedCount).initialize(to: JPIPDataBin(
                        binClass: kind, binID: id, data: payload, isComplete: true))
                    initialisedCount += 1
                }
                guard initialisedCount == binCount else {
                    throw CodecError(.internalFailure, "JPIP bin scan count changed between passes.")
                }
            }
            return BoundedGeneration(bins: bins, peakWorkspaceBytes: workspace)
        }
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

    // MARK: - Borrowed range scanner

    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else {
            throw CodecError(.resourceLimitExceeded, "JPIP generator storage arithmetic overflow.")
        }
        return value
    }

    /// Emits non-overlapping byte ranges. Neither pass allocates intermediate byte arrays.
    private func enumerateBinRanges(
        _ bytes: UnsafeRawBufferPointer,
        checkWork: () throws -> Void,
        emit: (JPIPDataBinClass, Int, Range<Int>) throws -> Void
    ) throws {
        func malformed(_ message: String) -> CodecError { CodecError(.malformedInput, message) }
        func u16(_ p: Int) -> Int { (Int(bytes[p]) << 8) | Int(bytes[p + 1]) }
        func u32(_ p: Int) -> UInt32 {
            (UInt32(bytes[p]) << 24) | (UInt32(bytes[p + 1]) << 16) |
            (UInt32(bytes[p + 2]) << 8) | UInt32(bytes[p + 3])
        }
        try checkWork()
        var codestream = 0..<bytes.count
        var prefixEnd = 0
        var suffixStart = bytes.count
        if bytes[0] != 0xFF || bytes[1] != 0x4F {
            guard bytes.count >= 12, u32(0) == 12, u32(4) == 0x6A50_2020,
                  u32(8) == 0x0D0A_870A else { throw malformed("Invalid codestream: missing SOC marker") }
            var offset = 0
            var foundCodestream = false
            while offset < bytes.count {
                try checkWork()
                guard bytes.count - offset >= 8 else { throw malformed("Truncated JPIP container box.") }
                let length = u32(offset)
                let type = u32(offset + 4)
                var headerSize = 8
                let end: Int
                if length == 0 {
                    end = bytes.count
                } else if length == 1 {
                    guard bytes.count - offset >= 16 else { throw malformed("Truncated JPIP extended box length.") }
                    let extended = (UInt64(u32(offset + 8)) << 32) | UInt64(u32(offset + 12))
                    guard extended >= 16, extended <= UInt64(bytes.count - offset) else {
                        throw malformed("Invalid JPIP extended box bounds.")
                    }
                    headerSize = 16
                    end = offset + Int(extended)
                } else {
                    guard length >= 8, Int(length) <= bytes.count - offset else {
                        throw malformed("Invalid JPIP container box bounds.")
                    }
                    end = offset + Int(length)
                }
                if type == 0x6A70_3263 {
                    guard !foundCodestream, end - offset > headerSize else {
                        throw malformed("Empty or duplicate JPIP codestream box.")
                    }
                    foundCodestream = true
                    codestream = (offset + headerSize)..<end
                    prefixEnd = offset
                    suffixStart = end
                }
                offset = end
            }
            guard foundCodestream else { throw malformed("JPIP container is missing a codestream box.") }
        }
        let start = codestream.lowerBound
        let end = codestream.upperBound
        guard end - start >= 2, bytes[start] == 0xFF, bytes[start + 1] == 0x4F else {
            throw malformed("Invalid codestream: missing SOC marker")
        }
        if prefixEnd > 0 { try emit(.metadata, 0, 0..<prefixEnd) }

        var offset = start + 2
        var foundTile = false
        while end - offset >= 2 {
            try checkWork()
            if bytes[offset] == 0xFF && bytes[offset + 1] == 0x90 {
                foundTile = true
                break
            }
            if bytes[offset] == 0xFF && bytes[offset + 1] != 0xFF {
                let marker = bytes[offset + 1]
                if marker == 0xD9 { offset += 2; break }
                guard marker != 0x4F, marker != 0x93, end - offset >= 4 else {
                    throw malformed("Invalid marker in JPIP main header.")
                }
                let length = u16(offset + 2)
                guard length >= 2, length <= end - offset - 2 else {
                    throw malformed("Invalid JPIP main-header segment length.")
                }
                offset += 2 + length
            } else {
                offset += 1
            }
        }
        try emit(.mainHeader, 0, start..<(foundTile ? offset : end))
        var tileID = 0
        while foundTile && offset < end {
            try checkWork()
            guard end - offset >= 2 else { throw malformed("Truncated JPIP tile marker.") }
            if bytes[offset] == 0xFF && bytes[offset + 1] == 0xD9 { break }
            guard end - offset >= 12, bytes[offset] == 0xFF, bytes[offset + 1] == 0x90,
                  u16(offset + 2) == 10 else { throw malformed("Invalid JPIP SOT marker.") }
            let psot = Int(u32(offset + 6))
            let tileEnd: Int
            if psot == 0 {
                tileEnd = end
            } else {
                guard psot >= 14, psot <= end - offset else {
                    throw malformed("JPIP tile-part length is outside its codestream bounds.")
                }
                tileEnd = offset + psot
            }
            var sod = offset + 12
            while true {
                try checkWork()
                guard tileEnd - sod >= 2 else { throw malformed("JPIP tile part has no SOD marker.") }
                if bytes[sod] == 0xFF && bytes[sod + 1] == 0x93 { break }
                guard bytes[sod] == 0xFF else { throw malformed("Invalid JPIP tile-header marker.") }
                if bytes[sod + 1] == 0xFF { sod += 1; continue }
                guard bytes[sod + 1] != 0x90, bytes[sod + 1] != 0xD9,
                      tileEnd - sod >= 4 else { throw malformed("Invalid JPIP tile-header boundary.") }
                let length = u16(sod + 2)
                guard length >= 2, length <= tileEnd - sod - 2 else {
                    throw malformed("JPIP tile-header segment extends past Psot.")
                }
                sod += 2 + length
            }
            let dataStart = sod + 2
            var dataEnd = tileEnd
            if psot == 0 {
                // Psot=0 denotes the final tile part. Stop only at EOC, never rescan
                // an overlapping SOT/header as a second materialised tile part.
                var cursor = dataStart
                while end - cursor >= 2 {
                    if cursor & 0xFFFF == 0 { try checkWork() }
                    if bytes[cursor] == 0xFF && bytes[cursor + 1] == 0xD9 { break }
                    if bytes[cursor] == 0xFF && bytes[cursor + 1] == 0x90 {
                        throw malformed("A zero-length JPIP tile part must be the final tile part.")
                    }
                    cursor += 1
                }
                guard end - cursor >= 2 else { throw malformed("Zero-length JPIP tile part has no EOC marker.") }
                dataEnd = cursor
            }
            try emit(.tileHeader, tileID, offset..<sod)
            try emit(.tile, tileID, dataStart..<dataEnd)
            tileID = try Self.add(tileID, 1)
            offset = dataEnd // Always beyond the SOT and SOD; no overlapping/backwards scan.
        }
        if foundTile {
            guard end - offset == 2, bytes[offset] == 0xFF, bytes[offset + 1] == 0xD9 else {
                throw malformed("JPIP codestream must finish with EOC after its final tile part.")
            }
        }
        if suffixStart < bytes.count { try emit(.metadata, 1, suffixStart..<bytes.count) }
    }
}
