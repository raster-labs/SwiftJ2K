// SPDX-License-Identifier: MIT
// Executable companion of MIGRATION.md: an application adapter that holds its
// own padded 16-bit plane, encodes it losslessly, inspects the codestream and
// decodes it straight back into caller-owned storage. The body of this file is
// reproduced verbatim in the guide; keep the two identical.
import Foundation
import SwiftJ2K

// 1. Samples the application already holds: 12 meaningful bits in 16-bit
//    words, five samples per row, rows padded to 16 bytes.
let width = 5, height = 3, rowBytes = 16
var plane = [UInt16](repeating: 0xA5A5, count: rowBytes / 2 * height)
for y in 0..<height {
    for x in 0..<width { plane[y * rowBytes / 2 + x] = UInt16((x * 731 + y * 1093) % 4096) }
}

// 2. Finite limits on every operation, and a descriptor that states the layout.
let limits = try ResourceLimits(maximumCompressedBytes: 1 << 20, maximumDecodedBytes: 1 << 20,
                                maximumWorkspaceBytes: 8 << 20, maximumPixels: 1 << 20,
                                maximumDimension: 4096, deadlineSeconds: 10, maximumMemoryBytes: 16 << 20)
let descriptor = try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: 12,
                                                 rowBytes: rowBytes, limits: limits)

// 3. Source image: one explicit, counted copy of the application's samples.
let source = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
    .writeUInt16 { x, y in plane[y * rowBytes / 2 + x] }

// 4. Lossless encode. `mode` replaces the predecessor's quality/lossless flags.
let encoder = try Encoder(configuration: .init(mode: .lossless, codecOptions: .init(decompositionLevels: 1)))
let encoded = try await encoder.encode(source, options: .init(resourceLimits: limits))

// 5. Inspect first, then decode into storage the application owns.
let decoder = try Decoder()
let info = try decoder.inspect(encoded.data, options: .init(resourceLimits: limits))
guard info.descriptor.width == width, info.descriptor.height == height, info.descriptor.meaningfulBits == 12 else {
    throw CodecError(.internalFailure, "Inspection disagrees with the source.")
}
let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
let decoded = try await decoder.decode(encoded.data, into: destination,
                                       options: .init(resourceLimits: limits, copyPolicy: .requireSharedStorage))

// 6. Lossless means every logical sample, and the report says what the codec did.
for y in 0..<height {
    for x in 0..<width where try decoded.image.sampleUInt16(x: x, y: y) != plane[y * rowBytes / 2 + x] {
        throw CodecError(.internalFailure, "Round trip changed sample (\(x), \(y)).")
    }
}
guard decoded.report.copyEvents.isEmpty, decoded.report.pixelAllocationCount == 0 else {
    throw CodecError(.internalFailure, "The shared-storage path copied or allocated pixels.")
}

// 7. Unsupported or malformed input stays an error; it never becomes empty output.
do {
    _ = try await decoder.decode(Data([0xFF, 0x4F, 0xFF, 0x51]), options: .init(resourceLimits: limits))
    throw CodecError(.internalFailure, "A truncated codestream decoded.")
} catch let error as CodecError where error.category == .malformedInput {}

print("Migration example passed: \(encoded.data.count)-byte lossless codestream; decode into caller storage with \(decoded.report.pixelAllocationCount ?? -1) pixel allocations and \(decoded.report.copyEvents.count) copy events.")
