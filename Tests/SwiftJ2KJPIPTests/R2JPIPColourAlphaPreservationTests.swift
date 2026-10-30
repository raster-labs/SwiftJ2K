// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2KJPIP

struct R2JPIPColourAlphaPreservationTests {
    @Test("F07: JPIP preserves permuted premultiplied roles and native sYCC through both coding preferences")
    func nativeColourAndPermutedOpacityDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r2-colour-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rgbaDescriptor = try ImageDescriptor.rgbPlanar(width: 4, height: 4, storageBits: 8,
                                                          meaningfulBits: 8, alpha: .premultiplied)
        let rgba = try ImageDestination.allocate(descriptor: rgbaDescriptor).writeSamples { c, _, _ in [32, 48, 64, 128][c] }
        let encoder = try Encoder(configuration: EncoderConfiguration(
            mode: .lossless, codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jp2)
        ))
        let rgbaURL = directory.appendingPathComponent("rgba.jp2")
        try await encoder.encode(rgba).data.write(to: rgbaURL)

        let rgbDescriptor = try ImageDescriptor.rgbPlanar(width: 4, height: 4, storageBits: 8, meaningfulBits: 8)
        let samples = try ImageDestination.allocate(descriptor: rgbDescriptor).writeSamples { c, _, _ in [100, 128, 128][c] }
        let bytes = [UInt8](try await encoder.encode(samples).data)
        var reader = try JP2BoxReader(bytes: bytes, limits: .default)
        var writer = JP2BoxWriter()
        while let box = try reader.nextBox() {
            if box.type == .jp2Header {
                var childReader = try reader.childReader(for: box)
                var header = JP2BoxWriter()
                while let child = try childReader.nextBox() {
                    let payload = child.type == .colourSpecification
                        ? try JP2ColourSpecificationBox(method: .enumerated(18)).serialise()
                        : Array(bytes[child.payloadRange])
                    try header.appendBox(type: child.type, payload: payload)
                }
                try writer.appendBox(type: box.type, payload: header.bytes)
            } else {
                try writer.appendBox(type: box.type, payload: Array(bytes[box.payloadRange]))
            }
        }
        let colourURL = directory.appendingPathComponent("sycc.jp2")
        try Data(writer.bytes).write(to: colourURL)
        let server = JPIPServer(port: 19_426)
        try await server.registerImage(name: "rgba.jp2", at: rgbaURL)
        try await server.registerImage(name: "sycc.jp2", at: colourURL)
        try await server.start()
        defer { Task { try? await server.stop() } }
        for preference in [JPIPCodingPreference.none, .htj2k] {
            let session = JPIPStreamingSession(server: server, port: 19_426,
                configuration: try JPIPSessionConfiguration(codingPreference: preference))
            let view = try await session.deliverImage(imageID: "rgba.jp2",
                                                      viewWindow: JPIPViewWindow(components: [3, 0, 1, 2]))
            for image in [view.image, try view.legacyImage.toContractImage()] {
                #expect(image.descriptor.alpha == .premultiplied)
                #expect(image.descriptor.components == [.alpha, .red, .green, .blue])
                for c in 0..<4 { #expect(try image.sampleInt(component: c, x: 0, y: 0) == [128, 32, 48, 64][c]) }
            }
            let colour = try await session.deliverImage(imageID: "sycc.jp2",
                viewWindow: JPIPViewWindow(region: (x: 1, y: 1, width: 2, height: 2)))
            for image in [colour.image, try colour.legacyImage.toContractImage()] {
                #expect(image.descriptor.colour == .unknown)
                #expect(image.metadata.requiredKeys.contains("colr"))
                #expect(image.descriptor.components == [.uninterpreted("colr.18.1"), .uninterpreted("colr.18.2"), .uninterpreted("colr.18.3")])
                for c in 0..<3 { #expect(try image.sampleInt(component: c, x: 0, y: 0) == [100, 128, 128][c]) }
            }
            try await session.close()
        }
    }
}
