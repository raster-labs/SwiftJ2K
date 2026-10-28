// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K

enum HTJ2KFixtures {
    struct DecodeExact: Decodable {
        let kakadu: Bool?
        let openjpeg: Bool?
        let openjph: Bool?
    }
    struct Codestream: Decodable {
        let file: String
        let tool: String
        let bytes: Int
        let sha256: String
        let description: String
        let triangulated: Bool
        let independent_decode_exact: DecodeExact
    }
    struct Entry: Decodable {
        let name: String
        let width: Int
        let height: Int
        let meaningfulBits: Int
        let storageBits: Int
        let minimum: Int
        let maximum: Int
        let pgm_sha256: String
        let sample_digest_le16: String
        let codestreams: [Codestream]
    }
    struct Manifest: Decodable {
        let fixtures: [Entry]
    }

    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/HTJ2K")
    static let manifest: Manifest = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func bytes(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file))
    }

    static let allCodestreams: [(Entry, Codestream)] = manifest.fixtures.flatMap { entry in
        entry.codestreams.map { (entry, $0) }
    }
}

enum HTOracle {
    static let openJPH = ["/opt/homebrew/bin/ojph_expand", "/usr/local/bin/ojph_expand"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }
    static let openJPEG = Oracle.openJPEG
    static let kakadu = Oracle.kakadu
    static var available: Bool { openJPH != nil || openJPEG != nil || kakadu != nil }

    #if os(macOS) || os(Linux)
    static func decodePGM(_ tool: String, _ input: URL, _ output: URL) throws -> [UInt16] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-i", input.path, "-o", output.path] + (tool.contains("kdu") ? ["-quiet"] : [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) exited with \(process.terminationStatus) on \(input.lastPathComponent)")
        let pgm = [UInt8](try Data(contentsOf: output))
        var fields: [String] = []
        var i = 0
        while fields.count < 4 {
            while pgm[i] == 0x20 || pgm[i] == 0x0A || pgm[i] == 0x0D || pgm[i] == 0x09 { i += 1 }
            if pgm[i] == 0x23 { while pgm[i] != 0x0A { i += 1 }; continue }
            var j = i
            while !(pgm[j] == 0x20 || pgm[j] == 0x0A || pgm[j] == 0x0D || pgm[j] == 0x09) { j += 1 }
            fields.append(String(decoding: pgm[i..<j], as: UTF8.self))
            i = j
        }
        i += 1
        let width = Int(fields[1]) ?? 0
        let height = Int(fields[2]) ?? 0
        let count = width * height
        let maxval = Int(fields[3]) ?? 0
        return maxval <= 255
            ? pgm[i..<i + count].map { UInt16($0) }
            : (0..<count).map { UInt16(pgm[i + 2 * $0]) << 8 | UInt16(pgm[i + 2 * $0 + 1]) }
    }
    #endif
}

// MARK: - 1. Independent HTJ2K fixture decoding (all 120 OpenJPH and Kakadu codestreams)

@Test(arguments: HTJ2KFixtures.allCodestreams.map { "\($0.0.name)|\($0.1.file)" })
func allHTJ2KFixturesDecodeToExactSamples(key: String) async throws {
    let (entry, codestream) = HTJ2KFixtures.allCodestreams.first { "\($0.0.name)|\($0.1.file)" == key }!
    let losslessEntry = Fixtures.manifest.fixtures.first { $0.name == entry.name }!
    let data = try HTJ2KFixtures.bytes(codestream.file)
    #expect(data.count == codestream.bytes)
    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.format == "htj2k-codestream")
    #expect(info.descriptor.width == entry.width && info.descriptor.height == entry.height)
    #expect(info.descriptor.meaningfulBits == entry.meaningfulBits && info.frameCount == 1)
    let decoded = try await decoder.decode(data)
    #expect(decoded.report.backend == .accelerated && decoded.report.fidelity == .exactSamples)
    #expect(decoded.report.copyEvents.isEmpty && decoded.report.pixelAllocationCount == 1)
    #expect(decoded.report.peakPixelBytes == entry.width * entry.height * 2)
    try expectSamples(decoded.image, equal: try Fixtures.samples(losslessEntry), width: entry.width, height: entry.height)
}

// MARK: - 2. Lossless HTJ2K encoding and round trips

@Test(arguments: Fixtures.manifest.fixtures.map(\.name))
func htj2kEncoderOutputDecodesExactlyWithDefaultOptions(name: String) async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == name }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
    let encoder = try Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: try CodecOptions(blockCoding: .htj2k)
    ))
    let encoded = try await encoder.encode(image)
    #expect(encoded.encoding.format == "htj2k-codestream" && encoded.encoding.mode == .lossless)
    #expect(encoded.report.copyEvents.isEmpty && encoded.report.pixelAllocationCount == 0)
    #expect(encoded.data.prefix(2) == Data([0xFF, 0x4F]) && encoded.data.suffix(2) == Data([0xFF, 0xD9]))

    let parsed = try CodestreamSyntax.parse([UInt8](encoded.data), limits: try ResourceLimits())
    #expect(parsed.isHTJ2K)
    #expect(parsed.size.capabilities == 0x4000)
    #expect(parsed.extendedCapabilities?.pcap == 0x0002_0000)
    #expect(parsed.extendedCapabilities?.mode == .htOnly)
    #expect(parsed.extendedCapabilities?.multiHT == false)
    #expect(parsed.extendedCapabilities?.irreversible == false)
    #expect(parsed.codingStyle.codeBlockStyle == 0x40)

    let decoder = try Decoder()
    let info = try decoder.inspect(encoded.data)
    #expect(info.format == "htj2k-codestream")
    let decoded = try await decoder.decode(encoded.data)
    #expect(decoded.image.descriptor.meaningfulBits == entry.meaningfulBits)
    try expectSamples(decoded.image, equal: samples, width: entry.width, height: entry.height)
}

@Test(arguments: [(0, 64, 64), (1, 16, 16), (2, 32, 8), (3, 4, 4), (5, 64, 64), (6, 8, 512)])
func htj2kEncoderOptionsRoundTrip(levels: Int, blockWidth: Int, blockHeight: Int) async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g12_129x67_gradient" }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
    let options = try CodecOptions(
        decompositionLevels: levels,
        codeBlockWidth: blockWidth,
        codeBlockHeight: blockHeight,
        blockCoding: .htj2k
    )
    let encoder = try Encoder(configuration: EncoderConfiguration(codecOptions: options))
    let encoded = try await encoder.encode(image)
    #expect(encoded.encoding.format == "htj2k-codestream")
    let decoded = try await Decoder().decode(encoded.data)
    try expectSamples(decoded.image, equal: samples, width: entry.width, height: entry.height)

    #if os(macOS) || os(Linux)
    if HTOracle.available {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-ht-opts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("opts_\(levels)_\(blockWidth)x\(blockHeight).j2c")
        try encoded.data.write(to: input)
        for (label, tool) in [("ojph", HTOracle.openJPH), ("kdu", HTOracle.kakadu), ("opj", HTOracle.openJPEG)] {
            guard let tool else { continue }
            let output = directory.appendingPathComponent("out.\(label).pgm")
            let oracleDecoded = try HTOracle.decodePGM(tool, input, output)
            #expect(oracleDecoded == samples, "\(tool) mismatch for levels=\(levels) block=\(blockWidth)x\(blockHeight)")
        }
    }
    #endif
}

@Test(arguments: [(1, 1), (1, 7), (7, 1), (2, 2), (3, 5), (65, 1), (1, 65), (17, 33)])
func htj2kDegenerateGeometriesRoundTrip(width: Int, height: Int) async throws {
    var state: UInt32 = 0x85EB_CA6B
    let samples: [UInt16] = (0..<(width * height)).map { _ in
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return UInt16(truncatingIfNeeded: state)
    }
    let image = try makeImage(samples, width: width, height: height, bits: 16)
    let encoder = try Encoder(configuration: EncoderConfiguration(
        codecOptions: try CodecOptions(blockCoding: .htj2k)
    ))
    let encoded = try await encoder.encode(image)
    let decoded = try await Decoder().decode(encoded.data)
    try expectSamples(decoded.image, equal: samples, width: width, height: height)
}

@Test func htj2kExtremeValuesAndKMaxReversibleGainRegression() async throws {
    let encoder = try Encoder(configuration: EncoderConfiguration(
        codecOptions: try CodecOptions(blockCoding: .htj2k)
    ))
    for bits in [1, 2, 7, 8, 9, 10, 12, 15, 16] {
        let maximum = UInt16((1 << bits) - 1)
        var samples: [UInt16] = []
        for index in 0..<(16 * 16) {
            let x = index % 16, y = index / 16
            // High-contrast alternating blocks and impulses that produce 5/3 wavelet
            // coefficients exceeding 2^B - 1 (reproducing the htj2k_lossless_fail_min condition).
            let value: UInt16
            if (x + y) % 2 == 0 {
                value = maximum
            } else if x % 4 == 0 && y % 4 == 0 {
                value = 0
            } else {
                value = (UInt16(index * 97) & maximum)
            }
            samples.append(value)
        }
        let image = try makeImage(samples, width: 16, height: 16, bits: bits)
        let encoded = try await encoder.encode(image)
        let decoded = try await Decoder().decode(encoded.data)
        #expect(decoded.image.descriptor.meaningfulBits == bits)
        try expectSamples(decoded.image, equal: samples, width: 16, height: 16)
    }

    // Verify magnitude scaling by 2^(K_max - 1 - missingMSBs) when missingMSBs < K_max - 1.
    let rawCoeffs: [Int32] = [0, 8, -16, 24, -32, 0, 40, -48,
                              16, 0, -8, 64, 0, -24, 8, 0]
    let kMax = 10
    let missingMSBs = 6 // bandShift = 10 - 1 - 6 = 3 (scale by 8)
    let encodedBlock = try HTBlockEncoder.encodeCleanup(
        coefficients: rawCoeffs,
        width: 4,
        height: 4,
        bandShift: 3
    )
    let decodedBlock = try HTBlockDecoder.decodeCleanup(
        block: encodedBlock,
        width: 4,
        height: 4,
        kMax: kMax,
        missingMSBs: missingMSBs
    )
    #expect(decodedBlock == rawCoeffs)
}

// MARK: - 3. Independent oracle verification of SwiftJ2K HTJ2K encoder output

@Test(.enabled(if: HTOracle.available, "No independent HTJ2K decoder installed; oracle coverage unexecuted"),
      .serialized, arguments: Fixtures.manifest.fixtures.map(\.name))
func independentHTDecodersReadSuccessorHTJ2KCodestreams(name: String) async throws {
    #if os(macOS) || os(Linux)
    let entry = Fixtures.manifest.fixtures.first { $0.name == name }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
    let encoder = try Encoder(configuration: EncoderConfiguration(
        codecOptions: try CodecOptions(blockCoding: .htj2k)
    ))
    let encoded = try await encoder.encode(image).data
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-ht-oracle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent(name + ".j2c")
    try encoded.write(to: input)
    for (label, tool) in [("ojph", HTOracle.openJPH), ("kdu", HTOracle.kakadu), ("opj", HTOracle.openJPEG)] {
        guard let tool else { continue }
        let output = directory.appendingPathComponent("\(name).\(label).pgm")
        let decoded = try HTOracle.decodePGM(tool, input, output)
        #expect(decoded == samples, "\(tool) decoded different samples for \(name)")
    }
    #endif
}

// MARK: - 4. Native J2K <-> HTJ2K compressed-to-compressed transcoding

@Test(arguments: Fixtures.manifest.fixtures.map(\.name))
func nativeTranscodeRoundTripsPart1AndHTJ2KInCoefficientDomain(name: String) async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == name }!
    let expectedSamples = try Fixtures.samples(entry)
    let part1Source = try Fixtures.bytes(entry.codestreams[0].file)
    let htSource = try HTJ2KFixtures.bytes("\(name).ojph.j2c")

    let transcoder = try Transcoder(configuration: .init(mode: .lossless))
    let decoder = try Decoder()

    // 1. Part 1 -> HTJ2K -> Part 1
    let limits = try ResourceLimits()
    let sourcePart1Bytes = [UInt8](part1Source)
    let sourcePart1Profile = try ScalarLosslessCodec.inspect(sourcePart1Bytes, limits: limits)
    let sourcePart1Coeffs = try ScalarLosslessCodec.extractTileCoefficients(bytes: sourcePart1Bytes, profile: sourcePart1Profile)

    let toHT = try await transcoder.transcode(part1Source, to: .htj2k)
    #expect(toHT.encoding.format == "htj2k-codestream" && toHT.encoding.mode == .lossless)
    #expect(toHT.report.backend == .accelerated && toHT.report.fidelity == .exactSamples)
    #expect(toHT.report.copyEvents.isEmpty)
    #expect(toHT.report.pixelAllocationCount == 0 && toHT.report.peakPixelBytes == 0)
    #expect((toHT.report.peakWorkspaceBytes ?? 0) > 0)

    let toHTBytes = [UInt8](toHT.data)
    let toHTProfile = try ScalarLosslessCodec.inspect(toHTBytes, limits: limits)
    let toHTCoeffs = try ScalarLosslessCodec.extractTileCoefficients(bytes: toHTBytes, profile: toHTProfile)
    #expect(toHTCoeffs == sourcePart1Coeffs, "Transcoded HTJ2K wavelet coefficients must match Part 1 source coefficients exactly")

    let decodedHT = try await decoder.decode(toHT.data)
    #expect(decodedHT.image.descriptor.meaningfulBits == entry.meaningfulBits)
    try expectSamples(decodedHT.image, equal: expectedSamples, width: entry.width, height: entry.height)

    let backToPart1 = try await transcoder.transcode(toHT.data, to: .jpeg2000)
    #expect(backToPart1.encoding.format == "jpeg2000-codestream" && backToPart1.encoding.mode == .lossless)
    #expect(backToPart1.report.copyEvents.isEmpty)
    #expect(backToPart1.report.pixelAllocationCount == 0 && backToPart1.report.peakPixelBytes == 0)

    let decodedPart1 = try await decoder.decode(backToPart1.data)
    try expectSamples(decodedPart1.image, equal: expectedSamples, width: entry.width, height: entry.height)

    // 2. Independent OpenJPH HTJ2K -> Part 1 -> HTJ2K
    let ojphToPart1 = try await transcoder.transcode(htSource, to: .jpeg2000)
    #expect(ojphToPart1.encoding.format == "jpeg2000-codestream")
    #expect(ojphToPart1.report.pixelAllocationCount == 0 && ojphToPart1.report.copyEvents.isEmpty)
    try expectSamples(try await decoder.decode(ojphToPart1.data).image,
                      equal: expectedSamples, width: entry.width, height: entry.height)

    let backToHT = try await transcoder.transcode(ojphToPart1.data, to: .htj2k)
    #expect(backToHT.encoding.format == "htj2k-codestream")
    #expect(backToHT.report.pixelAllocationCount == 0 && backToHT.report.copyEvents.isEmpty)
    try expectSamples(try await decoder.decode(backToHT.data).image,
                      equal: expectedSamples, width: entry.width, height: entry.height)
}

@Test func nativeTranscodeHandlesMultiTileMultiLayerPrecinctsAndReblocking() async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g16_64x64_random" }!
    let expected = try Fixtures.samples(entry)
    let decoder = try Decoder()
    let transcoder = try Transcoder()

    let limits = try ResourceLimits()
    // Multi-tile Part 1 <-> HTJ2K preserves tile grid when levels match.
    let part1Tiled = try Fixtures.bytes("g16_64x64_random.tiled.j2k")
    let htFromTiled = try await transcoder.transcode(part1Tiled, to: .htj2k)
    let parsedHTTiled = try CodestreamSyntax.parse([UInt8](htFromTiled.data), limits: limits)
    #expect(parsedHTTiled.isHTJ2K && parsedHTTiled.tileParts.count == 4)
    try expectSamples(try await decoder.decode(htFromTiled.data).image, equal: expected, width: 64, height: 64)

    let part1FromHTTiled = try await transcoder.transcode(htFromTiled.data, to: .jpeg2000)
    let parsedPart1Tiled = try CodestreamSyntax.parse([UInt8](part1FromHTTiled.data), limits: limits)
    #expect(!parsedPart1Tiled.isHTJ2K && parsedPart1Tiled.tileParts.count == 4)
    try expectSamples(try await decoder.decode(part1FromHTTiled.data).image, equal: expected, width: 64, height: 64)

    // Multi-layer HTJ2K, precincts HTJ2K, and mixed HT/Part 1 -> Part 1.
    for variant in ["kdu_ht_layers", "kdu_ht_precincts", "kdu_htmix", "kdu_ht_tiles"] {
        let htBytes = try HTJ2KFixtures.bytes("g16_64x64_random.\(variant).j2k")
        let transcoded = try await transcoder.transcode(htBytes, to: .jpeg2000)
        #expect(transcoded.report.pixelAllocationCount == 0 && transcoded.report.copyEvents.isEmpty)
        try expectSamples(try await decoder.decode(transcoded.data).image, equal: expected, width: 64, height: 64)
    }

    // Re-blocking in the coefficient domain preserves wavelet coefficients without wavelet transforms.
    let reblockTranscoder = try Transcoder(configuration: .init(
        mode: .lossless,
        codecOptions: try CodecOptions(codeBlockWidth: 16, codeBlockHeight: 16)
    ))
    let reblockedHT = try await reblockTranscoder.transcode(part1Tiled, to: .htj2k)
    #expect(reblockedHT.report.pixelAllocationCount == 0 && reblockedHT.report.copyEvents.isEmpty)
    try expectSamples(try await decoder.decode(reblockedHT.data).image, equal: expected, width: 64, height: 64)

    // M6-AUD-001 regression: Source 64x64, levels 0, block 64x64 (1 source block) transcoded
    // to target block 4x4 (256 target blocks) with and without progress callback.
    let image64 = try makeImage(expected, width: 64, height: 64, bits: 16)
    let singleBlockSource = try await Encoder(configuration: .init(
        codecOptions: try CodecOptions(decompositionLevels: 0, codeBlockWidth: 64, codeBlockHeight: 64, blockCoding: .part1)
    )).encode(image64).data
    let fineReblockTranscoder = try Transcoder(configuration: .init(
        mode: .lossless,
        codecOptions: try CodecOptions(codeBlockWidth: 4, codeBlockHeight: 4)
    ))
    let withoutCallback = try await fineReblockTranscoder.transcode(singleBlockSource, to: .htj2k)
    let recordedUpdates = Mutex<[ProgressUpdate]>([])
    let withCallback = try await fineReblockTranscoder.transcode(
        singleBlockSource,
        to: .htj2k,
        options: .init(progress: { update in
            recordedUpdates.withLock { $0.append(update) }
        })
    )
    #expect(withoutCallback.data == withCallback.data)
    let updates = recordedUpdates.withLock { $0 }
    #expect(updates.first?.phase == .inspecting && updates.last?.phase == .completed)
    let processingUpdates = updates.filter { $0.phase == .processing }
    #expect(!processingUpdates.isEmpty)
    var prevCompleted = -1
    for u in processingUpdates {
        #expect(u.totalUnits == 1 + 256)
        #expect(u.completedUnits >= prevCompleted && u.completedUnits <= (u.totalUnits ?? 0))
        prevCompleted = u.completedUnits
    }
    try expectSamples(try await decoder.decode(withCallback.data).image, equal: expected, width: 64, height: 64)

    // M6-AUD-002 regression:Changing decomposition levels is rejected on the pure coefficient path (.unsupportedFeature),
    // and multi-tile codestreams with differing per-tile COD/QCD decomposition levels preserve each tile's levels
    // in the coefficient domain without invoking wavelet reconstruction.
    let levelChangeTranscoder = try Transcoder(configuration: .init(
        mode: .lossless,
        codecOptions: try CodecOptions(decompositionLevels: 1, codeBlockWidth: 16, codeBlockHeight: 16)
    ))
    do {
        _ = try await levelChangeTranscoder.transcode(part1Tiled, to: .htj2k)
        Issue.record("Changing decomposition levels was accepted on the coefficient path")
    } catch let error as CodecError {
        #expect(error.category == .unsupportedFeature)
    }

    // Construct a 2-tile 16x8 Part 1 codestream (two 8x8 tiles) where Tile 0 uses 1 level (main COD)
    // and Tile 1 overrides COD/QCD in its tile-part header to 2 levels.
    let tile0Samples: [UInt16] = (0..<64).map { UInt16(($0 * 17) & 0xFF) }
    let tile1Samples: [UInt16] = (0..<64).map { UInt16((($0 * 31) + 7) & 0xFF) }
    var fullSamples = [UInt16](repeating: 0, count: 16 * 8)
    for y in 0..<8 {
        for x in 0..<8 {
            fullSamples[y * 16 + x] = tile0Samples[y * 8 + x]
            fullSamples[y * 16 + (8 + x)] = tile1Samples[y * 8 + x]
        }
    }
    let t0Encoded = [UInt8](try await Encoder(configuration: .init(
        codecOptions: try CodecOptions(decompositionLevels: 1, codeBlockWidth: 8, codeBlockHeight: 8, blockCoding: .part1)
    )).encode(try makeImage(tile0Samples, width: 8, height: 8, bits: 8)).data)
    let t1Encoded = [UInt8](try await Encoder(configuration: .init(
        codecOptions: try CodecOptions(decompositionLevels: 2, codeBlockWidth: 8, codeBlockHeight: 8, blockCoding: .part1)
    )).encode(try makeImage(tile1Samples, width: 8, height: 8, bits: 8)).data)
    let parsedT0 = try CodestreamSyntax.parse(t0Encoded, limits: limits)
    let parsedT1 = try CodestreamSyntax.parse(t1Encoded, limits: limits)
    var multiLevelTilesWriter = ByteWriter()
    multiLevelTilesWriter.writeUInt16(Marker.soc)
    try CodestreamSyntax.writeSIZ(
        ImageSizeSegment(
            capabilities: 0, width: 16, height: 8, originX: 0, originY: 0,
            tileWidth: 8, tileHeight: 8, tileOriginX: 0, tileOriginY: 0,
            components: [ComponentSignalling(precision: 8, signed: false, horizontalSeparation: 1, verticalSeparation: 1)]
        ),
        into: &multiLevelTilesWriter
    )
    try CodestreamSyntax.writeCOD(parsedT0.codingStyle, into: &multiLevelTilesWriter)
    try CodestreamSyntax.writeQCD(parsedT0.quantization, into: &multiLevelTilesWriter)
    // Tile 0 (uses main COD/QCD, 1 level)
    let t0Body = Array(t0Encoded[parsedT0.tileParts[0].dataRange])
    multiLevelTilesWriter.writeUInt16(Marker.sot)
    multiLevelTilesWriter.writeUInt16(10)
    multiLevelTilesWriter.writeUInt16(0)
    multiLevelTilesWriter.writeUInt32(UInt32(14 + t0Body.count))
    multiLevelTilesWriter.writeUInt8(0)
    multiLevelTilesWriter.writeUInt8(1)
    multiLevelTilesWriter.writeUInt16(Marker.sod)
    multiLevelTilesWriter.writeBytes(t0Body)
    // Tile 1 (tile-part COD/QCD override, 2 levels)
    var t1Header = ByteWriter()
    try CodestreamSyntax.writeCOD(parsedT1.codingStyle, into: &t1Header)
    try CodestreamSyntax.writeQCD(parsedT1.quantization, into: &t1Header)
    let t1Body = Array(t1Encoded[parsedT1.tileParts[0].dataRange])
    multiLevelTilesWriter.writeUInt16(Marker.sot)
    multiLevelTilesWriter.writeUInt16(10)
    multiLevelTilesWriter.writeUInt16(1)
    multiLevelTilesWriter.writeUInt32(UInt32(14 + t1Header.count + t1Body.count))
    multiLevelTilesWriter.writeUInt8(0)
    multiLevelTilesWriter.writeUInt8(1)
    multiLevelTilesWriter.writeBytes(t1Header.bytes)
    multiLevelTilesWriter.writeUInt16(Marker.sod)
    multiLevelTilesWriter.writeBytes(t1Body)
    multiLevelTilesWriter.writeUInt16(Marker.eoc)

    let mixedLevelsPart1 = Data(multiLevelTilesWriter.bytes)
    let mixedLevelsHT = try await transcoder.transcode(mixedLevelsPart1, to: .htj2k)
    let parsedMixedHT = try CodestreamSyntax.parse([UInt8](mixedLevelsHT.data), limits: limits)
    #expect(parsedMixedHT.isHTJ2K && parsedMixedHT.tileParts.count == 2)
    #expect(parsedMixedHT.codingStyle.decompositionLevels == 1)
    #expect(parsedMixedHT.tileOverrides[1]?.codingStyle?.decompositionLevels == 2)
    try expectSamples(try await decoder.decode(mixedLevelsHT.data).image, equal: fullSamples, width: 16, height: 8)
    let mixedLevelsBackToPart1 = try await transcoder.transcode(mixedLevelsHT.data, to: .jpeg2000)
    try expectSamples(try await decoder.decode(mixedLevelsBackToPart1.data).image, equal: fullSamples, width: 16, height: 8)
}

@Test(.enabled(if: HTOracle.available, "No independent HTJ2K decoder installed; oracle coverage unexecuted"),
      .serialized, arguments: ["g12_5x3_ramp_extremes", "g16_17x9_alternating", "g16_64x64_random", "g12_129x67_gradient"])
func independentOraclesVerifyTranscodedOutputsInBothDirections(name: String) async throws {
    #if os(macOS) || os(Linux)
    let transcoder = try Transcoder()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-transcode-oracle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let entry = Fixtures.manifest.fixtures.first { $0.name == name }!
    let expected = try Fixtures.samples(entry)
    let part1Input = try Fixtures.bytes(entry.codestreams[0].file)
    let htInput = try HTJ2KFixtures.bytes("\(name).kdu_ht.j2k")

    let transcodedHT = try await transcoder.transcode(part1Input, to: .htj2k).data
    let htFile = directory.appendingPathComponent("\(name).transcoded.j2c")
    try transcodedHT.write(to: htFile)
    for (label, tool) in [("ojph", HTOracle.openJPH), ("kdu", HTOracle.kakadu), ("opj", HTOracle.openJPEG)] {
        guard let tool else { continue }
        let outPGM = directory.appendingPathComponent("\(name).ht.\(label).pgm")
        #expect(try HTOracle.decodePGM(tool, htFile, outPGM) == expected, "\(tool) failed on transcoded HTJ2K \(name)")
    }

    let transcodedPart1 = try await transcoder.transcode(htInput, to: .jpeg2000).data
    let part1File = directory.appendingPathComponent("\(name).transcoded.j2k")
    try transcodedPart1.write(to: part1File)
    for (label, tool) in [("kdu", HTOracle.kakadu), ("opj", HTOracle.openJPEG)] {
        guard let tool else { continue }
        let outPGM = directory.appendingPathComponent("\(name).part1.\(label).pgm")
        #expect(try HTOracle.decodePGM(tool, part1File, outPGM) == expected, "\(tool) failed on transcoded Part 1 \(name)")
    }
    #endif
}

// MARK: - 5. Signalling validation and unsupported feature rejection

@Test func htSignallingAndUnsupportedPassStructuresFailPredictably() async throws {
    let decoder = try Decoder()
    let transcoder = try Transcoder()

    // Base valid HTJ2K codestream from our encoder (1x1 image):
    // SOC (0..1), SIZ (2..43), CAP (44..53), COD (54..67), QCD (68..), SOT ...
    let image = try makeImage([42], width: 1, height: 1, bits: 8)
    let validHT = [UInt8](try await Encoder(configuration: .init(
        codecOptions: try CodecOptions(decompositionLevels: 0, blockCoding: .htj2k)
    )).encode(image).data)
    let validPart1 = [UInt8](try await Encoder(configuration: .init(
        codecOptions: try CodecOptions(decompositionLevels: 0, blockCoding: .part1)
    )).encode(image).data)

    // 1. Part 1 stream with Rsiz changed to 0x4000 but no CAP marker -> .malformedInput
    var rsizWithoutCAP = validPart1
    rsizWithoutCAP[6] = 0x40; rsizWithoutCAP[7] = 0x00
    #expect(throws: CodecError.self) { try decoder.inspect(Data(rsizWithoutCAP)) }
    do { _ = try decoder.inspect(Data(rsizWithoutCAP)) }
    catch let error as CodecError { #expect(error.category == .malformedInput) }

    // 2. HT stream with Rsiz cleared to 0x0000 while CAP is present -> .malformedInput
    var capWithoutRsiz = validHT
    capWithoutRsiz[6] = 0x00; capWithoutRsiz[7] = 0x00
    do { _ = try decoder.inspect(Data(capWithoutRsiz)); Issue.record("CAP without Rsiz=0x4000 accepted") }
    catch let error as CodecError { #expect(error.category == .malformedInput) }

    // 3. Part 1 stream with COD code-block style set to 0x40 without CAP -> .malformedInput
    var codHTWithoutCAP = validPart1
    // In validPart1, SOC is 0..1, SIZ is 2..44 (Lsiz = 41, ends at 45), COD marker 0xFF52 is at 45..46,
    // Lcod at 47..48, Scod at 49, SGcod at 50..53, SPcod levels at 54, xcb at 55, ycb at 56, style at 57.
    codHTWithoutCAP[57] = 0x40
    do { _ = try decoder.inspect(Data(codHTWithoutCAP)); Issue.record("COD 0x40 without CAP accepted") }
    catch let error as CodecError { #expect(error.category == .malformedInput) }

    // 4. HT stream with CAP HTONLY (bits 14..15 == 0) but COD style 0x00 (Part 1) -> .malformedInput
    // In validHT, CAP is at 45..54 (10 bytes: FF50 at 45..46, 0008 at 47..48, Pcap at 49..52, Ccap15 at 53..54),
    // COD is at 55..68, style at 67.
    var capHTOnlyWithPart1COD = validHT
    capHTOnlyWithPart1COD[67] = 0x00
    do { _ = try decoder.inspect(Data(capHTOnlyWithPart1COD)); Issue.record("HTONLY with Part 1 COD accepted") }
    catch let error as CodecError { #expect(error.category == .malformedInput) }

    // 5. HT stream with CAP HTONLY but COD style 0xC0 (mixed) -> .malformedInput
    var capHTOnlyWithMixedCOD = validHT
    capHTOnlyWithMixedCOD[67] = 0xC0
    do { _ = try decoder.inspect(Data(capHTOnlyWithMixedCOD)); Issue.record("HTONLY with 0xC0 COD accepted") }
    catch let error as CodecError { #expect(error.category == .malformedInput) }

    // 6. CAP with MULTIHT (bit 12 of Ccap15 set: byte 53 |= 0x10) -> .unsupportedFeature
    var multiHT = validHT
    multiHT[53] |= 0x10
    do { _ = try decoder.inspect(Data(multiHT)); Issue.record("MULTIHT accepted") }
    catch let error as CodecError { #expect(error.category == .unsupportedFeature) }

    // 7. CAP with HTIRV (bit 5 of Ccap15 set: byte 54 |= 0x20) -> .unsupportedFeature
    var irreversibleHT = validHT
    irreversibleHT[54] |= 0x20
    do { _ = try decoder.inspect(Data(irreversibleHT)); Issue.record("HTIRV accepted") }
    catch let error as CodecError { #expect(error.category == .unsupportedFeature) }

    // 8. CAP with non-Part-15 Pcap bit -> .unsupportedFeature
    var unknownPcap = validHT
    unknownPcap[49] = 0x00; unknownPcap[50] = 0x01
    do { _ = try decoder.inspect(Data(unknownPcap)); Issue.record("Unknown Pcap accepted") }
    catch let error as CodecError { #expect(error.category == .unsupportedFeature) }

    // 9. Valid CPF marker (0xFF59) in main header is accepted; odd-length CPF is .malformedInput.
    var withCPF: [UInt8] = Array(validHT[0..<55])
    var cpfWriter = ByteWriter()
    try CodestreamSyntax.writeCPF(CorrespondingProfileSegment(values: [0x0001]), into: &cpfWriter)
    withCPF.append(contentsOf: cpfWriter.bytes)
    withCPF.append(contentsOf: validHT[55...])
    #expect(try decoder.inspect(Data(withCPF)).format == "htj2k-codestream")

    var oddCPF: [UInt8] = Array(validHT[0..<55])
    oddCPF.append(contentsOf: [0xFF, 0x59, 0x00, 0x03, 0x00])
    oddCPF.append(contentsOf: validHT[55...])
    do { _ = try decoder.inspect(Data(oddCPF)); Issue.record("Odd-length CPF accepted") }
    catch let error as CodecError { #expect(error.category == .malformedInput) }

    // 10. HTJ2K codestream with refinement pass signalling (codeBlockStyle 0x41 and 2 passes) -> .unsupportedFeature
    var htRefinementStream = validHT
    htRefinementStream[67] = 0x41 // HT + SigProp/MagRef refinement segment enabled
    // Construct a 1-block packet with 2 passes (Lcup = 4 bytes, Lref = 2 bytes):
    // bit 0: 1 (non-empty packet)
    // bit 1: 1 (included)
    // bits 2..9: 00000001 (zeroBitPlanes = 7 -> 7 zeros + 1)
    // bits 10..11: 10 (passCount = 2)
    // bit 12: 0 (lblock stays 3)
    // bits 13..15: 100 (Lcup = 4 bytes, 3 bits)
    // bits 16..18: 010 (Lref = 2 bytes, 3 bits)
    var refPacket = PacketBitWriter()
    refPacket.writeBit(true)
    refPacket.writeBit(true)
    for _ in 0..<7 { refPacket.writeBit(false) }
    refPacket.writeBit(true)
    try Tier2.writePassCount(2, &refPacket)
    refPacket.writeBit(false)
    refPacket.writeBits(4, count: 3)
    refPacket.writeBits(2, count: 3)
    let refPacketHeader = refPacket.finish()
    let refTileBody = refPacketHeader + [0x01, 0x02, 0x04, 0x00, 0xAA, 0x55]
    // SOT is at offset 75 in validHT (after SOC 2 + SIZ 43 + CAP 10 + COD 14 + QCD 6 = 75)
    var refStream = Array(htRefinementStream[0..<75])
    var sotWriter = ByteWriter()
    sotWriter.writeUInt16(Marker.sot)
    sotWriter.writeUInt16(10)
    sotWriter.writeUInt16(0)
    sotWriter.writeUInt32(UInt32(14 + refTileBody.count))
    sotWriter.writeUInt8(0)
    sotWriter.writeUInt8(1)
    sotWriter.writeUInt16(Marker.sod)
    sotWriter.writeBytes(refTileBody)
    sotWriter.writeUInt16(Marker.eoc)
    refStream.append(contentsOf: sotWriter.bytes)
    do {
        _ = try await decoder.decode(Data(refStream))
        Issue.record("HT refinement passes (SigProp/MagRef) accepted")
    } catch let error as CodecError {
        #expect(error.category == .unsupportedFeature)
    }
    do {
        _ = try await transcoder.transcode(Data(refStream), to: .jpeg2000)
        Issue.record("HT refinement passes (SigProp/MagRef) accepted in transcode")
    } catch let error as CodecError {
        #expect(error.category == .unsupportedFeature)
    }

    // 11. Transcoder rejects same-format target, lossy mode, and unavailable backends.
    do {
        _ = try await transcoder.transcode(Data(validPart1), to: .jpeg2000)
        Issue.record("Part 1 -> Part 1 transcode accepted")
    } catch let error as CodecError { #expect(error.category == .unsupportedFormat) }

    do {
        _ = try await transcoder.transcode(Data(validHT), to: .htj2k)
        Issue.record("HTJ2K -> HTJ2K transcode accepted")
    } catch let error as CodecError { #expect(error.category == .unsupportedFormat) }

    #expect(throws: CodecError.self) { try Transcoder(configuration: .init(mode: .lossy)) }
    try await AccelerationRuntime.withSimulatedUnavailable {
        do {
            _ = try await transcoder.transcode(Data(validPart1), to: .htj2k,
                                               options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Unavailable backend accepted")
        } catch let error as CodecError { #expect(error.category == .backendUnavailable) }
    }
}

@Test func htj2kSharedStorageAndZeroIntermediateFilesProof() async throws {
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g16_17x9_alternating" }!
    let expected = try Fixtures.samples(entry)
    let htData = try HTJ2KFixtures.bytes("g16_17x9_alternating.ojph.j2c")

    // 1. Decode directly into caller-owned destination with prefix and row padding;
    // verify zero copies, zero extra pixel allocations, and intact padding bytes.
    let prefix = 4
    let rowBytes = 40
    let descriptor = try ImageDescriptor.greyscale16(
        width: entry.width,
        height: entry.height,
        meaningfulBits: entry.meaningfulBits,
        rowBytes: rowBytes,
        offset: prefix
    )
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    let identity = destination.storage.allocationID
    let decoded = try await Decoder().decode(htData, into: destination, options: .init(copyPolicy: .requireSharedStorage))
    #expect(decoded.report.copyEvents.isEmpty)
    #expect(decoded.report.pixelAllocationCount == 0)
    #expect(decoded.image.storage.allocationID == identity)
    try expectSamples(decoded.image, equal: expected, width: entry.width, height: entry.height)
    try decoded.image.storage.withUnsafeBytes { bytes in
        for i in 0..<prefix { #expect(bytes[i] == 0) }
        for y in 0..<(entry.height - 1) {
            for p in (entry.width * 2)..<rowBytes {
                #expect(bytes[prefix + y * rowBytes + p] == 0)
            }
        }
    }

    // 2. Verify Transcoder.transcode performs no temporary file creation during operation.
    let transcoder = try Transcoder()
    let tempDir = FileManager.default.temporaryDirectory
    let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
    let midFilesBox = Mutex<Set<String>>([])
    let transcoded = try await transcoder.transcode(
        htData,
        to: .jpeg2000,
        options: .init(
            copyPolicy: .requireSharedStorage,
            progress: { update in
                if update.phase == .processing {
                    let current = Set((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
                    midFilesBox.withLock { $0.formUnion(current.subtracting(beforeFiles)) }
                }
            }
        )
    )
    #expect(transcoded.report.copyEvents.isEmpty)
    #expect(transcoded.report.pixelAllocationCount == 0 && transcoded.report.peakPixelBytes == 0)
    let newSwiftJ2KTempFiles = midFilesBox.withLock { $0 }.filter {
        !$0.hasPrefix("swiftj2k-oracle-")
            && !$0.hasPrefix("swiftj2k-ht-oracle-")
            && !$0.hasPrefix("swiftj2k-transcode-oracle-")
            && !$0.hasPrefix("swiftj2k-m8-oracle-")
            && ($0.contains("swiftj2k") || $0.contains("j2k") || $0.contains("htj2k"))
    }
    #expect(newSwiftJ2KTempFiles.isEmpty, "Unexpected temporary files created during in-memory transcode: \(newSwiftJ2KTempFiles)")
}

// MARK: - 6. Truncation, single-bit corruption, limits, and cancellation

@Test func truncatedHTJ2KCodestreamsFailWithDefinedErrorsInDecodeAndTranscode() async throws {
    let data = [UInt8](try HTJ2KFixtures.bytes("g12_5x3_ramp_extremes.ojph_b16_n2.j2c"))
    let decoder = try Decoder()
    let transcoder = try Transcoder()
    for length in 0..<data.count {
        let prefix = Data(data[0..<length])
        do {
            _ = try await decoder.decode(prefix)
            #expect(length >= data.count - 2, "decode: prefix of \(length) bytes succeeded")
        } catch let error as CodecError {
            #expect([.malformedInput, .unsupportedFormat].contains(error.category), "decode \(length): \(error.message)")
        }
        do {
            _ = try await transcoder.transcode(prefix, to: .jpeg2000)
            #expect(length >= data.count - 2, "transcode: prefix of \(length) bytes succeeded")
        } catch let error as CodecError {
            #expect([.malformedInput, .unsupportedFormat].contains(error.category), "transcode \(length): \(error.message)")
        }
    }
}

@Test func singleBitCorruptionOnHTJ2KNeverTrapsOrHangs() async throws {
    let data = [UInt8](try HTJ2KFixtures.bytes("g16_17x9_alternating.kdu_ht_l3.j2k"))
    let decoder = try Decoder()
    let transcoder = try Transcoder()
    let limits = try ResourceLimits(maximumPixels: 4_000_000, deadlineSeconds: 10)
    var decodeOutcomes: [String: Int] = [:]
    var transcodeOutcomes: [String: Int] = [:]
    for index in data.indices {
        for bit in [0, 4, 7] {
            var mutated = data
            mutated[index] ^= UInt8(1) << UInt8(bit)
            let bytes = Data(mutated)
            do {
                _ = try await decoder.decode(bytes, options: .init(resourceLimits: limits))
                decodeOutcomes["decoded", default: 0] += 1
            } catch let error as CodecError {
                decodeOutcomes[error.category.rawValue, default: 0] += 1
            }
            do {
                _ = try await transcoder.transcode(bytes, to: .jpeg2000, options: .init(resourceLimits: limits))
                transcodeOutcomes["transcoded", default: 0] += 1
            } catch let error as CodecError {
                transcodeOutcomes[error.category.rawValue, default: 0] += 1
            }
        }
    }
    #expect(decodeOutcomes["internalFailure", default: 0] == 0, "\(decodeOutcomes)")
    #expect(transcodeOutcomes["internalFailure", default: 0] == 0, "\(transcodeOutcomes)")
}

@Test func resourceLimitsAndCancellationAreEnforcedForHTJ2KAndTranscoder() async throws {
    let data = try HTJ2KFixtures.bytes("g16_256x256_smooth.ojph_b32.j2c")
    let transcoder = try Transcoder()
    let cases: [(ResourceLimits, String)] = [
        (try ResourceLimits(maximumPixels: 65535), "pixels"),
        (try ResourceLimits(maximumDimension: 255), "dimension"),
        (try ResourceLimits(maximumCompressedBytes: data.count - 1), "compressed"),
        (try ResourceLimits(maximumWorkspaceBytes: 256 * 256 * 4 - 1), "workspace"),
        (try ResourceLimits(maximumMemoryBytes: data.count + 256 * 256 * 4 - 1), "memory"),
        (try ResourceLimits(deadlineSeconds: 0.000001), "deadline"),
    ]
    for (limits, label) in cases {
        do {
            _ = try await transcoder.transcode(data, to: .jpeg2000, options: .init(resourceLimits: limits))
            Issue.record("transcoder \(label) limit not enforced")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded, "\(label): \(error.message)")
        }
    }

    // Cancellation during transcode throws CancellationError.
    let cancelProgress: @Sendable (ProgressUpdate) -> Void = { update in
        guard update.phase == .processing, update.completedUnits > 0 else { return }
        withUnsafeCurrentTask { $0?.cancel() }
    }
    // Cancel a child operation, not Swift Testing's test task. The test must
    // complete normally after checking the cancellation result and cleanup.
    let cancelledOperation = Task {
        do {
            _ = try await transcoder.transcode(data, to: .jpeg2000, options: .init(progress: cancelProgress))
            return false
        } catch is CancellationError {
            return true
        }
    }
    #expect(try await cancelledOperation.value)
}

@Test func boundedHTJ2KAndTranscodeFuzzingNeverTrapsOrHangs() async throws {
    let decoder = try Decoder()
    let transcoder = try Transcoder()
    let limits = try ResourceLimits(
        maximumCompressedBytes: 256 * 1024,
        maximumWorkspaceBytes: 4 * 1024 * 1024,
        maximumPixels: 65536,
        maximumDimension: 512,
        deadlineSeconds: 2.0,
        maximumMemoryBytes: 8 * 1024 * 1024
    )

    var rng: UInt64 = 0xD1B5_4A32_D192_ED03
    func nextUInt64() -> UInt64 {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        return rng &* 0x2545_F491_4F6C_DD1D
    }

    // 1. Direct HTBlockDecoder.decodeCleanup fuzzing with 500 pseudo-random byte payloads and geometries.
    let dimensions = [(1, 1), (2, 3), (4, 4), (7, 5), (16, 16), (32, 8), (64, 64)]
    for iter in 0..<500 {
        let (w, h) = dimensions[iter % dimensions.count]
        let len = Int(nextUInt64() % 192)
        var block = [UInt8](repeating: 0, count: len)
        for i in 0..<len {
            block[i] = UInt8(truncatingIfNeeded: nextUInt64())
        }
        // Inject plausible Scup in last two bytes on half the iterations to reach deep VLC/MEL/MagSgn paths.
        if len >= 2 && (iter & 1) == 0 {
            let scup = max(2, Int(nextUInt64() % UInt64(len + 1)))
            block[len - 1] = UInt8((scup >> 4) & 0xFF)
            block[len - 2] = (block[len - 2] & 0xF0) | UInt8(scup & 0x0F)
        }
        let kMax = 1 + Int(nextUInt64() % 30)
        let missingMSBs = Int(nextUInt64() % UInt64(kMax))
        do {
            let out = try HTBlockDecoder.decodeCleanup(
                block: block,
                width: w,
                height: h,
                kMax: kMax,
                missingMSBs: missingMSBs
            )
            #expect(out.count == w * h)
        } catch let error as CodecError {
            #expect(error.category != .internalFailure, "Block fuzz iter \(iter): \(error.message)")
        }
    }

    // 2. Multi-mutation codestream fuzzing across HTJ2K and Part 1 fixtures in decode and both transcode directions.
    let seeds: [[UInt8]] = [
        [UInt8](try HTJ2KFixtures.bytes("g12_5x3_ramp_extremes.ojph_b16_n2.j2c")),
        [UInt8](try HTJ2KFixtures.bytes("g16_17x9_alternating.kdu_ht_l3.j2k")),
        [UInt8](try HTJ2KFixtures.bytes("g16_64x64_random.kdu_htmix.j2k")),
        [UInt8](try Fixtures.bytes("g12_5x3_ramp_extremes.kdu.j2k")),
    ]
    for iter in 0..<200 {
        var mutated = seeds[iter % seeds.count]
        let mutationCount = 1 + Int(nextUInt64() % 6)
        for _ in 0..<mutationCount where !mutated.isEmpty {
            let op = Int(nextUInt64() % 4)
            let idx = Int(nextUInt64() % UInt64(mutated.count))
            switch op {
            case 0:
                mutated[idx] ^= UInt8(truncatingIfNeeded: nextUInt64() | 1)
            case 1:
                mutated[idx] = UInt8(truncatingIfNeeded: nextUInt64())
            case 2 where mutated.count > 4:
                mutated.remove(at: idx)
            default:
                mutated.insert(UInt8(truncatingIfNeeded: nextUInt64()), at: idx)
            }
        }
        let payload = Data(mutated)
        do {
            _ = try await decoder.decode(payload, options: .init(resourceLimits: limits))
        } catch let error as CodecError {
            #expect(error.category != .internalFailure, "Decode fuzz iter \(iter): \(error.message)")
        }
        for target in [TranscodeTarget.jpeg2000, TranscodeTarget.htj2k] {
            do {
                _ = try await transcoder.transcode(payload, to: target, options: .init(resourceLimits: limits))
            } catch let error as CodecError {
                #expect(error.category != .internalFailure, "Transcode(\(target)) fuzz iter \(iter): \(error.message)")
            }
        }
    }
}

// MARK: - M6-AUD-004 COM metadata policy and M6-AUD-006 pre-allocation resource accounting regressions

@Test func transcodePreservesAndDiscardsCOMMetadataAndEnforcesMetadataLimits() async throws {
    let commentASCII = Array("Codex-M6-ancillary-metadata-audit".utf8)
    let comPayload: [UInt8] = [0x00, 0x01] + commentASCII // Rcom = 1 (Latin-1 text)
    let comLen = UInt16(2 + comPayload.count)
    let comSegment: [UInt8] = [
        0xFF, 0x64,
        UInt8(comLen >> 8), UInt8(comLen & 0xFF)
    ] + comPayload

    // 1. Exact M6-AUD-004 reproducer: first Lossless fixture with FF64 COM immediately after SOC.
    let firstEntry = Fixtures.manifest.fixtures[0]
    let baseJ2K = [UInt8](try Fixtures.bytes(firstEntry.codestreams[0].file))
    let baseParsed = try CodestreamSyntax.parse(baseJ2K, limits: try ResourceLimits())
    let expectedMainComments = [comPayload] + baseParsed.mainHeaderComments
    let expectedMainDiscardCount = 1 + baseParsed.commentCount
    let expectedMainDiscardBytes = comPayload.count + baseParsed.commentPayloadBytes
    let expectedSamples = try Fixtures.samples(firstEntry)
    var j2kWithCOMAfterSOC: [UInt8] = Array(baseJ2K[0..<2])
    j2kWithCOMAfterSOC.append(contentsOf: comSegment)
    j2kWithCOMAfterSOC.append(contentsOf: baseJ2K[2...])

    let transcoder = try Transcoder()
    let decoder = try Decoder()

    // Default metadataPolicy (.preserve): J2K -> HTJ2K -> J2K retains COM payload in both directions and reports 0 discarded.
    let htPreserved = try await transcoder.transcode(Data(j2kWithCOMAfterSOC), to: .htj2k)
    #expect(htPreserved.data.range(of: Data(commentASCII)) != nil, "HT output dropped main-header COM under .preserve")
    #expect(htPreserved.report.discardedMetadataCount == 0)
    #expect(htPreserved.report.discardedMetadataBytes == 0)
    #expect(htPreserved.report.discardedMetadataKinds.isEmpty)
    let parsedHT = try CodestreamSyntax.parse([UInt8](htPreserved.data), limits: try ResourceLimits())
    #expect(parsedHT.mainHeaderComments == expectedMainComments)

    let j2kRestored = try await transcoder.transcode(htPreserved.data, to: .jpeg2000)
    #expect(j2kRestored.data.range(of: Data(commentASCII)) != nil, "Restored J2K dropped main-header COM under .preserve")
    #expect(j2kRestored.report.discardedMetadataCount == 0)
    #expect(j2kRestored.report.discardedMetadataBytes == 0)
    #expect(j2kRestored.report.discardedMetadataKinds.isEmpty)
    let parsedRestored = try CodestreamSyntax.parse([UInt8](j2kRestored.data), limits: try ResourceLimits())
    #expect(parsedRestored.mainHeaderComments == expectedMainComments)
    let decodedPreserved = try await decoder.decode(j2kRestored.data)
    #expect(decodedPreserved.report.discardedMetadataCount == 0)
    try expectSamples(decodedPreserved.image, equal: expectedSamples, width: firstEntry.width, height: firstEntry.height)

    // Explicit .discardAncillary: J2K -> HTJ2K and HTJ2K -> J2K strip COM segments cleanly and report API-07 discard summary.
    let htDiscarded = try await transcoder.transcode(
        Data(j2kWithCOMAfterSOC),
        to: .htj2k,
        options: .init(metadataPolicy: .discardAncillary)
    )
    #expect(htDiscarded.data.range(of: Data(commentASCII)) == nil, "HT output retained COM under .discardAncillary")
    #expect(htDiscarded.report.discardedMetadataCount == expectedMainDiscardCount)
    #expect(htDiscarded.report.discardedMetadataBytes == expectedMainDiscardBytes)
    #expect(htDiscarded.report.discardedMetadataKinds == ["COM"])
    let j2kDiscarded = try await transcoder.transcode(
        htPreserved.data,
        to: .jpeg2000,
        options: .init(metadataPolicy: .discardAncillary)
    )
    #expect(j2kDiscarded.data.range(of: Data(commentASCII)) == nil, "J2K output retained COM under .discardAncillary")
    #expect(j2kDiscarded.report.discardedMetadataCount == expectedMainDiscardCount)
    #expect(j2kDiscarded.report.discardedMetadataBytes == expectedMainDiscardBytes)
    #expect(j2kDiscarded.report.discardedMetadataKinds == ["COM"])
    let decodedDiscarded = try await decoder.decode(
        Data(j2kWithCOMAfterSOC),
        options: .init(metadataPolicy: .discardAncillary)
    )
    #expect(decodedDiscarded.report.discardedMetadataCount == expectedMainDiscardCount)
    #expect(decodedDiscarded.report.discardedMetadataBytes == expectedMainDiscardBytes)
    #expect(decodedDiscarded.report.discardedMetadataKinds == ["COM"])

    // 2. Tile-part header COM + main-header COM in HTJ2K -> J2K -> HTJ2K.
    let tileCommentASCII = Array("Tile-0-COM-annotation".utf8)
    let tileCOMPayload: [UInt8] = [0x00, 0x01] + tileCommentASCII
    let tileCOMLen = UInt16(2 + tileCOMPayload.count)
    let tileCOMSegment: [UInt8] = [
        0xFF, 0x64,
        UInt8(tileCOMLen >> 8), UInt8(tileCOMLen & 0xFF)
    ] + tileCOMPayload

    // Insert tileCOMSegment immediately before SOD (0xFF93) in htPreserved and update Psot.
    var htWithTileCOM = [UInt8](htPreserved.data)
    var sotPos: Int?
    var sodPos: Int?
    var scan = 2
    while scan + 2 <= htWithTileCOM.count {
        let m = (UInt16(htWithTileCOM[scan]) << 8) | UInt16(htWithTileCOM[scan + 1])
        if m == 0xFF90 {
            sotPos = scan
            scan += 12
            while scan + 2 <= htWithTileCOM.count {
                let tm = (UInt16(htWithTileCOM[scan]) << 8) | UInt16(htWithTileCOM[scan + 1])
                if tm == 0xFF93 {
                    sodPos = scan
                    break
                }
                let tlen = Int((UInt16(htWithTileCOM[scan + 2]) << 8) | UInt16(htWithTileCOM[scan + 3]))
                scan += 2 + tlen
            }
            break
        }
        let slen = Int((UInt16(htWithTileCOM[scan + 2]) << 8) | UInt16(htWithTileCOM[scan + 3]))
        scan += 2 + slen
    }
    let foundSOT = try #require(sotPos)
    let foundSOD = try #require(sodPos)
    let oldPsot = (UInt32(htWithTileCOM[foundSOT + 6]) << 24)
        | (UInt32(htWithTileCOM[foundSOT + 7]) << 16)
        | (UInt32(htWithTileCOM[foundSOT + 8]) << 8)
        | UInt32(htWithTileCOM[foundSOT + 9])
    let newPsot = oldPsot + UInt32(tileCOMSegment.count)
    htWithTileCOM[foundSOT + 6] = UInt8((newPsot >> 24) & 0xFF)
    htWithTileCOM[foundSOT + 7] = UInt8((newPsot >> 16) & 0xFF)
    htWithTileCOM[foundSOT + 8] = UInt8((newPsot >> 8) & 0xFF)
    htWithTileCOM[foundSOT + 9] = UInt8(newPsot & 0xFF)
    htWithTileCOM.insert(contentsOf: tileCOMSegment, at: foundSOD)

    let j2kWithBothCOMs = try await transcoder.transcode(Data(htWithTileCOM), to: .jpeg2000)
    let parsedBoth = try CodestreamSyntax.parse([UInt8](j2kWithBothCOMs.data), limits: try ResourceLimits())
    #expect(parsedBoth.mainHeaderComments == expectedMainComments)
    #expect(parsedBoth.tileParts.first?.comments == [tileCOMPayload])
    #expect(j2kWithBothCOMs.report.discardedMetadataCount == 0)

    let j2kDiscardedBoth = try await transcoder.transcode(
        Data(htWithTileCOM),
        to: .jpeg2000,
        options: .init(metadataPolicy: .discardAncillary)
    )
    let parsedDiscardedBoth = try CodestreamSyntax.parse([UInt8](j2kDiscardedBoth.data), limits: try ResourceLimits())
    #expect(parsedDiscardedBoth.mainHeaderComments.isEmpty)
    #expect(parsedDiscardedBoth.tileParts.first?.comments.isEmpty == true)
    #expect(j2kDiscardedBoth.report.discardedMetadataCount == expectedMainDiscardCount + 1)
    #expect(j2kDiscardedBoth.report.discardedMetadataBytes == expectedMainDiscardBytes + tileCOMPayload.count)
    #expect(j2kDiscardedBoth.report.discardedMetadataKinds == ["COM"])

    // 3. Metadata byte limit enforcement (maximumMetadataBytes) and malformed COM (Lcom < 4).
    let tightMetaLimits = try ResourceLimits(maximumMetadataBytes: comPayload.count - 1)
    do {
        _ = try await transcoder.transcode(Data(j2kWithCOMAfterSOC), to: .htj2k, options: .init(resourceLimits: tightMetaLimits))
        Issue.record("transcode accepted COM exceeding maximumMetadataBytes")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }

    var malformedCOM: [UInt8] = Array(baseJ2K[0..<2])
    malformedCOM.append(contentsOf: [0xFF, 0x64, 0x00, 0x03, 0x00]) // Lcom = 3 (< 4)
    malformedCOM.append(contentsOf: baseJ2K[2...])
    do {
        _ = try await transcoder.transcode(Data(malformedCOM), to: .htj2k)
        Issue.record("transcode accepted malformed COM with Lcom < 4")
    } catch let error as CodecError {
        #expect(error.category == .malformedInput)
    }
}

@Test func transcodeResourceAccountingAndTelemetryCoverTargetGeometryEncodingsAndOutput() async throws {
    let width = 64, height = 64
    var samples = [UInt16](repeating: 0, count: width * height)
    for i in 0..<samples.count {
        samples[i] = UInt16((i &* 4099 + 17) & 0xFFFF)
    }
    let image = try makeImage(samples, width: width, height: height, bits: 16)
    let sourceOpts = try CodecOptions(decompositionLevels: 0, codeBlockWidth: 64, codeBlockHeight: 64, blockCoding: .part1)
    let sourceEncoded = try await Encoder(configuration: .init(mode: .lossless, codecOptions: sourceOpts)).encode(image)

    let reblockOpts = try CodecOptions(decompositionLevels: 0, codeBlockWidth: 4, codeBlockHeight: 4)
    let reblockTranscoder = try Transcoder(configuration: .init(mode: .lossless, codecOptions: reblockOpts))

    let recorder = StorageTelemetry.Recorder()
    let transcoded = try await StorageTelemetry.$recorder.withValue(recorder) {
        try await reblockTranscoder.transcode(sourceEncoded.data, to: .htj2k)
    }
    let counts = recorder.counts
    let events = recorder.events
    let stages = events.map(\.stage)
    #expect(counts.pixelAllocations == 0 && counts.pixelBytes == 0)
    // Stage telemetry proves every major workspace stage was admitted:
    #expect(stages.contains("input-copy"))
    #expect(stages.contains("source-geometry"))
    #expect(stages.contains("target-geometry"))
    #expect(stages.contains("output-writer"))
    #expect(stages.contains("decode-state"))
    #expect(stages.contains("coefficient-plane"))
    #expect(stages.filter { $0 == "block-encoding" }.count == 256)
    #expect(stages.contains("packet-writer"))
    #expect(stages.contains("output-data"))
    let peakWorkspace = try #require(transcoded.report.peakWorkspaceBytes)

    // 1. Pre-allocation denial of duplicate input copy ([UInt8](data)):
    // Admitting `data` + `[UInt8](data)` (32 + data.count) requires 2 * data.count + 32 bytes.
    let denyInputCopyRecorder = StorageTelemetry.Recorder()
    let denyInputCopyLimits = try ResourceLimits(maximumMemoryBytes: sourceEncoded.data.count * 2)
    do {
        _ = try await StorageTelemetry.$recorder.withValue(denyInputCopyRecorder) {
            try await reblockTranscoder.transcode(sourceEncoded.data, to: .htj2k, options: .init(resourceLimits: denyInputCopyLimits))
        }
        Issue.record("transcode should reject duplicate input buffer before allocating [UInt8](data)")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }
    #expect(denyInputCopyRecorder.events.isEmpty, "input-copy was allocated despite admission denial: \(denyInputCopyRecorder.events)")

    // 2. Pre-allocation denial of target 4x4 geometry (256 code-blocks + nested precinct/tag-tree state):
    let inputCopyBytes = events.first { $0.stage == "input-copy" }!.bytes
    let sourceGeoBytes = events.first { $0.stage == "source-geometry" }!.bytes
    let targetGeoBytes = events.first { $0.stage == "target-geometry" }!.bytes
    #expect(targetGeoBytes == sourceGeoBytes + 255 * MemoryLayout<CodeBlockGeometry>.stride)

    let denyTargetGeoRecorder = StorageTelemetry.Recorder()
    let denyTargetGeoLimits = try ResourceLimits(maximumWorkspaceBytes: inputCopyBytes + sourceGeoBytes + targetGeoBytes - 1)
    do {
        _ = try await StorageTelemetry.$recorder.withValue(denyTargetGeoRecorder) {
            try await reblockTranscoder.transcode(sourceEncoded.data, to: .htj2k, options: .init(resourceLimits: denyTargetGeoLimits))
        }
        Issue.record("transcode should reject 4x4 target geometry before allocating target TileGeometry arrays")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }
    let deniedTargetGeoStages = denyTargetGeoRecorder.events.map(\.stage)
    #expect(deniedTargetGeoStages == ["input-copy", "source-geometry"], "target-geometry or later stages allocated before denial: \(deniedTargetGeoStages)")

    // 3. Incremental pre-retention denial of encoded code-block payloads:
    // Allow live workspace before block payloads plus only half of the 256 encoded block payloads.
    let totalBlockEncodingBytes = events.filter { $0.stage == "block-encoding" }.reduce(0) { $0 + $1.bytes }
    let denyMidBlockRecorder = StorageTelemetry.Recorder()
    let denyMidBlockLimits = try ResourceLimits(
        maximumWorkspaceBytes: peakWorkspace - totalBlockEncodingBytes / 2
    )
    do {
        _ = try await StorageTelemetry.$recorder.withValue(denyMidBlockRecorder) {
            try await reblockTranscoder.transcode(sourceEncoded.data, to: .htj2k, options: .init(resourceLimits: denyMidBlockLimits))
        }
        Issue.record("transcode should reject retained block encodings partway through tile before all 256 blocks are retained")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }
    let midBlockStages = denyMidBlockRecorder.events.map(\.stage)
    let retainedBlockCount = midBlockStages.filter { $0 == "block-encoding" }.count
    #expect(retainedBlockCount > 0 && retainedBlockCount < 256, "Expected incremental denial partway through 256 blocks, got \(retainedBlockCount)")
    #expect(!midBlockStages.contains("packet-writer") && !midBlockStages.contains("output-data"))

    // 4. Pre-growth denial of packet/codestream output when maximumCompressedBytes is exceeded:
    if sourceEncoded.data.count < transcoded.data.count {
        let denyCompressedRecorder = StorageTelemetry.Recorder()
        let tightCompressedLimits = try ResourceLimits(maximumCompressedBytes: transcoded.data.count - 1)
        do {
            _ = try await StorageTelemetry.$recorder.withValue(denyCompressedRecorder) {
                try await reblockTranscoder.transcode(sourceEncoded.data, to: .htj2k, options: .init(resourceLimits: tightCompressedLimits))
            }
            Issue.record("transcode should fail before publishing output when growing codestream exceeds maximumCompressedBytes")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!denyCompressedRecorder.events.map(\.stage).contains("output-data"))
    }

    // 5. The successful operation must stay inside its own admission budget.
    // A prior run's peak is not a minimum: bounded writers may choose a smaller
    // growth capacity under a tighter limit. Either denial or a lower measured
    // bound is valid; accepting the same excessive bound is not. The writer tests
    // separately check the exact unavoidable old+new allocation boundary.
    let tightMemoryLimits = try ResourceLimits(maximumMemoryBytes: sourceEncoded.data.count + peakWorkspace - 1)
    do {
        let bounded = try await reblockTranscoder.transcode(sourceEncoded.data, to: .htj2k, options: .init(resourceLimits: tightMemoryLimits))
        let boundedWorkspace = try #require(bounded.report.peakWorkspaceBytes)
        #expect(sourceEncoded.data.count + boundedWorkspace <= tightMemoryLimits.maximumMemoryBytes)
        #expect(bounded.data == transcoded.data)
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }

    // 6. Pre-allocation denial of COM metadata ("comment-metadata" stage is never recorded when denied):
    let comPayload: [UInt8] = [0x00, 0x01] + Array(repeating: 0x41, count: 64)
    let comLen = UInt16(2 + comPayload.count)
    var sourceWithCOM = [UInt8](sourceEncoded.data[0..<2])
    sourceWithCOM.append(contentsOf: [0xFF, 0x64, UInt8(comLen >> 8), UInt8(comLen & 0xFF)])
    sourceWithCOM.append(contentsOf: comPayload)
    sourceWithCOM.append(contentsOf: sourceEncoded.data[2...])
    let denyCOMRecorder = StorageTelemetry.Recorder()
    let denyCOMLimits = try ResourceLimits(maximumMetadataBytes: comPayload.count - 1)
    do {
        _ = try await StorageTelemetry.$recorder.withValue(denyCOMRecorder) {
            try await reblockTranscoder.transcode(Data(sourceWithCOM), to: .htj2k, options: .init(resourceLimits: denyCOMLimits))
        }
        Issue.record("transcode should reject oversized COM segment before slicing comment-metadata")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }
    #expect(!denyCOMRecorder.events.map(\.stage).contains("comment-metadata"))

    // 7. Single-block encoder output budget (`maximumOutputBytes`) aborts before retaining an oversized 64x64 block:
    let coeffs64 = samples.map { Int32($0) - 32768 }
    #expect(throws: CodecError.self) {
        _ = try BitPlaneCoder.encode(
            coefficients: coeffs64,
            width: 64,
            height: 64,
            orientation: .ll,
            magnitudeBitPlanes: 16,
            maximumOutputBytes: 64
        )
    }
    #expect(throws: CodecError.self) {
        _ = try HTBlockEncoder.encodeCleanup(
            coefficients: coeffs64,
            width: 64,
            height: 64,
            bandShift: 0,
            maximumOutputBytes: 64
        )
    }
}
