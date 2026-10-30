// SPDX-License-Identifier: Apache-2.0
// In-house, deterministic synthetic fixtures; no external image assets.
// TIFF 6.0 pp. 31–32: https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf
// PNG ordering: https://www.w3.org/TR/2025/REC-png-3-20250624/#5ChunkOrdering
// Fixtures are 1×1, unsigned 8-bit: RGB [10,20,30,40] or grey [10,40].
// PNG is RGB [171,82,255] with four significant bits, expected [10,5,15].
// The fixture builders are independent of the production readers and writers.
// SHA-256 of canonical TIFF fixtures (photometric, ExtraSamples):
// (1,0) de630031f9ef3d38a80e35ca6704848e9a8bea57a584b79b351d61f86df43664
// (1,1) 62d23726e9ca225b9ce7ef0d466074c8a9b50e03abe041b00d6be79b4cfc3943
// (1,2) 7a01fa547509039e055a27ba96e3e72523fd0fea3e9422ed895241415d29a18e
// (2,0) f3eb402ebf5de9cd482cfaf909e55d2efb5970ecf1a5f5a726bbd508136fff2e
// (2,1) 9da3e5fcc5dabef5ea74a54ba1e0c4f6ec41d389e866463591a63f08e68aa511
// (2,2) f98dd735eff44a1b770bbf7e64149729abd34f9548580df57e9178c642393a04
// PNG IHDR,sBIT,PLTE,IDAT,IEND:
// f932d2c6ae7bc1dc6a868456e79ee6607d867d8b30d6c79aaa16fc1c70906e03
// PNG IHDR,PLTE,sBIT,IDAT,IEND (malformed order):
// 2b9b6cbde4a96f9febb7b0d9ac33d3f041fdffd1033d952de770875647c1bb59

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2KCLI

private func extraSampleTIFF(
    photometric: UInt16,
    extras: [UInt16]?,
    extraType: UInt16 = 3,
    duplicateExtraTag: Bool = false,
    firstExtraCountOverride: Int? = nil,
    includeExtraChannel: Bool = true
) -> Data {
    let colourSamples: [UInt8] = photometric == 2 ? [10, 20, 30] : [10]
    let samples = colourSamples + (includeExtraChannel ? [40] : [])
    let tagCount = 10 + (extras == nil ? 0 : (duplicateExtraTag ? 2 : 1))
    let bpsOffset = 8 + 2 + tagCount * 12 + 4
    let bpsByteCount = samples.count > 2 ? samples.count * 2 : 0
    let stripOffset = bpsOffset + bpsByteCount
    var bytes: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0]
    func le16(_ value: UInt16) {
        bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    func le32(_ value: UInt32) {
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    func tag(_ number: UInt16, _ type: UInt16, _ count: Int, _ value: UInt32) {
        le16(number); le16(type); le32(UInt32(count)); le32(value)
    }
    le16(UInt16(tagCount))
    tag(256, 4, 1, 1)
    tag(257, 4, 1, 1)
    let inlineDepth: UInt32 = samples.count == 2 ? 0x0008_0008 : 8
    tag(258, 3, samples.count, samples.count > 2 ? UInt32(bpsOffset) : inlineDepth)
    tag(259, 3, 1, 1)
    tag(262, 3, 1, UInt32(photometric))
    tag(273, 4, 1, UInt32(stripOffset))
    tag(277, 3, 1, UInt32(samples.count))
    tag(278, 4, 1, 1)
    tag(279, 4, 1, UInt32(samples.count))
    tag(284, 3, 1, 1)
    if let extras {
        let packed = extras.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 16)) }
        tag(338, extraType, firstExtraCountOverride ?? extras.count, packed)
        if duplicateExtraTag { tag(338, extraType, extras.count, packed) }
    }
    le32(0)
    if samples.count > 2 {
        for _ in samples { le16(8) }
    }
    bytes += samples
    return Data(bytes)
}

/// Read only the independently specified little-endian SHORT tag used by these tests.
private func outputExtraSampleTag(_ data: Data) throws -> UInt16? {
    let bytes = [UInt8](data)
    try #require(bytes.count >= 10)
    func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) }
    let count = Int(u16(8))
    try #require(bytes.count >= 10 + count * 12)
    for index in 0..<count {
        let offset = 10 + index * 12
        if u16(offset) == 338 {
            #expect(u16(offset + 2) == 3)
            #expect(Array(bytes[(offset + 4)..<(offset + 8)]) == [1, 0, 0, 0])
            return u16(offset + 8)
        }
    }
    return nil
}

private func orderedSignificantBitPNG(_ order: [String]) -> Data {
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    func bigEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    func appendChunk(_ name: String, _ payload: [UInt8]) {
        let chunk = Array(name.utf8) + payload
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in chunk {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
        }
        bytes += bigEndian(UInt32(payload.count)) + chunk + bigEndian(crc ^ 0xFFFF_FFFF)
    }
    // Independent RFC 1950/1951 stored-block zlib stream, one unfiltered RGB pixel.
    let row: [UInt8] = [0, 171, 82, 255]
    var a: UInt32 = 1
    var b: UInt32 = 0
    for value in row { a = (a + UInt32(value)) % 65521; b = (b + a) % 65521 }
    let idat: [UInt8] = [0x78, 1, 1, 4, 0, 0xFB, 0xFF] + row + bigEndian((b << 16) | a)
    for name in order {
        switch name {
        case "IHDR": appendChunk(name, [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])
        case "sBIT": appendChunk(name, [4, 4, 4])
        case "PLTE": appendChunk(name, [0, 0, 0, 255, 255, 255])
        case "IDAT": appendChunk(name, idat)
        case "IEND": appendChunk(name, [])
        default: break
        }
    }
    return Data(bytes)
}

@Suite("R2 CLI extra-sample meaning and PNG ordering")
struct R2CLIExtraSampleOrderingTests {
    @Test("TIFF ExtraSamples 0, 1 and 2 retain distinct RGB/grey interpretation")
    func tiffExtraSampleMeanings() throws {
        for photo in [UInt16(1), 2] {
            for extra in [UInt16(0), 1, 2] {
                let image = try parseTIFF(extraSampleTIFF(photometric: photo, extras: [extra]),
                                          declaredPrecision: nil, limits: .default)
                let alpha: AlphaInterpretation = extra == 0 ? .absent : (extra == 1 ? .premultiplied : .straight)
                let roles: [ComponentRole] = photo == 2 ? [.red, .green, .blue] : [.grey]
                let expectedRoles = roles + [extra == 0 ? .uninterpreted("c\(roles.count)") : .alpha]
                #expect(image.descriptor.components == expectedRoles)
                #expect(image.descriptor.alpha == alpha)
                #expect(image.descriptor.meaningfulBits == 8)
                if photo == 2 { #expect(image.descriptor.colour == .rgb) }
                else { #expect(image.descriptor.colour == .greyscale) }
                let expected = photo == 2 ? [10, 20, 30, 40] : [10, 40]
                for (channel, value) in expected.enumerated() {
                    #expect(try image.sampleInt(component: channel, x: 0, y: 0) == value)
                }
                // Inspect emitted tag bytes, so a matching reader/writer bug cannot hide.
                let encoded = try formatTIFF(image)
                #expect(try outputExtraSampleTag(encoded) == extra)
                let reparsed = try parseTIFF(encoded, declaredPrecision: nil, limits: .default)
                #expect(reparsed.descriptor.components == expectedRoles)
                #expect(reparsed.descriptor.alpha == alpha)
            }
        }
    }

    @Test("TIFF missing, invalid and inconsistent ExtraSamples fail as malformed input")
    func malformedTIFFExtraSamples() throws {
        for photo in [UInt16(1), 2] {
            let fixtures = [
                extraSampleTIFF(photometric: photo, extras: nil),
                extraSampleTIFF(photometric: photo, extras: []),
                extraSampleTIFF(photometric: photo, extras: [3]),
                extraSampleTIFF(photometric: photo, extras: [65535]),
                extraSampleTIFF(photometric: photo, extras: [0, 2]),
                extraSampleTIFF(photometric: photo, extras: [0], extraType: 4),
                extraSampleTIFF(photometric: photo, extras: [0], duplicateExtraTag: true),
                extraSampleTIFF(photometric: photo, extras: [0], duplicateExtraTag: true, firstExtraCountOverride: 0),
                extraSampleTIFF(photometric: photo, extras: [0], includeExtraChannel: false)
            ]
            for fixture in fixtures {
                #expect(throws: CodecError.self) {
                    do { _ = try parseTIFF(fixture, declaredPrecision: nil, limits: .default) }
                    catch let error as CodecError {
                        #expect(error.category == .malformedInput)
                        throw error
                    }
                }
            }
            // Absence is valid when SamplesPerPixel has no extra channels.
            let image = try parseTIFF(extraSampleTIFF(photometric: photo, extras: nil, includeExtraChannel: false),
                                      declaredPrecision: nil, limits: .default)
            #expect(image.descriptor.alpha == .absent)
            #expect(try outputExtraSampleTag(formatTIFF(image)) == nil)
        }
    }

    @Test("TIFF WhiteIsZero changes grey samples only, including unspecified extras")
    func whiteIsZeroLeavesExtrasUntouched() throws {
        for extra in [UInt16(0), 1, 2] {
            let image = try parseTIFF(extraSampleTIFF(photometric: 0, extras: [extra]),
                                      declaredPrecision: nil, limits: .default)
            #expect(try image.sampleInt(component: 0, x: 0, y: 0) == 245)
            #expect(try image.sampleInt(component: 1, x: 0, y: 0) == 40)
            #expect(image.descriptor.components[0] == .grey)
            #expect(image.descriptor.alpha == (extra == 0 ? .absent : (extra == 1 ? .premultiplied : .straight)))
        }
    }

    @Test("TIFF unspecified extras retain colour roles through JP2 encoding")
    func tiffUnspecifiedExtraThroughJP2() async throws {
        for photo in [UInt16(1), 2] {
            let image = try parseTIFF(extraSampleTIFF(photometric: photo, extras: [0]),
                                      declaredPrecision: nil, limits: .default)
            let encoder = try Encoder(configuration: .init(
                mode: .lossless, codecOptions: .init(colourTransform: .none, containerFormat: .jp2)))
            let encoded = try await encoder.encode(image).data
            let decoded = try await Decoder().decode(encoded).image
            #expect(decoded.descriptor.components == image.descriptor.components)
            #expect(decoded.descriptor.alpha == .absent)
            #expect(decoded.descriptor.colour == image.descriptor.colour)
            let expected = photo == 2 ? [10, 20, 30, 40] : [10, 40]
            for (channel, value) in expected.enumerated() {
                #expect(try decoded.sampleInt(component: channel, x: 0, y: 0) == value)
            }
        }
    }

    @Test("TIFF writer rejects unknown colour instead of inventing a photometric meaning")
    func tiffWriterRejectsUnknownColour() throws {
        let descriptor = try ImageDescriptor.multiComponentPlanar(
            width: 1, height: 1, componentCount: 2, storageBits: 8,
            meaningfulBits: 8, sampleType: .unsignedInteger)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let image = try destination.writeSamples { component, _, _ in component + 10 }
        #expect(throws: CodecError.self) {
            do { _ = try formatTIFF(image) }
            catch let error as CodecError {
                #expect(error.category == .unsupportedFeature)
                throw error
            }
        }
    }

    @Test("PNG output preserves canonical roles and rejects unspecified or premultiplied extras")
    func pngWriterPreservesChannelMeaning() throws {
        for photo in [UInt16(1), 2] {
            for extra in [UInt16(0), 1, 2] {
                let image = try parseTIFF(extraSampleTIFF(photometric: photo, extras: [extra]),
                                          declaredPrecision: nil, limits: .default)
                if extra == 2 {
                    let decoded = try parsePNG(formatPNG(image), declaredPrecision: nil, limits: .default)
                    #expect(decoded.descriptor.components == image.descriptor.components)
                    #expect(decoded.descriptor.alpha == .straight)
                    let expected = photo == 2 ? [10, 20, 30, 40] : [10, 40]
                    for (channel, value) in expected.enumerated() {
                        #expect(try decoded.sampleInt(component: channel, x: 0, y: 0) == value)
                    }
                    let base = image.descriptor
                    let permutedRoles: [ComponentRole] = photo == 2
                        ? [.alpha, .red, .green, .blue] : [.alpha, .grey]
                    let descriptor = try ImageDescriptor(
                        width: 1, height: 1, sampleType: base.sampleType,
                        storageBits: base.storageBits, meaningfulBits: base.meaningfulBits,
                        byteOrder: base.byteOrder, components: permutedRoles, colour: base.colour,
                        alpha: .straight, planes: base.planes)
                    let permuted = try Image(descriptor: descriptor, storage: image.storage)
                    #expect(throws: CodecError.self) {
                        do { _ = try formatPNG(permuted) }
                        catch let error as CodecError {
                            #expect(error.category == .unsupportedFeature)
                            throw error
                        }
                    }
                } else {
                    #expect(throws: CodecError.self) {
                        do { _ = try formatPNG(image) }
                        catch let error as CodecError {
                            #expect(error.category == .unsupportedFeature)
                            throw error
                        }
                    }
                }
            }
            let plain = try parseTIFF(extraSampleTIFF(photometric: photo, extras: nil, includeExtraChannel: false),
                                      declaredPrecision: nil, limits: .default)
            let decoded = try parsePNG(formatPNG(plain), declaredPrecision: nil, limits: .default)
            #expect(decoded.descriptor.components == plain.descriptor.components)
            #expect(decoded.descriptor.alpha == .absent)
            let expected = photo == 2 ? [10, 20, 30] : [10]
            for (channel, value) in expected.enumerated() {
                #expect(try decoded.sampleInt(component: channel, x: 0, y: 0) == value)
            }
        }
    }

    @Test("PNG sBIT before optional PLTE preserves exact significant samples")
    func pngValidSignificantBitOrdering() throws {
        for order in [
            ["IHDR", "sBIT", "PLTE", "IDAT", "IEND"],
            ["IHDR", "sBIT", "IDAT", "IEND"]
        ] {
            let image = try parsePNG(orderedSignificantBitPNG(order), declaredPrecision: nil, limits: .default)
            #expect(image.descriptor.meaningfulBits == 4)
            for (channel, value) in [10, 5, 15].enumerated() {
                #expect(try image.sampleInt(component: channel, x: 0, y: 0) == value)
            }
        }
    }

    @Test("PNG rejects sBIT after PLTE, duplicate sBIT and misplaced palette chunks")
    func pngMalformedSignificantBitOrdering() {
        for order in [
            ["IHDR", "PLTE", "sBIT", "IDAT", "IEND"],
            ["IHDR", "sBIT", "sBIT", "PLTE", "IDAT", "IEND"],
            ["IHDR", "IDAT", "sBIT", "IEND"],
            ["sBIT", "IHDR", "IDAT", "IEND"],
            ["PLTE", "IHDR", "sBIT", "IDAT", "IEND"],
            ["IHDR", "sBIT", "PLTE", "PLTE", "IDAT", "IEND"],
            ["IHDR", "sBIT", "IDAT", "PLTE", "IEND"]
        ] {
            #expect(throws: CodecError.self) {
                do { _ = try parsePNG(orderedSignificantBitPNG(order), declaredPrecision: nil, limits: .default) }
                catch let error as CodecError {
                    #expect(error.category == .malformedInput)
                    throw error
                }
            }
        }
    }
}
