// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

@Test func boundedWriterRejectsGrowthBeforeAllocationAndPreservesPrefix() throws {
    let recorder = StorageTelemetry.Recorder()
    try StorageTelemetry.$recorder.withValue(recorder) {
        var writer = try BoundedByteWriter(reserving: 16, maximumBytes: 17, maximumAllocationBytes: 32)
        let prefix = Array(UInt8(0)..<UInt8(16))
        try writer.writeBytesChecked(prefix)
        let before = recorder.events.count
        do {
            try writer.writeUInt8Checked(16)
            Issue.record("16 old + 17 replacement bytes must be denied by a 32-byte live budget")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(recorder.events.count == before)
        #expect(writer.count == 16 && writer.capacity == 16)
        #expect(try writer.copyData() == Data(prefix))

        try writer.updateBudget(maximumBytes: 17, maximumAllocationBytes: 33)
        try writer.writeUInt8Checked(16)
        #expect(writer.count == 17 && writer.allocatedBytes == 17)
        #expect(writer.peakAllocationBytes == 33)
        #expect(try writer.copyData() == Data(UInt8(0)...UInt8(16)))
        let after = recorder.events.count
        #expect(throws: CodecError.self) { try writer.writeUInt8Checked(17) }
        #expect(writer.count == 17 && recorder.events.count == after)
    }
}

@Test func boundedWriterGrowthAndDirectCopiesPublishIndependentBytes() throws {
    var published = Data()
    do {
        let expected = (0..<4097).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
        var source = try BoundedByteWriter(reserving: 1, maximumBytes: expected.count, maximumAllocationBytes: 8193)
        for byte in expected { try source.writeUInt8Checked(byte) }
        #expect(source.allocatedBytes <= expected.count)
        #expect(source.peakAllocationBytes <= 8193)
        var destination = try BoundedByteWriter(reserving: 0, maximumBytes: expected.count + 6, maximumAllocationBytes: 2 * (expected.count + 6))
        try destination.reserveCapacity(expected.count + 6)
        try destination.writeUInt16Checked(0xff4f)
        try destination.writeBytesChecked(from: source)
        try destination.writeUInt32Checked(0x12345678)
        published = try destination.copyData()
        #expect(published == Data([0xff, 0x4f] + expected + [0x12, 0x34, 0x56, 0x78]))
    }
    // Both mutable owners have been destroyed; publication owns its own bytes.
    #expect(published.count == 4103)
    #expect(published.suffix(4) == Data([0x12, 0x34, 0x56, 0x78]))
}

@Test func boundedWriterRejectsInvalidReservationsWithoutAllocating() throws {
    let recorder = StorageTelemetry.Recorder()
    try StorageTelemetry.$recorder.withValue(recorder) {
        for (capacity, logical, resident) in [(17, 17, 16), (17, 16, 100), (-1, 17, 100)] {
            do {
                let writer = try BoundedByteWriter(reserving: capacity, maximumBytes: logical, maximumAllocationBytes: resident)
                _ = writer.count
                Issue.record("Invalid initial reservation was accepted")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
        }
        #expect(recorder.events.isEmpty)
        var empty = try BoundedByteWriter(reserving: 0, maximumBytes: 0, maximumAllocationBytes: 0)
        #expect(try empty.copyData().isEmpty)
        #expect(throws: CodecError.self) { try empty.reserveCapacity(Int.max) }
        #expect(recorder.events.isEmpty)
    }
}
