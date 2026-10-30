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
        let definitions = (0..<4).map { index in
            JP2ChannelDefinitionBox.Entry(channelIndex: UInt16(index),
                channelType: cmyk || index == 0 ? 0 : 0xFFFF,
                association: cmyk ? UInt16(index + 1) : (index == 0 ? 1 : 0xFFFF))
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
}
