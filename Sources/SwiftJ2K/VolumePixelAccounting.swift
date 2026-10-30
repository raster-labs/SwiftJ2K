// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// Counts explicit pixel buffers and bridge conversions for one volume operation.
/// Reconstruction/coefficient arrays remain algorithm workspace. Concurrent ARC
/// lifetimes are not measured here, so a bridge operation cannot claim a pixel peak.
package enum VolumePixelAccounting {
    package enum Conversion: Int, CaseIterable, Sendable {
        case packEncoderSlice
        case copyEncoderSlice
        case unpackDecoderSlice

        var layouts: (reason: String, source: String, destination: String) {
            switch self {
            case .packEncoderSlice:
                return ("pack reconstructed slice samples for the 2D encoder", "int32-slice-samples", "packed-slice-pixels")
            case .copyEncoderSlice:
                return ("copy packed slice pixels into the 2D encoder destination", "packed-slice-pixels", "image-destination")
            case .unpackDecoderSlice:
                return ("convert decoded slice pixels into reconstruction samples", "image-destination", "int32-slice-samples")
            }
        }
    }

    private struct State: Sendable {
        var allocationCount = 0
        var copyBytes = [Int](repeating: 0, count: Conversion.allCases.count)
    }

    package final class Recorder: Sendable {
        private let state = Mutex(State())
        package init() {}
        package var allocationCount: Int { state.withLock { $0.allocationCount } }

        package var copyEvents: [CopyEvent] {
            get throws {
                let bytes = state.withLock { $0.copyBytes }
                return try Conversion.allCases.compactMap { conversion in
                    guard bytes[conversion.rawValue] > 0 else { return nil }
                    let layouts = conversion.layouts
                    return try CopyEvent(reason: layouts.reason, bytesMoved: bytes[conversion.rawValue],
                                         sourceLayout: layouts.source, destinationLayout: layouts.destination)
                }
            }
        }

        fileprivate func recordAllocation() throws {
            try state.withLock { $0.allocationCount = try checkedAdd($0.allocationCount, 1) }
        }

        fileprivate func recordConversion(_ conversion: Conversion, bytes: Int) throws {
            guard bytes >= 0 else {
                throw CodecError(.invalidArgument, "Pixel conversion byte count must not be negative")
            }
            try state.withLock {
                $0.copyBytes[conversion.rawValue] = try checkedAdd($0.copyBytes[conversion.rawValue], bytes)
            }
        }
    }

    @TaskLocal package static var recorder: Recorder?

    package static func recordAllocation() throws {
        if let recorder { try recorder.recordAllocation() }
    }

    package static func recordConversion(_ conversion: Conversion, bytes: Int) throws {
        if let recorder { try recorder.recordConversion(conversion, bytes: bytes) }
    }
}
