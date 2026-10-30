// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K
import SwiftJ2KJPIP

struct R2PixelAccountingTests {
    @Test func combinedViewCountsFullDecodeAndEveryMaterialisedView() async throws {
        let descriptor = try ImageDescriptor.rgbPlanar(width: 64, height: 64, storageBits: 8, meaningfulBits: 8)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, x, y in
            (c * 40 + x + y) & 255
        }
        let encoded = try await Encoder(configuration: EncoderConfiguration(mode: .lossless,
            codecOptions: CodecOptions(colourTransform: .none, containerFormat: .jp2)))
            .encode(source, options: EncodeOptions(executionPolicy: .scalarCPU))
        let result = try J2KDecoder.decodeWithInfo(encoded.data, resolutionLevel: 1,
            components: [2, 0, 1], region: (1, 1, 4, 4), executionPolicy: .scalarCPU)
        // Full contract + full legacy remain explicitly owned until projection finishes.
        // Crop materialises 3*4*4 bytes; reduction materialises another3*2*2.
        #expect(result.pixelAccounting.copyEvents.map(\.bytesMoved) == [12288, 48, 12])
        #expect(result.pixelAccounting.allocationCount == 10)
        #expect(result.pixelAccounting.peakBytes == 24576 + 48 + 12)
        #expect(try result.image.toContractImage().sampleInt(component: 0, x: 1, y: 1) == 86)
    }

    @Test func finalLegacyConversionAdmitsBothSourceAndDestination() throws {
        let legacy = J2KImage(width: 8, height: 8, components: [J2KComponent(
            index: 0, bitDepth: 8, width: 8, height: 8, data: Data(repeating: 7, count: 64))], colorSpace: .grayscale)
        let limits = try ResourceLimits(maximumMemoryBytes: 191)
        do {
            _ = try legacy.toContractImage(colourOverride: nil, alphaOverride: nil,
                iccProfileOverride: nil, metadata: .empty, limits: limits, retainedBytes: 64)
            Issue.record("Source64 plus destination128 bytes must not fit in191 bytes")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        let image = try legacy.toContractImage(colourOverride: nil, alphaOverride: nil,
            iccProfileOverride: nil, metadata: .empty,
            limits: ResourceLimits(maximumMemoryBytes: 192), retainedBytes: 64)
        #expect(try image.sampleUInt16(x: 7, y: 7) == 7)
    }
}
