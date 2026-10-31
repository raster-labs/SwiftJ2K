// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("R3 terminal progress publication")
struct CodexR3ProgressTests {
    @Test("Required acceleration rejected after tile work never announces success")
    func ineligibleTilesDoNotComplete() async throws {
        // Original RA2-08 reproducer: no eligible accelerated kernel for
        // the 1x1x2 volume. Required-backend failure must precede completion.
        let volume = J2KVolume(width: 1, height: 1, depth: 2, components: [
            J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
                               width: 1, height: 1, depth: 2,
                               data: Data([7, 31]))
        ])
        let configuration = try VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 1, tileSizeY: 1, tileSizeZ: 1),
            levelsX: 0, levelsY: 0, levelsZ: 0
        )
        let source = try await VolumeEncoder(configuration: configuration).encode(volume)
        let phases = Mutex<[ProgressUpdate.Phase]>([])
        let progress: @Sendable (ProgressUpdate) -> Void = { p in phases.withLock { $0.append(p.phase) } }
        for operation in 0..<3 {
            phases.withLock { $0.removeAll() }
            do {
                switch operation {
                case 0:
                    _ = try await VolumeEncoder(configuration: configuration).encode(volume,
                        options: VolumeEncodeOptions(executionPolicy: .required(.accelerated), progress: progress))
                case 1:
                    _ = try await VolumeDecoder().decode(source.data,
                        options: VolumeDecodeOptions(executionPolicy: .required(.accelerated), progress: progress))
                default:
                    _ = try await VolumeTranscoder().transcode(source.data, to: .htj2k,
                        options: TranscodeOptions(executionPolicy: .required(.accelerated), progress: progress))
                }
                Issue.record("Ineligible tile geometry unexpectedly used acceleration")
            } catch let error as CodecError {
                #expect(error.category == .backendUnavailable)
            }
            #expect(!phases.withLock { $0 }.contains(.completed))
        }
    }

}
