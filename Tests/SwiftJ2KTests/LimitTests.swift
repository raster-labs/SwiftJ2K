// SPDX-License-Identifier: MIT
import Foundation
import Testing
import SwiftJ2K

@Test func independentAllocationAndMemoryCeilingsAreEnforced() throws {
    let limits = try ResourceLimits(maximumDecodedBytes: 8, maximumMemoryBytes: 4)
    _ = try OwnedImageStorage(byteCount: 4, limits: limits)
    #expect(throws: CodecError.self) { try OwnedImageStorage(byteCount: 5, limits: limits) }
    #expect(throws: CodecError.self) { try OwnedImageStorage(byteCount: 9, limits: limits) }
    #expect(throws: CodecError.self) { try OwnedImageStorage(byteCount: 0, limits: limits) }
    #expect(throws: CodecError.self) { try OwnedImageStorage(byteCount: -1, limits: limits) }
}

@Test func paddedStorageCountsTowardsDecodedLimit() throws {
    let limits = try ResourceLimits(maximumDecodedBytes: 12)
    let packed = try ImageDescriptor.greyscale16(width: 3, height: 2, limits: limits)
    #expect(packed.requiredByteCount == 12)
    #expect(throws: CodecError.self) {
        try ImageDescriptor.greyscale16(width: 3, height: 2, rowBytes: 8, limits: limits)
    }
}

@Test func pixelAndDimensionLimitsRejectBeforeAllocation() throws {
    let limits = try ResourceLimits(maximumPixels: 5, maximumDimension: 3)
    _ = try ImageDescriptor.greyscale16(width: 2, height: 2, limits: limits)
    #expect(throws: CodecError.self) {
        try ImageDescriptor.greyscale16(width: 3, height: 2, limits: limits)
    }
    #expect(throws: CodecError.self) {
        try ImageDescriptor.greyscale16(width: 4, height: 1, limits: limits)
    }
}

@Test func invalidResourceProfilesAndProgressFailPredictably() throws {
    #expect(throws: CodecError.self) { try ResourceLimits(maximumWorkers: 0) }
    #expect(throws: CodecError.self) { try ResourceLimits(deadlineSeconds: .infinity) }
    #expect(throws: CodecError.self) { try ResourceLimits(deadlineSeconds: .nan) }
    #expect(throws: CodecError.self) { try ResourceLimits(deadlineSeconds: -1) }
    #expect(throws: CodecError.self) { try ProgressUpdate(phase: .processing, completedUnits: -1) }
    #expect(throws: CodecError.self) {
        try ProgressUpdate(phase: .processing, completedUnits: 2, totalUnits: 1)
    }
    let unknownTotal = try ProgressUpdate(phase: .processing, completedUnits: 1)
    #expect(unknownTotal.totalUnits == nil)
    #expect(ResourceLimits.watch.maximumDecodedBytes == 32 * 1024 * 1024)
    #expect(ResourceLimits.watch.maximumWorkers == 2)
    #expect(ResourceLimits.watch.deadlineSeconds == 30)
}
