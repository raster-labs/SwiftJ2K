// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

public struct ImageMetadata: Sendable, Equatable {
    public let entries: [String: Data]
    public let requiredKeys: Set<String>
    public static let empty = Self()
    public init(entries: [String: Data] = [:], requiredKeys: Set<String> = []) {
        self.entries = entries; self.requiredKeys = requiredKeys
    }
    @discardableResult
    func validate(limits: ResourceLimits, additionalBytes: Int = 0) throws -> Int {
        guard requiredKeys.isSubset(of: Set(entries.keys)) else {
            throw CodecError(.invalidArgument, "Required metadata has no value.")
        }
        var count = additionalBytes
        guard count <= limits.maximumMetadataBytes else {
            throw CodecError(.resourceLimitExceeded, "Metadata limit exceeded.")
        }
        for (key, value) in entries {
            count = try checkedAdd(count, checkedAdd(key.utf8.count, value.count))
            guard count <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "Metadata limit exceeded.")
            }
        }
        return count
    }
}

public struct Image: Sendable {
    public let descriptor: ImageDescriptor
    public let storage: any ReadOnlyImageStorage
    public let metadata: ImageMetadata

    /// `storage` must be a sealed owner, not an escaped pointer or mutable view.
    /// External providers are responsible for making that guarantee across adapters.
    public init(descriptor: ImageDescriptor, storage: any ReadOnlyImageStorage,
                metadata: ImageMetadata = .empty, limits: ResourceLimits = .default) throws {
        guard storage.byteCount >= descriptor.requiredByteCount else {
            throw CodecError(.incompatibleImageLayout, "Storage is shorter than the descriptor capacity.")
        }
        try descriptor.validate(limits: limits)
        let metadataBytes = try metadata.validate(limits: limits, additionalBytes: descriptor.iccProfile?.count ?? 0)
        guard storage.byteCount <= limits.maximumDecodedBytes,
              try checkedAdd(storage.byteCount, metadataBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image exceeds the admission budget.")
        }
        try storage.withUnsafeBytes { bytes in
            guard bytes.count >= descriptor.requiredByteCount, bytes.count == storage.byteCount else {
                throw CodecError(.storageUnavailable, "Provider returned inconsistent capacity.")
            }
        }
        self.descriptor = descriptor; self.storage = storage; self.metadata = metadata
    }

    /// A safe sample accessor for the required greyscale profile; never reads padding.
    public func sampleUInt16(x: Int, y: Int) throws -> UInt16 {
        try validateGreyscale16(descriptor)
        guard x >= 0, y >= 0, x < descriptor.width, y < descriptor.height else {
            throw CodecError(.invalidArgument, "Sample coordinates are outside the image.")
        }
        let plane = descriptor.planes[0]
        // Descriptor validation proves these coordinate calculations fit in Int.
        let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride
        return try storage.withUnsafeBytes { bytes in
            guard bytes.count >= descriptor.requiredByteCount else {
                throw CodecError(.storageUnavailable, "Provider returned insufficient capacity.")
            }
            // The provider retains sealed storage for this synchronous borrow.
            // Descriptor and capacity checks above prove the two-byte extent.
            return try loadUInt16(bytes, at: offset, order: descriptor.byteOrder)
        }
    }

    /// Component-aware integer sample accessor for 8-bit or 16-bit unsigned/signed descriptors.
    public func sampleInt(component: Int = 0, x: Int, y: Int) throws -> Int {
        guard descriptor.sampleType == .unsignedInteger || descriptor.sampleType == .signedInteger else {
            throw CodecError(.unsupportedFeature, "Sample helper requires integer sample storage.")
        }
        guard component >= 0, component < descriptor.components.count,
              x >= 0, y >= 0, x < descriptor.width, y < descriptor.height else {
            throw CodecError(.invalidArgument, "Sample component or coordinates are outside the image.")
        }
        let offset = try sampleByteOffset(descriptor: descriptor, component: component, x: x, y: y)
        return try storage.withUnsafeBytes { bytes in
            guard bytes.count >= descriptor.requiredByteCount else {
                throw CodecError(.storageUnavailable, "Provider returned insufficient capacity.")
            }
            return try loadSampleInt(bytes, at: offset, storageBits: descriptor.storageBits,
                                     signed: descriptor.sampleType == .signedInteger,
                                     order: descriptor.byteOrder)
        }
    }

    /// Component-aware unsigned 16-bit sample accessor (supports 8-bit or 16-bit unsigned descriptors).
    public func sampleUInt16(component: Int, x: Int, y: Int) throws -> UInt16 {
        guard descriptor.sampleType == .unsignedInteger else {
            throw CodecError(.unsupportedFeature, "Unsigned sample helper requires unsigned integer storage.")
        }
        return UInt16(try sampleInt(component: component, x: x, y: y))
    }

    /// Component-aware signed 16-bit sample accessor (supports 8-bit or 16-bit signed descriptors).
    public func sampleInt16(component: Int = 0, x: Int, y: Int) throws -> Int16 {
        guard descriptor.sampleType == .signedInteger else {
            throw CodecError(.unsupportedFeature, "Signed sample helper requires signed integer storage.")
        }
        return Int16(try sampleInt(component: component, x: x, y: y))
    }
}

/// Reserves the provider on construction; abandoned destinations abort on release.
/// Only one write call is accepted. A thrown fill or cancellation invalidates the
/// destination, and a sealed image independently retains its immutable owner.
public final class ImageDestination: Sendable {
    public let descriptor: ImageDescriptor
    public let storage: any WritableImageStorage
    private let lease: StorageWriteLease
    private let limits: ResourceLimits
    private let started = Mutex(false)

    public init(descriptor: ImageDescriptor, storage: any WritableImageStorage,
                limits: ResourceLimits = .default) throws {
        try descriptor.validate(limits: limits)
        guard storage.byteCount <= limits.maximumDecodedBytes,
              try checkedAdd(storage.byteCount, descriptor.iccProfile?.count ?? 0) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Destination exceeds the admission budget.")
        }
        guard storage.byteCount >= descriptor.requiredByteCount else {
            throw CodecError(.incompatibleImageLayout, "Destination storage is too short.")
        }
        self.descriptor = descriptor; self.storage = storage; self.limits = limits
        self.lease = try storage.reserveWrite()
    }
    deinit { try? storage.abortAndInvalidate(lease: lease) }

    /// A decoder calls this when its operation fails after admission but
    /// before the final write began, so that a failed decode never leaves a
    /// destination that can still be published (MEMORY_CONTRACT "Failure and
    /// limits"). Preflight rejections do not call it.
    func invalidateAfterFailure() {
        let first = started.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if first { try? storage.abortAndInvalidate(lease: lease) }
    }

    public static func allocate(descriptor: ImageDescriptor, limits: ResourceLimits = .default) throws -> ImageDestination {
        try descriptor.validate(limits: limits)
        guard try checkedAdd(descriptor.requiredByteCount, descriptor.iccProfile?.count ?? 0) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Destination exceeds the admission budget.")
        }
        let storage = try OwnedImageStorage(byteCount: descriptor.requiredByteCount, limits: limits)
        return try Self(descriptor: descriptor, storage: storage, limits: limits)
    }

    /// Advanced unsafe fill boundary. Initialise every sample before returning.
    /// The pointer must not escape or be used by asynchronous/concurrent work.
    /// Ordinary callers should prefer `writeUInt16`, which validates sample values.
    /// The caller controls cancellation/work bounds inside this synchronous closure.
    public func write(_ body: (UnsafeMutableRawBufferPointer) throws -> Void) throws -> Image {
        let accepted = started.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard accepted else { throw CodecError(.storageUnavailable, "Destination was already used.") }
        do {
            try Task.checkCancellation()
            try storage.withUnsafeMutableBytes(lease: lease) { bytes in
                guard bytes.count == storage.byteCount, bytes.count >= descriptor.requiredByteCount else {
                    throw CodecError(.storageUnavailable, "Provider returned inconsistent capacity.")
                }
                try body(bytes)
            }
            try Task.checkCancellation()
            let sealed = try storage.finishAndSeal(lease: lease)
            let image = try Image(descriptor: descriptor, storage: sealed, limits: limits)
            // External providers may perform bounded finalisation or validation
            // work. Cancellation during either callback must prevent publication.
            try Task.checkCancellation()
            return image
        } catch {
            try? storage.abortAndInvalidate(lease: lease)
            throw error
        }
    }

    /// Synthetic sample initialisation; this is not compression or decompression.
    /// A row is the maximum cancellation interval for the provided scalar writer.
    public func writeUInt16(_ sample: (Int, Int) throws -> UInt16) throws -> Image {
        try validateGreyscale16(descriptor)
        let plane = descriptor.planes[0]
        let maximum = UInt32(1) << descriptor.meaningfulBits
        return try write { bytes in
            for y in 0..<descriptor.height {
                try Task.checkCancellation()
                for x in 0..<descriptor.width {
                    let value = try sample(x, y)
                    guard UInt32(value) < maximum else {
                        throw CodecError(.invalidArgument, "Sample exceeds declared meaningful precision.")
                    }
                    let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride
                    // The exclusive lease retains these two bytes. External
                    // providers need not initialise samples before this write.
                    try storeUInt16(value, into: bytes, at: offset, order: descriptor.byteOrder)
                }
            }
        }
    }

    /// Synthetic signed 16-bit greyscale sample initialisation.
    public func writeInt16(_ sample: (Int, Int) throws -> Int16) throws -> Image {
        guard descriptor.sampleType == .signedInteger, descriptor.storageBits == 16,
              descriptor.components == [.grey], descriptor.planes.count == 1 else {
            throw CodecError(.unsupportedFeature, "Sample helper requires signed 16-bit greyscale.")
        }
        let plane = descriptor.planes[0]
        let minVal = -(1 << (descriptor.meaningfulBits - 1))
        let maxVal = (1 << (descriptor.meaningfulBits - 1)) - 1
        return try write { bytes in
            for y in 0..<descriptor.height {
                try Task.checkCancellation()
                for x in 0..<descriptor.width {
                    let value = Int(try sample(x, y))
                    guard value >= minVal && value <= maxVal else {
                        throw CodecError(.invalidArgument, "Signed sample exceeds declared meaningful precision.")
                    }
                    let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride
                    try storeUInt16(UInt16(bitPattern: Int16(value)), into: bytes, at: offset, order: descriptor.byteOrder)
                }
            }
        }
    }

    /// Component-aware integer sample writer for any 8-bit or 16-bit unsigned/signed layout (planar or interleaved).
    public func writeSamples(_ sample: (_ component: Int, _ x: Int, _ y: Int) throws -> Int) throws -> Image {
        guard descriptor.sampleType == .unsignedInteger || descriptor.sampleType == .signedInteger else {
            throw CodecError(.unsupportedFeature, "Sample helper requires integer sample storage.")
        }
        let signed = descriptor.sampleType == .signedInteger
        let minVal = signed ? -(1 << (descriptor.meaningfulBits - 1)) : 0
        let maxVal = signed ? ((1 << (descriptor.meaningfulBits - 1)) - 1) : ((1 << descriptor.meaningfulBits) - 1)
        return try write { bytes in
            for plane in descriptor.planes {
                for y in 0..<descriptor.height {
                    try Task.checkCancellation()
                    let rowBase = plane.offset + y * plane.rowBytes
                    for x in 0..<descriptor.width {
                        let pixelBase = rowBase + x * plane.pixelStride
                        for (compIdxInPlane, component) in plane.components.enumerated() {
                            let value = try sample(component, x, y)
                            guard value >= minVal && value <= maxVal else {
                                throw CodecError(.invalidArgument, "Sample exceeds declared meaningful precision.")
                            }
                            let offset = pixelBase + compIdxInPlane * plane.sampleStride
                            try storeSampleInt(value, into: bytes, at: offset,
                                               storageBits: descriptor.storageBits,
                                               signed: signed, order: descriptor.byteOrder)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Byte-order-explicit 8/16-bit sample access

@inline(__always)
func sampleByteOffset(descriptor: ImageDescriptor, component: Int, x: Int, y: Int) throws -> Int {
    for plane in descriptor.planes {
        if let compIdx = plane.components.firstIndex(of: component) {
            return plane.offset + y * plane.rowBytes + x * plane.pixelStride + compIdx * plane.sampleStride
        }
    }
    throw CodecError(.invalidArgument, "Component \(component) is not mapped in any plane.")
}

@inline(__always)
func loadSampleInt(_ bytes: UnsafeRawBufferPointer, at offset: Int,
                   storageBits: Int, signed: Bool, order: ByteOrder) throws -> Int {
    if storageBits == 8 {
        guard offset >= 0, offset < bytes.count else {
            throw CodecError(.storageUnavailable, "Sample extent lies outside the retained allocation.")
        }
        let raw = bytes[offset]
        return signed ? Int(Int8(bitPattern: raw)) : Int(raw)
    } else {
        let raw = try loadUInt16(bytes, at: offset, order: order)
        return signed ? Int(Int16(bitPattern: raw)) : Int(raw)
    }
}

@inline(__always)
func storeSampleInt(_ value: Int, into bytes: UnsafeMutableRawBufferPointer,
                    at offset: Int, storageBits: Int, signed: Bool, order: ByteOrder) throws {
    if storageBits == 8 {
        guard offset >= 0, offset < bytes.count else {
            throw CodecError(.storageUnavailable, "Sample extent lies outside the retained allocation.")
        }
        bytes[offset] = signed ? UInt8(bitPattern: Int8(truncatingIfNeeded: value)) : UInt8(truncatingIfNeeded: value)
    } else {
        let word = signed ? UInt16(bitPattern: Int16(truncatingIfNeeded: value)) : UInt16(truncatingIfNeeded: value)
        try storeUInt16(word, into: bytes, at: offset, order: order)
    }
}

// These replace the `RawSpan.load(fromByteOffset:as:_:)` and
// `OutputRawSpan.append(_:as:_:)` byte-order operations. Those standard-library
// entry points are annotated `@available(macOS 27, *)` and equivalents, so using
// them would raise every Apple deployment floor above the 26.0 baseline that
// PLATFORMS.md PLAT-02 fixes. They are a spelling convenience, not a capability:
// the contract requires an explicit byte order (MEM-01), never a particular
// standard-library type to express it.
//
// Assembling each sample byte-wise keeps two properties the span types provided
// implicitly and that the accessors depend on:
//
//   * Alignment independence. MEM-03 permits any plane `offset`, so a sample may
//     begin at an odd address. Byte access has no alignment precondition.
//   * A bounds check before the allocation is touched (MEM-04). A raw buffer
//     subscript is unchecked in release builds, so the guards below are load
//     bearing, not defensive duplication of the descriptor arithmetic.

@inline(__always)
func loadUInt16(_ bytes: UnsafeRawBufferPointer, at offset: Int,
                order: ByteOrder) throws -> UInt16 {
    guard offset >= 0, offset <= bytes.count - MemoryLayout<UInt16>.size else {
        throw CodecError(.storageUnavailable, "Sample extent lies outside the retained allocation.")
    }
    let first = UInt16(bytes[offset]), second = UInt16(bytes[offset + 1])
    return order == .littleEndian ? first | (second << 8) : (first << 8) | second
}

@inline(__always)
func storeUInt16(_ value: UInt16, into bytes: UnsafeMutableRawBufferPointer,
                 at offset: Int, order: ByteOrder) throws {
    guard offset >= 0, offset <= bytes.count - MemoryLayout<UInt16>.size else {
        throw CodecError(.storageUnavailable, "Sample extent lies outside the retained allocation.")
    }
    let low = UInt8(truncatingIfNeeded: value), high = UInt8(truncatingIfNeeded: value >> 8)
    // Assigning through the raw buffer initialises these bytes, so a provider
    // may hand over uninitialised sample storage under the exclusive lease.
    bytes[offset] = order == .littleEndian ? low : high
    bytes[offset + 1] = order == .littleEndian ? high : low
}

private func validateGreyscale16(_ descriptor: ImageDescriptor) throws {
    guard descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16,
          descriptor.components == [.grey], descriptor.planes.count == 1 else {
        throw CodecError(.unsupportedFeature, "Sample helper requires unsigned 16-bit greyscale.")
    }
}
