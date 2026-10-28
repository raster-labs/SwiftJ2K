// SPDX-License-Identifier: Apache-2.0
//
// JP3DProgressiveDecoder.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DProgressiveDecoder.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.

import Foundation
import SwiftJ2K

/// Progressive decoding mode.
public enum JP3DProgressionMode: Sendable, Equatable {
    /// Resolution-progressive: decode from lowest to highest resolution.
    case resolution

    /// Quality-progressive: decode from lowest to highest quality layer.
    case quality

    /// Slice-progressive: decode Z-slices incrementally in batches.
    case slice(batchSize: Int)
}

/// A partial result yielded during progressive decoding.
public struct JP3DProgressiveResult: Sendable {
    /// The partially reconstructed volume at this progression step.
    public let volume: J2KVolume

    /// The progression step index (0-based).
    public let stepIndex: Int

    /// The total number of steps.
    public let totalSteps: Int

    /// Progress fraction (0.0 to 1.0).
    public var progress: Double {
        guard totalSteps > 0 else { return 1.0 }
        return Double(stepIndex + 1) / Double(totalSteps)
    }

    /// Whether this is the final (full quality/resolution) result.
    public var isFinal: Bool { stepIndex == totalSteps - 1 }

    public init(volume: J2KVolume, stepIndex: Int, totalSteps: Int) {
        self.volume = volume
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
    }
}

/// Provides progressive (incremental) decoding of JP3D volumetric codestreams.
public actor JP3DProgressiveDecoder {
    // MARK: - State

    private let configuration: JP3DDecoderConfiguration
    private var cancelled = false

    // MARK: - Init

    /// Creates a progressive decoder with the given configuration.
    public init(configuration: JP3DDecoderConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Cancels an in-progress progressive decode.
    public func cancel() {
        cancelled = true
    }

    /// Resets the cancellation flag, allowing a new decode to start.
    public func reset() {
        cancelled = false
    }

    /// Decodes a JP3D codestream progressively, invoking a callback at each step.
    public func decode(
        _ data: Data,
        mode: JP3DProgressionMode,
        onProgress: @Sendable (JP3DProgressiveResult) async -> Bool
    ) async throws {
        cancelled = false

        switch mode {
        case .resolution:
            try await decodeResolutionProgressive(data, onProgress: onProgress)
        case .quality:
            try await decodeQualityProgressive(data, onProgress: onProgress)
        case .slice(let batchSize):
            try await decodeSliceProgressive(data, batchSize: max(1, batchSize), onProgress: onProgress)
        }
    }

    // MARK: - Resolution-Progressive

    private func decodeResolutionProgressive(
        _ data: Data,
        onProgress: @Sendable (JP3DProgressiveResult) async -> Bool
    ) async throws {
        let parser = JP3DCodestreamParser()
        let codestream = try parser.parse(data)
        let cod = codestream.cod

        let maxLevel = max(cod.levelsX, max(cod.levelsY, cod.levelsZ))
        let totalSteps = maxLevel + 1

        for step in 0..<totalSteps {
            guard !cancelled else { return }

            let resReduction = totalSteps - 1 - step
            let config = JP3DDecoderConfiguration(
                maxQualityLayers: 0,
                resolutionLevel: resReduction,
                tolerateErrors: configuration.tolerateErrors
            )

            let decoder = JP3DDecoder(configuration: config)
            let result = try await decoder.decode(data)

            let partial = JP3DProgressiveResult(
                volume: result.volume,
                stepIndex: step,
                totalSteps: totalSteps
            )

            let shouldContinue = await onProgress(partial)
            if !shouldContinue { return }
        }
    }

    // MARK: - Quality-Progressive

    private func decodeQualityProgressive(
        _ data: Data,
        onProgress: @Sendable (JP3DProgressiveResult) async -> Bool
    ) async throws {
        let steps = 3
        for step in 0..<steps {
            guard !cancelled else { return }

            let maxLayers = step + 1
            let config = JP3DDecoderConfiguration(
                maxQualityLayers: maxLayers,
                resolutionLevel: 0,
                tolerateErrors: configuration.tolerateErrors
            )
            let decoder = JP3DDecoder(configuration: config)
            let result = try await decoder.decode(data)

            let partial = JP3DProgressiveResult(
                volume: result.volume,
                stepIndex: step,
                totalSteps: steps
            )

            let shouldContinue = await onProgress(partial)
            if !shouldContinue { return }
        }
    }

    // MARK: - Slice-Progressive

    private func decodeSliceProgressive(
        _ data: Data,
        batchSize: Int,
        onProgress: @Sendable (JP3DProgressiveResult) async -> Bool
    ) async throws {
        let parser = JP3DCodestreamParser()
        let codestream = try parser.parse(data)
        let siz = codestream.siz

        let totalDepth = siz.depth
        let numBatches = max(1, (totalDepth + batchSize - 1) / batchSize)

        let fullConfig = JP3DDecoderConfiguration(
            maxQualityLayers: 0,
            resolutionLevel: 0,
            tolerateErrors: configuration.tolerateErrors
        )
        let decoder = JP3DDecoder(configuration: fullConfig)
        let fullResult = try await decoder.decode(data)
        let fullVolume = fullResult.volume

        for batch in 0..<numBatches {
            guard !cancelled else { return }

            let z0 = batch * batchSize
            let z1 = min(z0 + batchSize, totalDepth)

            let batchVolume = extractSliceRange(
                from: fullVolume,
                z0: z0, z1: z1,
                siz: siz
            )

            let partial = JP3DProgressiveResult(
                volume: batchVolume,
                stepIndex: batch,
                totalSteps: numBatches
            )

            let shouldContinue = await onProgress(partial)
            if !shouldContinue { return }
        }
    }

    private func extractSliceRange(
        from volume: J2KVolume,
        z0: Int,
        z1: Int,
        siz: JP3DSIZInfo
    ) -> J2KVolume {
        let w = siz.width
        let h = siz.height
        let d = z1 - z0
        let bytesPerSample = (siz.bitDepth + 7) / 8
        var components: [J2KVolumeComponent] = []

        for comp in volume.components {
            let sliceBytes = w * h * bytesPerSample
            var outData = Data(count: d * sliceBytes)
            for z in 0..<d {
                let srcZ = z0 + z
                let srcOffset = srcZ * sliceBytes
                let dstOffset = z * sliceBytes
                let srcEnd = min(srcOffset + sliceBytes, comp.data.count)
                if srcOffset < srcEnd {
                    let range = srcOffset..<srcEnd
                    outData.replaceSubrange(
                        dstOffset..<(dstOffset + (srcEnd - srcOffset)),
                        with: comp.data[range]
                    )
                }
            }
            components.append(J2KVolumeComponent(
                index: comp.index,
                bitDepth: comp.bitDepth,
                signed: comp.signed,
                width: w,
                height: h,
                depth: d,
                data: outData
            ))
        }
        return J2KVolume(width: w, height: h, depth: d, components: components)
    }
}
