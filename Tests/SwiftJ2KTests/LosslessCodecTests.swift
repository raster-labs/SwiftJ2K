// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K

// MARK: - Fixture access

/// Deterministic synthetic fixtures with independently produced codestreams.
/// See Tests/SwiftJ2KTests/Fixtures/Lossless/manifest.json and
/// Scripts/generate-lossless-fixtures.py for provenance and SHA-256 values.
enum Fixtures {
    struct Codestream: Decodable { let file: String; let tool: String; let bytes: Int; let sha256: String }
    struct Entry: Decodable {
        let name: String; let width: Int; let height: Int; let meaningfulBits: Int
        let codestreams: [Codestream]
    }
    struct Variant: Decodable { let file: String; let note: String; let produced: Bool }
    struct SyntaxVariant: Decodable { let base: String; let file: String; let note: String; let produced: Bool }
    struct Manifest: Decodable {
        let fixtures: [Entry]
        let variants_of_g16_64x64_random: [Variant]
        let rgb_fixture: Variant
        let syntax_variants: [SyntaxVariant]
    }

    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Lossless")
    static let manifest: Manifest = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func bytes(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file))
    }

    /// Parses a binary PGM (P5), big-endian samples when maxval exceeds 255.
    static func samples(_ entry: Entry) throws -> [UInt16] {
        let data = [UInt8](try bytes(entry.name + ".pgm"))
        var fields: [String] = []
        var i = 0
        while fields.count < 4 {
            while data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D || data[i] == 0x09 { i += 1 }
            if data[i] == 0x23 { while data[i] != 0x0A { i += 1 }; continue }
            var j = i
            while !(data[j] == 0x20 || data[j] == 0x0A || data[j] == 0x0D || data[j] == 0x09) { j += 1 }
            fields.append(String(decoding: data[i..<j], as: UTF8.self)); i = j
        }
        i += 1
        let count = entry.width * entry.height
        guard fields[0] == "P5", Int(fields[1]) == entry.width, Int(fields[2]) == entry.height,
              let maxval = Int(fields[3]) else { throw CodecError(.internalFailure, "Bad PGM fixture.") }
        if maxval <= 255 { return data[i..<i + count].map { UInt16($0) } }
        return (0..<count).map { UInt16(data[i + 2 * $0]) << 8 | UInt16(data[i + 2 * $0 + 1]) }
    }

    static let allCodestreams: [(Entry, Codestream)] = manifest.fixtures.flatMap { entry in
        entry.codestreams.map { (entry, $0) }
    }
}

func expectSamples(_ image: Image, equal expected: [UInt16], width: Int, height: Int,
                   sourceLocation: SourceLocation = #_sourceLocation) throws {
    var mismatches = 0
    for y in 0..<height {
        for x in 0..<width where try image.sampleUInt16(x: x, y: y) != expected[y * width + x] {
            mismatches += 1
        }
    }
    #expect(mismatches == 0, "\(mismatches) of \(width * height) samples differ", sourceLocation: sourceLocation)
}

func makeImage(_ samples: [UInt16], width: Int, height: Int, bits: Int,
               rowBytes: Int? = nil, offset: Int = 0) throws -> Image {
    let descriptor = try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: bits,
                                                     rowBytes: rowBytes, offset: offset)
    return try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in samples[y * width + x] }
}

// MARK: - Independent codestreams decode exactly

@Test(arguments: Fixtures.allCodestreams.map { "\($0.0.name)|\($0.1.file)" })
func independentCodestreamsDecodeToTheGeneratedSamples(key: String) async throws {
    let (entry, codestream) = Fixtures.allCodestreams.first { "\($0.0.name)|\($0.1.file)" == key }!
    let data = try Fixtures.bytes(codestream.file)
    #expect(data.count == codestream.bytes)
    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.descriptor.width == entry.width && info.descriptor.height == entry.height)
    #expect(info.descriptor.meaningfulBits == entry.meaningfulBits && info.frameCount == 1)
    let decoded = try await decoder.decode(data)
    #expect(decoded.report.backend == .scalarCPU && decoded.report.fidelity == .exactSamples)
    #expect(decoded.report.copyEvents.isEmpty && decoded.report.pixelAllocationCount == 1)
    #expect(decoded.report.peakPixelBytes == entry.width * entry.height * 2)
    try expectSamples(decoded.image, equal: try Fixtures.samples(entry), width: entry.width, height: entry.height)
}

@Test(arguments: ["precincts", "sop_eph", "rpcl", "cprl", "kdu_tileparts", "kdu_plt",
                  "tiled", "layers2", "bypass", "termall", "segsym", "kdu_ht"])
func supportedSyntaxVariantsDecodeExactly(variant: String) async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g16_64x64_random" }!
    let data = try Fixtures.bytes("g16_64x64_random.\(variant).j2k")
    let decoded = try await Decoder().decode(data)
    try expectSamples(decoded.image, equal: try Fixtures.samples(entry), width: 64, height: 64)
}

@Test(arguments: [("irreversible97", "9/7")])
func irreversible97FixtureDecodesWithLossyFidelityAndPart2IsRejected(variant: String, expected: String) async throws {
    let data = try Fixtures.bytes("g16_64x64_random.\(variant).j2k")
    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.descriptor.width == 64 && info.descriptor.height == 64)
    let decoded = try await decoder.decode(data)
    #expect(decoded.report.fidelity == .lossy)

    // Part 2 Rsiz (0x8000) at bytes 6..7 remains unsupported and leaves the caller's destination reusable.
    var part2Data = data
    part2Data[6] = 0x80
    part2Data[7] = 0x02
    let destination = try ImageDestination.allocate(descriptor: .greyscale16(width: 64, height: 64))
    for attempt in 0..<2 {
        do {
            if attempt == 0 { _ = try decoder.inspect(part2Data) } else { _ = try await decoder.decode(part2Data, into: destination) }
            Issue.record("Part 2 Rsiz codestream was accepted")
        } catch let error as CodecError {
            #expect(error.category == .unsupportedFeature, "\(error.message)")
            #expect(error.message.contains("Part 2"), "\(error.message)")
        }
    }
    #expect(try destination.writeUInt16 { _, _ in 5 }.sampleUInt16(x: 63, y: 63) == 5)
}

/// Milestone 4: layers, every code-block style, tiles, origins and
/// precinct-major progressions from both reference encoders.
@Test(arguments: Fixtures.manifest.syntax_variants.filter(\.produced).map(\.file))
func syntaxCoverageVariantsDecodeExactly(file: String) async throws {
    let variant = Fixtures.manifest.syntax_variants.first { $0.file == file }!
    let entry = Fixtures.manifest.fixtures.first { $0.name == variant.base }!
    let data = try Fixtures.bytes(file)
    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.descriptor.width == entry.width && info.descriptor.height == entry.height, "\(variant.note)")
    let decoded = try await decoder.decode(data)
    try expectSamples(decoded.image, equal: try Fixtures.samples(entry), width: entry.width, height: entry.height)
}

@Test func colourCodestreamsInspectAndDecode() async throws {
    let data = try Fixtures.bytes(Fixtures.manifest.rgb_fixture.file)
    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.descriptor.width == 16 && info.descriptor.height == 16 && info.descriptor.components == [.red, .green, .blue])
    let decoded = try await decoder.decode(data)
    #expect(decoded.image.descriptor.components == [.red, .green, .blue])
}

// MARK: - Round trips through the successor encoder

@Test(arguments: Fixtures.manifest.fixtures.map(\.name))
func encoderOutputDecodesExactlyWithDefaultOptions(name: String) async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == name }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
    let encoded = try await Encoder().encode(image)
    #expect(encoded.encoding.format == "jpeg2000-codestream" && encoded.encoding.mode == .lossless)
    #expect(encoded.report.copyEvents.isEmpty && encoded.report.pixelAllocationCount == 0)
    #expect(encoded.data.prefix(2) == Data([0xFF, 0x4F]) && encoded.data.suffix(2) == Data([0xFF, 0xD9]))
    let decoded = try await Decoder().decode(encoded.data)
    #expect(decoded.image.descriptor.meaningfulBits == entry.meaningfulBits)
    try expectSamples(decoded.image, equal: samples, width: entry.width, height: entry.height)
}

@Test(arguments: [(0, 64, 64), (1, 16, 16), (2, 32, 8), (3, 4, 4), (5, 64, 64), (6, 8, 512)])
func encoderOptionsRoundTrip(levels: Int, blockWidth: Int, blockHeight: Int) async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g12_129x67_gradient" }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
    let options = try CodecOptions(decompositionLevels: levels, codeBlockWidth: blockWidth, codeBlockHeight: blockHeight)
    let encoder = try Encoder(configuration: EncoderConfiguration(codecOptions: options))
    let encoded = try await encoder.encode(image)
    let decoded = try await Decoder().decode(encoded.data)
    try expectSamples(decoded.image, equal: samples, width: entry.width, height: entry.height)
}

@Test(arguments: [(1, 1), (1, 7), (7, 1), (2, 2), (3, 5), (65, 1), (1, 65), (17, 33)])
func degenerateGeometriesRoundTrip(width: Int, height: Int) async throws {
    var state: UInt32 = 0x9E37_79B9
    let samples: [UInt16] = (0..<(width * height)).map { _ in
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return UInt16(truncatingIfNeeded: state)
    }
    let image = try makeImage(samples, width: width, height: height, bits: 16)
    let encoded = try await Encoder().encode(image)
    let decoded = try await Decoder().decode(encoded.data)
    try expectSamples(decoded.image, equal: samples, width: width, height: height)
}

@Test func extremeValuesSurviveEveryPrecision() async throws {
    for bits in [1, 2, 7, 8, 9, 12, 15, 16] {
        let maximum = UInt16((1 << bits) - 1)
        var samples: [UInt16] = []
        for index in 0..<(9 * 7) {
            let value: UInt16
            switch index % 3 {
            case 0: value = maximum
            case 1: value = 0
            default: value = UInt16(index) & maximum
            }
            samples.append(value)
        }
        let image = try makeImage(samples, width: 9, height: 7, bits: bits)
        let decoded = try await Decoder().decode(try await Encoder().encode(image).data)
        #expect(decoded.image.descriptor.meaningfulBits == bits)
        try expectSamples(decoded.image, equal: samples, width: 9, height: 7)
    }
}

// MARK: - Shared storage behaviour (TEST-09 style checks that Milestone 3 will extend)

@Test func decodeIntoCallerStorageKeepsIdentityAndLeavesPaddingUntouched() async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g12_5x3_ramp_extremes" }!
    let data = try Fixtures.bytes("g12_5x3_ramp_extremes.kdu.j2k")
    let descriptor = try ImageDescriptor.greyscale16(width: 5, height: 3, meaningfulBits: 12, rowBytes: 16, offset: 4)
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    let identity = destination.storage.allocationID
    let decoded = try await Decoder().decode(data, into: destination)
    #expect(decoded.image.storage.allocationID == identity)
    #expect(decoded.report.pixelAllocationCount == 0 && decoded.report.copyEvents.isEmpty)
    try expectSamples(decoded.image, equal: try Fixtures.samples(entry), width: 5, height: 3)
    try decoded.image.storage.withUnsafeBytes { bytes in
        #expect(bytes.count == 52)
        for i in 0..<4 { #expect(bytes[i] == 0) }
        for y in 0..<3 { for p in 10..<16 { #expect(bytes[4 + y * 16 + p] == 0) } }
    }
    // A second writer is refused after sealing.
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
}

@Test func incompatibleDestinationIsRejectedInPreflight() async throws {
    let data = try Fixtures.bytes("g12_5x3_ramp_extremes.kdu.j2k")
    let wrongSize = try ImageDestination.allocate(descriptor: .greyscale16(width: 5, height: 4, meaningfulBits: 12))
    let wrongBits = try ImageDestination.allocate(descriptor: .greyscale16(width: 5, height: 3, meaningfulBits: 16))
    for destination in [wrongSize, wrongBits] {
        do {
            _ = try await Decoder().decode(data, into: destination)
            Issue.record("Incompatible destination accepted")
        } catch let error as CodecError { #expect(error.category == .incompatibleImageLayout) }
        #expect(try destination.writeUInt16 { _, _ in 1 }.sampleUInt16(x: 0, y: 0) == 1)
    }
}

@Test func encoderIgnoresRowPaddingAndReadsSharedStorageOnce() async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g16_17x9_alternating" }!
    let samples = try Fixtures.samples(entry)
    let packed = try makeImage(samples, width: 17, height: 9, bits: 16)
    let padded = try makeImage(samples, width: 17, height: 9, bits: 16, rowBytes: 48, offset: 6)
    let encoder = try Encoder()
    let a = try await encoder.encode(packed).data
    let b = try await encoder.encode(padded).data
    #expect(a == b, "row padding or offset reached the codestream")
    // Concurrent readers of one sealed source agree byte for byte.
    let results = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<4 { group.addTask { try await encoder.encode(padded).data } }
        return try await group.reduce(into: [Data]()) { $0.append($1) }
    }
    #expect(results.allSatisfy { $0 == a })
    // A mutation of the stride must change the samples the encoder sees.
    let decoded = try await Decoder().decode(a)
    // The same bytes viewed through a different stride and offset are a different image.
    let wide: [UInt16] = (0..<(24 * 9)).map { samples[($0 / 24) * 17 + ($0 % 24) % 17] }
    let wrongStride = try ImageDescriptor.greyscale16(width: 17, height: 9, meaningfulBits: 16, rowBytes: 46)
    let sheared = try Image(descriptor: wrongStride, storage: try makeImage(wide, width: 24, height: 9, bits: 16).storage)
    #expect(try await encoder.encode(sheared).data != a)
    try expectSamples(decoded.image, equal: samples, width: 17, height: 9)
}

// MARK: - Malformed input, limits, cancellation

@Test func truncatedCodestreamsFailWithDefinedErrors() async throws {
    let data = [UInt8](try Fixtures.bytes("g12_5x3_ramp_extremes.opj_n2_b16.j2k"))
    let decoder = try Decoder()
    for length in 0..<data.count {
        let prefix = Data(data[0..<length])
        do {
            _ = try await decoder.decode(prefix)
            // Only the EOC marker may be missing from a decodable prefix.
            #expect(length >= data.count - 2, "prefix of \(length) bytes decoded")
        } catch let error as CodecError {
            #expect([.malformedInput, .unsupportedFormat].contains(error.category), "\(length): \(error.message)")
        }
    }
}

@Test func singleBitCorruptionNeverTrapsOrHangs() async throws {
    let data = [UInt8](try Fixtures.bytes("g16_17x9_alternating.kdu_l3.j2k"))
    let decoder = try Decoder()
    // Corrupted geometry may legitimately trip an admission limit; a bounded
    // image must never reach the deadline.
    let options = DecodeOptions(resourceLimits: try ResourceLimits(maximumPixels: 4_000_000, deadlineSeconds: 10))
    var outcomes: [String: Int] = [:]
    var deadlines = 0
    for index in data.indices {
        for bit in [0, 3, 7] {
            var mutated = data
            mutated[index] ^= UInt8(1) << UInt8(bit)
            do {
                _ = try await decoder.decode(Data(mutated), options: options)
                outcomes["decoded", default: 0] += 1
            } catch let error as CodecError {
                outcomes[error.category.rawValue, default: 0] += 1
                if error.message.contains("deadline") { deadlines += 1 }
            }
        }
    }
    #expect(outcomes["internalFailure", default: 0] == 0, "\(outcomes)")
    #expect(deadlines == 0, "\(outcomes)")
}

@Test func headerOnlyInputIsMalformedNotAnImage() async throws {
    let data = [UInt8](try Fixtures.bytes("g16_8x8_zero.kdu.j2k"))
    // Keep the main header, drop every tile-part: SOT is the first 0xFF90.
    var cut = 2
    while !(data[cut] == 0xFF && data[cut + 1] == 0x90) { cut += 1 }
    do {
        _ = try Decoder().inspect(Data(data[0..<cut]))
        Issue.record("main header without tile-parts inspected successfully")
    } catch let error as CodecError { #expect(error.category == .malformedInput) }
    #expect(throws: CodecError.self) { try Decoder().inspect(Data([0xFF, 0xD8, 0xFF, 0xE0])) }
}

@Test func resourceLimitsGateAdmission() async throws {
    let data = try Fixtures.bytes("g16_256x256_smooth.opj.j2k")
    let decoder = try Decoder()
    let cases: [(ResourceLimits, String)] = [
        (try ResourceLimits(maximumPixels: 65535), "pixels"),
        (try ResourceLimits(maximumDimension: 255), "dimension"),
        (try ResourceLimits(maximumCompressedBytes: data.count - 1), "compressed"),
        (try ResourceLimits(maximumWorkspaceBytes: 256 * 256 * 4 - 1), "workspace"),
        (try ResourceLimits(maximumDecodedBytes: 256 * 256 * 2 - 1), "decoded"),
    ]
    for (limits, label) in cases {
        do {
            _ = try await decoder.decode(data, options: .init(resourceLimits: limits))
            Issue.record("\(label) limit not enforced")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded, "\(label)") }
    }
    do {
        _ = try await decoder.decode(data, options: .init(resourceLimits: try ResourceLimits(deadlineSeconds: 0.000001)))
        Issue.record("deadline not enforced")
    } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded && error.message.contains("deadline")) }
}

@Test func cancellationDuringDecodeInvalidatesTheDestination() async throws {
    let data = try Fixtures.bytes("g16_256x256_smooth.opj_b32.j2k")
    let destination = try ImageDestination.allocate(descriptor: .greyscale16(width: 256, height: 256))
    // The progress callback runs on the decoding task, so it can cancel that task
    // itself once real work has started (after admission, before the final write).
    let progress: @Sendable (ProgressUpdate) -> Void = { update in
        guard update.phase == .processing, update.completedUnits > 0 else { return }
        withUnsafeCurrentTask { $0?.cancel() }
    }
    // Cancel a child operation rather than Swift Testing's test task so the test
    // declaration itself completes normally after checking cancellation and cleanup.
    let cancelledOperation = Task {
        do {
            _ = try await Decoder().decode(data, into: destination, options: .init(progress: progress))
            Issue.record("cancelled decode published an image")
            return false
        } catch is CancellationError {
            return true
        }
    }
    #expect(try await cancelledOperation.value)
    #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
}

@Test func progressIsMonotonicAndCompletesAfterPublication() async throws {
    let data = try Fixtures.bytes("g16_256x256_smooth.opj_b32.j2k")
    let updates = Mutex<[ProgressUpdate]>([])
    let decoded = try await Decoder().decode(data, options: .init(progress: { update in
        updates.withLock { $0.append(update) }
    }))
    let recorded = updates.withLock { $0 }
    #expect(recorded.first?.phase == .inspecting && recorded.last?.phase == .completed)
    #expect(recorded.count >= 3)
    var previous = -1
    for update in recorded where update.phase == .processing {
        #expect(update.completedUnits >= previous && update.totalUnits != nil)
        previous = update.completedUnits
    }
    #expect(decoded.image.descriptor.width == 256)
}

// MARK: - Encoder validation

@Test func encoderRejectsSamplesOutsideDeclaredPrecision() async throws {
    let destination = try ImageDestination.allocate(descriptor: .greyscale16(width: 2, height: 1, meaningfulBits: 12))
    let image = try destination.write { bytes in bytes[0] = 0x00; bytes[1] = 0x10; bytes[2] = 1; bytes[3] = 0 }
    do {
        _ = try await Encoder().encode(image)
        Issue.record("out-of-range sample was encoded")
    } catch let error as CodecError { #expect(error.category == .invalidArgument) }
}

@Test func codecOptionsAreValidatedExplicitly() async throws {
    #expect(throws: CodecError.self) { try CodecOptions(decompositionLevels: 33) }
    #expect(throws: CodecError.self) { try CodecOptions(codeBlockWidth: 3) }
    #expect(throws: CodecError.self) { try CodecOptions(codeBlockWidth: 128, codeBlockHeight: 64) }
    #expect(throws: CodecError.self) { try CodecOptions(codeBlockWidth: 2048, codeBlockHeight: 2) }
    let tooDeep = try Encoder(configuration: EncoderConfiguration(codecOptions: try CodecOptions(decompositionLevels: 2)))
    let tiny = try makeImage([1, 2, 3, 4, 5, 6], width: 3, height: 2, bits: 8)
    do {
        _ = try await tooDeep.encode(tiny)
        Issue.record("levels beyond the image were accepted")
    } catch let error as CodecError { #expect(error.category == .invalidArgument) }
    // The automatic level count adapts instead.
    let decoded = try await Decoder().decode(try await Encoder().encode(tiny).data)
    try expectSamples(decoded.image, equal: [1, 2, 3, 4, 5, 6], width: 3, height: 2)
}

@Test func encoderRefusesMetadataItCannotCarry() async throws {
    let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
    let storage = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 9 }.storage
    let annotated = try Image(descriptor: descriptor, storage: storage,
                              metadata: ImageMetadata(entries: ["note": Data([1])]))
    do {
        _ = try await Encoder().encode(annotated)
        Issue.record("metadata silently dropped")
    } catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
}

// MARK: - Component checks

@Test func mqCoderRoundTripsRandomSymbolsOverAllContexts() throws {
    var state: UInt32 = 12345
    var symbols: [(Bool, Int)] = []
    for _ in 0..<20_000 {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        symbols.append(((state >> 7) % 5 == 0, Int(state % 19)))
    }
    var encoder = MQEncoder()
    var contexts = ContextSet()
    for (symbol, context) in symbols { encoder.encode(symbol, context: &contexts.contexts[context]) }
    let bytes = encoder.finish()
    var decoder = try MQDecoder(bytes: bytes, start: 0, end: bytes.count)
    var decodeContexts = ContextSet()
    var errors = 0
    for (symbol, context) in symbols where decoder.decode(context: &decodeContexts.contexts[context]) != symbol {
        errors += 1
    }
    #expect(errors == 0 && bytes.count < 20_000 / 8)
}

@Test func packetBitCoderStuffsAfterFF() throws {
    var writer = PacketBitWriter()
    for _ in 0..<20 { writer.writeBit(true) }
    writer.writeBits(0b1010, count: 4)
    let bytes = writer.finish()
    #expect(bytes[0] == 0xFF && bytes[1] & 0x80 == 0)
    var reader = PacketBitReader(bytes: bytes, start: 0, end: bytes.count)
    for _ in 0..<20 { #expect(try reader.readBit()) }
    #expect(try reader.readBits(4) == 0b1010)
    try reader.alignToByte()
    #expect(reader.position == bytes.count)
}

@Test(arguments: [(1, 1), (1, 9), (9, 1), (2, 3), (33, 17), (64, 64)])
func waveletForwardInverseIsIdentity(width: Int, height: Int) throws {
    var state: UInt32 = 77
    var plane: [Int32] = (0..<(width * height)).map { _ in
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Int32(truncatingIfNeeded: state % 65536) - 32768
    }
    let original = plane
    let levels = min(5, Int.bitWidth - 1 - min(width, height).leadingZeroBitCount)
    for (x0, y0) in [(0, 0), (3, 5), (1, 0), (0, 7), (129, 64)] {
        plane = original
        try Wavelet53.forward(plane: &plane, stride: width, x0: x0, x1: x0 + width, y0: y0, y1: y0 + height, levels: levels) {}
        try Wavelet53.inverse(plane: &plane, stride: width, x0: x0, x1: x0 + width, y0: y0, y1: y0 + height, levels: levels) {}
        #expect(plane == original, "origin (\(x0), \(y0))")
    }
}

@Test func tagTreeEncodesAndDecodesInclusionAndZeroBitPlanes() throws {
    let values: [Int32] = [3, 0, 5, 2, 7, 1, 0, 4, 6]
    var encodeTree = TagTree(width: 3, height: 3)
    for (leaf, value) in values.enumerated() { try encodeTree.setValue(leaf: leaf, value: value) }
    var writer = PacketBitWriter()
    for leaf in 0..<9 { try encodeTree.encode(writer: &writer, leaf: leaf, threshold: values[leaf] + 1) }
    let bytes = writer.finish()
    var decodeTree = TagTree(width: 3, height: 3)
    var reader = PacketBitReader(bytes: bytes, start: 0, end: bytes.count)
    for leaf in 0..<9 {
        var threshold: Int32 = 1
        while try !decodeTree.decode(reader: &reader, leaf: leaf, threshold: threshold) { threshold += 1 }
        #expect(decodeTree.value(leaf: leaf) == values[leaf])
    }
}

// MARK: - Independent oracle decoding of successor output (development hosts only)

enum Oracle {
    static let openJPEG = ["/opt/homebrew/bin/opj_decompress", "/usr/local/bin/opj_decompress"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let kakadu = ["/usr/local/bin/kdu_expand", "/opt/homebrew/bin/kdu_expand"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static var available: Bool { openJPEG != nil || kakadu != nil }

    #if os(macOS) || os(Linux)
    static func decode(_ tool: String, _ input: URL, _ output: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-i", input.path, "-o", output.path] + (tool.contains("kdu") ? ["-quiet"] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus == 0
    }
    #endif
}

/// Missing oracles are recorded as missing coverage by the skip reason; they
/// are never a pass (TEST-01).
@Test(.enabled(if: Oracle.available, "No independent JPEG 2000 decoder installed; oracle coverage unexecuted"),
      .serialized, arguments: Fixtures.manifest.fixtures.map(\.name))
func independentDecodersReadSuccessorCodestreams(name: String) async throws {
    #if os(macOS) || os(Linux)
    let entry = Fixtures.manifest.fixtures.first { $0.name == name }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
    let encoded = try await Encoder().encode(image).data
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-oracle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent(name + ".j2k")
    try encoded.write(to: input)
    for tool in [Oracle.openJPEG, Oracle.kakadu].compactMap({ $0 }) {
        let output = directory.appendingPathComponent(name + (tool.contains("kdu") ? ".kdu" : ".opj") + ".pgm")
        #expect(try Oracle.decode(tool, input, output), "\(tool) rejected the successor codestream")
        let pgm = [UInt8](try Data(contentsOf: output))
        // Locate the raster: header is "P5\n<w> <h>\n<max>\n" possibly with a comment line.
        var fields: [String] = []; var i = 0
        while fields.count < 4 {
            while pgm[i] == 0x20 || pgm[i] == 0x0A || pgm[i] == 0x0D || pgm[i] == 0x09 { i += 1 }
            if pgm[i] == 0x23 { while pgm[i] != 0x0A { i += 1 }; continue }
            var j = i
            while !(pgm[j] == 0x20 || pgm[j] == 0x0A || pgm[j] == 0x0D || pgm[j] == 0x09) { j += 1 }
            fields.append(String(decoding: pgm[i..<j], as: UTF8.self)); i = j
        }
        i += 1
        let maxval = Int(fields[3]) ?? 0
        let decoded: [UInt16] = maxval <= 255
            ? pgm[i..<i + samples.count].map { UInt16($0) }
            : (0..<samples.count).map { UInt16(pgm[i + 2 * $0]) << 8 | UInt16(pgm[i + 2 * $0 + 1]) }
        #expect(decoded == samples, "\(tool) decoded different samples for \(name)")
    }
    #endif
}
