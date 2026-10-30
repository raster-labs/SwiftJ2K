// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Counts explicitly materialised pixel buffers; compressed/parser/coefficient storage is workspace.
/// Shared Data component selections allocate no sample buffers and contribute no copy event.
package struct LegacyPixelAccounting: Sendable {
    package private(set) var allocationCount: Int = 1
    package private(set) var peakBytes: Int
    package private(set) var copyEvents: [CopyEvent] = []

    init(decodedBytes: Int) { peakBytes = decodedBytes }

    package mutating func recordAllocation(bytes: Int, count: Int, liveBefore: Int,
                                          residentBytes: Int, reason: String,
                                          limits: ResourceLimits) throws {
        let peak = try checkedAdd(liveBefore, bytes)
        guard bytes >= 0, count > 0, liveBefore >= 0, residentBytes >= 0,
              bytes <= limits.maximumDecodedBytes,
              try checkedAdd(peak, residentBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Pixel materialisation exceeds the combined live-storage budget.")
        }
        allocationCount = try checkedAdd(allocationCount, count)
        peakBytes = max(peakBytes, peak)
        copyEvents.append(try CopyEvent(reason: reason, bytesMoved: bytes,
                                       sourceLayout: "decoded-samples", destinationLayout: "materialised-pixel-buffer"))
    }
}

extension J2KImage {
    package func pixelBytes(width: Int? = nil, height: Int? = nil) throws -> Int {
        if let width, let height {
            let samples = try checkedMultiply(width, height)
            return try components.reduce(0) { try checkedAdd($0, checkedMultiply(samples, $1.bytesPerSample)) }
        }
        return try components.reduce(0) { try checkedAdd($0, $1.data.count) }
    }
}

extension ResourceLimits {
    /// Derives a nested operation's remaining allowance without enlarging any other ceiling.
    package func reserving(workspaceBytes: Int = 0, memoryBytes: Int) throws -> ResourceLimits {
        guard workspaceBytes >= 0, memoryBytes >= 0,
              workspaceBytes < maximumWorkspaceBytes, memoryBytes < maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Retained buffers exhaust the nested operation budget.")
        }
        return try ResourceLimits(maximumCompressedBytes: maximumCompressedBytes,
            maximumDecodedBytes: maximumDecodedBytes,
            maximumWorkspaceBytes: maximumWorkspaceBytes - workspaceBytes,
            maximumPixels: maximumPixels, maximumDimension: maximumDimension,
            maximumFrames: maximumFrames, maximumMetadataBytes: maximumMetadataBytes,
            maximumICCBytes: maximumICCBytes, maximumNestingDepth: maximumNestingDepth,
            maximumWorkers: maximumWorkers, deadlineSeconds: deadlineSeconds,
            maximumMemoryBytes: maximumMemoryBytes - memoryBytes)
    }
}
