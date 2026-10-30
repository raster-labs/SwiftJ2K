// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

struct R2ICCModelPreservationTests {
    // A complete ICC header and empty tag table identify a model for opaque
    // preservation tests. They provide no colour transform or oracle evidence.
    private func profile(_ signature: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 132)
        bytes[3] = 132
        bytes[8] = 4; bytes[9] = 0x40
        bytes[12..<16] = ArraySlice("scnr".utf8)
        bytes[16..<20] = ArraySlice(signature.utf8)
        bytes[20..<24] = ArraySlice("XYZ ".utf8)
        bytes[36..<40] = ArraySlice("acsp".utf8)
        return Data(bytes)
    }

    private func fixture(codestream: Data, icc: Data, cmyk: Bool) throws -> Data {
        var writer = JP2BoxWriter()
        try writer.appendBox(type: .signature, payload: JP2SignatureBox.expectedPayload)
        try writer.appendBox(type: .fileType, payload: JP2FileTypeBox(
            brand: cmyk ? "jpx " : "jp2 ",
            compatibleBrands: cmyk ? ["jpx ", "jpxb"] : ["jp2 "]
        ).serialise())
        if cmyk {
            try writer.appendBox(type: .readerRequirements, payload: JP2ReaderRequirementsBox.defaultJPX(
                isLossless: true, isHTJ2K: false, colour: .unknown, hasAlpha: false,
                isPremultipliedAlpha: false, hasRestrictedICC: false, colourFeatures: [.anyICCProfile]
            ).serialise())
        }
        let definitions: [JP2ChannelDefinitionBox.Entry] = (0..<4).map { index in
            let isColour = cmyk || index == 0
            let channelType: UInt16 = isColour ? 0 : 0xFFFF
            let association: UInt16 = cmyk ? UInt16(index + 1) : (index == 0 ? 1 : 0xFFFF)
            return JP2ChannelDefinitionBox.Entry(channelIndex: UInt16(index),
                channelType: channelType, association: association)
        }
        let header = try JP2HeaderSuperbox(
            imageHeader: JP2ImageHeaderBox(height: 4, width: 4, numComponents: 4,
                uniformBitDepth: JP2ComponentBitDepth(bitDepth: 8, isSigned: false)),
            colourSpecifications: [JP2ColourSpecificationBox(
                method: cmyk ? .anyICC(icc) : .restrictedICC(icc), approximation: cmyk ? 1 : 0)],
            channelDefinition: JP2ChannelDefinitionBox(entries: definitions)
        )
        try writer.appendBox(type: .jp2Header, payload: header.serialise())
        try writer.appendBox(type: .contiguousCodestream, payload: [UInt8](codestream))
        return Data(writer.bytes)
    }

    @Test("F07/F08: ICC-only GRAY plus extras and CMYK retain the declared model and exact opaque profile")
    func iccOnlyColourModels() async throws {
        let layout = try ImageDescriptor.multiComponentPlanar(width: 4, height: 4,
            componentCount: 4, storageBits: 8, meaningfulBits: 8)
        let source = try ImageDestination.allocate(descriptor: layout).writeSamples { c, _, _ in c * 41 + 7 }
        let raw = try await Encoder(configuration: EncoderConfiguration(mode: .lossless,
            codecOptions: CodecOptions(colourTransform: .none))).encode(source).data
        for cmyk in [false, true] {
            let icc = profile(cmyk ? "CMYK" : "GRAY")
            let data = try fixture(codestream: raw, icc: icc, cmyk: cmyk)
            let expectedRoles: [ComponentRole] = cmyk
                ? (1...4).map { .uninterpreted("icc.CMYK.\($0)") }
                : [.grey, .uninterpreted("c1"), .uninterpreted("c2"), .uninterpreted("c3")]
            let image = try await Decoder().decode(data).image
            #expect(image.descriptor.colour == (cmyk ? .unknown : .greyscale))
            #expect(image.descriptor.components == expectedRoles)
            #expect(image.descriptor.alpha == .absent)
            #expect(image.descriptor.iccProfile == icc)
            #expect(image.metadata.requiredKeys.contains("colr"))
            let bridged = try J2KDecoder.decodeSync(data).toContractImage()
            #expect(bridged.descriptor.components == expectedRoles)
            #expect(bridged.descriptor.iccProfile == icc)
            if cmyk {
                let partial = try J2KDecoder.decodeSync(data, components: [0, 1, 2]).toContractImage()
                #expect(partial.descriptor.colour == .unknown)
                #expect(partial.descriptor.iccProfile == nil)
                #expect(partial.descriptor.components == Array(expectedRoles.prefix(3)))
                #expect(!partial.metadata.entries.keys.contains { $0 == "colr" || $0.hasPrefix("colr.") })
                // Direct callers may retain the source colr even after removing the
                // descriptor ICC. That also must not produce an incomplete CMYK file.
                let retainedWholeTuple = try Image(descriptor: partial.descriptor,
                    storage: partial.storage, metadata: image.metadata)
                let partialEncoder = try Encoder(configuration: EncoderConfiguration(mode: .lossless,
                    codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jpx)))
                for candidate in [partial, retainedWholeTuple] {
                    do {
                        _ = try await partialEncoder.encode(candidate)
                        Issue.record("An incomplete CMYK tuple produced a container")
                    } catch let error as CodecError {
                        #expect(error.category == .unsupportedFeature)
                    }
                }
            } else {
                let greyOnly = try J2KDecoder.decodeSync(data, components: [0]).toContractImage()
                #expect(greyOnly.descriptor.components == [.grey])
                #expect(greyOnly.descriptor.iccProfile == icc)
            }
            let output = try await Encoder(configuration: EncoderConfiguration(mode: .lossless,
                codecOptions: CodecOptions(colourTransform: .none, containerFormat: cmyk ? .jpx : .jp2)))
                .encode(bridged, options: EncodeOptions(metadataPolicy: .discardAncillary)).data
            let parsed = try JP2Container.parse([UInt8](output), limits: .default, metadataPolicy: .preserve)
            #expect(parsed.header.colourSpecifications.first?.method == (cmyk ? .anyICC(icc) : .restrictedICC(icc)))
            if cmyk {
                #expect(!parsed.fileType.compatibleBrands.contains("jp2 "))
                #expect(parsed.readerRequirements?.standardFeatures.contains { $0.knownFeature == .anyICCProfile } == true)
                do {
                    _ = try await Encoder(configuration: EncoderConfiguration(mode: .lossless,
                        codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jp2))).encode(bridged)
                    Issue.record("An unrestricted CMYK profile was encoded as JP2")
                } catch let error as CodecError {
                    #expect(error.category == .unsupportedFeature)
                }
            }
            let restored = try await Decoder().decode(output).image
            #expect(restored.descriptor.components == expectedRoles)
            #expect(restored.descriptor.iccProfile == icc)
            for c in 0..<4 { #expect(try restored.sampleInt(component: c, x: 0, y: 0) == c * 41 + 7) }
        }
    }

    @Test("F07: dropping an unspecified extra preserves a complete RGB ICC tuple")
    func rgbProfileSurvivesDroppingExtra() async throws {
        let layout = try ImageDescriptor.multiComponentPlanar(width: 4, height: 4,
            componentCount: 4, storageBits: 8, meaningfulBits: 8)
        let icc = profile("RGB ")
        let descriptor = try ImageDescriptor(width: 4, height: 4, sampleType: .unsignedInteger,
            storageBits: 8, meaningfulBits: 8, byteOrder: .native,
            components: [.red, .green, .blue, .uninterpreted("c3")], colour: .rgb,
            alpha: .absent, planes: layout.planes, iccProfile: icc)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, _, _ in c * 41 + 7 }
        let encoder = try Encoder(configuration: EncoderConfiguration(mode: .lossless,
            codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jp2)))
        let data = try await encoder.encode(source).data
        let selected = try J2KDecoder.decodeSync(data, components: [0, 1, 2]).toContractImage()
        #expect(selected.descriptor.components == [.red, .green, .blue])
        #expect(selected.descriptor.colour == .rgb)
        #expect(selected.descriptor.iccProfile == icc)
        let output = try await encoder.encode(selected).data
        let restored = try await Decoder().decode(output).image
        #expect(restored.descriptor.iccProfile == icc)
        for c in 0..<3 { #expect(try restored.sampleInt(component: c, x: 0, y: 0) == c * 41 + 7) }
        let mismatchedDescriptor = try ImageDescriptor(width: 4, height: 4, sampleType: .unsignedInteger,
            storageBits: 8, meaningfulBits: 8, byteOrder: .native,
            components: [.grey, .uninterpreted("c1"), .uninterpreted("c2"), .uninterpreted("c3")],
            colour: .greyscale, alpha: .absent, planes: layout.planes, iccProfile: icc)
        let mismatched = try Image(descriptor: mismatchedDescriptor, storage: source.storage)
        do {
            _ = try await encoder.encode(mismatched)
            Issue.record("A greyscale image with an RGB ICC tuple produced a container")
        } catch let error as CodecError {
            #expect(error.category == .unsupportedFeature)
        }
    }
}
