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

        let encodedBands: [Data] = processed.enumerated().map { (index, samples) in
            encodeBand(
                samples: samples,
                bandIndex: index,
                width: volume.width,
                height: volume.height,
                depth: volume.depth,
                qualityLayers: configuration.qualityLayersPerBand
            )
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

    private func encodeBand(
        samples: [Float],
        bandIndex: Int,
        width: Int,
        height: Int,
        depth: Int,
        qualityLayers: Int
    ) -> Data {
        _ = qualityLayers
        var data = Data()
        data.reserveCapacity(24 + samples.count)
        // 4-byte magic "JP3M" (extended multi-spectral band header with width/height/depth)
        data.append(contentsOf: [0x4A, 0x50, 0x33, 0x4D])
        withUnsafeBytes(of: UInt32(clamping: bandIndex).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(clamping: samples.count).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(clamping: width).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(clamping: height).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(clamping: depth).bigEndian) { data.append(contentsOf: $0) }
        for s in samples {
            let clamped = max(0, min(1, s))
            data.append(UInt8((clamped * 255).rounded()))
        }
        return data
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
