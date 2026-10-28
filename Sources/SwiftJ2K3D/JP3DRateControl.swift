// SPDX-License-Identifier: Apache-2.0
//
// JP3DRateControl.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DRateControl.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.

import Foundation
import SwiftJ2K

/// Result of quantizing a tile's wavelet coefficients.
public struct JP3DQuantizedTile: Sendable {
    /// The tile this quantized data belongs to.
    public let tile: JP3DTile

    /// The component index.
    public let componentIndex: Int

    /// Quantized coefficients as Int32 values.
    public let coefficients: [Int32]

    /// The quantization step size used.
    public let stepSize: Float

    /// The width of the tile data.
    public let width: Int

    /// The height of the tile data.
    public let height: Int

    /// The depth of the tile data.
    public let depth: Int

    /// Number of decomposition levels.
    public let decompositionLevels: Int

    public init(
        tile: JP3DTile,
        componentIndex: Int,
        coefficients: [Int32],
        stepSize: Float,
        width: Int,
        height: Int,
        depth: Int,
        decompositionLevels: Int
    ) {
        self.tile = tile
        self.componentIndex = componentIndex
        self.coefficients = coefficients
        self.stepSize = stepSize
        self.width = width
        self.height = height
        self.depth = depth
        self.decompositionLevels = decompositionLevels
    }
}

/// A quality layer containing rate-distortion optimised data.
public struct JP3DQualityLayer: Sendable {
    /// The quality layer index (0 = lowest quality).
    public let index: Int

    /// The target bitrate for this layer in bits per voxel.
    public let targetBitsPerVoxel: Float

    /// Truncation points for each code-block contribution.
    public let truncationPoints: [Int]

    /// The estimated distortion reduction from this layer.
    public let distortionReduction: Float

    public init(
        index: Int,
        targetBitsPerVoxel: Float,
        truncationPoints: [Int],
        distortionReduction: Float
    ) {
        self.index = index
        self.targetBitsPerVoxel = targetBitsPerVoxel
        self.truncationPoints = truncationPoints
        self.distortionReduction = distortionReduction
    }
}

/// Rate controller for JP3D encoding.
public struct JP3DRateController: Sendable {
    /// The compression mode.
    public let mode: JP3DCompressionMode

    /// Number of quality layers.
    public let qualityLayers: Int

    /// Creates a rate controller for the given compression mode.
    public init(mode: JP3DCompressionMode = .lossless, qualityLayers: Int = 1) {
        self.mode = mode
        self.qualityLayers = max(1, qualityLayers)
    }

    /// Computes the quantization step size for the given compression mode.
    public func stepSize(bitDepth: Int, decompositionLevels: Int) -> Float {
        switch mode {
        case .lossless, .losslessHTJ2K:
            return 1.0
        case .lossy(let psnr):
            return stepSizeForPSNR(psnr, bitDepth: bitDepth)
        case .lossyHTJ2K(let psnr):
            return stepSizeForPSNR(psnr, bitDepth: bitDepth)
        case .targetBitrate(let bpv):
            return stepSizeForBitrate(bpv, bitDepth: bitDepth, levels: decompositionLevels)
        case .visuallyLossless:
            return stepSizeForPSNR(50.0, bitDepth: bitDepth)
        }
    }

    /// Quantizes wavelet coefficients for a tile.
    public func quantize(
        coefficients: [Float],
        tile: JP3DTile,
        componentIndex: Int,
        bitDepth: Int,
        decompositionLevels: Int
    ) -> JP3DQuantizedTile {
        let step = stepSize(bitDepth: bitDepth, decompositionLevels: decompositionLevels)
        let quantized: [Int32]

        if mode.isLossless {
            quantized = coefficients.map { Int32(roundf($0)) }
        } else {
            quantized = coefficients.map { coeff in
                let sign: Float = coeff >= 0 ? 1.0 : -1.0
                let magnitude = abs(coeff) / step
                return Int32(sign * floor(magnitude))
            }
        }

        return JP3DQuantizedTile(
            tile: tile,
            componentIndex: componentIndex,
            coefficients: quantized,
            stepSize: step,
            width: tile.width,
            height: tile.height,
            depth: tile.depth,
            decompositionLevels: decompositionLevels
        )
    }

    /// Dequantizes a quantized tile back to float coefficients.
    public func dequantize(_ quantized: JP3DQuantizedTile) -> [Float] {
        if quantized.stepSize <= 1.0 {
            return quantized.coefficients.map { Float($0) }
        }
        return quantized.coefficients.map { Float($0) * quantized.stepSize }
    }

    /// Forms quality layers for rate-distortion optimisation.
    public func formQualityLayers(totalVoxels: Int, totalBits: Int) -> [JP3DQualityLayer] {
        guard qualityLayers > 0, totalVoxels > 0 else { return [] }

        var layers: [JP3DQualityLayer] = []
        let maxBPV = Float(totalBits) / Float(totalVoxels)

        for i in 0..<qualityLayers {
            let fraction = Float(i + 1) / Float(qualityLayers)
            let layerBPV = maxBPV * fraction
            let distortionReduction = fraction * fraction

            layers.append(JP3DQualityLayer(
                index: i,
                targetBitsPerVoxel: layerBPV,
                truncationPoints: [],
                distortionReduction: distortionReduction
            ))
        }

        return layers
    }

    // MARK: - Private Helpers

    private func stepSizeForPSNR(_ targetPSNR: Double, bitDepth: Int) -> Float {
        let clampedDepth = max(1, min(30, bitDepth))
        let maxVal = Float((1 << clampedDepth) - 1)
        let mse = Double(maxVal * maxVal) / pow(10.0, targetPSNR / 10.0)
        let step = sqrt(12.0 * mse)
        return max(1.0, Float(step))
    }

    private func stepSizeForBitrate(
        _ bitsPerVoxel: Double,
        bitDepth: Int,
        levels: Int
    ) -> Float {
        let exponent = Double(bitDepth) - bitsPerVoxel
        let step = pow(2.0, max(0, exponent)) / sqrt(Double(levels + 1))
        return max(1.0, Float(step))
    }
}
