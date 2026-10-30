// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

struct R2ColourAlphaPreservationTests {
    private func encoded(_ image: Image, format: CodecOptions.ContainerFormat = .jp2) async throws -> Data {
        try await Encoder(configuration: EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(colourTransform: .none, containerFormat: format)
        )).encode(image).data
    }

    private func replaceColour(_ data: Data, code: UInt32) throws -> Data {
        let bytes = [UInt8](data)
        let needsJPX = ![UInt32(16), 17, 18].contains(code)
        var reader = try JP2BoxReader(bytes: bytes, limits: .default)
        var writer = JP2BoxWriter()
        while let box = try reader.nextBox() {
            if box.type == .fileType && needsJPX {
                let baseline = [UInt32(20), 21].contains(code)
                try writer.appendBox(type: .fileType, payload: JP2FileTypeBox(
                    brand: "jpx ", compatibleBrands: baseline ? ["jpx ", "jpxb"] : ["jpx "]
                ).serialise())
                let features: [UInt32: JP2ReaderRequirementsBox.StandardFeature] = [
                    1: .yCbCr1EnumeratedColourSpace, 3: .yCbCr2EnumeratedColourSpace,
                    4: .yCbCr3EnumeratedColourSpace, 20: .eSRGBEnumeratedColourSpace,
                    21: .rommRGBEnumeratedColourSpace
                ]
                let feature = try #require(features[code])
                try writer.appendBox(type: .readerRequirements, payload: JP2ReaderRequirementsBox.defaultJPX(
                    isLossless: true, isHTJ2K: false, colour: .unknown, hasAlpha: false,
                    isPremultipliedAlpha: false, hasRestrictedICC: false, colourFeatures: [feature]
                ).serialise())
            } else if box.type == .jp2Header {
                var children = try reader.childReader(for: box)
                var header = JP2BoxWriter()
                while let child = try children.nextBox() {
                    let payload = child.type == .colourSpecification
                        ? try JP2ColourSpecificationBox(method: .enumerated(code), approximation: needsJPX ? 1 : 0).serialise()
                        : Array(bytes[child.payloadRange])
                    try header.appendBox(type: child.type, payload: payload)
                }
                try writer.appendBox(type: box.type, payload: header.bytes)
            } else {
                try writer.appendBox(type: box.type, payload: Array(bytes[box.payloadRange]))
            }
        }
        return Data(writer.bytes)
    }

    @Test("F07: permuted and alpha-only component views retain sample meaning")
    func componentViewsPreserveRolesAndAlpha() async throws {
        let descriptor = try ImageDescriptor.rgbPlanar(width: 4, height: 4, storageBits: 8,
                                                      meaningfulBits: 8, alpha: .premultiplied)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, _, _ in
            [32, 48, 64, 128][c]
        }
        let data = try await encoded(source)
        let permuted = try J2KDecoder.decodeSync(data, components: [3, 0, 1, 2]).toContractImage()
        #expect(permuted.descriptor.colour == .rgb)
        #expect(permuted.descriptor.alpha == .premultiplied)
        #expect(permuted.descriptor.components == [.alpha, .red, .green, .blue])
        for c in 0..<4 {
            #expect(try permuted.sampleInt(component: c, x: 0, y: 0) == [128, 32, 48, 64][c])
        }
        let alphaOnly = try J2KDecoder.decodeSync(data, components: [3]).toContractImage()
        #expect(alphaOnly.descriptor.colour == .unknown)
        #expect(alphaOnly.descriptor.components == [.alpha])
        #expect(alphaOnly.descriptor.alpha == .premultiplied)
        #expect(try alphaOnly.sampleInt(x: 0, y: 0) == 128)
        #expect(throws: J2KError.self) { _ = try J2KDecoder.decodeSync(data, components: [0, 1, 2]) }

        // Container cdef restores the canonical tuple after encoding a valid permutation.
        let restored = try await Decoder().decode(encoded(permuted)).image
        #expect(restored.descriptor.components == [.red, .green, .blue, .alpha])
        #expect(restored.descriptor.alpha == .premultiplied)
        for c in 0..<4 { #expect(try restored.sampleInt(component: c, x: 0, y: 0) == [32, 48, 64, 128][c]) }
    }

    @Test("F07/F08: native enumerated colour survives core, legacy, JPX and metadata-discard round trips")
    func enumeratedColourRemainsExplicit() async throws {
        let descriptor = try ImageDescriptor.rgbPlanar(width: 4, height: 4, storageBits: 8, meaningfulBits: 8)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, _, _ in [100, 128, 128][c] }
        let baseline = try await encoded(source)
        for code: UInt32 in [1, 3, 4, 18, 20, 21] {
            let native = try replaceColour(baseline, code: code)
            let decoded = try await Decoder().decode(native).image
            #expect(decoded.descriptor.colour == .unknown)
            #expect(decoded.descriptor.components == (1...3).map { .uninterpreted("colr.\(code).\($0)") })
            #expect(decoded.metadata.requiredKeys.contains("colr"))
            for c in 0..<3 { #expect(try decoded.sampleInt(component: c, x: 0, y: 0) == [100, 128, 128][c]) }
            let legacy = try await J2KDecoder().decode(native)
            let bridged = try legacy.toContractImage()
            #expect(bridged.metadata == decoded.metadata)
            #expect(bridged.descriptor.components == decoded.descriptor.components)
            // Raw codestreams cannot carry the required native colour interpretation.
            #expect(throws: J2KError.self) { _ = try J2KEncoder().encodeSync(legacy) }
            let formats: [CodecOptions.ContainerFormat] = code == 18 ? [.jp2, .jpx] : [.jpx]
            if code != 18 {
                do {
                    _ = try await encoded(bridged, format: .jp2)
                    Issue.record("A JPX-only enumeration was encoded as JP2")
                } catch let error as CodecError {
                    #expect(error.category == .unsupportedFeature)
                }
            }
            for format in formats {
                let output = try await Encoder(configuration: EncoderConfiguration(
                    mode: .lossless, codecOptions: CodecOptions(colourTransform: .none, containerFormat: format)
                )).encode(bridged, options: EncodeOptions(metadataPolicy: .discardAncillary)).data
                let parsed = try JP2Container.parse([UInt8](output), limits: .default, metadataPolicy: .preserve)
                #expect(parsed.header.colourSpecifications.first?.method == .enumerated(code))
                #expect(parsed.header.colourSpecifications.first?.approximation == (format == .jpx ? 1 : 0))
                if format == .jpx {
                    #expect(parsed.fileType.compatibleBrands.contains("jp2 ") == (code == 18))
                    #expect(parsed.fileType.compatibleBrands.contains("jpxb") == [UInt32(18), 20, 21].contains(code))
                }
                if code == 18, let rreq = parsed.readerRequirements {
                    #expect(rreq.standardFeatures.contains { $0.knownFeature == .sYCCEnumeratedColourSpace })
                    #expect(!rreq.standardFeatures.contains { $0.knownFeature == .greyscaleEnumeratedColourSpace })
                    #expect(rreq.evaluate().canDecodeCompletely)
                }
                let roundTrip = try await Decoder().decode(output, options: DecodeOptions(metadataPolicy: .discardAncillary)).image
                #expect(roundTrip.metadata.requiredKeys.contains("colr"))
                #expect(roundTrip.descriptor.colour == .unknown)
                for c in 0..<3 { #expect(try roundTrip.sampleInt(component: c, x: 0, y: 0) == [100, 128, 128][c]) }
            }
        }
    }

    @Test("F07: container output requires an explicit colour representation")
    func unknownColourIsNotInvented() async throws {
        let descriptor = try ImageDescriptor.multiComponentPlanar(width: 4, height: 4, componentCount: 4,
                                                                 storageBits: 8, meaningfulBits: 8)
        let image = try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, _, _ in c * 41 }
        for format in [CodecOptions.ContainerFormat.jp2, .jpx] {
            do {
                _ = try await encoded(image, format: format)
                Issue.record("An unknown tuple without colour metadata produced a container")
            } catch let error as CodecError {
                #expect(error.category == .unsupportedFeature)
            }
        }
    }

    @Test("F08: shifted-mask compatibility depends on actual baseline structure, not COM attribution")
    func boundedStructuralCompatibility() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Containers")
        for name in ["jpx_rgb8_part1.kdu.jpx", "jpx_rgb8_htj2k.kdu.jpx"] {
            var bytes = [UInt8](try Data(contentsOf: fixtureRoot.appendingPathComponent(name)))
            _ = try Decoder().inspect(Data(bytes))
            let comment = Array("Kakadu-v8.".utf8)
            if let index = bytes.indices.first(where: { $0 + comment.count <= bytes.count && bytes[$0..<($0 + comment.count)].elementsEqual(comment) }) {
                bytes.replaceSubrange(index..<(index + comment.count), with: repeatElement(UInt8(0x78), count: comment.count))
            } else { Issue.record("Independent fixture lost its expected comment"); continue }
            _ = try Decoder().inspect(Data(bytes))

            var reader = try JP2BoxReader(bytes: bytes, limits: .default)
            var writer = JP2BoxWriter()
            while let box = try reader.nextBox() {
                if box.type == .compositingLayerHdr {
                    var layer = JP2BoxWriter()
                    try layer.appendBox(type: .colourSpecification,
                                        payload: JP2ColourSpecificationBox(method: .enumerated(18)).serialise())
                    try writer.appendBox(type: box.type, payload: layer.bytes)
                } else {
                    try writer.appendBox(type: box.type, payload: Array(bytes[box.payloadRange]))
                }
            }
            #expect(throws: CodecError.self) { _ = try Decoder().inspect(Data(writer.bytes)) }
        }
    }
}
