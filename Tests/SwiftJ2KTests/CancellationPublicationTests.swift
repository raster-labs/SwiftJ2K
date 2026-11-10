// SPDX-License-Identifier: MIT
import Foundation
import Testing
import SwiftJ2K

private enum ProviderCancellationPoint: Sendable, CaseIterable {
    case sealing, validatingSealedStorage
}

/// Represents cancellation arriving while an external provider finishes work.
private final class CancellingWriteProvider: WritableImageStorage {
    let owner: OwnedImageStorage
    let point: ProviderCancellationPoint
    init(point: ProviderCancellationPoint) throws {
        owner = try OwnedImageStorage(byteCount: 2)
        self.point = point
    }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func reserveWrite() throws -> StorageWriteLease { try owner.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease,
                                  _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try owner.withUnsafeMutableBytes(lease: lease, body)
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage {
        let sealed = try owner.finishAndSeal(lease: lease)
        switch point {
        case .sealing:
            withUnsafeCurrentTask { $0?.cancel() }
            return sealed
        case .validatingSealedStorage:
            return CancellingReadProvider(owner: sealed)
        }
    }
    func abortAndInvalidate(lease: StorageWriteLease) throws {
        try owner.abortAndInvalidate(lease: lease)
    }
}

private struct CancellingReadProvider: ReadOnlyImageStorage {
    let owner: any ReadOnlyImageStorage
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        withUnsafeCurrentTask { $0?.cancel() }
        return try owner.withUnsafeBytes(body)
    }
}

@Test(arguments: ProviderCancellationPoint.allCases)
private func cancellationInProviderFinalisationPreventsPublication(_ point: ProviderCancellationPoint) async throws {
    let provider = try CancellingWriteProvider(point: point)
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let destination = try ImageDestination(descriptor: descriptor, storage: provider)
    let operation = Task {
        try destination.writeUInt16 { _, _ in 65535 }
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
    #expect(throws: CodecError.self) { try provider.reserveWrite() }
}
