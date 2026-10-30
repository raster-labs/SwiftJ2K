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

    private func binKey(_ binClass: JPIPDataBinClass, _ binID: Int) -> String {
        "\(binClass.rawValue):\(binID)"
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
    public func hasDataBin(binClass: JPIPDataBinClass, binID: Int) -> Bool {
        let key = binKey(binClass, binID)
        return completedBinKeys.contains(key)
            || (sentByteOffsets[key] ?? 0) > 0
            || clientCache.hasDataBin(binClass: binClass, binID: binID)
    }

    /// Checks whether the client already holds the complete data-bin.
    public func hasCompleteDataBin(binClass: JPIPDataBinClass, binID: Int, totalLength: Int) -> Bool {
        let key = binKey(binClass, binID)
        if completedBinKeys.contains(key) {
            return true
        }
        return totalLength > 0 && (sentByteOffsets[key] ?? 0) >= totalLength
    }

    /// Returns the number of leading bytes already held by the client for `(binClass, binID)`.
    public func sentByteOffset(binClass: JPIPDataBinClass, binID: Int) -> Int {
        sentByteOffsets[binKey(binClass, binID)] ?? 0
    }

    /// Records that a data bin (full or partial `Msg-Offset` slice) was sent to the client.
    public func recordSentDataBin(_ dataBin: JPIPDataBin) {
        let key = binKey(dataBin.binClass, dataBin.binID)
        let endOffset = max(0, dataBin.msgOffset) + dataBin.data.count
        let prev = sentByteOffsets[key] ?? 0
        if endOffset > prev {
            sentByteOffsets[key] = endOffset
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

        for dir in directives {
            if dir.binClass == nil && dir.binID == nil {
                if !dir.isAdditive {
                    sentByteOffsets.removeAll()
                    completedBinKeys.removeAll()
                    clientCache.clear()
                } else {
                    for bin in availableBins {
                        let key = binKey(bin.binClass, bin.binID)
                        let len = dir.byteLength.map { min($0, bin.data.count) } ?? bin.data.count
                        sentByteOffsets[key] = len
                        if dir.byteLength == nil || len >= bin.data.count {
                            completedBinKeys.insert(key)
                        }
                    }
                }
                continue
            }

            guard let targetClass = dir.binClass else { continue }
            if let explicitID = dir.binID {
                let key = binKey(targetClass, explicitID)
                let matchingLen = availableBins.first {
                    $0.binClass == targetClass && $0.binID == explicitID
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
                    if let specifiedBytes = dir.byteLength, specifiedBytes > 0 {
                        let cur = sentByteOffsets[key] ?? (matchingLen ?? 0)
                        sentByteOffsets[key] = max(0, cur - specifiedBytes)
                    } else {
                        sentByteOffsets.removeValue(forKey: key)
                    }
                    completedBinKeys.remove(key)
                }
            } else {
                // Wildcard within `targetClass` (e.g. `H*`, `P*`, `-P*`)
                if dir.isAdditive {
                    for bin in availableBins where bin.binClass == targetClass {
                        let key = binKey(bin.binClass, bin.binID)
                        let len = dir.byteLength.map { min($0, bin.data.count) } ?? bin.data.count
                        sentByteOffsets[key] = max(sentByteOffsets[key] ?? 0, len)
                        if dir.byteLength == nil || len >= bin.data.count {
                            completedBinKeys.insert(key)
                        }
                    }
                } else {
                    let prefix = "\(targetClass.rawValue):"
                    for k in sentByteOffsets.keys where k.hasPrefix(prefix) {
                        sentByteOffsets.removeValue(forKey: k)
                    }
                    for k in completedBinKeys where k.hasPrefix(prefix) {
                        completedBinKeys.remove(k)
                    }
                    clientCache.invalidate(binClass: targetClass)
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
