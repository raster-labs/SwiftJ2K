// SPDX-License-Identifier: MIT
import Dispatch
import Foundation
import Synchronization
import Testing
import SwiftJ2K

private func storageFailure(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("Expected storageUnavailable.")
    } catch let error as CodecError {
        #expect(error.category == .storageUnavailable)
    } catch {
        Issue.record("Unexpected error category: \(type(of: error))")
    }
}

/// Represents an application-owned adapter, forwarding the same provider state.
private final class WritableAdapter: WritableImageStorage {
    let owner: OwnedImageStorage
    init(_ owner: OwnedImageStorage) { self.owner = owner }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func reserveWrite() throws -> StorageWriteLease { try owner.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease,
                                  _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try owner.withUnsafeMutableBytes(lease: lease, body)
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage {
        try owner.finishAndSeal(lease: lease)
    }
    func abortAndInvalidate(lease: StorageWriteLease) throws {
        try owner.abortAndInvalidate(lease: lease)
    }
}

private final class ReleaseCounter: Sendable {
    let value = Mutex(0)
}

private final class ReadAdapter: ReadOnlyImageStorage {
    let owner: any ReadOnlyImageStorage
    let releases: ReleaseCounter
    let reads = Mutex(0)
    init(_ owner: any ReadOnlyImageStorage, releases: ReleaseCounter) {
        self.owner = owner; self.releases = releases
    }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        reads.withLock { $0 += 1 }
        return try owner.withUnsafeBytes(body)
    }
    deinit { releases.value.withLock { $0 += 1 } }
}

@Test func adaptersShareWriterAuthorityAndRejectForgedLease() throws {
    let owner = try OwnedImageStorage(byteCount: 6)
    let first = WritableAdapter(owner)
    let second = WritableAdapter(owner)
    #expect(first.allocationID == second.allocationID)
    let lease = try first.reserveWrite()
    storageFailure { _ = try second.reserveWrite() }
    storageFailure { try second.withUnsafeMutableBytes(lease: StorageWriteLease()) { _ in } }
    try first.withUnsafeMutableBytes(lease: lease) { bytes in
        bytes[0] = 0x34; bytes[1] = 0x12
    }
    let sealed = try second.finishAndSeal(lease: lease)
    #expect(try sealed.withUnsafeBytes { Array($0.prefix(2)) } == [0x34, 0x12])
    #expect(sealed.allocationID == owner.allocationID)
    storageFailure { try first.withUnsafeMutableBytes(lease: lease) { _ in } }
    storageFailure { _ = try second.reserveWrite() }
}

@Test func reentrantLeaseOperationsRejectWithoutDeadlocking() throws {
    let storage = try OwnedImageStorage(byteCount: 2)
    let lease = try storage.reserveWrite()
    try storage.withUnsafeMutableBytes(lease: lease) { bytes in
        storageFailure { try storage.withUnsafeMutableBytes(lease: lease) { _ in } }
        storageFailure { _ = try storage.finishAndSeal(lease: lease) }
        storageFailure { try storage.abortAndInvalidate(lease: lease) }
        storageFailure { _ = try storage.reserveWrite() }
        bytes[0] = 11
    }
    let sealed = try storage.finishAndSeal(lease: lease)
    #expect(try sealed.withUnsafeBytes { $0[0] } == 11)
}

@Test func sameTokenCannotAuthoriseConcurrentOverlappingBorrows() throws {
    let storage = try OwnedImageStorage(byteCount: 2)
    let lease = try storage.reserveWrite()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let result = Mutex(false)
    // A dedicated thread, not the global dispatch queue: while the whole suite
    // runs in parallel on every core, a default-QoS dispatch block can be
    // starved for seconds and the 5-second waits below would report a
    // scheduling delay as an ownership failure.
    let writer = Thread {
        defer { done.signal() }
        do {
            try storage.withUnsafeMutableBytes(lease: lease) { bytes in
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { return }
                bytes[0] = 29
                result.withLock { $0 = true }
            }
        } catch { }
    }
    writer.start()
    guard entered.wait(timeout: .now() + 5) == .success else {
        release.signal()
        Issue.record("First writer did not enter its scoped borrow.")
        return
    }
    storageFailure { try storage.withUnsafeMutableBytes(lease: lease) { _ in } }
    storageFailure { _ = try storage.finishAndSeal(lease: lease) }
    release.signal()
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(result.withLock { $0 })
    let sealed = try storage.finishAndSeal(lease: lease)
    #expect(try sealed.withUnsafeBytes { $0[0] } == 29)
}

@Test func concurrentAdaptersReserveExactlyOneWriter() async throws {
    let owner = try OwnedImageStorage(byteCount: 2)
    let winners = await withTaskGroup(of: StorageWriteLease?.self) { group in
        for _ in 0..<16 {
            group.addTask {
                do { return try WritableAdapter(owner).reserveWrite() }
                catch { return nil }
            }
        }
        var result: [StorageWriteLease] = []
        for await lease in group { if let lease { result.append(lease) } }
        return result
    }
    #expect(winners.count == 1)
    if let lease = winners.first { try owner.abortAndInvalidate(lease: lease) }
    storageFailure { _ = try owner.reserveWrite() }
}

@Test func imageRetainsAdapterUntilLastImageReleaseExactlyOnce() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let provider = try OwnedImageStorage(byteCount: 2)
    let lease = try provider.reserveWrite()
    try provider.withUnsafeMutableBytes(lease: lease) { $0[0] = 255; $0[1] = 255 }
    let releases = ReleaseCounter()
    var adapter: ReadAdapter? = ReadAdapter(try provider.finishAndSeal(lease: lease), releases: releases)
    weak var observed = adapter
    var image: SwiftJ2K.Image? = try SwiftJ2K.Image(
        descriptor: descriptor, storage: #require(adapter), metadata: .empty)
    let retainedID = image?.storage.allocationID
    adapter = nil
    #expect(observed != nil)
    #expect(retainedID == provider.allocationID)
    #expect(try image?.storage.withUnsafeBytes { Array($0) } == [255, 255])
    #expect(releases.value.withLock { $0 } == 0)
    image = nil
    #expect(observed == nil)
    #expect(releases.value.withLock { $0 } == 1)
    observed = nil
}

@Test func sealedOwnerSupportsConcurrentReadersAndNestedRead() async throws {
    let provider = try OwnedImageStorage(byteCount: 4)
    let lease = try provider.reserveWrite()
    try provider.withUnsafeMutableBytes(lease: lease) {
        $0[0] = 0; $0[1] = 0; $0[2] = 255; $0[3] = 255
    }
    let sealed = try provider.finishAndSeal(lease: lease)
    let sums = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<16 {
            group.addTask {
                try sealed.withUnsafeBytes { outer in
                    try sealed.withUnsafeBytes { inner in Int(outer[2]) + Int(inner[3]) }
                }
            }
        }
        var result: [Int] = []
        for try await sum in group { result.append(sum) }
        return result
    }
    #expect(sums.count == 16)
    #expect(sums.allSatisfy { $0 == 510 })
}

@Test func failedFillInvalidatesDestination() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let provider = try OwnedImageStorage(byteCount: 2)
    let destination = try ImageDestination(descriptor: descriptor, storage: provider)
    #expect(throws: CancellationError.self) {
        _ = try destination.write { bytes in
            bytes[0] = 1
            throw CancellationError()
        }
    }
    storageFailure { _ = try destination.write { _ in } }
    storageFailure { _ = try provider.reserveWrite() }
}

@Test func abandonedDestinationInvalidatesItsReservedOwner() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let provider = try OwnedImageStorage(byteCount: 2)
    do {
        let destination = try ImageDestination(descriptor: descriptor, storage: provider)
        withExtendedLifetime(destination) { }
    }
    storageFailure { _ = try provider.reserveWrite() }
}
