// SPDX-License-Identifier: Apache-2.0
// Development-only experiment. No codec algorithms or compressed inputs.
import Foundation
import Synchronization
import SwiftJ2K
import SwiftJLS
import SwiftJXL
import SwiftJLI

struct ExperimentFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ExperimentFailure(message: message) }
}

final class Metrics: Sendable {
    struct Counts: Sendable { var allocations = 0; var writes = 0; var reads = 0 }
    let counts = Mutex(Counts())
}

final class InstrumentedOwner: SwiftJ2K.WritableImageStorage, Sendable {
    let underlying: SwiftJ2K.OwnedImageStorage
    let metrics: Metrics
    var byteCount: Int { underlying.byteCount }
    var allocationID: UUID { underlying.allocationID }
    init(byteCount: Int, metrics: Metrics) throws {
        underlying = try SwiftJ2K.OwnedImageStorage(byteCount: byteCount)
        self.metrics = metrics
        metrics.counts.withLock { $0.allocations += 1 }
    }
    func reserveWrite() throws -> SwiftJ2K.StorageWriteLease { try underlying.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: SwiftJ2K.StorageWriteLease,
        _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try underlying.withUnsafeMutableBytes(lease: lease) { bytes in
            metrics.counts.withLock { $0.writes += 1 }
            return try body(bytes)
        }
    }
    func finishAndSeal(lease: SwiftJ2K.StorageWriteLease) throws -> any SwiftJ2K.ReadOnlyImageStorage {
        CountingReadOwner(underlying: try underlying.finishAndSeal(lease: lease), metrics: metrics)
    }
    func abortAndInvalidate(lease: SwiftJ2K.StorageWriteLease) throws {
        try underlying.abortAndInvalidate(lease: lease)
    }
}
struct CountingReadOwner: SwiftJ2K.ReadOnlyImageStorage {
    let underlying: any SwiftJ2K.ReadOnlyImageStorage
    let metrics: Metrics
    var byteCount: Int { underlying.byteCount }
    var allocationID: UUID { underlying.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        metrics.counts.withLock { $0.reads += 1 }
        return try underlying.withUnsafeBytes(body)
    }
}

struct SwiftJLSReadAdapter: SwiftJLS.ReadOnlyImageStorage {
    let underlying: any SwiftJ2K.ReadOnlyImageStorage
    var byteCount: Int { underlying.byteCount }
    var allocationID: UUID { underlying.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try underlying.withUnsafeBytes(body)
    }
}

struct SwiftJXLReadAdapter: SwiftJXL.ReadOnlyImageStorage {
    let underlying: any SwiftJ2K.ReadOnlyImageStorage
    var byteCount: Int { underlying.byteCount }
    var allocationID: UUID { underlying.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try underlying.withUnsafeBytes(body)
    }
}

struct SwiftJLIReadAdapter: SwiftJLI.ReadOnlyImageStorage {
    let underlying: any SwiftJ2K.ReadOnlyImageStorage
    var byteCount: Int { underlying.byteCount }
    var allocationID: UUID { underlying.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try underlying.withUnsafeBytes(body)
    }
}

// Local tokens map explicitly to the issuing provider's tokens. No memory/type casts.
final class JLSWriteAdapter: SwiftJLS.WritableImageStorage, Sendable {
    let underlying: any SwiftJ2K.WritableImageStorage
    private let leases = Mutex<[SwiftJLS.StorageWriteLease: SwiftJ2K.StorageWriteLease]>([:])
    var byteCount: Int { underlying.byteCount }
    var allocationID: UUID { underlying.allocationID }
    init(_ underlying: any SwiftJ2K.WritableImageStorage) { self.underlying = underlying }
    private func mapped<R>(_ body: () throws -> R) throws -> R {
        do { return try body() }
        catch let error as SwiftJ2K.CodecError {
            throw SwiftJLS.CodecError(SwiftJLS.CodecError.Category(rawValue: error.category.rawValue) ?? .internalFailure, error.message)
        }
    }
    func reserveWrite() throws -> SwiftJLS.StorageWriteLease {
        try mapped {
            let base = try underlying.reserveWrite()
            let local = SwiftJLS.StorageWriteLease()
            leases.withLock { $0[local] = base }
            return local
        }
    }
    private func resolve(_ local: SwiftJLS.StorageWriteLease) throws -> SwiftJ2K.StorageWriteLease {
        guard let base = leases.withLock({ $0[local] }) else {
            throw SwiftJLS.CodecError(.storageUnavailable, "Unknown adapter lease.")
        }
        return base
    }
    func withUnsafeMutableBytes<R>(lease: SwiftJLS.StorageWriteLease,
        _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try mapped { try underlying.withUnsafeMutableBytes(lease: resolve(lease), body) }
    }
    func finishAndSeal(lease: SwiftJLS.StorageWriteLease) throws -> any SwiftJLS.ReadOnlyImageStorage {
        try mapped {
            let sealed = try underlying.finishAndSeal(lease: resolve(lease))
            leases.withLock { _ = $0.removeValue(forKey: lease) }
            return SwiftJLSReadAdapter(underlying: sealed)
        }
    }
    func abortAndInvalidate(lease: SwiftJLS.StorageWriteLease) throws {
        try mapped {
            try underlying.abortAndInvalidate(lease: resolve(lease))
            leases.withLock { _ = $0.removeValue(forKey: lease) }
        }
    }
}

@main struct ContractExperiment {
    static func main() async throws {
        for precision in [12, 16] {
            let metrics = Metrics()
            let descriptor = try SwiftJ2K.ImageDescriptor.greyscale16(width: 5, height: 3,
                meaningfulBits: precision, rowBytes: 14, offset: 2)
            let owner = try InstrumentedOwner(byteCount: descriptor.requiredByteCount, metrics: metrics)
            let destination = try SwiftJ2K.ImageDestination(descriptor: descriptor, storage: owner)
            let jlsDescriptor = try SwiftJLS.ImageDescriptor.greyscale16(width: 5, height: 3,
                meaningfulBits: precision, rowBytes: 14, offset: 2)
            do {
                _ = try SwiftJLS.ImageDestination(descriptor: jlsDescriptor, storage: JLSWriteAdapter(owner))
                throw ExperimentFailure(message: "A cross-module second writer was accepted.")
            } catch let error as SwiftJLS.CodecError {
                try require(error.category == .storageUnavailable, "Adapter error category changed.")
            }
            let maximum = precision == 12 ? 4095 : 65535
            var writeAddress: UInt = 0 // test-only equality; never dereferenced or logged
            let image = try destination.write { bytes in
                writeAddress = UInt(bitPattern: bytes.baseAddress)
                for y in 0..<3 {
                    for x in 0..<5 {
                        let value = (x + y) % 2 == 0 ? maximum : (x + y * 5)
                        let at = 2 + y * 14 + x * 2
                        bytes[at] = UInt8(value & 255)
                        bytes[at + 1] = UInt8(value >> 8)
                    }
                }
            }
            let jls = try SwiftJLS.Image(descriptor: jlsDescriptor,
                storage: SwiftJLSReadAdapter(underlying: image.storage))
            let jxl = try SwiftJXL.Image(descriptor: .greyscale16(width: 5, height: 3,
                meaningfulBits: precision, rowBytes: 14, offset: 2),
                storage: SwiftJXLReadAdapter(underlying: image.storage))
            let jli = try SwiftJLI.Image(descriptor: .greyscale16(width: 5, height: 3,
                meaningfulBits: precision, rowBytes: 14, offset: 2),
                storage: SwiftJLIReadAdapter(underlying: image.storage))
            try require([jls.storage.allocationID, jxl.storage.allocationID, jli.storage.allocationID]
                .allSatisfy { $0 == owner.allocationID }, "Allocation identity changed across modules.")
            let expectedAddress = writeAddress
            let check: @Sendable (UnsafeRawBufferPointer) throws -> Void = { bytes in
                try require(UInt(bitPattern: bytes.baseAddress) == expectedAddress, "A pixel copy occurred.")
                try require(bytes.count == 44 && bytes[0] == 0 && bytes[1] == 0, "Capacity or prefix changed.")
                for y in 0..<3 {
                    for x in 0..<5 {
                        let at = 2 + y * 14 + x * 2
                        let value = Int(bytes[at]) | Int(bytes[at + 1]) << 8
                        let expected = (x + y) % 2 == 0 ? maximum : (x + y * 5)
                        try require(value == expected, "Logical sample changed.")
                    }
                    for padding in 10..<14 {
                        try require(bytes[2 + y * 14 + padding] == 0, "Padding was not initialised.")
                    }
                }
            }
            try image.storage.withUnsafeBytes(check)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try jls.storage.withUnsafeBytes(check) }
                group.addTask { try jxl.storage.withUnsafeBytes(check) }
                group.addTask { try jli.storage.withUnsafeBytes(check) }
                try await group.waitForAll()
            }
            let counts = metrics.counts.withLock { $0 }
            try require(counts.allocations == 1 && counts.writes == 1 && counts.reads >= 4,
                "Expected owner allocation/borrow instrumentation was not observed.")
            print("PASS: \(precision)-in-16, 5x3 padded storage, 1 pixel allocation, 0 adapter copy bytes, shared identity, concurrent reads, second writer rejected")
        }
        // The opposite adapter direction actually writes through a local lease mapping.
        let metrics = Metrics()
        let owner = try InstrumentedOwner(byteCount: 2, metrics: metrics)
        let destination = try SwiftJLS.ImageDestination(descriptor: .greyscale16(width: 1, height: 1),
            storage: JLSWriteAdapter(owner))
        let image = try destination.write { $0[0] = 255; $0[1] = 255 }
        try require(image.storage.allocationID == owner.allocationID, "Writable adapter changed identity.")
        try image.storage.withUnsafeBytes { try require($0[0] == 255 && $0[1] == 255, "Mapped write failed.") }
        print("PASS: local write-lease mapping and exact UInt16 maximum")
        try await SharedStorageProof.run()
    }
}

// MARK: - Milestone 3: a real codestream through one owner (TESTING TEST-02 shape)

/// Decodes an OpenJPEG-made lossless JPEG 2000 codestream straight into a
/// harness-owned, sentinel-filled allocation, hands a sealed read view of the
/// same owner to the other modules, re-encodes from that owner with SwiftJ2K,
/// and has the reference tools decode the result. SwiftJLS advertises no
/// encoder yet, so the JPEG-LS leg of TEST-02 is attempted and recorded as
/// unexecuted rather than simulated.
enum SharedStorageProof {
    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Lossless")
    static let htj2kFixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/HTJ2K")

    /// Sentinel-filled caller allocation; borrows are counted by the harness.
    final class SentinelOwner: SwiftJ2K.WritableImageStorage, @unchecked Sendable {
        let allocationID = UUID()
        let byteCount: Int
        let allocation: UnsafeMutableRawPointer
        let metrics: Metrics
        private enum Phase { case available, writing(SwiftJ2K.StorageWriteLease), sealed, invalid }
        private let phase = Mutex(Phase.available)
        init(byteCount: Int, metrics: Metrics) {
            self.byteCount = byteCount; self.metrics = metrics
            allocation = .allocate(byteCount: byteCount, alignment: 2)
            allocation.initializeMemory(as: UInt8.self, repeating: 0xA5, count: byteCount)
            metrics.counts.withLock { $0.allocations += 1 }
        }
        deinit { allocation.deallocate() }
        func reserveWrite() throws -> SwiftJ2K.StorageWriteLease {
            try phase.withLock { phase in
                guard case .available = phase else { throw SwiftJ2K.CodecError(.storageUnavailable, "Owner is not available.") }
                let lease = SwiftJ2K.StorageWriteLease(); phase = .writing(lease); return lease
            }
        }
        func withUnsafeMutableBytes<R>(lease: SwiftJ2K.StorageWriteLease, _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
            try phase.withLock { phase in
                guard case .writing(let current) = phase, current == lease else { throw SwiftJ2K.CodecError(.storageUnavailable, "Bad lease.") }
                metrics.counts.withLock { $0.writes += 1 }
                return try body(UnsafeMutableRawBufferPointer(start: allocation, count: byteCount))
            }
        }
        func finishAndSeal(lease: SwiftJ2K.StorageWriteLease) throws -> any SwiftJ2K.ReadOnlyImageStorage {
            try phase.withLock { phase in
                guard case .writing(let current) = phase, current == lease else { throw SwiftJ2K.CodecError(.storageUnavailable, "Bad lease.") }
                phase = .sealed
                return SentinelReadView(owner: self)
            }
        }
        func abortAndInvalidate(lease: SwiftJ2K.StorageWriteLease) throws {
            try phase.withLock { phase in
                guard case .writing(let current) = phase, current == lease else { throw SwiftJ2K.CodecError(.storageUnavailable, "Bad lease.") }
                phase = .invalid
            }
        }
        func read<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
            let sealed = phase.withLock { if case .sealed = $0 { return true }; return false }
            guard sealed else { throw SwiftJ2K.CodecError(.storageUnavailable, "Owner is not sealed.") }
            metrics.counts.withLock { $0.reads += 1 }
            return try body(UnsafeRawBufferPointer(start: allocation, count: byteCount))
        }
    }
    struct SentinelReadView: SwiftJ2K.ReadOnlyImageStorage {
        let owner: SentinelOwner
        var byteCount: Int { owner.byteCount }
        var allocationID: UUID { owner.allocationID }
        func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R { try owner.read(body) }
    }

    static func pgmSamples(_ url: URL, count: Int) throws -> [UInt16] {
        let data = [UInt8](try Data(contentsOf: url))
        var fields: [String] = []; var i = 0
        while fields.count < 4 {
            while data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D || data[i] == 0x09 { i += 1 }
            if data[i] == 0x23 { while data[i] != 0x0A { i += 1 }; continue }
            var j = i
            while !(data[j] == 0x20 || data[j] == 0x0A || data[j] == 0x0D || data[j] == 0x09) { j += 1 }
            fields.append(String(decoding: data[i..<j], as: UTF8.self)); i = j
        }
        i += 1
        if (Int(fields[3]) ?? 0) <= 255 { return data[i..<i + count].map { UInt16($0) } }
        return (0..<count).map { UInt16(data[i + 2 * $0]) << 8 | UInt16(data[i + 2 * $0 + 1]) }
    }

    static func liveHeapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    static func run() async throws {
        let cases: [(name: String, file: String, width: Int, height: Int, bits: Int, prefix: Int, padding: Int)] = [
            ("g12_129x67_gradient", "g12_129x67_gradient.opj.j2k", 129, 67, 12, 6, 10),
            ("g16_17x9_alternating", "g16_17x9_alternating.kdu.j2k", 17, 9, 16, 2, 4),
            ("g16_256x256_smooth", "g16_256x256_smooth.opj_b32.j2k", 256, 256, 16, 0, 0),
        ]
        for c in cases {
            let expected = try pgmSamples(fixturesDirectory.appendingPathComponent(c.name + ".pgm"), count: c.width * c.height)
            let codestream = try Data(contentsOf: fixturesDirectory.appendingPathComponent(c.file))
            let rowBytes = c.width * 2 + c.padding
            let capacity = c.prefix + rowBytes * c.height
            let metrics = Metrics()
            let descriptorsBefore = openDescriptors()
            let heapBefore = liveHeapBytes()

            // 2. One owner, one destination.
            let owner = SentinelOwner(byteCount: capacity, metrics: metrics)
            let descriptor = try SwiftJ2K.ImageDescriptor.greyscale16(width: c.width, height: c.height, meaningfulBits: c.bits, rowBytes: rowBytes, offset: c.prefix)
            let destination = try SwiftJ2K.ImageDestination(descriptor: descriptor, storage: owner)
            let decoder = try SwiftJ2K.Decoder()
            let info = try decoder.inspect(codestream)
            try require(info.descriptor.width == c.width && info.descriptor.meaningfulBits == c.bits, "Inspection disagrees with the fixture.")

            // 3. Decode straight into it.
            let decoded = try await decoder.decode(codestream, into: destination)
            let heapAfterDecode = liveHeapBytes()
            try require(decoded.image.storage.allocationID == owner.allocationID, "Decode changed the allocation identity.")
            try require(decoded.report.pixelAllocationCount == 0 && decoded.report.copyEvents.isEmpty, "Decode reported an allocation or copy.")
            try owner.read { bytes in
                for i in 0..<c.prefix { try require(bytes[i] == 0xA5, "Prefix byte was written.") }
                for y in 0..<c.height {
                    for p in (c.width * 2)..<rowBytes { try require(bytes[c.prefix + y * rowBytes + p] == 0xA5, "Padding byte was written.") }
                    for x in 0..<c.width {
                        let at = c.prefix + y * rowBytes + x * 2
                        try require(UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 == expected[y * c.width + x], "Decoded sample differs.")
                    }
                }
            }

            // 4. The same owner, seen by the other modules through explicit adapters.
            let jlsImage = try SwiftJLS.Image(descriptor: .greyscale16(width: c.width, height: c.height, meaningfulBits: c.bits, rowBytes: rowBytes, offset: c.prefix),
                                              storage: SwiftJLSReadAdapter(underlying: decoded.image.storage))
            try require(jlsImage.storage.allocationID == owner.allocationID, "SwiftJLS adapter changed identity.")
            var jpegLSLeg = "unexecuted: SwiftJLS advertises canEncode == \(SwiftJLS.Encoder.capabilities.canEncode)"
            do {
                _ = try await SwiftJLS.Encoder().encode(jlsImage)
                jpegLSLeg = "executed"
            } catch let error as SwiftJLS.CodecError {
                try require(error.category == .unsupportedFeature, "SwiftJLS failed for an unexpected reason: \(error.message)")
            }

            // Corresponding codec extension: SwiftJ2K re-encodes from the same sealed owner.
            let readsBefore = metrics.counts.withLock { $0.reads }
            let encoded = try await SwiftJ2K.Encoder().encode(decoded.image)
            let readsAfter = metrics.counts.withLock { $0.reads }
            try require(readsAfter == readsBefore + 1, "Encoder did not read the owner exactly once.")
            try require(encoded.report.pixelAllocationCount == 0 && encoded.report.copyEvents.isEmpty, "Encode reported an allocation or copy.")
            let heapAfterEncode = liveHeapBytes()

            // 5. Independent decoders read the re-encoded output.
            var oracles: [String] = []
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-harness-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let input = temporary.appendingPathComponent("re-encoded.j2k")
            try encoded.data.write(to: input)
            for (label, tool, extra) in [("OpenJPEG", "/opt/homebrew/bin/opj_decompress", [String]()), ("Kakadu", "/usr/local/bin/kdu_expand", ["-quiet"])]
            where FileManager.default.isExecutableFile(atPath: tool) {
                let output = temporary.appendingPathComponent(label + ".pgm")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = ["-i", input.path, "-o", output.path] + extra
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                try require(process.terminationStatus == 0, "\(label) rejected the re-encoded codestream.")
                try require(try pgmSamples(output, count: c.width * c.height) == expected, "\(label) decoded different samples.")
                oracles.append(label)
            }

            // 6. Accounting: harness counters, module report and the process allocator.
            let counts = metrics.counts.withLock { $0 }
            try require(counts.allocations == 1 && counts.writes == 1, "Expected exactly one owner allocation and one write borrow.")
            let heldAfterDecode = heapAfterDecode - heapBefore
            try require(heldAfterDecode < capacity + 64 * 1024,
                        "Live heap grew by \(heldAfterDecode) bytes after decode; the coefficient workspace (\(c.width * c.height * 4) bytes) was not released or a second frame is retained.")
            try require(openDescriptors() == descriptorsBefore, "A file descriptor was opened by the library path.")

            // 7. A second writer, and a mutation attempt while readers are active, are refused.
            do {
                _ = try owner.reserveWrite()
                throw ExperimentFailure(message: "A second writer was accepted on the sealed owner.")
            } catch let error as SwiftJ2K.CodecError { try require(error.category == .storageUnavailable, "Unexpected second-writer error.") }

            print("PASS: \(c.name) \(c.width)x\(c.height)@\(c.bits) prefix \(c.prefix) padding \(c.padding): decoded into the caller owner (1 allocation, 1 write borrow, identity kept, padding intact), re-encoded from it (\(readsAfter - readsBefore) read borrow, \(encoded.data.count) bytes, workspace \(encoded.report.peakWorkspaceBytes ?? -1) bytes), live heap +\(heldAfterDecode) B after decode and +\(heapAfterEncode - heapBefore) B after encode, oracles \(oracles.isEmpty ? "none available" : oracles.joined(separator: "+")) exact; JPEG-LS leg \(jpegLSLeg)")
        }

        // Milestone 6: HTJ2K shared-storage decode/encode and native J2K <-> HTJ2K coefficient transcoding.
        let htCases: [(name: String, file: String, width: Int, height: Int, bits: Int, prefix: Int, padding: Int)] = [
            ("g12_129x67_gradient", "g12_129x67_gradient.ojph.j2c", 129, 67, 12, 6, 10),
            ("g16_17x9_alternating", "g16_17x9_alternating.kdu_ht.j2k", 17, 9, 16, 2, 4),
            ("g16_256x256_smooth", "g16_256x256_smooth.ojph_b32.j2c", 256, 256, 16, 0, 0),
        ]
        let transcoder = try SwiftJ2K.Transcoder()
        let htEncoder = try SwiftJ2K.Encoder(configuration: .init(codecOptions: try .init(blockCoding: .htj2k)))
        for c in htCases {
            let expected = try pgmSamples(fixturesDirectory.appendingPathComponent(c.name + ".pgm"), count: c.width * c.height)
            let codestream = try Data(contentsOf: htj2kFixturesDirectory.appendingPathComponent(c.file))
            let rowBytes = c.width * 2 + c.padding
            let capacity = c.prefix + rowBytes * c.height
            let metrics = Metrics()
            let descriptorsBefore = openDescriptors()
            let heapBefore = liveHeapBytes()

            let owner = SentinelOwner(byteCount: capacity, metrics: metrics)
            let descriptor = try SwiftJ2K.ImageDescriptor.greyscale16(width: c.width, height: c.height, meaningfulBits: c.bits, rowBytes: rowBytes, offset: c.prefix)
            let destination = try SwiftJ2K.ImageDestination(descriptor: descriptor, storage: owner)
            let decoder = try SwiftJ2K.Decoder()
            let info = try decoder.inspect(codestream)
            try require(info.format == "htj2k-codestream" && info.descriptor.width == c.width && info.descriptor.meaningfulBits == c.bits, "HTJ2K inspection disagrees with fixture.")

            let decoded = try await decoder.decode(codestream, into: destination)
            let heapAfterDecode = liveHeapBytes()
            try require(decoded.image.storage.allocationID == owner.allocationID, "HTJ2K decode changed allocation identity.")
            try require(decoded.report.pixelAllocationCount == 0 && decoded.report.copyEvents.isEmpty, "HTJ2K decode reported an allocation or copy.")
            try owner.read { bytes in
                for i in 0..<c.prefix { try require(bytes[i] == 0xA5, "HTJ2K prefix byte was written.") }
                for y in 0..<c.height {
                    for p in (c.width * 2)..<rowBytes { try require(bytes[c.prefix + y * rowBytes + p] == 0xA5, "HTJ2K padding byte was written.") }
                    for x in 0..<c.width {
                        let at = c.prefix + y * rowBytes + x * 2
                        try require(UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 == expected[y * c.width + x], "HTJ2K decoded sample differs.")
                    }
                }
            }

            let readsBefore = metrics.counts.withLock { $0.reads }
            let reencodedHT = try await htEncoder.encode(decoded.image)
            let readsAfter = metrics.counts.withLock { $0.reads }
            try require(readsAfter == readsBefore + 1, "HTJ2K encoder did not read the owner exactly once.")
            try require(reencodedHT.encoding.format == "htj2k-codestream" && reencodedHT.report.pixelAllocationCount == 0 && reencodedHT.report.copyEvents.isEmpty, "HTJ2K encode reported an allocation or copy.")

            // Native compressed-to-compressed transcode: HTJ2K -> Part 1 -> HTJ2K.
            let toPart1 = try await transcoder.transcode(codestream, to: .jpeg2000)
            let backToHT = try await transcoder.transcode(toPart1.data, to: .htj2k)
            try require(toPart1.encoding.format == "jpeg2000-codestream" && toPart1.report.pixelAllocationCount == 0 && toPart1.report.copyEvents.isEmpty, "HT->J2K transcode reported pixel allocation or copy.")
            try require(backToHT.encoding.format == "htj2k-codestream" && backToHT.report.pixelAllocationCount == 0 && backToHT.report.copyEvents.isEmpty, "J2K->HT transcode reported pixel allocation or copy.")
            let heapAfterTranscode = liveHeapBytes()

            var oracles: [String] = []
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-ht-harness-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let htInput = temporary.appendingPathComponent("re-encoded.j2c")
            let part1Input = temporary.appendingPathComponent("transcoded.j2k")
            let roundtripHTInput = temporary.appendingPathComponent("transcoded.j2c")
            try reencodedHT.data.write(to: htInput)
            try toPart1.data.write(to: part1Input)
            try backToHT.data.write(to: roundtripHTInput)
            for (label, tool, extra) in [
                ("OpenJPH", "/opt/homebrew/bin/ojph_expand", [String]()),
                ("Kakadu", "/usr/local/bin/kdu_expand", ["-quiet"]),
                ("OpenJPEG", "/opt/homebrew/bin/opj_decompress", [String]()),
            ] where FileManager.default.isExecutableFile(atPath: tool) {
                for (tag, file) in [("ht", htInput), ("rt-ht", roundtripHTInput)] + (label == "OpenJPH" ? [] : [("part1", part1Input)]) {
                    let output = temporary.appendingPathComponent("\(label)-\(tag).pgm")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: tool)
                    process.arguments = ["-i", file.path, "-o", output.path] + extra
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    try require(process.terminationStatus == 0, "\(label) rejected \(tag) codestream.")
                    try require(try pgmSamples(output, count: c.width * c.height) == expected, "\(label) decoded different samples for \(tag).")
                }
                oracles.append(label)
            }

            let counts = metrics.counts.withLock { $0 }
            try require(counts.allocations == 1 && counts.writes == 1, "Expected one HTJ2K owner allocation and one write borrow.")
            let heldAfterDecode = heapAfterDecode - heapBefore
            try require(heldAfterDecode < capacity + 64 * 1024, "Live heap grew by \(heldAfterDecode) B after HTJ2K decode.")
            try require(openDescriptors() == descriptorsBefore, "A file descriptor was opened by the HTJ2K/transcode library path.")

            print("PASS: HTJ2K+Transcode \(c.name) \(c.width)x\(c.height)@\(c.bits) prefix \(c.prefix) padding \(c.padding): HT decoded into caller owner (1 allocation, 1 write borrow, padding intact), HT re-encoded (\(reencodedHT.data.count) B), coefficient-transcoded HT->J2K (\(toPart1.data.count) B, 0 pixel allocs) and J2K->HT (\(backToHT.data.count) B, 0 pixel allocs), live heap +\(heldAfterDecode) B after decode and +\(heapAfterTranscode - heapBefore) B after transcode, oracles \(oracles.isEmpty ? "none available" : oracles.joined(separator: "+")) exact")
        }
    }
}
