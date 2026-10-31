// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
@_exported import SwiftJ2K

/// Operation-local high-water ledger. Observers may run on a reconstruction worker.
package final class JPIPWorkspaceHighWater: Sendable {
    private let value = Mutex<Int>(0)
    package init() {}
    package func observe(_ bytes: Int) { value.withLock { $0 = max($0, bytes) } }
    package var peak: Int { value.withLock { $0 } }
}

package final class JPIPTransferBudget: Sendable {
    package let limits: ResourceLimits
    package let workspace = JPIPWorkspaceHighWater()
    private let wireCount = Mutex<Int>(0)
    package init(_ limits: ResourceLimits) { self.limits = limits }
    package var cumulativeWireBytes: Int { wireCount.withLock { $0 } }
    package func bodyLimit(retaining bytes: Int) throws -> Int {
        try JPIPAdmission.responseBodyLimit(limits: limits, retaining: bytes, cumulativeWireBytes: cumulativeWireBytes)
    }
    package func received(_ count: Int, pushedPayloadBytes: Int = 0, retaining bytes: Int) throws {
        try wireCount.withLock { total in
            let next = try JPIPAdmission.add(total, JPIPAdmission.add(count, pushedPayloadBytes))
            guard next <= limits.maximumCompressedBytes else {
                throw CodecError(.resourceLimitExceeded, "JPIP cumulative wire limit exceeded.")
            }
            // Queued pushes are already included in retained storage. Charge
            // their payload to cumulative transfer exactly once, independently
            // of response scratch and later queue draining/cache replacement.
            try JPIPAdmission.admit(JPIPAdmission.add(bytes, JPIPAdmission.multiply(count, 2)), limits: limits, peak: workspace)
            total = next
        }
    }
}

package enum JPIPAdmission {
    package static func add(_ a: Int, _ b: Int) throws -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else {
            throw CodecError(.resourceLimitExceeded, "JPIP live-storage arithmetic overflow.")
        }
        return sum
    }
    package static func multiply(_ count: Int, _ stride: Int) throws -> Int {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
        guard count >= 0, stride >= 0, !overflow else {
            throw CodecError(.resourceLimitExceeded, "JPIP descriptor-storage arithmetic overflow.")
        }
        return bytes
    }
    package static func bins(_ bins: [JPIPDataBin]) throws -> Int {
        try bins.reduce(multiply(bins.count, MemoryLayout<JPIPDataBin>.stride)) { try add($0, $1.data.count) }
    }
    package static func response(_ response: JPIPResponse) throws -> Int {
        try add(response.data.count, response.retainedHeaderStorageBytes)
    }
    package static func string(_ value: String?) throws -> Int {
        guard let value else { return 0 }
        return try add(value.utf8.count, MemoryLayout<String>.stride)
    }
    package static func cache(_ statistics: JPIPCacheModel.Statistics) throws -> Int {
        try add(statistics.totalSize, multiply(statistics.entryCount,
            MemoryLayout<JPIPCacheModel.CacheEntry>.stride + MemoryLayout<String>.stride + MemoryLayout<Range<Int>>.stride))
    }
    package static func remaining(_ limits: ResourceLimits, retaining bytes: Int) throws -> Int {
        let cap = min(limits.maximumMemoryBytes, limits.maximumWorkspaceBytes)
        guard bytes >= 0, bytes < cap else {
            throw CodecError(.resourceLimitExceeded, "JPIP retained storage exhausts the operation budget.")
        }
        return cap - bytes
    }
    package static func admit(_ bytes: Int, limits: ResourceLimits, peak: JPIPWorkspaceHighWater? = nil) throws {
        guard bytes <= limits.maximumWorkspaceBytes, bytes <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP simultaneous live storage exceeds resource limits before allocation.")
        }
        peak?.observe(bytes)
    }
    /// TCP may retain buffered input while publishing its response Data. Reserve
    /// both owners; VBAS descriptors are admitted separately once headers are read.
    package static func responseBodyLimit(
        limits: ResourceLimits, retaining bytes: Int, cumulativeWireBytes: Int
    ) throws -> Int {
        guard cumulativeWireBytes >= 0, cumulativeWireBytes < limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP cumulative wire allowance is exhausted before response read.")
        }
        return min(limits.maximumCompressedBytes - cumulativeWireBytes,
                   try remaining(limits, retaining: bytes) / 2)
    }
}

extension JPIPCacheModel {
    package func snapshotStorageBytes() throws -> Int {
        try JPIPAdmission.add(statistics.totalSize, JPIPAdmission.multiply(statistics.entryCount,
            MemoryLayout<CacheEntry>.stride + MemoryLayout<JPIPDataBin>.stride))
    }

    /// Includes the projection dictionary before creating it, and the old cache
    /// while replacement buffers and interval arrays are assembled.
    package mutating func addAdmitted(
        _ bins: [JPIPDataBin], limits: ResourceLimits, retainingExternalBytes: Int,
        peak: JPIPWorkspaceHighWater? = nil
    ) throws {
        let retained = try JPIPAdmission.add(retainingExternalBytes, retainedStorageBytes())
        let remaining = try JPIPAdmission.remaining(limits, retaining: retained)
        let projectionBytes = try projectionStorageBytes(addingCount: bins.count)
        try JPIPAdmission.admit(JPIPAdmission.add(retained, projectionBytes), limits: limits, peak: peak)
        let projected = try projectedAllocation(adding: bins, maximumProjectionBytes: remaining)
        guard projected.peakPayloadBytes <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP cache span exceeds compressed allowance before allocation.")
        }
        let newStorage = try JPIPAdmission.add(JPIPAdmission.multiply(projected.peakPayloadBytes, 2),
            JPIPAdmission.multiply(projected.entryCount,
                2 * MemoryLayout<(String, CacheEntry)>.stride))
        let rangeStorage = try JPIPAdmission.multiply(bins.count, 3 * MemoryLayout<Range<Int>>.stride)
        try JPIPAdmission.admit(JPIPAdmission.add(retained, JPIPAdmission.add(newStorage, rangeStorage)), limits: limits, peak: peak)
        for bin in bins { addDataBin(bin) }
    }
}
