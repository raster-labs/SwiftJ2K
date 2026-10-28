// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DSpectralAnalysis.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

// MARK: - JP3DSpectralIndex

/// Standard normalised spectral indices for remote-sensing analysis.
public enum JP3DSpectralIndex: Sendable, Equatable, CaseIterable {
    /// Normalised Difference Vegetation Index (NDVI).
    case ndvi

    /// Normalised Difference Water Index (NDWI).
    case ndwi

    /// Normalised Difference Built-up Index (NDBI).
    case ndbi
}

// MARK: - JP3DSpectralIndexResult

/// The computed values for a single spectral index over a multi-spectral volume.
public struct JP3DSpectralIndexResult: Sendable {
    /// The spectral index that was computed.
    public let index: JP3DSpectralIndex

    /// Per-Z-slice index values; `values[z]` has `width * height` entries.
    public let values: [[Float]]

    /// Creates a spectral index result.
    public init(index: JP3DSpectralIndex, values: [[Float]]) {
        self.index = index
        self.values = values
    }
}

// MARK: - JP3DSpectralAnalyser

/// Actor that computes spectral indices and inter-band correlation matrices
/// for multi-spectral JP3D volumes.
public actor JP3DSpectralAnalyser {
    /// Creates a new spectral analyser.
    public init() {}

    /// Computes the specified spectral index over all Z-slices of a volume.
    public func computeIndex(
        _ volume: JP3DMultiSpectralVolume,
        index: JP3DSpectralIndex
    ) async throws -> JP3DSpectralIndexResult {
        let (bandA, bandB) = try resolveBandPair(for: index, in: volume)
        let planeSize = volume.width * volume.height

        let slices: [[Float]] = (0..<volume.depth).map { z in
            let offset = z * planeSize
            return (0..<planeSize).map { p in
                let i = offset + p
                guard bandA < volume.samplesPerBand.count,
                      bandB < volume.samplesPerBand.count,
                      i < volume.samplesPerBand[bandA].count,
                      i < volume.samplesPerBand[bandB].count else { return 0 }
                let a = volume.samplesPerBand[bandA][i]
                let b = volume.samplesPerBand[bandB][i]
                let denom = a + b
                return denom == 0 ? 0 : (b - a) / denom
            }
        }

        return JP3DSpectralIndexResult(index: index, values: slices)
    }

    /// Computes the Pearson inter-band correlation matrix for a multi-spectral volume.
    public func computeCorrelationMatrix(
        _ volume: JP3DMultiSpectralVolume
    ) async -> [[Double]] {
        let n = min(volume.bandCount, volume.samplesPerBand.count)
        guard n > 0 else { return [] }

        let means: [Double] = volume.samplesPerBand.prefix(n).map { samples in
            guard !samples.isEmpty else { return 0 }
            return samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        }

        let stds: [Double] = volume.samplesPerBand.prefix(n).enumerated().map { (b, samples) in
            guard !samples.isEmpty else { return 1 }
            let mu = means[b]
            let variance = samples.reduce(0.0) { acc, v in
                let d = Double(v) - mu
                return acc + d * d
            } / Double(samples.count)
            return max(1e-12, variance.squareRoot())
        }

        var matrix = [[Double]](
            repeating: [Double](repeating: 0, count: n),
            count: n
        )

        for i in 0..<n {
            for j in i..<n {
                if i == j {
                    matrix[i][j] = 1.0
                } else {
                    let sampA = volume.samplesPerBand[i]
                    let sampB = volume.samplesPerBand[j]
                    let count = min(sampA.count, sampB.count)
                    guard count > 0 else { continue }
                    var cov = 0.0
                    for k in 0..<count {
                        cov += (Double(sampA[k]) - means[i]) * (Double(sampB[k]) - means[j])
                    }
                    cov /= Double(count)
                    let r = cov / (stds[i] * stds[j])
                    matrix[i][j] = r
                    matrix[j][i] = r
                }
            }
        }

        return matrix
    }

    // MARK: - Private Helpers

    private func resolveBandPair(
        for index: JP3DSpectralIndex,
        in volume: JP3DMultiSpectralVolume
    ) throws -> (Int, Int) {
        guard volume.bandCount >= 2, volume.samplesPerBand.count >= 2 else {
            throw J2KError.invalidParameter(
                "At least 2 bands are required to compute spectral index \(index)"
            )
        }

        func closestBand(to targetNm: Double) -> Int {
            volume.bands.enumerated().min(by: {
                abs($0.element.wavelengthNanometres - targetNm) <
                abs($1.element.wavelengthNanometres - targetNm)
            })?.offset ?? 0
        }

        switch index {
        case .ndvi:
            return (closestBand(to: 665), closestBand(to: 842))
        case .ndwi:
            return (closestBand(to: 560), closestBand(to: 842))
        case .ndbi:
            return (closestBand(to: 842), closestBand(to: 1610))
        }
    }
}
