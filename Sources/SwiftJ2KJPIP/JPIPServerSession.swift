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

    /// Applies ITU-T Rec. T.808 Clause C.8.1 `model=` cache-model directives against the
    /// candidate bins of the target codestream.
    public func applyCacheModel(
        items: [String],
        availableBins: [JPIPDataBin]
    ) {
        let directives = JPIPCacheModel.parseModelItems(items)
        guard !directives.isEmpty else { return }

        func matchesCodestream(_ cs: Int, target: Int?) -> Bool {
            target == nil || target == cs
        }

        for dir in directives {
            if dir.binClass == nil && dir.binID == nil {
                if !dir.isAdditive {
                    if let targetCS = dir.codestreamID {
                        if let retain = dir.byteLength, retain > 0 {
                            for (k, cur) in sentByteOffsets {
                                if let parsed = Self.parseBinKey(k), parsed.codestreamID == targetCS {
                                    sentByteOffsets[k] = min(cur, retain)
                                    completedBinKeys.remove(k)
                                    if let cls = JPIPDataBinClass(rawValue: parsed.rawClass) {
                                        clientCache.truncateOrRemove(
                                            binClass: cls,
                                            binID: parsed.binID,
                                            codestreamID: parsed.codestreamID,
                                            retainBytes: retain
                                        )
                                    }
                                }
                            }
                        } else {
                            let needle = ":\(targetCS):"
                            for k in Array(sentByteOffsets.keys) where k.contains(needle) {
                                sentByteOffsets.removeValue(forKey: k)
                            }
                            for k in Array(completedBinKeys) where k.contains(needle) {
                                completedBinKeys.remove(k)
                            }
                            clientCache.invalidateCodestream(targetCS)
                        }
                    } else if let retain = dir.byteLength, retain > 0 {
                        for (k, cur) in sentByteOffsets {
                            sentByteOffsets[k] = min(cur, retain)
                            if let parsed = Self.parseBinKey(k),
                               let cls = JPIPDataBinClass(rawValue: parsed.rawClass) {
                                clientCache.truncateOrRemove(
                                    binClass: cls,
                                    binID: parsed.binID,
                                    codestreamID: parsed.codestreamID,
                                    retainBytes: retain
                                )
                            }
                        }
                        completedBinKeys.removeAll()
                    } else {
                        sentByteOffsets.removeAll()
                        completedBinKeys.removeAll()
                        clientCache.clear()
                    }
                } else {
                    for bin in availableBins where matchesCodestream(bin.codestreamID, target: dir.codestreamID) {
                        let key = binKey(bin.binClass, bin.binID, codestreamID: bin.codestreamID)
                        let len = dir.byteLength.map { min($0, bin.data.count) } ?? bin.data.count
                        sentByteOffsets[key] = max(sentByteOffsets[key] ?? 0, len)
                        if dir.byteLength == nil || len >= bin.data.count {
                            completedBinKeys.insert(key)
                        }
                    }
                }
                continue
            }

            guard let rawTargetClass = dir.binClass else { continue }
            let targetClass = rawTargetClass.canonicalClass

            if let explicitID = dir.binID {
                var candidateCS = Set<Int>()
                if let cs = dir.codestreamID {
                    candidateCS.insert(cs)
                } else {
                    for bin in availableBins where bin.binClass.canonicalClass == targetClass && bin.binID == explicitID {
                        candidateCS.insert(bin.codestreamID)
                    }
                    for k in sentByteOffsets.keys {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == targetClass.rawValue,
                           parsed.binID == explicitID {
                            candidateCS.insert(parsed.codestreamID)
                        }
                    }
                    for k in completedBinKeys {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == targetClass.rawValue,
                           parsed.binID == explicitID {
                            candidateCS.insert(parsed.codestreamID)
                        }
                    }
                    if candidateCS.isEmpty {
                        candidateCS.insert(0)
                    }
                }

                for cs in candidateCS {
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
            } else {
                // Wildcard within `targetClass` (e.g. `H*`, `P*`, `-P*`, `-P*:20`)
                if dir.isAdditive {
                    for bin in availableBins
                    where bin.binClass.canonicalClass == targetClass
                        && matchesCodestream(bin.codestreamID, target: dir.codestreamID) {
                        let key = binKey(bin.binClass, bin.binID, codestreamID: bin.codestreamID)
                        let len = dir.byteLength.map { min($0, bin.data.count) } ?? bin.data.count
                        sentByteOffsets[key] = max(sentByteOffsets[key] ?? 0, len)
                        if dir.byteLength == nil || len >= bin.data.count {
                            completedBinKeys.insert(key)
                        }
                    }
                } else if let specifiedBytes = dir.byteLength, specifiedBytes > 0 {
                    for (k, cur) in sentByteOffsets {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == targetClass.rawValue,
                           matchesCodestream(parsed.codestreamID, target: dir.codestreamID) {
                            sentByteOffsets[k] = min(cur, specifiedBytes)
                            completedBinKeys.remove(k)
                            clientCache.truncateOrRemove(
                                binClass: targetClass,
                                binID: parsed.binID,
                                codestreamID: parsed.codestreamID,
                                retainBytes: specifiedBytes
                            )
                        }
                    }
                    for k in Array(completedBinKeys) {
                        if let parsed = Self.parseBinKey(k),
                           parsed.rawClass == targetClass.rawValue,
                           matchesCodestream(parsed.codestreamID, target: dir.codestreamID) {
                            completedBinKeys.remove(k)
                        }
                    }
                } else {
                    let prefix = dir.codestreamID.map { "\(targetClass.rawValue):\($0):" } ?? "\(targetClass.rawValue):"
                    for k in Array(sentByteOffsets.keys) where k.hasPrefix(prefix) {
                        sentByteOffsets.removeValue(forKey: k)
                    }
                    for k in Array(completedBinKeys) where k.hasPrefix(prefix) {
                        completedBinKeys.remove(k)
                    }
                    clientCache.invalidate(binClass: targetClass, codestreamID: dir.codestreamID)
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
