// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

// MARK: - Container Fixture Loader

enum ContainerFixtures {
    struct Entry: Decodable, Sendable {
        let file: String
        let generator: String
        let format: String
        let width: Int
        let height: Int
        let components: Int
        let meaningfulBits: Int
        let signed: Bool
        let lossless: Bool
        let hasAlpha: Bool?
        let hasICC: Bool?
        let hasXML: Bool?
        let hasUUID: Bool?
        let isPalettised: Bool?
        let bytes: Int
        let sha256: String
        let samples: [[Int]]
    }

    struct Manifest: Decodable, Sendable {
        let milestone: Int
        let fixtures: [Entry]
    }

    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Containers")
    static let manifest: Manifest = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func bytes(_ entry: Entry) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(entry.file))
    }
}

// MARK: - Helper to Build Nested/Structured Box Payloads

private func makeUinfPayload(uuids: [[UInt8]], url: String) -> Data {
    var writer = JP2BoxWriter()
    var ulstPayload: [UInt8] = []
    JP2BoxWriter.appendUInt16(&ulstPayload, UInt16(uuids.count))
    for u in uuids { ulstPayload.append(contentsOf: u) }
    try! writer.appendBox(type: .uuidList, payload: ulstPayload)
    var urlPayload: [UInt8] = [0, 0, 0, 0] // Version=0, Flags=0
    urlPayload.append(contentsOf: url.utf8)
    urlPayload.append(0)
    try! writer.appendBox(type: .dataEntryURL, payload: urlPayload)
    return Data(writer.bytes)
}

private func makeAsocPayload(label: String, xml: Data, nestedAsoc: Data? = nil) -> Data {
    var writer = JP2BoxWriter()
    try! writer.appendBox(type: .label, payload: [UInt8](label.utf8))
    if !xml.isEmpty {
        try! writer.appendBox(type: .xml, payload: [UInt8](xml))
    }
    if let nestedAsoc {
        try! writer.appendBox(type: .association, payload: [UInt8](nestedAsoc))
    }
    return Data(writer.bytes)
}

// MARK: - 1. Independent OpenJPEG 2.5.4 and Kakadu 8.4.1 Container Fixtures

@Test(arguments: ContainerFixtures.manifest.fixtures.map(\.file))
func independentContainerFixturesInspectAndDecode(file: String) async throws {
    let entry = ContainerFixtures.manifest.fixtures.first { $0.file == file }!
    let data = try ContainerFixtures.bytes(entry)
    #expect(data.count == entry.bytes)

    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.format == entry.format)
    #expect(info.descriptor.width == entry.width)
    #expect(info.descriptor.height == entry.height)
    #expect(info.descriptor.components.count == entry.components)
    #expect(info.descriptor.meaningfulBits == entry.meaningfulBits)
    #expect(info.descriptor.sampleType == (entry.signed ? .signedInteger : .unsignedInteger))

    if entry.hasAlpha == true {
        #expect(info.descriptor.alpha == .straight)
        #expect(info.descriptor.components.last == .alpha)
    }
    if entry.hasICC == true {
        #expect(info.descriptor.iccProfile != nil)
        #expect(!(info.descriptor.iccProfile?.isEmpty ?? true))
    }
    if entry.hasXML == true {
        #expect(info.metadata.entries["xml"] != nil)
    }
    if entry.hasUUID == true {
        #expect(info.metadata.entries["uuid"] != nil)
    }

    let decoded = try await decoder.decode(data)
    #expect(decoded.report.backend == .scalarCPU)
    #expect(decoded.report.copyEvents.isEmpty && decoded.report.pixelAllocationCount == 1)

    let actualPlanes = try extractPlanes(decoded.image)
    let (maxErr, psnr) = computeErrorMetrics(entry.samples, actualPlanes, meaningfulBits: entry.meaningfulBits)

    if entry.lossless {
        #expect(decoded.report.fidelity == .exactSamples)
        #expect(maxErr == 0, "Lossless container fixture \(entry.file) had maxErr=\(maxErr)")
    } else {
        #expect(decoded.report.fidelity == .lossy)
        #expect(psnr >= 38.0, "Lossy container fixture \(entry.file) PSNR \(psnr) dB too low")
    }
}

// MARK: - 2. JP2, JPH, and JPX Container Encoding & Oracle Interoperability

@Test func encodeAndDecodeJP2JPHAndJPXContainersWithMetadataAndResolution() async throws {
    let w = 24, h = 16
    var r = [Int](repeating: 0, count: w * h)
    var g = [Int](repeating: 0, count: w * h)
    var b = [Int](repeating: 0, count: w * h)
    var a = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        r[i] = (i * 11 + 3) & 0xFF
        g[i] = (i * 17 + 50) & 0xFF
        b[i] = (i * 23 + 120) & 0xFF
        a[i] = (i * 7 + 200) & 0xFF
    }

    // Minimal valid 132-byte synthetic ICC profile header + tag table
    var icc = [UInt8](repeating: 0, count: 132)
    icc[0] = 0; icc[1] = 0; icc[2] = 0; icc[3] = 132 // profile size = 132
    icc[12..<16] = ArraySlice("mntr".utf8)
    icc[16..<20] = ArraySlice("RGB ".utf8)
    icc[20..<24] = ArraySlice("XYZ ".utf8)
    icc[36..<40] = ArraySlice("acsp".utf8)

    let xmlPayload = Data("<?xml version=\"1.0\"?><meta>SwiftJ2K</meta>".utf8)
    let uuidID: [UInt8] = [0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]
    let uuidPayload = Data(uuidID) + Data("UUID-Body".utf8)
    let iprPayload = Data("Copyright 2026 Raster-Lab".utf8)
    let uinfPayload = makeUinfPayload(uuids: [uuidID], url: "https://example.org/schema")
    let asocPayload = makeAsocPayload(label: "Associated-Metadata", xml: xmlPayload)

    let baseImage = try makeMultiPlaneImage(planes: [r, g, b, a], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)
    let rgbaDescriptor = try ImageDescriptor(
        width: w,
        height: h,
        sampleType: .unsignedInteger,
        storageBits: 8,
        meaningfulBits: 8,
        byteOrder: .native,
        components: [.red, .green, .blue, .alpha],
        colour: .rgb,
        alpha: .premultiplied,
        planes: baseImage.descriptor.planes,
        iccProfile: Data(icc)
    )
    let imageMetadata = ImageMetadata(entries: [
        "xml": xmlPayload,
        "uuid": uuidPayload,
        "jp2i": iprPayload,
        "uinf": uinfPayload,
        "asoc": asocPayload
    ])
    let rgbaImage = try Image(descriptor: rgbaDescriptor, storage: baseImage.storage, metadata: imageMetadata)

    let captureRes = try JP2GridResolution(
        verticalNumerator: 3000, verticalDenominator: 1,
        horizontalNumerator: 3000, horizontalDenominator: 1,
        verticalExponent: 0, horizontalExponent: 0
    )
    let displayRes = try JP2GridResolution(
        verticalNumerator: 6000, verticalDenominator: 1,
        horizontalNumerator: 6000, horizontalDenominator: 1,
        verticalExponent: 0, horizontalExponent: 0
    )

    for (container, blockCoding, expectedFormat) in [
        (CodecOptions.ContainerFormat.jp2, CodecOptions.BlockCoding.part1, "jp2"),
        (CodecOptions.ContainerFormat.jph, CodecOptions.BlockCoding.htj2k, "jph"),
        (CodecOptions.ContainerFormat.jpx, CodecOptions.BlockCoding.part1, "jpx"),
        (CodecOptions.ContainerFormat.jpx, CodecOptions.BlockCoding.htj2k, "jpx")
    ] {
        let opts = try CodecOptions(
            decompositionLevels: 2,
            blockCoding: blockCoding,
            containerFormat: container,
            captureResolution: captureRes,
            displayResolution: displayRes
        )
        let encoder = try Encoder(configuration: EncoderConfiguration(mode: .lossless, codecOptions: opts))
        let encoded = try await encoder.encode(rgbaImage)
        #expect(encoded.encoding.format == expectedFormat)
        #expect(JP2Container.isContainer([UInt8](encoded.data)))

        let decoder = try Decoder()
        let info = try decoder.inspect(encoded.data)
        #expect(info.format == expectedFormat)
        #expect(info.descriptor.width == w && info.descriptor.height == h)
        #expect(info.descriptor.alpha == .premultiplied)
        #expect(info.descriptor.iccProfile == Data(icc))
        #expect(info.metadata.entries["xml"] == xmlPayload)
        #expect(info.metadata.entries["uuid"] == uuidPayload)
        #expect(info.metadata.entries["jp2i"] == iprPayload)
        #expect(info.metadata.entries["uinf"] == uinfPayload)
        #expect(info.metadata.entries["asoc"] == asocPayload)

        let parsed = try JP2Container.parse([UInt8](encoded.data), limits: ResourceLimits.default, metadataPolicy: .preserve)
        #expect(parsed.header.resolution?.capture == captureRes)
        #expect(parsed.header.resolution?.display == displayRes)
        #expect(abs((parsed.header.resolution?.capture?.horizontalPixelsPerMetre ?? 0) - 3000.0) < 1e-6)
        if container == .jpx {
            #expect(parsed.readerRequirements != nil)
        }

        let decoded = try await decoder.decode(encoded.data)
        let planes = try extractPlanes(decoded.image)
        #expect(planes == [r, g, b, a])

        // Test discardAncillary policy on decode
        let decodedDiscarded = try await decoder.decode(
            encoded.data,
            options: DecodeOptions(metadataPolicy: .discardAncillary)
        )
        #expect(decodedDiscarded.image.metadata.entries["xml"] == nil)
        #expect(decodedDiscarded.image.metadata.entries["uuid"] == nil)
        #expect(decodedDiscarded.image.metadata.entries["jp2i"] == nil)
        #expect(decodedDiscarded.image.metadata.entries["uinf"] == nil)
        #expect(decodedDiscarded.image.metadata.entries["asoc"] == nil)
        #expect(decodedDiscarded.report.discardedMetadataCount == 5)
        #expect((decodedDiscarded.report.discardedMetadataBytes ?? 0) > 0)
        #expect(Set(decodedDiscarded.report.discardedMetadataKinds) == Set(["asoc", "jp2i", "uinf", "uuid", "xml"]))
    }
}

@Test(.enabled(if: Oracle.available, "No independent JPEG 2000 decoder installed"))
func independentOraclesDecodeSuccessorJP2JPHAndJPXContainers() async throws {
    #if os(macOS) || os(Linux)
    let w = 32, h = 24
    var r = [Int](repeating: 0, count: w * h)
    var g = [Int](repeating: 0, count: w * h)
    var b = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        r[i] = (i * 9 + 12) & 0xFF
        g[i] = (i * 15 + 40) & 0xFF
        b[i] = (i * 27 + 90) & 0xFF
    }
    let rgbImage = try makeMultiPlaneImage(planes: [r, g, b], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-m8-oracle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 1. JP2 container -> OpenJPEG and Kakadu
    let jp2Data = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 2, containerFormat: .jp2)
    )).encode(rgbImage).data
    let jp2URL = dir.appendingPathComponent("test.jp2")
    try jp2Data.write(to: jp2URL)

    for tool in [Oracle.openJPEG, Oracle.kakadu].compactMap({ $0 }) {
        let outPPM = dir.appendingPathComponent("jp2_\(tool.contains("kdu") ? "kdu" : "opj").ppm")
        #expect(try Oracle.decode(tool, jp2URL, outPPM), "\(tool) failed to decode successor .jp2 container")
    }

    // 2. JPH and JPX containers -> Kakadu
    if let kdu = Oracle.kakadu {
        let jphData = try await Encoder(configuration: EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(decompositionLevels: 2, blockCoding: .htj2k, containerFormat: .jph)
        )).encode(rgbImage).data
        let jphURL = dir.appendingPathComponent("test.jph")
        try jphData.write(to: jphURL)
        #expect(try Oracle.decode(kdu, jphURL, dir.appendingPathComponent("jph_kdu.ppm")), "Kakadu failed to decode successor .jph container")

        let jpxData = try await Encoder(configuration: EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(decompositionLevels: 2, blockCoding: .part1, containerFormat: .jpx)
        )).encode(rgbImage).data
        let jpxURL = dir.appendingPathComponent("test.jpx")
        try jpxData.write(to: jpxURL)
        #expect(try Oracle.decode(kdu, jpxURL, dir.appendingPathComponent("jpx_kdu.ppm")), "Kakadu failed to decode successor .jpx container")
    }
    #endif
}

// MARK: - 3. Container Transcoding (JP2 <-> JPH & Codestream <-> Container)

@Test func transcodeBetweenJP2AndJPHContainersPreservesAndDiscardsMetadata() async throws {
    let w = 16, h = 12
    let samples = (0..<(w * h)).map { (($0 * 173 + 19) & 0x0FFF) }
    let baseImg = try makeMultiPlaneImage(planes: [samples], width: w, height: h, meaningfulBits: 12, storageBits: 16, signed: false)
    var icc = [UInt8](repeating: 0, count: 132)
    icc[0] = 0; icc[1] = 0; icc[2] = 0; icc[3] = 132
    icc[12..<16] = ArraySlice("mntr".utf8)
    icc[16..<20] = ArraySlice("GRAY".utf8)
    icc[20..<24] = ArraySlice("XYZ ".utf8)
    icc[36..<40] = ArraySlice("acsp".utf8)
    let descWithICC = try ImageDescriptor(
        width: w, height: h, sampleType: .unsignedInteger, storageBits: 16, meaningfulBits: 12,
        byteOrder: .native, components: [.grey], colour: .greyscale, alpha: .absent,
        planes: baseImg.descriptor.planes, iccProfile: Data(icc)
    )
    let xmlPayload = Data("<?xml version=\"1.0\"?><transcode>M8</transcode>".utf8)
    let uuidPayload = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]) + Data("M8-UUID".utf8)
    let srcImg = try Image(
        descriptor: descWithICC,
        storage: baseImg.storage,
        metadata: ImageMetadata(entries: ["xml": xmlPayload, "uuid": uuidPayload])
    )
    let jp2Bytes = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 2, containerFormat: .jp2)
    )).encode(srcImg).data

    // 1. Transcode JP2 -> JPH with MetadataPolicy.preserve
    let toJPH = try Transcoder(configuration: TranscoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(blockCoding: .htj2k, containerFormat: .jph)
    ))
    let jphResult = try await toJPH.transcode(jp2Bytes, to: .htj2k, options: TranscodeOptions(metadataPolicy: .preserve))
    #expect(jphResult.encoding.format == "jph")
    #expect(jphResult.report.pixelAllocationCount == 0)
    #expect(jphResult.report.copyEvents.isEmpty)
    #expect(jphResult.report.discardedMetadataCount == 0)

    let decoder = try Decoder()
    let jphInfo = try decoder.inspect(jphResult.data)
    #expect(jphInfo.format == "jph")
    #expect(jphInfo.descriptor.iccProfile == Data(icc))
    #expect(jphInfo.metadata.entries["xml"] == xmlPayload)
    #expect(jphInfo.metadata.entries["uuid"] == uuidPayload)

    let jphDecoded = try await decoder.decode(jphResult.data)
    #expect(try extractPlanes(jphDecoded.image) == [samples])

    // 2. Transcode JPH -> JP2 with MetadataPolicy.discardAncillary
    let toJP2 = try Transcoder(configuration: TranscoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(blockCoding: .part1, containerFormat: .jp2)
    ))
    let jp2Discarded = try await toJP2.transcode(
        jphResult.data,
        to: .jpeg2000,
        options: TranscodeOptions(metadataPolicy: .discardAncillary)
    )
    #expect(jp2Discarded.encoding.format == "jp2")
    #expect((jp2Discarded.report.discardedMetadataCount ?? 0) == 2)
    #expect((jp2Discarded.report.discardedMetadataBytes ?? 0) == xmlPayload.count + uuidPayload.count)
    #expect(jp2Discarded.report.discardedMetadataKinds.contains("xml"))
    #expect(jp2Discarded.report.discardedMetadataKinds.contains("uuid"))

    let jp2Info = try decoder.inspect(jp2Discarded.data)
    #expect(jp2Info.descriptor.iccProfile == Data(icc)) // Essential colour specification is preserved!
    #expect(jp2Info.metadata.entries["xml"] == nil)
    #expect(jp2Info.metadata.entries["uuid"] == nil)
    #expect(try extractPlanes(await decoder.decode(jp2Discarded.data).image) == [samples])
}

// MARK: - 4. Palette ('pclr') + Component Mapping ('cmap') Direct & Signed Columns

@Test func paletteAndComponentMappingWith12BitAndDirectChannels() async throws {
    let w = 8, h = 6
    let indices: [Int] = (0..<(w * h)).map { $0 % 4 }
    let indexImage = try makeMultiPlaneImage(planes: [indices], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)
    let rawCodestream = try await Encoder().encode(indexImage).data

    let columns = [
        try JP2ComponentBitDepth(bitDepth: 12, isSigned: false),
        try JP2ComponentBitDepth(bitDepth: 12, isSigned: false),
        try JP2ComponentBitDepth(bitDepth: 12, isSigned: false)
    ]
    let entries: [[Int64]] = [
        [100, 200, 300],
        [1000, 2000, 3000],
        [1500, 2500, 3500],
        [4000, 4050, 4095]
    ]
    let pclr = try JP2PaletteBox(columns: columns, values: entries)
    let cmap = try JP2ComponentMappingBox(entries: [
        JP2ComponentMappingBox.Entry(componentIndex: 0, mappingType: 1, paletteColumn: 0),
        JP2ComponentMappingBox.Entry(componentIndex: 0, mappingType: 1, paletteColumn: 1),
        JP2ComponentMappingBox.Entry(componentIndex: 0, mappingType: 1, paletteColumn: 2)
    ])
    let ihdr = try JP2ImageHeaderBox(
        height: UInt32(h), width: UInt32(w), numComponents: 1,
        uniformBitDepth: JP2ComponentBitDepth(bitDepth: 8, isSigned: false)
    )
    let colr = try JP2ColourSpecificationBox(
        method: .enumerated(JP2ColourSpecificationBox.EnumeratedColourSpace.sRGB.rawValue)
    )
    let ftyp = try JP2FileTypeBox(brand: "jp2 ", compatibleBrands: ["jp2 "])
    let jp2h = try JP2HeaderSuperbox(
        imageHeader: ihdr,
        colourSpecifications: [colr],
        palette: pclr,
        componentMapping: cmap
    )

    var writer = JP2BoxWriter()
    try writer.appendBox(type: .signature, payload: JP2SignatureBox.expectedPayload)
    try writer.appendBox(type: .fileType, payload: ftyp.serialise())
    try writer.appendBox(type: .jp2Header, payload: try jp2h.serialise())
    try writer.appendBox(type: .contiguousCodestream, payload: [UInt8](rawCodestream))

    let containerData = Data(writer.bytes)
    let decoder = try Decoder()
    let info = try decoder.inspect(containerData)
    #expect(info.descriptor.components.count == 3)
    #expect(info.descriptor.meaningfulBits == 12)
    #expect(info.descriptor.storageBits == 16)

    let decoded = try await decoder.decode(containerData)
    for y in 0..<h {
        for x in 0..<w {
            let idx = indices[y * w + x]
            for c in 0..<3 {
                let sample = try decoded.image.sampleInt(component: c, x: x, y: y)
                #expect(sample == Int(entries[idx][c]))
            }
        }
    }
}

// MARK: - 5. Reader Requirements ('rreq') Box Round-Trip and Feature Queries

@Test func readerRequirementsBoxRoundTripAndFeatureEvaluation() throws {
    let vendorUUID: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]
    let box = try JP2ReaderRequirementsBox(
        fuam: 0xC0,
        dcm: 0x80,
        standardFeatures: [
            .init(feature: .codestreamContainsNoExtensions, mask: 0x80),
            .init(feature: .sRGBEnumeratedColourSpace, mask: 0x40),
            .init(code: 45, mask: 0x20) // Kakadu extended feature code
        ],
        vendorFeatures: [
            try .init(uuid: vendorUUID, mask: 0x10)
        ]
    )
    #expect(box.standardFeatures[0].knownFeature == .codestreamContainsNoExtensions)
    #expect(box.standardFeatures[2].knownFeature == .compositingLayerSingleCodestream)
    let unmapped = JP2ReaderRequirementsBox.StandardFeatureEntry(code: 9999, mask: 0x01)
    #expect(unmapped.knownFeature == nil)

    for maskLen: UInt8 in [1, 2, 4, 8] {
        let b = try JP2ReaderRequirementsBox(
            maskLength: maskLen,
            fuam: 0x03,
            dcm: 0x01,
            standardFeatures: [.init(code: 5, mask: 0x01)],
            vendorFeatures: [try .init(uuid: vendorUUID, mask: 0x02)]
        )
        let bytes = b.serialise()
        let parsed = try JP2ReaderRequirementsBox.parse(bytes: bytes, range: 0..<bytes.count)
        #expect(parsed == b)
    }
}

// MARK: - 6. Security, Resource Limits & Malformed Box Validation

@Test func boxReaderRejectsInvalidExtendedLengthsAndTruncatedBoxes() throws {
    let limits = ResourceLimits.default

    // 1. LBox == 1 with XLBox == 0 (infinite loop trap in predecessor)
    let xlZero: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x78, 0x6D, 0x6C, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]
    #expect(throws: CodecError.self) {
        var reader = try JP2BoxReader(bytes: xlZero, limits: limits)
        _ = try reader.nextBox()
    }

    // 2. LBox == 1 with XLBox == 8 (< 16 negative range trap in predecessor)
    let xlEight: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x78, 0x6D, 0x6C, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08
    ]
    #expect(throws: CodecError.self) {
        var reader = try JP2BoxReader(bytes: xlEight, limits: limits)
        _ = try reader.nextBox()
    }

    // 3. LBox in 2...7 (reserved invalid lengths)
    for invalidLBox: UInt8 in 2...7 {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, invalidLBox, 0x78, 0x6D, 0x6C, 0x20]
        #expect(throws: CodecError.self) {
            var reader = try JP2BoxReader(bytes: bytes, limits: limits)
            _ = try reader.nextBox()
        }
    }

    // 4. Valid LBox == 1 extended box round-trip
    var writer = JP2BoxWriter()
    try writer.appendBox(type: .xml, payload: [0x41, 0x42, 0x43], useExtendedLength: true)
    var reader = try JP2BoxReader(bytes: writer.bytes, limits: limits)
    let box = try reader.nextBox()!
    #expect(box.headerSize == 16 && box.payloadRange.count == 3)
}

@Test func metadataICCAndNestingDepthResourceLimitsAreEnforced() async throws {
    let fixture = ContainerFixtures.manifest.fixtures.first { $0.file == "jp2_rgb8_icc_res_meta.kdu.jp2" }!
    let data = try ContainerFixtures.bytes(fixture)
    let decoder = try Decoder()

    // 1. maximumICCBytes limit exceeded (fixture has 504-byte ICC profile)
    let tightICCLimits = try ResourceLimits(maximumICCBytes: 128)
    do {
        _ = try decoder.inspect(data, options: DecodeOptions(resourceLimits: tightICCLimits))
        Issue.record("Expected maximumICCBytes limit error")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }

    // 2. maximumMetadataBytes limit exceeded (even when discardAncillary is set)
    let tightMetaLimits = try ResourceLimits(maximumMetadataBytes: 64)
    do {
        _ = try await decoder.decode(
            data,
            options: DecodeOptions(resourceLimits: tightMetaLimits, metadataPolicy: .discardAncillary)
        )
        Issue.record("Expected maximumMetadataBytes limit error")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }

    // 3. maximumNestingDepth limit exceeded on deeply nested 'asoc' boxes
    let w = 8, h = 8
    let img = try makeMultiPlaneImage(planes: [[Int](repeating: 42, count: 64)], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)
    var nestedAsoc = makeAsocPayload(label: "leaf", xml: Data())
    for i in 0..<6 {
        nestedAsoc = makeAsocPayload(label: "level-\(i)", xml: Data(), nestedAsoc: nestedAsoc)
    }
    let imgNested = try Image(
        descriptor: img.descriptor,
        storage: img.storage,
        metadata: ImageMetadata(entries: ["asoc": nestedAsoc])
    )
    let encodedNested = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(containerFormat: .jp2)
    )).encode(imgNested).data

    // Succeeds with default maximumNestingDepth (32)
    _ = try decoder.inspect(encodedNested)

    // Fails when maximumNestingDepth is set to 3
    let shallowLimits = try ResourceLimits(maximumNestingDepth: 3)
    do {
        _ = try decoder.inspect(encodedNested, options: DecodeOptions(resourceLimits: shallowLimits))
        Issue.record("Expected maximumNestingDepth limit error")
    } catch let error as CodecError {
        #expect(error.category == .resourceLimitExceeded)
    }
}

@Test func containerStructuralInvariantsAreValidatedStrictly() async throws {
    let fixture = ContainerFixtures.manifest.fixtures.first { $0.file == "jp2_g16_lossless.opj.jp2" }!
    let validJP2 = [UInt8](try ContainerFixtures.bytes(fixture))
    let decoder = try Decoder()

    // 1. Corrupt 'ihdr' width so it disagrees with codestream SIZ width
    var badWidth = validJP2
    if let ihdrIdx = (0..<(badWidth.count - 12)).first(where: {
        badWidth[$0] == 0x69 && badWidth[$0 + 1] == 0x68 && badWidth[$0 + 2] == 0x64 && badWidth[$0 + 3] == 0x72
    }) {
        // Payload starts at ihdrIdx + 4: height (4B), width (4B)
        badWidth[ihdrIdx + 11] = 99
        do {
            _ = try decoder.inspect(Data(badWidth))
            Issue.record("Expected ihdr/SIZ width mismatch failure")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }
    }

    // 2. Corrupt 'ftyp' brand to unknown brand 'xxxx'
    var badBrand = validJP2
    badBrand[20] = 0x78; badBrand[21] = 0x78; badBrand[22] = 0x78; badBrand[23] = 0x78
    for i in 28..<32 { badBrand[i] = 0x78 }
    do {
        _ = try decoder.inspect(Data(badBrand))
        Issue.record("Expected unsupported brand failure")
    } catch let error as CodecError {
        #expect(error.category == .unsupportedFormat)
    }
}
