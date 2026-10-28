// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJ2K

@Test(arguments: [12, 16]) func syntheticExactSamplesAndPadding(precision: Int) throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 5, height: 3,
        meaningfulBits: precision, rowBytes: 14, offset: 2)
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    let identity = destination.storage.allocationID
    let maximum: UInt16 = precision == 12 ? 4095 : 65535
    let image = try destination.writeUInt16 { x, y in
        (x + y) % 2 == 0 ? maximum : UInt16(x + y * 5)
    }
    #expect(image.storage.allocationID == identity)
    #expect(image.descriptor.meaningfulBits == precision)
    for y in 0..<3 {
        for x in 0..<5 {
            #expect(try image.sampleUInt16(x: x, y: y) == ((x + y) % 2 == 0 ? maximum : UInt16(x + y * 5)))
        }
    }
    try image.storage.withUnsafeBytes { bytes in
        #expect(bytes.count == 44)
        #expect(bytes[0] == 0 && bytes[1] == 0)
        for y in 0..<3 { for padding in 10..<14 { #expect(bytes[2 + y * 14 + padding] == 0) } }
    }
}

@Test func safeWriterRejectsOutOfRangeInsteadOfTruncating() throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1, meaningfulBits: 12)
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    #expect(throws: CodecError(.invalidArgument, "Sample exceeds declared meaningful precision.")) {
        try destination.writeUInt16 { _, _ in 4096 }
    }
    #expect(throws: CodecError.self) { try destination.storage.reserveWrite() }
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
}

@Test func descriptorMutationRejectsInvalidStridesAndOffsets() throws {
    for offset in [-1, 1, 3, Int.max] {
        #expect(throws: CodecError.self) {
            try ImageDescriptor.greyscale16(width: 3, height: 2, rowBytes: 8, offset: offset)
        }
    }
    for rowBytes in [-1, 0, 1, 2, 4, 5, 7, Int.max] {
        #expect(throws: CodecError.self) {
            try ImageDescriptor.greyscale16(width: 3, height: 2, rowBytes: rowBytes)
        }
    }
    for precision in [Int.min, -1, 0, 17, Int.max] {
        #expect(throws: CodecError.self) {
            try ImageDescriptor.greyscale16(width: 1, height: 1, meaningfulBits: precision)
        }
    }
}

@Test func integerOverflowWithExplicitLargeLimitsThrows() throws {
    let limits = try ResourceLimits(maximumDecodedBytes: Int.max, maximumPixels: Int.max,
                                    maximumDimension: Int.max, maximumMemoryBytes: Int.max)
    #expect(throws: CodecError.self) {
        try ImageDescriptor.greyscale16(width: Int.max, height: 1, limits: limits)
    }
    #expect(throws: CodecError.self) {
        try ImageDescriptor.greyscale16(width: 1, height: Int.max, rowBytes: 2, limits: limits)
    }
}

@Test func borrowedStorageRejectsForgedLeasesAndPublication() throws {
    let owner = try OwnedImageStorage(byteCount: 2)
    let lease = try owner.reserveWrite()
    #expect(throws: CodecError.self) { try owner.withUnsafeMutableBytes(lease: .init()) { $0[0] = 1 } }
    try owner.withUnsafeMutableBytes(lease: lease) { bytes in
        bytes[0] = 255; bytes[1] = 255
        #expect(throws: CodecError.self) { try owner.finishAndSeal(lease: lease) }
        #expect(throws: CodecError.self) { try owner.abortAndInvalidate(lease: lease) }
        #expect(throws: CodecError.self) { try owner.reserveWrite() }
    }
    let sealed = try owner.finishAndSeal(lease: lease)
    #expect(sealed.allocationID == owner.allocationID)
    #expect(throws: CodecError.self) { try owner.withUnsafeMutableBytes(lease: lease) { $0[0] = 0 } }
}

@Test func cancellationInsideWriteCannotPublishPartialImage() async throws {
    let destination = try ImageDestination.allocate(descriptor: .greyscale16(width: 5, height: 3))
    let task = Task {
        try destination.write { bytes in
            bytes[0] = 42
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    do { _ = try await task.value; Issue.record("Cancelled fill published an image.") }
    catch is CancellationError {}
    #expect(throws: CodecError.self) { try destination.storage.reserveWrite() }
    #expect(throws: CodecError.self) { try destination.write { _ in } }
}

@Test func independentPublicCallShapesReportTheirActualCoverage() async throws {
    let encoder = try SwiftJ2K.Encoder(configuration: EncoderConfiguration(mode: .lossless))
    let decoder = try SwiftJ2K.Decoder(configuration: .init())
    let transcoder = try SwiftJ2K.Transcoder(configuration: .init(mode: .lossless))
    #expect(encoder.capabilities.canEncode && decoder.capabilities.canDecode && decoder.capabilities.canInspect)
    #expect(encoder.capabilities.formats == ["jpeg2000-codestream", "htj2k-codestream", "jp2", "jph", "jpx"] && decoder.capabilities.compressionModes.contains(.lossless) && decoder.capabilities.compressionModes.contains(.lossy))
    #expect(encoder.capabilities.availableBackends == [.scalarCPU, .accelerated] && decoder.capabilities.meaningfulPrecision == 1...16)
    #expect(transcoder.capabilities.count == 2)
    let image = try ImageDestination.allocate(descriptor: .greyscale16(width: 1, height: 1))
        .writeUInt16 { _, _ in 65535 }
    let encoded = try await encoder.encode(image)
    #expect(try await decoder.decode(encoded.data).image.sampleUInt16(x: 0, y: 0) == 65535)
    // Empty or foreign bytes are rejected with the defined categories.
    #expect(throws: CodecError.self) { try decoder.inspect(Data()) }
    await #expect(throws: CodecError.self) { try await decoder.decode(Data()) }
    let destination = try ImageDestination.allocate(descriptor: .greyscale16(width: 1, height: 1))
    await #expect(throws: CodecError.self) { try await decoder.decode(Data(), into: destination) }
    await #expect(throws: CodecError.self) { try await transcoder.transcode(Data(), to: .htj2k) }
    // Unsupported preflight has not entered a write operation.
    #expect(try destination.writeUInt16 { _, _ in 7 }.sampleUInt16(x: 0, y: 0) == 7)
}
