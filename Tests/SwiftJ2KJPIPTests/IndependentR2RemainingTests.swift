import Foundation
import Testing
import SwiftJ2K
import SwiftJ2KJPIP

@Suite("Independent R2 remaining-gate probes")
struct IndependentR2RemainingTests {
    @Test("Tiny JPIP view reports at least the full image storage and copy it actually materialises")
    func tinyViewPixelTelemetry() async throws {
        let descriptor = try ImageDescriptor.rgbPlanar(width: 64, height: 64, storageBits: 8, meaningfulBits: 8)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let source = try destination.writeSamples { c, x, y in (c * 37 + x + 3 * y) & 255 }
        let encoded = try await Encoder(configuration: EncoderConfiguration(
            mode: .lossless, codecOptions: CodecOptions(containerFormat: .jp2)
        )).encode(source, options: EncodeOptions(executionPolicy: .scalarCPU))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("independent-tiny-view-\(UUID().uuidString).jp2")
        try encoded.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = JPIPServer(port: 19489)
        try await server.registerImage(name: "image.jp2", at: url)
        try await server.start()
        let session = JPIPStreamingSession(server: server, port: 19489)
        let view = try JPIPViewWindow(region: (x: 1, y: 1, width: 1, height: 1))
        let delivered = try await session.deliverImage(
            imageID: "image.jp2", viewWindow: view,
            options: JPIPStreamingOptions(executionPolicy: .scalarCPU)
        )
        try await session.close()
        try await server.stop()
        #expect(delivered.image.descriptor.width == 1)
        #expect(delivered.image.descriptor.height == 1)
        // The implementation decodes the entire 64x64 RGB image and then
        // copies its 12288 bytes into legacy planes before applying the crop.
        // These lower bounds do not depend on optimiser-dependent lifetimes.
        #expect((delivered.report.peakPixelBytes ?? 0) >= descriptor.requiredByteCount)
        #expect(delivered.report.copyEvents.reduce(0) { $0 + $1.bytesMoved } >= descriptor.requiredByteCount)
    }
}
