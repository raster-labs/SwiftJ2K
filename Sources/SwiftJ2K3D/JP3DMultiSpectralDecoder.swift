// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DMultiSpectralDecoder.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

// MARK: - JP3DMultiSpectralDecodeOptions

/// Options controlling how a multi-spectral volume is decoded.
public struct JP3DMultiSpectralDecodeOptions: Sendable {
    /// The subset of band indices to decode, or `nil` to decode all bands.
    public var targetBands: [Int]?

    /// The resolution level to decode (0 = full resolution, higher = lower resolution).
    public var resolutionLevel: Int

    /// Creates decode options.
    public init(targetBands: [Int]? = nil, resolutionLevel: Int = 0) {
        self.targetBands = targetBands
        self.resolutionLevel = max(0, resolutionLevel)
    }

    /// Default decode options: all bands at full resolution.
    public static let full = JP3DMultiSpectralDecodeOptions(
        targetBands: nil,
        resolutionLevel: 0
    )
}

// MARK: - JP3DMultiSpectralDecoder

/// Actor-based decoder for multi-spectral JP3D codestreams.
public actor JP3DMultiSpectralDecoder {
    /// Creates a new multi-spectral decoder.
    public init() {}

    /// Decodes a multi-spectral encode result into a volumetric data structure.
    public func decode(
        _ result: JP3DMultiSpectralEncodeResult,
        options: JP3DMultiSpectralDecodeOptions = .full
    ) async throws -> JP3DMultiSpectralVolume {
        let bandIndices: [Int] = options.targetBands
            ?? Array(0..<result.encodedBands.count)

        guard !bandIndices.isEmpty else {
            throw J2KError.invalidParameter("No bands selected for multi-spectral decode")
        }

        for idx in bandIndices {
            guard idx >= 0 && idx < result.encodedBands.count else {
                throw J2KError.invalidParameter(
                    "Band index \(idx) is out of range (0..<\(result.encodedBands.count))"
                )
            }
        }

        let selectedBands: [JP3DSpectralBand] = bandIndices.map { idx in
            if idx < result.spectralMapping.bands.count {
                return result.spectralMapping.bands[idx]
            } else {
                return JP3DSpectralBand(
                    bandIndex: idx,
                    wavelengthNanometres: 400.0 + Double(idx) * 50.0,
                    description: "Band \(idx)"
                )
            }
        }

        let samplesPerBand: [[Float]] = try bandIndices.map { idx in
            try decodeBand(result.encodedBands[idx])
        }

        let (width, height, depth) = try parseDimensions(from: result.encodedBands[bandIndices[0]])

        return JP3DMultiSpectralVolume(
            width: width,
            height: height,
            depth: depth,
            bands: selectedBands,
            samplesPerBand: samplesPerBand
        )
    }

    /// Classifies each voxel in a decoded volume using spectral signatures.
    public func classifyPixels(
        _ volume: JP3DMultiSpectralVolume
    ) async -> [[JP3DSpectralClassification]] {
        let planeSize = volume.width * volume.height
        return (0..<volume.depth).map { z in
            (0..<planeSize).map { pixel in
                classifyVoxel(at: pixel, z: z, in: volume)
            }
        }
    }

    // MARK: - Private Helpers

    private func parseDimensions(from data: Data) throws -> (width: Int, height: Int, depth: Int) {
        guard data.count >= 12 else {
            throw J2KError.invalidParameter("Codestream too short to parse dimensions")
        }
        let base = data.startIndex
        if data.count >= 24,
           data[base] == 0x4A, data[base + 1] == 0x50,
           data[base + 2] == 0x33, data[base + 3] == 0x4D {
            let width = Int(readUInt32(data, offset: base + 12))
            let height = Int(readUInt32(data, offset: base + 16))
            let depth = Int(readUInt32(data, offset: base + 20))
            return (width: max(1, width), height: max(1, height), depth: max(1, depth))
        }
        let sampleCount = Int(readUInt32(data, offset: base + 8))
        return (width: 1, height: 1, depth: max(1, sampleCount))
    }

    private func decodeBand(_ data: Data) throws -> [Float] {
        guard data.count >= 12 else {
            throw J2KError.invalidParameter("Band codestream is too short")
        }
        let base = data.startIndex
        let headerSize: Int
        if data.count >= 24,
           data[base] == 0x4A, data[base + 1] == 0x50,
           data[base + 2] == 0x33, data[base + 3] == 0x4D {
            headerSize = 24
        } else {
            headerSize = 12
        }
        let payload = data[(base + headerSize)..<data.endIndex]
        return payload.map { Float($0) / 255.0 }
    }

    private func readUInt32(_ data: Data, offset: Data.Index) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private func classifyVoxel(
        at pixel: Int,
        z: Int,
        in volume: JP3DMultiSpectralVolume
    ) -> JP3DSpectralClassification {
        var reflectance = [Double]()
        for b in 0..<volume.bandCount where b < volume.samplesPerBand.count {
            let idx = z * volume.width * volume.height + pixel
            guard idx < volume.samplesPerBand[b].count else { continue }
            reflectance.append(Double(volume.samplesPerBand[b][idx]))
        }
        guard !reflectance.isEmpty else { return .unclassified }

        let mean = reflectance.reduce(0, +) / Double(reflectance.count)
        if mean > 0.85 { return .cloud }
        if mean < 0.08 { return .water }
        if mean > 0.35 { return .vegetation }
        if mean > 0.25 { return .urban }
        if mean > 0.15 { return .bareSoil }
        return .unclassified
    }
}
