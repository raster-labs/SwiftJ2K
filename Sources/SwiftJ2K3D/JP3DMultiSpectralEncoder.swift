// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DMultiSpectralEncoder.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

// MARK: - JP3DMultiSpectralEncoderConfiguration

/// Configuration for the multi-spectral JP3D encoder.
public struct JP3DMultiSpectralEncoderConfiguration: Sendable {
    /// The base JP3D encoding configuration (tiling, wavelet, etc.).
    public var baseConfiguration: JP3DEncoderConfiguration

    /// The spectral-specific configuration (mapping, normalisation, prediction).
    public var spectralConfig: JP3DSpectralConfiguration

    /// Number of quality layers encoded per spectral band.
    public var qualityLayersPerBand: Int

    /// When `true`, the encoder applies a spectral decorrelation transform
    /// before per-band compression.
    public var enableSpectralDecorelation: Bool

    /// Creates an encoder configuration.
    public init(
        baseConfiguration: JP3DEncoderConfiguration,
        spectralConfig: JP3DSpectralConfiguration,
        qualityLayersPerBand: Int,
        enableSpectralDecorelation: Bool
    ) {
        self.baseConfiguration = baseConfiguration
        self.spectralConfig = spectralConfig
        self.qualityLayersPerBand = max(1, qualityLayersPerBand)
        self.enableSpectralDecorelation = enableSpectralDecorelation
    }

    /// Default encoder configuration.
    public static let `default` = JP3DMultiSpectralEncoderConfiguration(
        baseConfiguration: .lossless,
        spectralConfig: .default,
        qualityLayersPerBand: 1,
        enableSpectralDecorelation: false
    )
}

// MARK: - JP3DMultiSpectralEncodeResult

/// The result of encoding a multi-spectral volume.
public struct JP3DMultiSpectralEncodeResult: Sendable {
    /// Encoded codestream data for each band.
    public let encodedBands: [Data]

    /// The spectral mapping used during encoding.
    public let spectralMapping: JP3DSpectralMapping

    /// Creates an encode result.
    public init(encodedBands: [Data], spectralMapping: JP3DSpectralMapping) {
        self.encodedBands = encodedBands
        self.spectralMapping = spectralMapping
    }

    /// The total number of encoded bytes across all bands.
    public var totalBytes: Int {
        encodedBands.reduce(0) { $0 + $1.count }
    }
}

// MARK: - JP3DMultiSpectralEncoder

/// Actor-based encoder for multi-spectral JP3D volumetric data.
public actor JP3DMultiSpectralEncoder {
    /// Creates a new multi-spectral encoder.
    public init() {}

    /// Encodes a multi-spectral volume into per-band JP3D codestreams.
    public func encode(
        _ volume: JP3DMultiSpectralVolume,
        configuration: JP3DMultiSpectralEncoderConfiguration = .default
    ) async throws -> JP3DMultiSpectralEncodeResult {
        guard volume.bandCount == volume.samplesPerBand.count else {
            throw J2KError.invalidParameter(
                "Band count (\(volume.bandCount)) does not match samplesPerBand count " +
                "(\(volume.samplesPerBand.count))"
            )
        }

        var processed = volume.samplesPerBand
        if configuration.spectralConfig.enableInterBandPrediction {
            processed = applyInterBandPrediction(processed)
        }
        if configuration.enableSpectralDecorelation {
            processed = applySpectralDecorelation(processed)
        }

        var encodedBands: [Data] = []
        encodedBands.reserveCapacity(processed.count)
        for (index, samples) in processed.enumerated() {
            let bandCodestream = try await encodeBand(
                samples: samples,
                bandIndex: index,
                width: volume.width,
                height: volume.height,
                depth: volume.depth,
                baseConfiguration: configuration.baseConfiguration,
                qualityLayers: configuration.qualityLayersPerBand
            )
            encodedBands.append(bandCodestream)
        }

        let effectiveMapping = volume.bands.isEmpty
            ? configuration.spectralConfig.spectralMapping
            : JP3DSpectralMapping(bands: volume.bands)

        return JP3DMultiSpectralEncodeResult(
            encodedBands: encodedBands,
            spectralMapping: effectiveMapping
        )
    }

    /// Computes descriptive statistics for all bands in a multi-spectral volume.
    public func computeStatistics(
        _ volume: JP3DMultiSpectralVolume
    ) async -> JP3DMultiSpectralStatistics {
        var means = [Double](repeating: 0, count: volume.bandCount)
        var stdDevs = [Double](repeating: 0, count: volume.bandCount)
        var mins = [Double](repeating: 0, count: volume.bandCount)
        var maxs = [Double](repeating: 0, count: volume.bandCount)

        for (b, samples) in volume.samplesPerBand.enumerated() where b < volume.bandCount {
            guard !samples.isEmpty else { continue }
            let n = Double(samples.count)
            let minVal = Double(samples.min() ?? 0)
            let maxVal = Double(samples.max() ?? 0)
            let sum = samples.reduce(0.0) { $0 + Double($1) }
            let mean = sum / n
            let variance = samples.reduce(0.0) { acc, v in
                let d = Double(v) - mean
                return acc + d * d
            } / n
            means[b] = mean
            stdDevs[b] = variance.squareRoot()
            mins[b] = minVal
            maxs[b] = maxVal
        }

        return JP3DMultiSpectralStatistics(
            meanPerBand: means,
            stdDevPerBand: stdDevs,
            minPerBand: mins,
            maxPerBand: maxs
        )
    }

    // MARK: - Private Helpers

    /// Fixed-point reflectance scale factor (`1.0 == 8192` in signed 16-bit voxels,
    /// supporting reflectance and signed inter-band/decorrelation residuals in `[-4.0, +3.9998]`).
    internal static let reflectanceFixedPointScale: Double = 8192.0

    private static func maxAxisLevels(for dimension: Int, requested: Int) -> Int {
        guard dimension > 1, requested > 0 else { return 0 }
        var maxLvl = 0
        var d = dimension
        while d > 1 {
            d = (d + 1) / 2
            maxLvl += 1
        }
        return min(requested, maxLvl)
    }

    private func encodeBand(
        samples: [Float],
        bandIndex: Int,
        width: Int,
        height: Int,
        depth: Int,
        baseConfiguration: JP3DEncoderConfiguration,
        qualityLayers: Int
    ) async throws -> Data {
        _ = bandIndex
        let w = max(1, width)
        let h = max(1, height)
        let d = max(1, depth)
        let voxelCount = w * h * d
        var pcm = Data(count: voxelCount * 2)
        let scale = Self.reflectanceFixedPointScale
        pcm.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<voxelCount {
                let f = i < samples.count ? Double(samples[i]) : 0.0
                let scaled = f.isFinite ? (f * scale).rounded() : 0.0
                let clamped = Int16(clamping: Int64(max(-32768.0, min(32767.0, scaled))))
                let word = UInt16(bitPattern: clamped)
                base[i * 2] = UInt8(truncatingIfNeeded: word)
                base[i * 2 + 1] = UInt8(truncatingIfNeeded: word >> 8)
            }
        }
        let component = J2KVolumeComponent(
            index: 0,
            bitDepth: 16,
            signed: true,
            width: w,
            height: h,
            depth: d,
            data: pcm
        )
        let bandVolume = J2KVolume(width: w, height: h, depth: d, components: [component])
        let tileW = min(w, max(1, baseConfiguration.tiling.tileSizeX))
        let tileH = min(h, max(1, baseConfiguration.tiling.tileSizeY))
        let tileD = min(d, max(1, baseConfiguration.tiling.tileSizeZ))
        let bandEncConfig = JP3DEncoderConfiguration(
            compressionMode: baseConfiguration.compressionMode,
            tiling: JP3DTilingConfiguration(tileSizeX: tileW, tileSizeY: tileH, tileSizeZ: tileD),
            progressionOrder: baseConfiguration.progressionOrder,
            qualityLayers: max(1, qualityLayers),
            levelsX: Self.maxAxisLevels(for: tileW, requested: baseConfiguration.levelsX),
            levelsY: Self.maxAxisLevels(for: tileH, requested: baseConfiguration.levelsY),
            levelsZ: Self.maxAxisLevels(for: tileD, requested: baseConfiguration.levelsZ),
            parallelEncoding: baseConfiguration.parallelEncoding,
            maximumWorkers: baseConfiguration.maximumWorkers
        )
        let encoder = JP3DEncoder(configuration: bandEncConfig)
        let result = try await encoder.encode(bandVolume)
        return result.data
    }

    private func applyInterBandPrediction(_ samplesPerBand: [[Float]]) -> [[Float]] {
        guard samplesPerBand.count > 1 else { return samplesPerBand }
        var result = samplesPerBand
        for b in stride(from: samplesPerBand.count - 1, through: 1, by: -1) {
            result[b] = zip(samplesPerBand[b], samplesPerBand[b - 1]).map { $0 - $1 }
        }
        return result
    }

    private func applySpectralDecorelation(_ samplesPerBand: [[Float]]) -> [[Float]] {
        samplesPerBand.map { samples in
            guard !samples.isEmpty else { return samples }
            let mean = Float(samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count))
            return samples.map { $0 - mean }
        }
    }
}
