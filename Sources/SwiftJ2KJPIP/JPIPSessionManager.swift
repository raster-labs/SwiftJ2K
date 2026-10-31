// SPDX-License-Identifier: Apache-2.0
//
// JPIPSessionManager.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPSessionManager.swift
//
// Extended in Phase R3 (F04) with byte-range (`Msg-Offset`) interval merging,
// duplicate/out-of-order segment reconciliation, and normative ITU-T Rec. T.808
// (12/2022) Clause C.8.1 / C.8.1.2 `model=` cache-model grammar.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// One parsed directive from an ITU-T Rec. T.808 Clause C.8.1 / C.8.1.1 / C.8.1.2 / C.8.1.3 `model=` query field.
public struct JPIPCacheModelDirective: Sendable, Equatable {
    /// Non-negative integer range (`lo...hi` or open-ended `lo...` when `upperBound == nil`)
    /// used by ITU-T Rec. T.808 Clause C.8.1.3 implicit precinct selectors.
    public struct ImplicitRange: Sendable, Equatable {
        public let lowerBound: Int
        public let upperBound: Int?

        public init(lowerBound: Int, upperBound: Int?) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }

        public func contains(_ value: Int) -> Bool {
            guard value >= lowerBound else { return false }
            if let hi = upperBound {
                return value <= hi
            }
            return true
        }
    }

    /// `true` when additive (default), `false` when prefixed with `-` (subtractive).
    public let isAdditive: Bool
    /// Target data-bin class (`nil` represents `*` across all classes).
    public let binClass: JPIPDataBinClass?
    /// Target in-class ID (`nil` represents `*` wildcard within `binClass` or an implicit precinct selector).
    public let binID: Int?
    /// Prefix byte count (`:<length>`); `nil` denotes the complete data-bin (unless `layerCount` is set).
    public let byteLength: Int?
    /// Optional layer qualifier (`:L<layers>`).
    public let layerCount: Int?
    /// Target codestream index (`0` by default per Clause C.8.1.1; `nil` represents an open-ended codestream range `[lo-]`).
    public let codestreamID: Int?
    /// Lower bound when `codestreamID == nil` comes from an open-ended Clause C.8.1.1 range `[lo-]`.
    public let codestreamLowerBound: Int?
    /// Inclusive upper bound of a finite codestream range; nil denotes an open range.
    public let codestreamUpperBound: Int?
    /// `true` when parsed from an ITU-T Rec. T.808 Clause C.8.1.3 implicit precinct descriptor (`t`/`c`/`s`/`r`/`p`).
    public let isImplicitPrecinct: Bool
    /// Optional Clause C.8.1.3 `t<range|*>` tile selector (`nil` matches all tiles).
    public let tileFilter: ImplicitRange?
    /// Optional Clause C.8.1.3 `c<range|*>` component selector (`nil` matches all components).
    public let componentFilter: ImplicitRange?
    /// Optional Clause C.8.1.3 `s<range|*>` tile-component precinct sequence selector (`nil` matches all sequences).
    public let sequenceFilter: ImplicitRange?
    /// Optional Clause C.8.1.3 `r<range|*>` resolution-level selector (`nil` matches all resolution levels).
    public let resolutionFilter: ImplicitRange?
    /// Optional Clause C.8.1.3 `p<range|*>` within-resolution precinct selector (`nil` matches all positions).
    public let precinctFilter: ImplicitRange?

    public init(
        isAdditive: Bool,
        binClass: JPIPDataBinClass?,
        binID: Int?,
        byteLength: Int?,
        codestreamID: Int? = 0,
        codestreamLowerBound: Int? = nil,
        codestreamUpperBound: Int? = nil,
        layerCount: Int? = nil,
        isImplicitPrecinct: Bool = false,
        tileFilter: ImplicitRange? = nil,
        componentFilter: ImplicitRange? = nil,
        sequenceFilter: ImplicitRange? = nil,
        resolutionFilter: ImplicitRange? = nil,
        precinctFilter: ImplicitRange? = nil
    ) {
        self.isAdditive = isAdditive
        self.binClass = binClass?.canonicalClass
        self.binID = binID
        self.byteLength = byteLength
        self.layerCount = layerCount
        self.codestreamID = codestreamID
        self.codestreamLowerBound = codestreamLowerBound
        self.codestreamUpperBound = codestreamUpperBound
        self.isImplicitPrecinct = isImplicitPrecinct
        self.tileFilter = tileFilter
        self.componentFilter = componentFilter
        self.sequenceFilter = sequenceFilter
        self.resolutionFilter = resolutionFilter
        self.precinctFilter = precinctFilter
    }

    /// Checks whether a codestream index satisfies this directive's Clause C.8.1.1 codestream qualifier.
    public func matchesCodestream(_ cs: Int) -> Bool {
        if let exact = codestreamID {
            return cs == exact
        }
        if let hi = codestreamUpperBound, cs > hi { return false }
        if let lo = codestreamLowerBound {
            return cs >= lo
        }
        return true
    }
}

/// Manages a JPIP session with a server.
public actor JPIPSession {
    /// The unique session identifier.
    public let sessionID: String

    /// The channel ID assigned by the server.
    public private(set) var channelID: String?

    /// Optional channel request path returned in `JPIP-cnew` (e.g., `"jpip"` from `kdu_server`).
    public private(set) var channelPath: String?

    /// Optional target ID (`JPIP-tid`) returned by the server.
    public private(set) var targetID: String?

    /// The target image being accessed.
    public private(set) var target: String?

    /// Whether the session is active.
    public private(set) var isActive: Bool

    /// Whether the client's local cache may have diverged from the server's assumed cache model
    /// (for example after an aborted transfer, cache eviction, or cache invalidation).
    package private(set) var needsServerModelSync: Bool = false

    /// Cache model tracking what data the client has.
    private var cacheModel: JPIPCacheModel

    /// Precinct-based cache for fine-grained data management.
    private var precinctCache: JPIPPrecinctCache

    /// Creates a new JPIP session.
    ///
    /// - Parameter sessionID: A unique session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
        self.isActive = false
        self.cacheModel = JPIPCacheModel()
        self.precinctCache = JPIPPrecinctCache()
    }

    /// Creates a new JPIP session with explicit cache bounds from ``JPIPSessionConfiguration``.
    internal init(sessionID: String, maxCacheSizeBytes: Int, maxCachedDataBins: Int) {
        self.sessionID = sessionID
        self.isActive = false
        self.cacheModel = JPIPCacheModel(maxCacheSize: maxCacheSizeBytes, maxEntries: maxCachedDataBins)
        self.precinctCache = JPIPPrecinctCache()
    }

    /// Sets the channel ID for this session.
    internal func setChannelID(_ channelID: String) {
        self.channelID = channelID
    }

    /// Sets the channel request path from `JPIP-cnew`.
    internal func setChannelPath(_ path: String?) {
        self.channelPath = path
    }

    /// Sets the target ID (`JPIP-tid`) from response headers.
    internal func setTargetID(_ tid: String?) {
        self.targetID = tid
    }

    /// Sets the target image for this session.
    internal func setTarget(_ target: String) {
        self.target = target
    }

    /// Activates the session.
    internal func activate() {
        self.isActive = true
    }

    /// Closes the session.
    public func close() async throws {
        self.isActive = false
        self.channelID = nil
        self.channelPath = nil
        self.targetID = nil
        self.target = nil
        self.needsServerModelSync = false
        self.cacheModel.clear()
        self.precinctCache.clear()
    }

    package func markPendingWireTransfer() {
        self.needsServerModelSync = true
    }

    package func markWireTransferSynchronized() {
        self.needsServerModelSync = false
    }

    /// Computes prospective cache statistics if `newBins` were recorded without mutating session state.
    package func prospectiveCacheStatistics(adding newBins: [JPIPDataBin]) -> JPIPCacheModel.Statistics {
        var copy = cacheModel
        for bin in newBins {
            copy.addDataBin(bin)
        }
        return copy.statistics
    }

    /// Records that a data bin (or partial `Msg-Offset` segment) has been received.
    public func recordDataBin(_ dataBin: JPIPDataBin) {
        let evictionsBefore = cacheModel.statistics.evictions
        cacheModel.addDataBin(dataBin)
        if cacheModel.statistics.evictions > evictionsBefore ||
           !cacheModel.hasDataBin(
               binClass: dataBin.binClass,
               binID: dataBin.binID,
               codestreamID: dataBin.codestreamID
           ) {
            needsServerModelSync = true
        }
    }

    /// Checks if a data bin is already in the cache (any bytes or complete).
    public func hasDataBin(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Bool {
        cacheModel.hasDataBin(binClass: binClass, binID: binID, codestreamID: codestreamID)
    }

    /// Checks if a data bin is completely received (`0..<completeLength` contiguous).
    public func hasCompleteDataBin(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Bool {
        cacheModel.hasCompleteDataBin(binClass: binClass, binID: binID, codestreamID: codestreamID)
    }

    /// Returns the contiguous prefix length starting at byte `0` for `(binClass, binID, codestreamID)`.
    public func contiguousPrefixLength(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Int {
        cacheModel.contiguousPrefixLength(binClass: binClass, binID: binID, codestreamID: codestreamID)
    }

    /// Retrieves a cached data bin.
    public func getDataBin(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> JPIPDataBin? {
        cacheModel.getDataBin(binClass: binClass, binID: binID, codestreamID: codestreamID)
    }

    /// Returns all accumulated data bins currently stored in this session's cache model.
    public func getAccumulatedDataBins() -> [JPIPDataBin] {
        cacheModel.allDataBins()
    }

    /// Alias for ``getAccumulatedDataBins()``.
    public func cachedDataBins() -> [JPIPDataBin] {
        cacheModel.allDataBins()
    }

    /// Formats the session's cached bins as normative ITU-T Rec. T.808 Clause C.8.1 `model=` descriptors.
    public func formatCacheModelDescriptors() -> [String] {
        cacheModel.formatCacheModelDescriptors()
    }

    /// Gets the current cache statistics.
    public func getCacheStatistics() -> JPIPCacheModel.Statistics {
        cacheModel.statistics
    }

    package func copyCacheForAdmission() -> JPIPCacheModel { cacheModel }
    package func retainedStorageBytes() throws -> Int {
        let identifiers = try JPIPAdmission.add(JPIPAdmission.string(target),
            JPIPAdmission.add(JPIPAdmission.string(channelID),
                JPIPAdmission.add(JPIPAdmission.string(channelPath), JPIPAdmission.string(targetID))))
        return try JPIPAdmission.add(cacheModel.retainedStorageBytes(), identifiers)
    }

    /// Publication is allocation-free: prepare and admit the candidate before
    /// decode, retain the old cache on failure, and publish only after success.
    package func commitPreparedCache(_ candidate: JPIPCacheModel, requiresSync: Bool = false) {
        let evicted = candidate.statistics.evictions > cacheModel.statistics.evictions
        cacheModel = candidate
        needsServerModelSync = evicted || requiresSync
    }

    /// Invalidates cached entries by bin class (optionally scoped to one codestream).
    public func invalidateCache(binClass: JPIPDataBinClass, codestreamID: Int? = nil) {
        cacheModel.invalidate(binClass: binClass, codestreamID: codestreamID)
        needsServerModelSync = true
    }

    /// Invalidates cached entries older than a given date.
    public func invalidateCache(olderThan date: Date) {
        cacheModel.invalidate(olderThan: date)
        needsServerModelSync = true
    }

    /// Adds a precinct to the cache.
    public func addPrecinct(_ precinctData: JPIPPrecinctData) {
        precinctCache.addPrecinct(precinctData)
    }

    /// Retrieves a cached precinct.
    public func getPrecinct(_ precinctID: JPIPPrecinctID) -> JPIPPrecinctData? {
        precinctCache.getPrecinct(precinctID)
    }

    /// Checks if a precinct is in the cache.
    public func hasPrecinct(_ precinctID: JPIPPrecinctID) -> Bool {
        precinctCache.hasPrecinct(precinctID)
    }

    /// Gets precinct cache statistics.
    public func getPrecinctStatistics() -> JPIPPrecinctCache.Statistics {
        precinctCache.statistics
    }

    /// Merges partial precinct data with existing cached data.
    public func mergePrecinct(
        _ precinctID: JPIPPrecinctID,
        data: Data,
        layers: Set<Int>,
        isComplete: Bool
    ) -> JPIPPrecinctData {
        precinctCache.mergePrecinct(precinctID, data: data, layers: layers, isComplete: isComplete)
    }

    /// Invalidates precincts for a specific tile.
    public func invalidatePrecincts(tile: Int) {
        precinctCache.invalidate(tile: tile)
    }

    /// Invalidates precincts for a specific resolution level.
    public func invalidatePrecincts(resolution: Int) {
        precinctCache.invalidate(resolution: resolution)
    }
}

/// Tracks cached JPIP data bins with interval-merging `Msg-Offset` byte assembly,
/// bounded LRU eviction, and ITU-T Rec. T.808 Clause C.8.1 `model=` serialization.
public struct JPIPCacheModel: Sendable {
    /// Represents a cached entry with merged byte intervals and metadata.
    struct CacheEntry: Sendable {
        /// The assembled data bin (contiguous prefix or sparse buffer).
        var dataBin: JPIPDataBin

        /// Sorted, non-overlapping byte intervals `[start..<end]` received so far.
        var coveredRanges: [Range<Int>]

        /// Known total byte length once a message with `isComplete == true` has been observed.
        var knownCompleteLength: Int?

        /// Timestamp when the entry was added or last accessed.
        var timestamp: Date

        /// Monotonic access order used for eviction, independent of wall-clock changes.
        var accessOrder: UInt64 = 0

        /// Number of times this entry has been accessed.
        var accessCount: Int

        /// Allocated buffer size in bytes.
        var size: Int

        /// Contiguous prefix length from byte offset `0`.
        var contiguousPrefix: Int {
            guard let first = coveredRanges.first, first.lowerBound == 0 else {
                return 0
            }
            return first.upperBound
        }

        init(dataBin: JPIPDataBin, timestamp: Date = Date(), accessCount: Int = 0) {
            let start = max(0, dataBin.msgOffset)
            let (rawEnd, ov) = start.addingReportingOverflow(dataBin.data.count)
            let end = ov ? dataBin.data.count : rawEnd
            var assembled: Data
            if start == 0 || ov {
                assembled = dataBin.data
            } else {
                assembled = Data(count: end)
                if !dataBin.data.isEmpty {
                    assembled.replaceSubrange(start..<end, with: dataBin.data)
                }
            }
            let ranges: [Range<Int>] = (!ov && end > start) ? [start..<end] : []
            let knownEnd: Int? = (!ov && dataBin.isComplete) ? end : nil
            let fullyComplete: Bool
            if let ke = knownEnd {
                fullyComplete = (ke == 0) || (ranges.count == 1 && ranges[0] == (0..<ke))
            } else {
                fullyComplete = false
            }

            var mergedInitBin = JPIPDataBin(
                binClass: dataBin.binClass.canonicalClass,
                binID: dataBin.binID,
                data: assembled,
                isComplete: fullyComplete,
                qualityLayer: dataBin.qualityLayer,
                tileIndex: dataBin.tileIndex,
                codestreamID: dataBin.codestreamID,
                msgOffset: 0,
                aux: dataBin.aux
            )
            mergedInitBin.componentIndex = dataBin.componentIndex
            mergedInitBin.resolutionLevel = dataBin.resolutionLevel
            mergedInitBin.precinctInResolution = dataBin.precinctInResolution
            mergedInitBin.sequenceInTileComponent = dataBin.sequenceInTileComponent
            self.dataBin = mergedInitBin
            self.coveredRanges = ranges
            self.knownCompleteLength = knownEnd
            self.timestamp = timestamp
            self.accessCount = accessCount
            self.size = assembled.count
        }
    }

    /// Cache statistics.
    public struct Statistics: Sendable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var totalSize: Int = 0
        public var entryCount: Int = 0
        public var evictions: Int = 0

        public var hitRate: Double {
            let total = hits + misses
            return total > 0 ? Double(hits) / Double(total) : 0.0
        }
    }

    private var cachedBins: [String: CacheEntry]
    public private(set) var statistics: Statistics
    private var accessOrder: UInt64 = 0
    private let maxCacheSize: Int
    private let maxEntries: Int

    public init(maxCacheSize: Int = 100 * 1024 * 1024, maxEntries: Int = 10_000) {
        self.cachedBins = [:]
        self.statistics = Statistics()
        self.maxCacheSize = maxCacheSize
        self.maxEntries = maxEntries
    }

    private func cacheKey(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> String {
        "\(binClass.canonicalClass.rawValue):\(codestreamID):\(binID)"
    }

    /// Pre-computes the exact post-merge buffer sizes (`max(existingSize, msgOffset + data.count)`)
    /// and entry count for `incomingBins` using checked arithmetic without allocating any `Data`.
    package func projectedAllocation(
        adding incomingBins: [JPIPDataBin], maximumProjectionBytes: Int = Int.max
    ) throws -> (totalPayloadBytes: Int, peakPayloadBytes: Int, entryCount: Int, additionalEntries: Int) {
        let count = try JPIPAdmission.add(cachedBins.count, incomingBins.count)
        let projectionBytes = try projectionStorageBytes(addingCount: incomingBins.count)
        guard projectionBytes <= maximumProjectionBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP cache projection descriptors exceed remaining storage before allocation.")
        }
        var sizes: [String: (size: Int, isComplete: Bool)] = [:]
        sizes.reserveCapacity(count)
        var totalBytes = 0
        for (k, entry) in cachedBins {
            sizes[k] = (entry.size, entry.dataBin.isComplete)
            let (next, overflow) = totalBytes.addingReportingOverflow(entry.size)
            guard !overflow else { throw CodecError(.resourceLimitExceeded, "JPIP projected cache span overflows Int.") }
            totalBytes = next
        }
        var peakBytes = totalBytes
        let initialCount = sizes.count

        for bin in incomingBins {
            guard bin.msgOffset >= 0 else {
                throw CodecError(.malformedInput, "Negative JPIP Msg-Offset (\(bin.msgOffset)).")
            }
            let (segEnd, ov) = bin.msgOffset.addingReportingOverflow(bin.data.count)
            guard !ov else {
                throw CodecError(.resourceLimitExceeded, "JPIP Msg-Offset + length overflows Int.")
            }
            let key = cacheKey(binClass: bin.binClass, binID: bin.binID, codestreamID: bin.codestreamID)
            let previousSize = sizes[key]?.size ?? 0
            if let existing = sizes[key] {
                if bin.msgOffset == 0 && bin.isComplete && existing.isComplete {
                    sizes[key] = (segEnd, true)
                } else {
                    sizes[key] = (max(existing.size, segEnd), existing.isComplete || (bin.msgOffset == 0 && bin.isComplete))
                }
            } else {
                sizes[key] = (segEnd, bin.msgOffset == 0 && bin.isComplete)
            }
            let (sum, sumOverflow) = (totalBytes - previousSize).addingReportingOverflow(sizes[key]?.size ?? 0)
            guard !sumOverflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP projected cache span overflows Int.")
            }
            totalBytes = sum
            peakBytes = max(peakBytes, totalBytes)
        }
        return (totalBytes, peakBytes, sizes.count, max(0, sizes.count - initialCount))
    }

    package func projectionStorageBytes(addingCount: Int) throws -> Int {
        try JPIPAdmission.multiply(JPIPAdmission.add(cachedBins.count, addingCount),
            2 * (MemoryLayout<(String, (Int, Bool))>.stride + 3 * String(Int.min).utf8.count + 2))
    }

    package func retainedStorageBytes() throws -> Int {
        try cachedBins.reduce(0) { total, item in
            let ranges = try JPIPAdmission.multiply(item.value.coveredRanges.count, 2 * MemoryLayout<Range<Int>>.stride)
            let entry = try JPIPAdmission.add(item.value.size,
                JPIPAdmission.add(ranges, 2 * MemoryLayout<(String, CacheEntry)>.stride + item.key.utf8.count))
            return try JPIPAdmission.add(total, entry)
        }
    }

    private static func mergeRange(_ newRange: Range<Int>, into existing: [Range<Int>]) -> [Range<Int>] {
        guard !newRange.isEmpty else { return existing }
        var all = existing
        all.append(newRange)
        all.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        merged.reserveCapacity(all.count)
        for r in all {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Adds or merges a `Msg-Offset` data-bin segment into the cache.
    public mutating func addDataBin(_ dataBin: JPIPDataBin) {
        let canonical = dataBin.binClass.canonicalClass
        let key = cacheKey(binClass: canonical, binID: dataBin.binID, codestreamID: dataBin.codestreamID)
        let segStart = max(0, dataBin.msgOffset)
        let (segEnd, ov) = segStart.addingReportingOverflow(dataBin.data.count)
        guard !ov else { return }

        guard maxEntries > 0, segEnd <= maxCacheSize else {
            if let existing = cachedBins.removeValue(forKey: key) {
                statistics.totalSize -= existing.size
                statistics.entryCount -= 1
                statistics.evictions += 1
            }
            return
        }

        if var existing = cachedBins.removeValue(forKey: key) {
            statistics.totalSize -= existing.size
            statistics.entryCount -= 1

            let requiredBufferLen = max(existing.dataBin.data.count, segEnd)
            guard requiredBufferLen <= maxCacheSize else {
                statistics.evictions += 1
                return
            }

            while (statistics.totalSize + requiredBufferLen > maxCacheSize ||
                   statistics.entryCount >= maxEntries) && !cachedBins.isEmpty {
                evictLRU()
            }

            if segStart == 0 && dataBin.isComplete && existing.dataBin.isComplete {
                // Full replacement of an already-complete entry
                var fresh = CacheEntry(
                    dataBin: dataBin,
                    timestamp: Date(),
                    accessCount: existing.accessCount
                )
                fresh.accessOrder = nextAccessOrder()
                cachedBins[key] = fresh
                statistics.totalSize += fresh.size
                statistics.entryCount += 1
                return
            }

            var buf = existing.dataBin.data
            if buf.count < requiredBufferLen {
                buf.append(Data(count: requiredBufferLen - buf.count))
            }
            if !dataBin.data.isEmpty {
                buf.replaceSubrange(segStart..<segEnd, with: dataBin.data)
            }

            let mergedRanges = Self.mergeRange(segStart..<segEnd, into: existing.coveredRanges)
            let knownEnd: Int? = dataBin.isComplete ? segEnd : existing.knownCompleteLength
            if let ke = knownEnd, buf.count > ke {
                // Own exactly the admitted completed span; a prefix view could
                // retain the earlier larger sparse buffer after size accounting shrinks.
                buf = buf.withUnsafeBytes { bytes in
                    guard ke > 0, let base = bytes.baseAddress else { return Data() }
                    return Data(bytes: base, count: ke)
                }
            }
            let fullyComplete: Bool
            if let ke = knownEnd {
                fullyComplete = (ke == 0) || (mergedRanges.count == 1 && mergedRanges[0].lowerBound == 0 && mergedRanges[0].upperBound >= ke)
            } else {
                fullyComplete = false
            }

            var mergedBin = JPIPDataBin(
                binClass: canonical,
                binID: dataBin.binID,
                data: buf,
                isComplete: fullyComplete,
                qualityLayer: max(existing.dataBin.qualityLayer, dataBin.qualityLayer),
                tileIndex: dataBin.tileIndex != 0 ? dataBin.tileIndex : existing.dataBin.tileIndex,
                codestreamID: dataBin.codestreamID,
                msgOffset: 0,
                aux: dataBin.aux ?? existing.dataBin.aux
            )
            mergedBin.componentIndex = dataBin.componentIndex ?? existing.dataBin.componentIndex
            mergedBin.resolutionLevel = dataBin.resolutionLevel ?? existing.dataBin.resolutionLevel
            mergedBin.precinctInResolution = dataBin.precinctInResolution ?? existing.dataBin.precinctInResolution
            mergedBin.sequenceInTileComponent = dataBin.sequenceInTileComponent ?? existing.dataBin.sequenceInTileComponent
            existing.dataBin = mergedBin
            existing.coveredRanges = mergedRanges
            existing.knownCompleteLength = knownEnd
            existing.size = buf.count
            existing.timestamp = Date()
            existing.accessOrder = nextAccessOrder()

            cachedBins[key] = existing
            statistics.totalSize += existing.size
            statistics.entryCount += 1
            return
        }

        // New entry
        while (statistics.totalSize + segEnd > maxCacheSize ||
               statistics.entryCount >= maxEntries) && !cachedBins.isEmpty {
            evictLRU()
        }

        var entry = CacheEntry(dataBin: dataBin, timestamp: Date(), accessCount: 0)
        entry.accessOrder = nextAccessOrder()
        cachedBins[key] = entry
        statistics.totalSize += entry.size
        statistics.entryCount += 1
    }

    /// Retrieves a data bin from the cache, returning its contiguous prefix starting at byte `0`
    /// (or the full assembled buffer when complete).
    public mutating func getDataBin(
        binClass: JPIPDataBinClass,
        binID: Int,
        codestreamID: Int = 0
    ) -> JPIPDataBin? {
        let key = cacheKey(binClass: binClass, binID: binID, codestreamID: codestreamID)

        if var entry = cachedBins[key] {
            statistics.hits += 1
            entry.accessCount += 1
            entry.timestamp = Date()
            entry.accessOrder = nextAccessOrder()
            cachedBins[key] = entry
            if entry.dataBin.isComplete {
                return entry.dataBin
            }
            let prefixLen = entry.contiguousPrefix
            var partial = entry.dataBin
            if prefixLen < partial.data.count {
                partial.data = Data(partial.data.prefix(prefixLen))
            }
            return partial
        } else {
            statistics.misses += 1
            return nil
        }
    }

    public func hasDataBin(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Bool {
        cachedBins[cacheKey(binClass: binClass, binID: binID, codestreamID: codestreamID)] != nil
    }

    public func hasCompleteDataBin(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Bool {
        cachedBins[cacheKey(binClass: binClass, binID: binID, codestreamID: codestreamID)]?.dataBin.isComplete == true
    }

    public func contiguousPrefixLength(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Int {
        guard let entry = cachedBins[cacheKey(binClass: binClass, binID: binID, codestreamID: codestreamID)] else {
            return 0
        }
        return entry.dataBin.isComplete ? entry.dataBin.data.count : entry.contiguousPrefix
    }

    /// Alias for ``contiguousPrefixLength(binClass:binID:codestreamID:)``.
    public func deliveredPrefixLength(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Int {
        contiguousPrefixLength(binClass: binClass, binID: binID, codestreamID: codestreamID)
    }

    /// Truncates a cached data-bin entry to at most `retainBytes` leading bytes, or removes it when `retainBytes <= 0`.
    package mutating func truncateOrRemove(
        binClass: JPIPDataBinClass,
        binID: Int,
        codestreamID: Int = 0,
        retainBytes: Int
    ) {
        let key = cacheKey(binClass: binClass, binID: binID, codestreamID: codestreamID)
        guard var entry = cachedBins.removeValue(forKey: key) else { return }
        statistics.totalSize -= entry.size
        statistics.entryCount -= 1

        guard retainBytes > 0 else { return }
        let kept = min(entry.dataBin.data.count, retainBytes)
        let clippedData = Data(entry.dataBin.data.prefix(kept))
        let clippedRanges = entry.coveredRanges.compactMap { r -> Range<Int>? in
            guard r.lowerBound < retainBytes else { return nil }
            let hi = min(r.upperBound, retainBytes)
            return r.lowerBound < hi ? (r.lowerBound..<hi) : nil
        }
        guard !clippedData.isEmpty || !clippedRanges.isEmpty else { return }

        var truncatedBin = JPIPDataBin(
            binClass: entry.dataBin.binClass.canonicalClass,
            binID: entry.dataBin.binID,
            data: clippedData,
            isComplete: false,
            qualityLayer: entry.dataBin.qualityLayer,
            tileIndex: entry.dataBin.tileIndex,
            codestreamID: entry.dataBin.codestreamID,
            msgOffset: 0,
            aux: entry.dataBin.aux
        )
        truncatedBin.componentIndex = entry.dataBin.componentIndex
        truncatedBin.resolutionLevel = entry.dataBin.resolutionLevel
        truncatedBin.precinctInResolution = entry.dataBin.precinctInResolution
        truncatedBin.sequenceInTileComponent = entry.dataBin.sequenceInTileComponent
        entry.dataBin = truncatedBin
        entry.coveredRanges = clippedRanges
        entry.knownCompleteLength = nil
        entry.size = clippedData.count
        cachedBins[key] = entry
        statistics.totalSize += entry.size
        statistics.entryCount += 1
    }

    /// Returns all cached data bins (using contiguous prefixes from byte `0` for incomplete bins),
    /// ordered deterministically by `(codestreamID, wireClassID, binID)`.
    public func allDataBins() -> [JPIPDataBin] {
        let sorted = cachedBins.values.sorted { a, b in
            if a.dataBin.codestreamID != b.dataBin.codestreamID {
                return a.dataBin.codestreamID < b.dataBin.codestreamID
            }
            if a.dataBin.binClass.canonicalClass.wireClassID != b.dataBin.binClass.canonicalClass.wireClassID {
                return a.dataBin.binClass.canonicalClass.wireClassID < b.dataBin.binClass.canonicalClass.wireClassID
            }
            return a.dataBin.binID < b.dataBin.binID
        }
        return sorted.map { entry in
            if entry.dataBin.isComplete {
                return entry.dataBin
            }
            let p = entry.contiguousPrefix
            var copy = entry.dataBin
            if p < copy.data.count {
                copy.data = Data(copy.data.prefix(p))
            }
            return copy
        }
    }

    // MARK: - Normative ITU-T Rec. T.808 Clauses C.8.1 / C.8.1.1 / C.8.1.2 / C.8.1.3 `model=` Grammar

    private struct CodestreamTarget: Equatable {
        let exactID: Int?
        let lowerBound: Int?
        let upperBound: Int?
    }

    /// Model items use commas; the codestream range list inside brackets uses semicolons
    /// (T.808 clause 5.1 and C.8.1.1). Invalid embedded commas are rejected by the parser.
    package static func splitTopLevelModelTokens(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    /// Formats all cached entries into normative ITU-T Rec. T.808 Clauses C.8.1.1 / C.8.1.2 cache-model
    /// descriptors (`Hm`, `Hm:<bytes>`, `M<id>`, `H<id>`, `P<id>:<bytes>`, `T<id>`, preceded by a sticky
    /// bracketed `[<csn>]` codestream qualifier whenever `codestreamID` differs from the active context).
    public func formatCacheModelDescriptors() -> [String] {
        let sorted = cachedBins.values.sorted { a, b in
            if a.dataBin.codestreamID != b.dataBin.codestreamID {
                return a.dataBin.codestreamID < b.dataBin.codestreamID
            }
            if a.dataBin.binClass.canonicalClass.wireClassID != b.dataBin.binClass.canonicalClass.wireClassID {
                return a.dataBin.binClass.canonicalClass.wireClassID < b.dataBin.binClass.canonicalClass.wireClassID
            }
            return a.dataBin.binID < b.dataBin.binID
        }
        var items: [String] = []
        items.reserveCapacity(sorted.count + 2)
        var currentContextCodestream = 0
        for entry in sorted {
            let bin = entry.dataBin
            let formattedDescriptor: String?
            let base: String
            switch bin.binClass.canonicalClass {
            case .mainHeader:
                guard bin.binID == 0 else { continue }
                base = "Hm"
            case .tileHeader:
                base = "H\(bin.binID)"
            case .precinct, .extendedPrecinct:
                base = "P\(bin.binID)"
            case .tile, .extendedTile:
                base = "T\(bin.binID)"
            case .metadata:
                base = "M\(bin.binID)"
            }
            if bin.isComplete {
                formattedDescriptor = base
            } else {
                let prefix = entry.contiguousPrefix
                formattedDescriptor = prefix > 0 ? "\(base):\(prefix)" : nil
            }
            if let desc = formattedDescriptor {
                if bin.codestreamID != currentContextCodestream {
                    items.append("[\(bin.codestreamID)]")
                    currentContextCodestream = bin.codestreamID
                }
                items.append(desc)
            }
        }
        return items
    }

    /// Alias for ``formatCacheModelDescriptors()`` returning Clause C.8.1.1 / C.8.1.2 `model=` items.
    public func formatCacheModelField() -> [String] {
        formatCacheModelDescriptors()
    }

    /// Alias for ``parseModelItems(_:)`` parsing Clause C.8.1 `model=` items.
    public static func parseCacheModelField(_ items: [String]) -> [JPIPCacheModelDirective] {
        parseModelItems(items)
    }

    private static func parseDecimalUInt(_ text: Substring, context: String) throws -> Int {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }), let val = Int(text), val >= 0 else {
            throw J2KError.invalidParameter("Malformed unsigned integer '\(text)' in \(context).")
        }
        return val
    }

    /// Represents ranges without enumerating attacker-controlled codestream counts.
    private static func parseBracketedCodestreamQualifier(
        _ token: String, sessionBased: Bool
    ) throws -> [CodestreamTarget] {
        guard token.hasPrefix("["), token.hasSuffix("]"), token.count >= 3 else {
            throw J2KError.invalidParameter("Malformed codestream qualifier in JPIP model= field.")
        }
        let parts = token.dropFirst().dropLast().split(separator: ";", omittingEmptySubsequences: false)
        var targets: [CodestreamTarget] = []
        for part in parts {
            if let dash = part.firstIndex(of: "-") {
                let lo = try parseDecimalUInt(part[..<dash], context: "codestream range")
                let end = part[part.index(after: dash)...]
                let hi = end.isEmpty ? nil : try parseDecimalUInt(end, context: "codestream range")
                guard hi.map({ $0 >= lo }) ?? true else {
                    throw J2KError.invalidParameter("Inverted codestream range in JPIP model= field.")
                }
                if hi == lo {
                    targets.append(CodestreamTarget(exactID: lo, lowerBound: nil, upperBound: nil))
                } else {
                    targets.append(CodestreamTarget(exactID: nil, lowerBound: lo, upperBound: hi))
                }
            } else {
                let id = try parseDecimalUInt(part, context: "codestream qualifier")
                targets.append(CodestreamTarget(exactID: id, lowerBound: nil, upperBound: nil))
            }
        }
        if sessionBased, targets.count != 1 || targets.first?.exactID == nil {
            throw J2KError.invalidParameter("A session-based cache qualifier must identify one codestream.")
        }
        return targets
    }

    private static func parseImplicitRangeSpec(
        _ spec: Substring, sessionBased: Bool
    ) throws -> JPIPCacheModelDirective.ImplicitRange? {
        if spec == "*" {
            guard !sessionBased else {
                throw J2KError.invalidParameter("Wildcard cache selectors require a stateless request.")
            }
            return nil
        }
        if let dash = spec.firstIndex(of: "-") {
            guard !sessionBased else {
                throw J2KError.invalidParameter("Range cache selectors require a stateless request.")
            }
            let lo = try parseDecimalUInt(spec[..<dash], context: "implicit cache range")
            let hi = try parseDecimalUInt(spec[spec.index(after: dash)...], context: "implicit cache range")
            guard lo <= hi else {
                throw J2KError.invalidParameter("Inverted implicit cache range.")
            }
            return .init(lowerBound: lo, upperBound: hi)
        }
        let value = try parseDecimalUInt(spec, context: "implicit cache selector")
        return .init(lowerBound: value, upperBound: value)
    }

    private static func parseSingleModelToken(
        _ rawToken: String,
        activeCodestreams: inout [CodestreamTarget],
        awaitingDescriptorAfterQualifier: inout Bool,
        sessionBased: Bool
    ) throws -> [JPIPCacheModelDirective] {
        var token = rawToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            throw J2KError.invalidParameter("Empty descriptor in JPIP model= field.")
        }
        if token.hasPrefix("[") {
            guard !awaitingDescriptorAfterQualifier else {
                throw J2KError.invalidParameter("Consecutive codestream qualifiers without a descriptor.")
            }
            activeCodestreams = try parseBracketedCodestreamQualifier(token, sessionBased: sessionBased)
            awaitingDescriptorAfterQualifier = true
            return []
        }
        let additive = !token.hasPrefix("-")
        if !additive { token.removeFirst() }
        guard !token.isEmpty else {
            throw J2KError.invalidParameter("Dangling subtractive cache prefix.")
        }
        awaitingDescriptorAfterQualifier = false
        var bytes: Int?
        var layers: Int?
        if let colon = token.firstIndex(of: ":") {
            let suffix = token[token.index(after: colon)...]
            if suffix.hasPrefix("L") {
                layers = try parseDecimalUInt(suffix.dropFirst(), context: "cache layer count")
            } else {
                bytes = try parseDecimalUInt(suffix, context: "cache byte count")
            }
            token = String(token[..<colon])
        }
        guard let first = token.first else {
            throw J2KError.invalidParameter("Missing cache bin descriptor.")
        }

        var binClass: JPIPDataBinClass
        var binID: Int?
        var implicit = false
        var tile: JPIPCacheModelDirective.ImplicitRange?
        var component: JPIPCacheModelDirective.ImplicitRange?
        var resolution: JPIPCacheModelDirective.ImplicitRange?
        var position: JPIPCacheModelDirective.ImplicitRange?
        if ["t", "c", "r", "p"].contains(first) {
            guard bytes == nil else {
                throw J2KError.invalidParameter("Implicit precinct descriptors allow layers, not byte counts.")
            }
            implicit = true
            binClass = .precinct
            var seen = Set<Character>()
            var index = token.startIndex
            while index < token.endIndex {
                let tag = token[index]
                guard ["t", "c", "r", "p"].contains(tag), seen.insert(tag).inserted else {
                    throw J2KError.invalidParameter("Unknown or repeated implicit cache selector.")
                }
                let start = token.index(after: index)
                var end = start
                while end < token.endIndex, !["t", "c", "r", "p"].contains(token[end]) {
                    end = token.index(after: end)
                }
                let range = try parseImplicitRangeSpec(token[start..<end], sessionBased: sessionBased)
                switch tag {
                case "t": tile = range
                case "c": component = range
                case "r": resolution = range
                case "p": position = range
                default: break
                }
                index = end
            }
        } else if token == "Hm" {
            binClass = .mainHeader
            binID = 0
        } else {
            switch first {
            case "H": binClass = .tileHeader
            case "P": binClass = .precinct
            case "T": binClass = .tile
            case "M": binClass = .metadata
            default: throw J2KError.invalidParameter("Unknown explicit cache descriptor.")
            }
            let rest = token.dropFirst()
            if rest == "*" {
                guard !sessionBased else {
                    throw J2KError.invalidParameter("Wildcard cache descriptors require a stateless request.")
                }
            } else {
                binID = try parseDecimalUInt(rest, context: "explicit cache bin identifier")
            }
        }
        guard layers == nil || binClass == .precinct else {
            throw J2KError.invalidParameter("Layer counts apply only to precinct cache descriptors.")
        }
        return activeCodestreams.map { cs in
            JPIPCacheModelDirective(
                isAdditive: additive, binClass: binClass, binID: binID,
                byteLength: bytes, codestreamID: cs.exactID,
                codestreamLowerBound: cs.lowerBound, codestreamUpperBound: cs.upperBound,
                layerCount: layers, isImplicitPrecinct: implicit,
                tileFilter: tile, componentFilter: component,
                resolutionFilter: resolution, precinctFilter: position
            )
        }
    }

    /// Validates T.808 C.8.1 grammar and session-based selector restrictions.
    public static func parseValidatedModelItems(
        _ items: [String], sessionBased: Bool = false
    ) throws -> [JPIPCacheModelDirective] {
        var directives: [JPIPCacheModelDirective] = []
        var active = [CodestreamTarget(exactID: 0, lowerBound: nil, upperBound: nil)]
        var awaiting = false
        for item in items {
            for token in splitTopLevelModelTokens(item) {
                directives.append(contentsOf: try parseSingleModelToken(
                    token, activeCodestreams: &active,
                    awaitingDescriptorAfterQualifier: &awaiting, sessionBased: sessionBased
                ))
            }
        }
        guard !awaiting else {
            throw J2KError.invalidParameter("Trailing codestream qualifier without a descriptor.")
        }
        return directives
    }

    /// Returns no directives for an invalid field, avoiding partial mutation under a stale qualifier.
    public static func parseModelItems(_ items: [String]) -> [JPIPCacheModelDirective] {
        (try? parseValidatedModelItems(items)) ?? []
    }

    private mutating func nextAccessOrder() -> UInt64 {
        if accessOrder == UInt64.max {
            let keys = cachedBins.sorted { $0.value.accessOrder < $1.value.accessOrder }.map(\.key)
            for (index, key) in keys.enumerated() {
                cachedBins[key]?.accessOrder = UInt64(index)
            }
            accessOrder = UInt64(keys.count)
        }
        accessOrder += 1
        return accessOrder
    }

    private mutating func evictLRU() {
        guard let oldestKey = cachedBins.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key else {
            return
        }
        if let entry = cachedBins.removeValue(forKey: oldestKey) {
            statistics.totalSize -= entry.size
            statistics.entryCount -= 1
            statistics.evictions += 1
        }
    }

    public mutating func invalidate(binClass: JPIPDataBinClass, codestreamID: Int? = nil) {
        let canonicalRaw = binClass.canonicalClass.rawValue
        let prefix = codestreamID.map { "\(canonicalRaw):\($0):" } ?? "\(canonicalRaw):"
        let keysToRemove = cachedBins.keys.filter { key in
            key.hasPrefix(prefix)
        }
        for key in keysToRemove {
            if let entry = cachedBins.removeValue(forKey: key) {
                statistics.totalSize -= entry.size
                statistics.entryCount -= 1
            }
        }
    }

    public mutating func invalidateCodestream(_ codestreamID: Int) {
        let needle = ":\(codestreamID):"
        let keysToRemove = cachedBins.keys.filter { $0.contains(needle) }
        for key in keysToRemove {
            if let entry = cachedBins.removeValue(forKey: key) {
                statistics.totalSize -= entry.size
                statistics.entryCount -= 1
            }
        }
    }

    public mutating func invalidate(olderThan date: Date) {
        let keysToRemove = cachedBins.filter { $0.value.timestamp < date }.map { $0.key }
        for key in keysToRemove {
            if let entry = cachedBins.removeValue(forKey: key) {
                statistics.totalSize -= entry.size
                statistics.entryCount -= 1
            }
        }
    }

    public mutating func clear() {
        cachedBins.removeAll()
        statistics = Statistics()
        accessOrder = 0
    }
}
