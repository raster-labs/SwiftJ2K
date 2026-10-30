import Foundation
import Testing
@testable import SwiftJ2K

@Suite("Independent R2 audit probes")
struct IndependentR2AuditTests {
    @Test("Premultiplied alpha survives public legacy bridge and decoder")
    func premultipliedAlphaMeaningSurvivesLegacyRoundTrip() async throws {
        let descriptor = try ImageDescriptor.rgbPlanar(
            width: 2, height: 2, storageBits: 8, meaningfulBits: 8,
            alpha: .premultiplied
        )
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let image = try destination.writeSamples { component, _, _ in
            component == 3 ? 128 : 64
        }
        let throughLegacy = try J2KImage(contractImage: image).toContractImage()
        #expect(throughLegacy.descriptor.alpha == .premultiplied)
        let encoded = try await Encoder(configuration: EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jp2)
        )).encode(image, options: EncodeOptions(executionPolicy: .scalarCPU))
        let direct = try await Decoder().decode(encoded.data, options: DecodeOptions(executionPolicy: .scalarCPU))
        #expect(direct.image.descriptor.alpha == .premultiplied)
        let legacyDecoded = try await J2KDecoder().decode(encoded.data)
        let adapted = try legacyDecoded.toContractImage()
        #expect(adapted.descriptor.alpha == .premultiplied)
        for component in 0..<4 {
            #expect(try adapted.sampleInt(component: component, x: 0, y: 0)
                == direct.image.sampleInt(component: component, x: 0, y: 0))
        }
    }

    @Test("Undefined DCM requirements cannot be satisfied by shifting supported feature bits")
    func undefinedDecodeClauseRemainsUnsatisfied() throws {
        // The sole feature contributes bit 7 only. DCM requires bit 6, which
        // no feature contributes. T.801 M.6.2 evaluates the actual masks.
        let requirements = try JP2ReaderRequirementsBox(
            maskLength: 1, fuam: 0x80, dcm: 0x40,
            standardFeatures: [
                .init(feature: .sRGBEnumeratedColourSpace, mask: 0x80)
            ]
        )
        let result = requirements.evaluate(supportedFeatures: [.sRGBEnumeratedColourSpace])
        #expect(result.satisfiedMask == 0x80)
        #expect(!result.canDecodeCompletely)
        #expect(result.unsatisfiedDecodeMask == 0x40)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Containers/jpx_rgb8_part1.kdu.jpx")
        let bytes = [UInt8](try Data(contentsOf: fixture))
        var reader = try JP2BoxReader(bytes: bytes, limits: .default)
        var rebuilt: [UInt8] = []
        while let box = try reader.nextBox() {
            if box.type == .readerRequirements {
                let payload = requirements.serialise()
                let count = UInt32(payload.count + 8)
                rebuilt += [UInt8(count >> 24), UInt8((count >> 16) & 255),
                    UInt8((count >> 8) & 255), UInt8(count & 255)]
                rebuilt += Array("rreq".utf8) + payload
            } else {
                rebuilt += bytes[(box.payloadRange.lowerBound - box.headerSize)..<box.payloadRange.upperBound]
            }
        }
        #expect(throws: CodecError.self) { try Decoder().inspect(Data(rebuilt)) }
    }
}
