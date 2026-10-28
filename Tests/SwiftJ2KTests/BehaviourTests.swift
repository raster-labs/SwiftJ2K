// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJ2K

@Test func publicOperationsRejectForeignBytesAndAdvertiseScalarLosslessCoverage() async throws {
    let encoder = try SwiftJ2K.Encoder()
    let decoder = try SwiftJ2K.Decoder()
    #expect(encoder.configuration.mode == .lossless)
    #expect(encoder.capabilities.canEncode && !encoder.capabilities.canDecode)
    #expect(decoder.capabilities.canDecode && decoder.capabilities.canInspect && !decoder.capabilities.canEncode)
    #expect(encoder.capabilities.formats == decoder.capabilities.formats)
    #expect(encoder.capabilities.availableBackends == [.scalarCPU, .accelerated])
    #expect(encoder.capabilities.layouts.contains(CodecCapabilities.sharedGreyscaleLayout))
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    do {
        _ = try decoder.inspect(Data())
        Issue.record("Empty input inspected.")
    } catch let error as CodecError { #expect(error.category == .malformedInput) }
    do {
        // A JPEG (not JPEG 2000) SOI/EOI pair is a different format, not an image.
        _ = try await decoder.decode(Data([0xff, 0xd8, 0xff, 0xd9]))
        Issue.record("A JPEG marker pair must not decode.")
    } catch let error as CodecError { #expect(error.category == .unsupportedFormat) }
    do {
        _ = try await decoder.decode(Data(), into: destination)
        Issue.record("Empty input decoded into storage.")
    } catch let error as CodecError { #expect(error.category == .malformedInput) }
    // Rejection is preflight: no write began and the caller's reserved owner remains usable.
    let next = try destination.writeUInt16 { _, _ in 123 }
    #expect(try next.sampleUInt16(x: 0, y: 0) == 123)
}

@Test func configurationsAndBackendRequestsRejectUnsupportedChoices() throws {
    #expect(throws: CodecError.self) { try EncoderConfiguration(mode: .nearLossless(maximumAbsoluteError: 0)) }
    #expect(throws: CodecError.self) { try EncoderConfiguration(mode: .lossless, codecOptions: CodecOptions(wavelet: .irreversible97)) }
    #expect(throws: CodecError.self) { try EncoderConfiguration(mode: .lossy, codecOptions: CodecOptions(blockCoding: .htj2k)) }
    _ = try EncoderConfiguration(mode: .nearLossless(maximumAbsoluteError: 1))
    _ = try EncoderConfiguration(mode: .lossy)
    do {
        _ = try SwiftJ2K.Decoder().inspect(Data(), options: .init(executionPolicy: .required(.accelerated)))
        Issue.record("Empty input inspected under required(.accelerated).")
    } catch let error as CodecError { #expect(error.category == .malformedInput) }
    let limits = try ResourceLimits(maximumCompressedBytes: 1)
    do {
        _ = try SwiftJ2K.Decoder().inspect(Data([0, 1]), options: .init(resourceLimits: limits))
        Issue.record("Compressed input limit was ignored.")
    } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
}

@Test func safeSampleWriterRejectsOutOfRangeWithoutTruncating() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1, meaningfulBits: 12)
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 4096 } }
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 4095 } }
    let valid = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 4095 }
    #expect(try valid.sampleUInt16(x: 0, y: 0) == 4095)
    #expect(throws: CodecError.self) { try valid.sampleUInt16(x: -1, y: 0) }
    #expect(throws: CodecError.self) { try valid.sampleUInt16(x: 1, y: 0) }
}

@Test func cancellationDuringSyntheticRowsInvalidatesDestination() async throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 3)
    let provider = try OwnedImageStorage(byteCount: descriptor.requiredByteCount)
    let destination = try ImageDestination(descriptor: descriptor, storage: provider)
    let visits = Mutex(0)
    let cancelled = await Task {
        do {
            _ = try destination.writeUInt16 { x, y in
                visits.withLock { $0 += 1 }
                if x == 0 && y == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                return 29
            }
            return false
        } catch is CancellationError { return true }
        catch { return false }
    }.value
    #expect(cancelled)
    #expect(visits.withLock { $0 } == 3)
    #expect(throws: CodecError.self) { try provider.reserveWrite() }
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
}

@Test func cancellationIsCheckedBeforeAllocatingStorage() async {
    let cancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try OwnedImageStorage(byteCount: 2)
            return false
        } catch is CancellationError { return true }
        catch { return false }
    }.value
    #expect(cancelled)
}

@Test func unknownMeasurementsStayUnknownAndMetadataIsBounded() throws {
    let report = OperationReport(backend: .scalarCPU, fidelity: .exactSamples)
    #expect(report.pixelAllocationCount == nil)
    #expect(report.peakPixelBytes == nil && report.peakWorkspaceBytes == nil)
    #expect(report.elapsedSeconds == nil)
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let source = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 0 }
    #expect(throws: CodecError.self) {
        try SwiftJ2K.Image(descriptor: descriptor, storage: source.storage,
                          metadata: .init(entries: [:], requiredKeys: ["required"]))
    }
}

@Test func metadataAndDestinationLimitsUseCallerBudget() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 7 }
    let metadata = ImageMetadata(entries: ["a": Data([1, 2])])
    let adequate = try ResourceLimits(maximumDecodedBytes: 2, maximumMetadataBytes: 3, maximumMemoryBytes: 5)
    let accepted = try SwiftJ2K.Image(descriptor: descriptor, storage: image.storage, metadata: metadata, limits: adequate)
    #expect(accepted.metadata == metadata)
    let shortMetadata = try ResourceLimits(maximumMetadataBytes: 2)
    #expect(throws: CodecError.self) {
        try SwiftJ2K.Image(descriptor: descriptor, storage: image.storage, metadata: metadata, limits: shortMetadata)
    }
    let shortMemory = try ResourceLimits(maximumMemoryBytes: 4)
    #expect(throws: CodecError.self) {
        try SwiftJ2K.Image(descriptor: descriptor, storage: image.storage, metadata: metadata, limits: shortMemory)
    }
    let tooSmall = try ResourceLimits(maximumDecodedBytes: 1)
    #expect(throws: CodecError.self) { try ImageDestination.allocate(descriptor: descriptor, limits: tooSmall) }
}

@Test func explicitLargerMetadataLimitIsHonoured() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let source = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 1 }
    let metadata = ImageMetadata(entries: ["a": Data(repeating: 0, count: ResourceLimits.default.maximumMetadataBytes)])
    #expect(throws: CodecError.self) {
        try SwiftJ2K.Image(descriptor: descriptor, storage: source.storage, metadata: metadata)
    }
    let expanded = try ResourceLimits(maximumMetadataBytes: ResourceLimits.default.maximumMetadataBytes + 1)
    let image = try SwiftJ2K.Image(descriptor: descriptor, storage: source.storage,
                                 metadata: metadata, limits: expanded)
    #expect(image.metadata.entries["a"]?.count == ResourceLimits.default.maximumMetadataBytes)
}

@Test func safeSampleAccessHonoursExplicitBigEndian() throws {
    let plane = try PlaneDescriptor(width: 1, height: 1, rowBytes: 2, byteCount: 2)
    let descriptor = try ImageDescriptor(width: 1, height: 1, byteOrder: .bigEndian, planes: [plane])
    let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 0xABCD }
    #expect(try image.sampleUInt16(x: 0, y: 0) == 0xABCD)
    #expect(try image.storage.withUnsafeBytes { Array($0) } == [0xAB, 0xCD])
}

@Test func decoderPreservesTaskCancellationError() async throws {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SwiftJ2K.Decoder().decode(Data())
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
