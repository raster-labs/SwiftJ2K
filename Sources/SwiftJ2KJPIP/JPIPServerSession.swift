// SPDX-License-Identifier: Apache-2.0
//
// JPIPServerSession.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPServerSession.swift
//
// Extended in Phase R3 (F04) with per-bin byte-offset (`Msg-Offset`) delivery
// tracking and ITU-T Rec. T.808 (12/2022) Clause C.8.1 `model=` reconciliation.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// Represents a server-side session for a JPIP client.
///
/// Each session tracks the exact byte prefix already held by the client for every
/// `(binClass, binID)` data-bin so incremental `cid=` and `model=` requests emit
/// only unsent bytes.
public actor JPIPServerSession {
    /// The unique session identifier.
    nonisolated public let sessionID: String

    /// The channel ID for this session.
    nonisolated public let channelID: String

    /// The target image being accessed.
    nonisolated public let target: String

    /// Stable target identifier (`JPIP-tid`) associated with `target`.
    nonisolated public let targetID: String

    /// Whether the session is active.
    public private(set) var isActive: Bool

    /// Last activity timestamp.
    public private(set) var lastActivity: Date

    /// Client cache model tracking what data has been sent.
    private var clientCache: JPIPCacheModel

    /// Exact contiguous byte offset already known to be in the client's cache per `"<rawClass>:<binID>"`.
    private var sentByteOffsets: [String: Int]

    /// Bins known to be 100% complete in the client's cache (including 0-byte complete bins).
    private var completedBinKeys: Set<String>

    /// Session metadata.
    private var metadata: [String: String]

    /// Total bytes sent in this session.
    public private(set) var totalBytesSent: Int

    /// Total requests handled in this session.
    public private(set) var totalRequests: Int

    /// Creates a new server session.
    public init(sessionID: String, channelID: String, target: String, targetID: String? = nil) {
        self.sessionID = sessionID
        self.channelID = channelID
        self.target = target
        self.targetID = targetID ?? "tid-\(target)"
        self.isActive = true
        self.lastActivity = Date()
        self.clientCache = JPIPCacheModel()
        self.sentByteOffsets = [:]
        self.completedBinKeys = []
        self.metadata = [:]
        self.totalBytesSent = 0
        self.totalRequests = 0
    }

    private func binKey(_ binClass: JPIPDataBinClass, _ binID: Int, codestreamID: Int = 0) -> String {
        "\(binClass.canonicalClass.rawValue):\(codestreamID):\(binID)"
    }

    private static func parseBinKey(_ key: String) -> (rawClass: Int, codestreamID: Int, binID: Int)? {
        let parts = key.split(separator: ":")
        guard parts.count == 3,
              let cls = Int(parts[0]),
              let cs = Int(parts[1]),
              let bid = Int(parts[2]) else {
            return nil
        }
        return (cls, cs, bid)
    }

    /// Updates the last activity timestamp.
    public func updateActivity() {
        self.lastActivity = Date()
    }

    /// Records that a request was handled.
    public func recordRequest(bytesSent: Int) {
        self.totalRequests += 1
        self.totalBytesSent += bytesSent
        updateActivity()
    }

    /// Checks if any bytes (or complete marker) of a data bin have been sent to the client.
    public func hasDataBin(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Bool {
        let key = binKey(binClass, binID, codestreamID: codestreamID)
        return completedBinKeys.contains(key)
            || (sentByteOffsets[key] ?? 0) > 0
            || clientCache.hasDataBin(binClass: binClass, binID: binID, codestreamID: codestreamID)
    }

    /// Checks whether the client already holds the complete data-bin.
    public func hasCompleteDataBin(
        binClass: JPIPDataBinClass,
        binID: Int,
        totalLength: Int,
        codestreamID: Int = 0
    ) -> Bool {
        let key = binKey(binClass, binID, codestreamID: codestreamID)
        if completedBinKeys.contains(key) {
            return true
        }
        return totalLength > 0 && (sentByteOffsets[key] ?? 0) >= totalLength
    }

    /// Returns the number of leading bytes already held by the client for `(binClass, binID, codestreamID)`.
    public func sentByteOffset(binClass: JPIPDataBinClass, binID: Int, codestreamID: Int = 0) -> Int {
        sentByteOffsets[binKey(binClass, binID, codestreamID: codestreamID)] ?? 0
    }

    /// Records that a data bin (full or partial `Msg-Offset` slice) was sent to the client.
    public func recordSentDataBin(_ dataBin: JPIPDataBin) {
        let key = binKey(dataBin.binClass, dataBin.binID, codestreamID: dataBin.codestreamID)
        let (endOffset, ov) = max(0, dataBin.msgOffset).addingReportingOverflow(dataBin.data.count)
        if !ov {
            let prev = sentByteOffsets[key] ?? 0
            if endOffset > prev {
                sentByteOffsets[key] = endOffset
            }
        }
        if dataBin.isComplete {
            completedBinKeys.insert(key)
        }
        clientCache.addDataBin(dataBin)
    }

    /// Extracts `(totalTiles, componentCount)` from a JPEG 2000 Part 1 or Part 10 `SIZ` (+ optional `NSI`) main header.
    private static func extractPrecinctGridCounts(fromMainHeader data: Data) -> (totalTiles: Int, componentCount: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 42, bytes[0] == 0xFF, bytes[1] == 0x4F else { return nil }
        func u16(_ idx: Int) -> Int { (Int(bytes[idx]) << 8) | Int(bytes[idx + 1]) }
        func u32(_ idx: Int) -> Int {
            (Int(bytes[idx]) << 24) | (Int(bytes[idx + 1]) << 16) | (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        }
        func tileAxisCount(size: Int, tileOrigin: Int, tileSize: Int) -> Int {
            guard size > tileOrigin, tileSize > 0 else { return 1 }
            let span = size - tileOrigin
            return max(1, (span + tileSize - 1) / tileSize)
        }

        var pos = 2
        var tilesXY: Int? = nil
        var compCount: Int? = nil
        var tilesZ = 1
        while pos + 4 <= bytes.count {
            guard bytes[pos] == 0xFF else { break }
            let code = (UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1])
            pos += 2
            if code == 0xFF90 || code == 0xFF93 || code == 0xFFD9 { break }
            if (0xFF30...0xFF3F).contains(code) { continue }
            guard pos + 2 <= bytes.count else { break }
            let segLen = u16(pos)
            guard segLen >= 2, pos + segLen <= bytes.count else { break }
            if code == 0xFF51 && segLen >= 38 {
                let xsiz = u32(pos + 4)
                let ysiz = u32(pos + 8)
                let xtsiz = u32(pos + 20)
                let ytsiz = u32(pos + 24)
                let xtosiz = u32(pos + 28)
                let ytosiz = u32(pos + 32)
                let csiz = u16(pos + 36)
                let tx = tileAxisCount(size: xsiz, tileOrigin: xtosiz, tileSize: xtsiz)
                let ty = tileAxisCount(size: ysiz, tileOrigin: ytosiz, tileSize: ytsiz)
                let (tileCount, overflow) = tx.multipliedReportingOverflow(by: ty)
                guard !overflow, csiz > 0 else { return nil }
                tilesXY = tileCount
                compCount = csiz
            } else if code == 0xFF54 && segLen >= 19 {
                let zsiz = u32(pos + 3)
                let ztsiz = u32(pos + 11)
                let ztosiz = u32(pos + 15)
                tilesZ = tileAxisCount(size: zsiz, tileOrigin: ztosiz, tileSize: ztsiz)
            }
            pos += segLen
        }
        guard let txy = tilesXY, let c = compCount else { return nil }
        let (total, tileOverflow) = txy.multipliedReportingOverflow(by: tilesZ)
        let (_, componentOverflow) = total.multipliedReportingOverflow(by: c)
        guard !tileOverflow, !componentOverflow else { return nil }
        return (max(1, total), c)
    }

    /// Applies ITU-T Rec. T.808 Clauses C.8.1.1 / C.8.1.2 / C.8.1.3 `model=` cache-model directives against the
    /// candidate bins of the target codestream(s).
    public func applyCacheModel(
        items: [String],
        availableBins: [JPIPDataBin]
    ) {
        let directives = JPIPCacheModel.parseModelItems(items)
        guard !directives.isEmpty else { return }

        let cachedSnapshot = clientCache.allDataBins()
        var gridCache: [Int: (totalTiles: Int, componentCount: Int)?] = [:]
        func gridCounts(for codestreamID: Int) -> (totalTiles: Int, componentCount: Int)? {
            if let existing = gridCache[codestreamID] {
                return existing
            }
            let mh = availableBins.first { $0.codestreamID == codestreamID && $0.binClass.canonicalClass == .mainHeader && $0.binID == 0 }?.data
                ?? cachedSnapshot.first { $0.codestreamID == codestreamID && $0.binClass.canonicalClass == .mainHeader && $0.binID == 0 }?.data
            let extracted = mh.flatMap { Self.extractPrecinctGridCounts(fromMainHeader: $0) }
            gridCache[codestreamID] = extracted
            return extracted
        }

        func matchesImplicitPrecinct(
            dir: JPIPCacheModelDirective,
            binID: Int,
            codestreamID: Int,
            binMeta: JPIPDataBin?
        ) -> Bool {
            guard dir.matchesCodestream(codestreamID) else { return false }
            // Tile and position ranges denote rectangles, not linear intervals. Until
            // both grid dimensions are available, ignore additive rectangles; a
            // subtractive interval safely removes a superset of the rectangle.
            if dir.isAdditive,
               [dir.tileFilter, dir.precinctFilter].contains(where: {
                   guard let range = $0 else { return false }
                   return range.upperBound != range.lowerBound
               }) { return false }
            let grid = gridCounts(for: codestreamID)
            let tileIdx: Int? = binMeta.flatMap { _ in
                if let g = grid { return binID % g.totalTiles }
                return binMeta?.tileIndex
            } ?? grid.map { binID % $0.totalTiles }
            let compIdx: Int? = binMeta?.componentIndex ?? grid.map { (binID / $0.totalTiles) % $0.componentCount }
            let seqIdx: Int? = binMeta?.sequenceInTileComponent ?? grid.map { binID / ($0.totalTiles * $0.componentCount) }
            let resIdx: Int? = binMeta?.resolutionLevel
            let prcIdx: Int? = binMeta?.precinctInResolution

            if let tf = dir.tileFilter {
                guard let t = tileIdx, tf.contains(t) else { return false }
            }
            if let cf = dir.componentFilter {
                guard let c = compIdx, cf.contains(c) else { return false }
            }
            if let sf = dir.sequenceFilter {
                guard let s = seqIdx, sf.contains(s) else { return false }
            }
            if let rf = dir.resolutionFilter {
                guard let r = resIdx, rf.contains(r) else { return false }
            }
            if let pf = dir.precinctFilter {
                guard let p = prcIdx, pf.contains(p) else { return false }
            }
            return true
        }

        func applySingleBinDirective(
            dir: JPIPCacheModelDirective,
            targetClass: JPIPDataBinClass,
            explicitID: Int,
            cs: Int
        ) {
            // T.808 C.8.1.1 permits ignoring additive cache statements. Without a
            // packet-boundary index, never reinterpret a layer count as a complete bin.
            // Subtractive layer statements conservatively discard the whole precinct;
            // this may retransmit earlier packets, but cannot suppress required bytes.
            if dir.layerCount != nil && dir.isAdditive { return }
            let key = binKey(targetClass, explicitID, codestreamID: cs)
            let matchingLen = availableBins.first {
                $0.binClass.canonicalClass == targetClass
                    && $0.binID == explicitID
                    && $0.codestreamID == cs
            }?.data.count

            if dir.isAdditive {
                if let specifiedBytes = dir.byteLength {
                    let clamped = matchingLen.map { min(specifiedBytes, $0) } ?? specifiedBytes
                    sentByteOffsets[key] = max(sentByteOffsets[key] ?? 0, clamped)
                    if let total = matchingLen, clamped >= total {
                        completedBinKeys.insert(key)
                    }
                } else {
                    if let total = matchingLen {
                        sentByteOffsets[key] = total
                    }
                    completedBinKeys.insert(key)
                }
            } else {
                // ITU-T Rec. T.808 Clause C.8.1.2 & Example 1:
                // `-<bin>:<B>` retains at most the first `B` already-held bytes without adding unheld bytes.
                if let specifiedBytes = dir.byteLength, specifiedBytes > 0 {
                    if let cur = sentByteOffsets[key] {
                        let retained = min(cur, specifiedBytes)
                        if retained > 0 {
                            sentByteOffsets[key] = retained
                        } else {
                            sentByteOffsets.removeValue(forKey: key)
                        }
                    }
                } else {
                    sentByteOffsets.removeValue(forKey: key)
                }
                completedBinKeys.remove(key)
                clientCache.truncateOrRemove(
                    binClass: targetClass,
                    binID: explicitID,
                    codestreamID: cs,
                    retainBytes: dir.byteLength ?? 0
                )
            }
        }

        for dir in directives {
            guard let rawTargetClass = dir.binClass else { continue }
            let targetClass = rawTargetClass.canonicalClass

            if dir.isImplicitPrecinct {
                // Clause C.8.1.3 implicit precinct selector (`t`/`c`/`s`/`r`/`p`): applies only to precinct bins
                // matching the implicit component/tile/sequence/resolution filters within the active codestream(s).
                var matchedPairs: [(cs: Int, binID: Int)] = []
                var seenPairs = Set<String>()
                for bin in availableBins where bin.binClass.canonicalClass == .precinct {
                    if matchesImplicitPrecinct(dir: dir, binID: bin.binID, codestreamID: bin.codestreamID, binMeta: bin) {
                        let tag = "\(bin.codestreamID):\(bin.binID)"
                        if seenPairs.insert(tag).inserted {
                            matchedPairs.append((bin.codestreamID, bin.binID))
                        }
                    }
                }
                if !dir.isAdditive {
                    let cachedNow = clientCache.allDataBins()
                    for k in Array(sentByteOffsets.keys) {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == JPIPDataBinClass.precinct.rawValue {
                            let meta = availableBins.first {
                                $0.binClass.canonicalClass == .precinct
                                    && $0.codestreamID == parsed.codestreamID
                                    && $0.binID == parsed.binID
                            } ?? cachedNow.first {
                                $0.binClass.canonicalClass == .precinct
                                    && $0.codestreamID == parsed.codestreamID
                                    && $0.binID == parsed.binID
                            }
                            if matchesImplicitPrecinct(dir: dir, binID: parsed.binID, codestreamID: parsed.codestreamID, binMeta: meta) {
                                let tag = "\(parsed.codestreamID):\(parsed.binID)"
                                if seenPairs.insert(tag).inserted {
                                    matchedPairs.append((parsed.codestreamID, parsed.binID))
                                }
                            }
                        }
                    }
                }
                for pair in matchedPairs {
                    applySingleBinDirective(dir: dir, targetClass: .precinct, explicitID: pair.binID, cs: pair.cs)
                }
                continue
            }

            if let explicitID = dir.binID {
                var candidateCS = Set<Int>()
                if let cs = dir.codestreamID {
                    candidateCS.insert(cs)
                } else {
                    for bin in availableBins
                    where bin.binClass.canonicalClass == targetClass
                        && bin.binID == explicitID
                        && dir.matchesCodestream(bin.codestreamID) {
                        candidateCS.insert(bin.codestreamID)
                    }
                    for k in sentByteOffsets.keys {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == targetClass.rawValue,
                           parsed.binID == explicitID,
                           dir.matchesCodestream(parsed.codestreamID) {
                            candidateCS.insert(parsed.codestreamID)
                        }
                    }
                    for k in completedBinKeys {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == targetClass.rawValue,
                           parsed.binID == explicitID,
                           dir.matchesCodestream(parsed.codestreamID) {
                            candidateCS.insert(parsed.codestreamID)
                        }
                    }
                    if candidateCS.isEmpty, dir.matchesCodestream(0) {
                        candidateCS.insert(0)
                    }
                }

                for cs in candidateCS {
                    applySingleBinDirective(dir: dir, targetClass: targetClass, explicitID: explicitID, cs: cs)
                }
            } else {
                // Apply the same byte/layer semantics to explicit wildcards. Include
                // previously modelled bins for subtraction even when outside this window.
                var pairs = Set<String>()
                for bin in availableBins where bin.binClass.canonicalClass == targetClass
                    && dir.matchesCodestream(bin.codestreamID) {
                    pairs.insert(binKey(targetClass, bin.binID, codestreamID: bin.codestreamID))
                }
                if !dir.isAdditive {
                    for key in Set(sentByteOffsets.keys).union(completedBinKeys) {
                        if let parsed = Self.parseBinKey(key), parsed.rawClass == targetClass.rawValue,
                           dir.matchesCodestream(parsed.codestreamID) {
                            pairs.insert(key)
                        }
                    }
                }
                for key in pairs {
                    if let parsed = Self.parseBinKey(key) {
                        applySingleBinDirective(dir: dir, targetClass: targetClass,
                                                explicitID: parsed.binID, cs: parsed.codestreamID)
                    }
                }
            }
        }
    }

    /// Gets the client cache statistics.
    public func getCacheStatistics() -> JPIPCacheModel.Statistics {
        clientCache.statistics
    }

    /// Sets metadata for the session.
    public func setMetadata(_ key: String, value: String) {
        metadata[key] = value
    }

    /// Gets metadata from the session.
    public func getMetadata(_ key: String) -> String? {
        metadata[key]
    }

    /// Checks if the session has timed out.
    public func hasTimedOut(timeout: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastActivity) > timeout
    }

    /// Closes the session and cleans up resources.
    public func close() {
        self.isActive = false
        self.clientCache.clear()
        self.sentByteOffsets.removeAll()
        self.completedBinKeys.removeAll()
        self.metadata.removeAll()
    }

    /// Gets session information for debugging.
    public func getInfo() -> SessionInfo {
        SessionInfo(
            sessionID: sessionID,
            channelID: channelID,
            target: target,
            isActive: isActive,
            lastActivity: lastActivity,
            totalBytesSent: totalBytesSent,
            totalRequests: totalRequests,
            cacheSize: clientCache.statistics.totalSize,
            cacheEntries: clientCache.statistics.entryCount
        )
    }

    /// Session information struct.
    public struct SessionInfo: Sendable {
        public let sessionID: String
        public let channelID: String
        public let target: String
        public let isActive: Bool
        public let lastActivity: Date
        public let totalBytesSent: Int
        public let totalRequests: Int
        public let cacheSize: Int
        public let cacheEntries: Int
    }
}
