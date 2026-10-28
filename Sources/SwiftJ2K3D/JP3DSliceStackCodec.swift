// SPDX-License-Identifier: Apache-2.0
//
// JP3DSliceStackCodec.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DSliceStackCodec.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Delegated per-slice 2D encoding, decoding, and lossless transcoding to
//     SwiftJ2K's Part 1 and Part 15 (HTJ2K) pipelines via Slice2DBridge and Transcoder.
//   - Encoded Z-delta residual slices as signed 16-bit values so small negative
//     inter-slice residuals do not wrap across 65535, while preserving backward
//     compatibility with unsigned v2 residual streams on decode.
//   - Added transcodeTile(_:toHTJ2K:limits:executionPolicy:) for wavelet-domain
//     slice-stack transcoding without inverse/forward DWT or Z-delta reconstruction.
//   - Hardened J3DS header parsing with checked integer arithmetic.

import Foundation
import SwiftJ2K

/// Encodes and decodes a 3D tile by delegating each Z-slice to the 2D `SwiftJ2K` codec.
internal struct JP3DSliceStackCodec: Sendable {
    static let magic: [UInt8] = [0x4A, 0x33, 0x44, 0x53] // "J3DS"
    static let formatVersion: UInt8 = 2
    private static let zDeltaGainThreshold: Double = 0.85
    private static let zDeltaAutoMinSlicePixels: Int = 50_000

    init() {}

    /// Returns `true` if `data` starts with the `"J3DS"` slice-stack magic bytes.
    static func isSliceStackTile(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == magic[0]
            && data[s + 1] == magic[1]
            && data[s + 2] == magic[2]
            && data[s + 3] == magic[3]
    }

    /// Alias for ``isSliceStackTile(_:)``.
    static func hasMagic(_ data: Data) -> Bool {
        isSliceStackTile(data)
    }

    /// Returns `true` if the slice-stack tile payload uses HTJ2K (Part 15) coding.
    static func usesHTJ2K(_ data: Data) -> Bool {
        guard isSliceStackTile(data), data.count >= 20 else { return false }
        let s = data.startIndex
        if data.count >= 32 && data[s + 4] == 0 {
            return (data[s + 11] & 0x01) != 0
        }
        if data[s + 4] >= 2 && (data[s + 5] & 0x80) != 0 {
            return true
        }
        let headerEnd = data[s + 4] >= 2 ? 20 : 19
        guard data.count >= headerEnd + 6 else { return false }
        let scanUpper = min(data.count - 1, headerEnd + 256)
        for i in (headerEnd + 4)..<scanUpper {
            if data[s + i] == 0xFF && data[s + i + 1] == 0x50 {
                return true
            }
        }
        return false
    }

    /// Returns `true` when the tile dimensions and bit depth can be handled by the slice-stack path.
    static func canEncode(
        tileWidth: Int,
        tileHeight: Int,
        bitDepth: Int
    ) -> Bool {
        tileWidth >= 4 && tileHeight >= 4 && bitDepth >= 1 && bitDepth <= 16
    }

    // MARK: - Encode

    func encodeTile(
        componentSamples: [[Float]],
        tileWidth: Int,
        tileHeight: Int,
        tileDepth: Int,
        bitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int = 0,
        compressionMode: JP3DCompressionMode,
        qualityLayers: Int,
        zDeltaPolicy: JP3DZDeltaMode = .auto,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> Data {
        let componentCount = componentSamples.count
        let slicePixelCount = tileWidth * tileHeight
        let clampedBitDepth = max(1, min(16, bitDepth))
        let minVal = signed ? -(1 << (clampedBitDepth - 1)) : 0
        let maxVal = signed ? ((1 << (clampedBitDepth - 1)) - 1) : ((1 << clampedBitDepth) - 1)

        var intSlicesPerComp: [[[Int32]]] = []
        intSlicesPerComp.reserveCapacity(componentCount)
        for comp in 0..<componentCount {
            let flat = componentSamples[comp]
            var compSlices: [[Int32]] = []
            compSlices.reserveCapacity(tileDepth)
            for z in 0..<tileDepth {
                let zOffset = z * slicePixelCount
                var slice = [Int32](repeating: 0, count: slicePixelCount)
                for i in 0..<slicePixelCount {
                    let v = Int(flat[zOffset + i].rounded())
                    slice[i] = Int32(max(minVal, min(maxVal, v)))
                }
                compSlices.append(slice)
            }
            intSlicesPerComp.append(compSlices)
        }

        let useZDelta: UInt8
        let zDeltaSizeAllowed: Bool
        switch zDeltaPolicy {
        case .never:
            zDeltaSizeAllowed = false
        case .always:
            zDeltaSizeAllowed = true
        case .auto:
            zDeltaSizeAllowed = slicePixelCount >= Self.zDeltaAutoMinSlicePixels
        }

        if zDeltaSizeAllowed
            && compressionMode.isLossless
            && tileDepth >= 2
            && levelsZ > 0
            && shouldUseZDelta(slicesPerComp: intSlicesPerComp, slicePixelCount: slicePixelCount) {
            useZDelta = 1
        } else {
            useZDelta = 0
        }

        var out = Data()
        out.reserveCapacity(20 + componentCount * tileDepth * 64)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        let zDeltaFlags: UInt8 = useZDelta | (compressionMode.isHTJ2K ? 0x80 : 0x00)
        out.append(zDeltaFlags)
        appendUInt16BE(&out, UInt16(componentCount))
        appendUInt32BE(&out, UInt32(tileWidth))
        appendUInt32BE(&out, UInt32(tileHeight))
        appendUInt32BE(&out, UInt32(tileDepth))
        out.append(UInt8(clampedBitDepth))
        out.append(signed ? 1 : 0)

        for comp in 0..<componentCount {
            let compSlices = intSlicesPerComp[comp]
            for z in 0..<tileDepth {
                let sliceSamples: [Int32]
                let sliceBitDepth: Int
                let sliceSigned: Bool

                if useZDelta == 1 && z >= 1 {
                    let prev = compSlices[z - 1]
                    let cur = compSlices[z]
                    var residual = [Int32](repeating: 0, count: slicePixelCount)
                    for i in 0..<slicePixelCount {
                        let diff = Int16(truncatingIfNeeded: Int(cur[i]) &- Int(prev[i]))
                        residual[i] = Int32(diff)
                    }
                    sliceSamples = residual
                    sliceBitDepth = 16
                    sliceSigned = true
                } else {
                    sliceSamples = compSlices[z]
                    sliceBitDepth = clampedBitDepth
                    sliceSigned = signed
                }

                let sliceCodestream = try encodeSlice(
                    samples: sliceSamples,
                    width: tileWidth,
                    height: tileHeight,
                    bitDepth: sliceBitDepth,
                    signed: sliceSigned,
                    levelsX: levelsX,
                    levelsY: levelsY,
                    compressionMode: compressionMode,
                    qualityLayers: qualityLayers,
                    limits: limits,
                    executionPolicy: executionPolicy
                )
                appendUInt32BE(&out, UInt32(sliceCodestream.count))
                out.append(sliceCodestream)
            }
        }

        return out
    }

    // MARK: - Decode

    func decodeTile(
        _ data: Data,
        expectedComponents: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedDepth: Int,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int = 0,
        zRange: Range<Int>? = nil,
        xyROI: (x: Range<Int>, y: Range<Int>)? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> [[Float]] {
        var offset = 0
        guard data.count >= 20 else {
            throw J2KError.decodingError("J3DS tile header truncated (\(data.count) bytes)")
        }
        for b in Self.magic {
            guard data[data.startIndex + offset] == b else {
                throw J2KError.decodingError("Invalid J3DS magic in tile payload")
            }
            offset += 1
        }
        let version = data[data.startIndex + offset]
        offset += 1
        guard version == 1 || version == 2 else {
            throw J2KError.decodingError("Unsupported J3DS tile version \(version)")
        }
        let zDeltaMode: UInt8
        if version >= 2 {
            zDeltaMode = data[data.startIndex + offset] & 0x7F
            offset += 1
        } else {
            zDeltaMode = 0
        }

        let compCount = Int(readUInt16BE(data, at: &offset))
        let tileW = Int(readUInt32BE(data, at: &offset))
        let tileH = Int(readUInt32BE(data, at: &offset))
        let tileD = Int(readUInt32BE(data, at: &offset))
        let bitDepth = Int(data[data.startIndex + offset]); offset += 1
        let signed = data[data.startIndex + offset] != 0; offset += 1

        guard compCount > 0 && tileW > 0 && tileH > 0 && tileD > 0 else {
            throw J2KError.decodingError("Invalid J3DS tile dimensions")
        }
        let (wh, o1) = tileW.multipliedReportingOverflow(by: tileH)
        let (_, o2) = wh.multipliedReportingOverflow(by: tileD)
        guard !o1 && !o2, bitDepth >= 1 && bitDepth <= 38 else {
            throw J2KError.decodingError("J3DS tile dimensions or bit depth out of range")
        }

        let outW: Int
        let outH: Int
        let roiX: Range<Int>?
        let roiY: Range<Int>?
        if let roi = xyROI, resolutionLevel == 0 {
            let clampedX = max(0, roi.x.lowerBound)..<min(tileW, roi.x.upperBound)
            let clampedY = max(0, roi.y.lowerBound)..<min(tileH, roi.y.upperBound)
            roiX = clampedX
            roiY = clampedY
            outW = max(1, clampedX.count)
            outH = max(1, clampedY.count)
        } else {
            roiX = nil
            roiY = nil
            outW = resolutionLevel > 0
                ? max(1, (tileW + (1 << resolutionLevel) - 1) >> resolutionLevel)
                : tileW
            outH = resolutionLevel > 0
                ? max(1, (tileH + (1 << resolutionLevel) - 1) >> resolutionLevel)
                : tileH
        }
        let outSlicePixels = outW * outH
        let fullSlicePixels = tileW * tileH
        let clampedBitDepth = max(1, min(16, bitDepth))

        let zStart = max(0, min(tileD, zRange?.lowerBound ?? 0))
        let zEnd = max(zStart, min(tileD, zRange?.upperBound ?? tileD))
        let outD = (zRange != nil) ? (zEnd - zStart) : tileD
        let zRequiredMin = (zDeltaMode == 1) ? 0 : zStart
        let zRequiredMax = zEnd

        var sliceTable = [[Range<Int>]]()
        sliceTable.reserveCapacity(compCount)
        for _ in 0..<compCount {
            var compRanges = [Range<Int>]()
            compRanges.reserveCapacity(tileD)
            for _ in 0..<tileD {
                guard offset + 4 <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice length")
                }
                let sliceLen = Int(readUInt32BE(data, at: &offset))
                let (endPos, ov) = offset.addingReportingOverflow(sliceLen)
                guard !ov, sliceLen >= 0, endPos <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice payload (\(sliceLen) bytes)")
                }
                compRanges.append((data.startIndex + offset)..<(data.startIndex + endPos))
                offset = endPos
            }
            sliceTable.append(compRanges)
        }

        var result = [[Float]](
            repeating: [Float](repeating: 0, count: outSlicePixels * outD),
            count: compCount
        )

        for comp in 0..<compCount {
            let compRanges = sliceTable[comp]
            let decodeSliceCount = max(0, zRequiredMax - zRequiredMin)
            var decodedSlices = [[Int32]](repeating: [], count: decodeSliceCount)
            var decodedSignedFlags = [Bool](repeating: signed, count: decodeSliceCount)

            for idx in 0..<decodeSliceCount {
                let z = zRequiredMin + idx
                let sliceData = data.subdata(in: compRanges[z])
                let (samples, w, h, _, sliceSigned) = try Slice2DBridge.decodeSlice(
                    data: sliceData,
                    maxQualityLayers: maxQualityLayers,
                    limits: limits,
                    executionPolicy: executionPolicy
                )
                decodedSignedFlags[idx] = sliceSigned
                if zDeltaMode == 1 {
                    decodedSlices[idx] = samples
                } else if let rx = roiX, let ry = roiY {
                    decodedSlices[idx] = Self.cropSlice(
                        samples, srcW: w, srcH: h, xRange: rx, yRange: ry
                    )
                } else if w == outW && h == outH {
                    decodedSlices[idx] = samples
                } else {
                    decodedSlices[idx] = Self.downsampleSlice(
                        samples, srcW: w, srcH: h, dstW: outW, dstH: outH
                    )
                }
            }

            if zDeltaMode == 1 {
                var prevSlice = [Int32](repeating: 0, count: fullSlicePixels)
                for z in 0..<zRequiredMax {
                    let rawSlice = decodedSlices[z]
                    let isResidualSigned = decodedSignedFlags[z]
                    let count = min(fullSlicePixels, rawSlice.count)
                    var reconstructed = [Int32](repeating: 0, count: fullSlicePixels)
                    if z == 0 {
                        for i in 0..<count {
                            reconstructed[i] = rawSlice[i]
                        }
                    } else if isResidualSigned {
                        if signed {
                            let shift = 32 - clampedBitDepth
                            for i in 0..<count {
                                let sum = Int(prevSlice[i]) &+ Int(rawSlice[i])
                                reconstructed[i] = Int32(bitPattern: UInt32(truncatingIfNeeded: sum) << shift) >> shift
                            }
                        } else {
                            let mask = (1 << clampedBitDepth) - 1
                            for i in 0..<count {
                                let sum = Int(prevSlice[i]) &+ Int(rawSlice[i])
                                reconstructed[i] = Int32(sum & mask)
                            }
                        }
                    } else if clampedBitDepth <= 8 && !signed {
                        for i in 0..<count {
                            let r = UInt8(truncatingIfNeeded: rawSlice[i])
                            let p = UInt8(truncatingIfNeeded: prevSlice[i])
                            reconstructed[i] = Int32(p &+ r)
                        }
                    } else {
                        for i in 0..<count {
                            let r = UInt16(truncatingIfNeeded: rawSlice[i])
                            let p = UInt16(truncatingIfNeeded: prevSlice[i])
                            let u = p &+ r
                            if signed {
                                reconstructed[i] = Int32(Int16(bitPattern: u))
                            } else {
                                let maxVal = (1 << clampedBitDepth) - 1
                                reconstructed[i] = Int32(Int(u) & maxVal)
                            }
                        }
                    }
                    prevSlice = reconstructed

                    if z >= zStart && z < zEnd {
                        let outSlice: [Int32]
                        if let rx = roiX, let ry = roiY {
                            outSlice = Self.cropSlice(
                                reconstructed, srcW: tileW, srcH: tileH,
                                xRange: rx, yRange: ry
                            )
                        } else if outW == tileW && outH == tileH {
                            outSlice = reconstructed
                        } else {
                            outSlice = Self.downsampleSlice(
                                reconstructed, srcW: tileW, srcH: tileH,
                                dstW: outW, dstH: outH
                            )
                        }
                        let dstBase = (z - zStart) * outSlicePixels
                        let copyCount = min(outSlicePixels, outSlice.count)
                        for i in 0..<copyCount {
                            result[comp][dstBase + i] = Float(outSlice[i])
                        }
                    }
                }
            } else {
                for idx in 0..<decodeSliceCount {
                    let slice = decodedSlices[idx]
                    let dstBase = idx * outSlicePixels
                    let count = min(outSlicePixels, slice.count)
                    for i in 0..<count {
                        result[comp][dstBase + i] = Float(slice[i])
                    }
                }
            }
        }

        return result
    }

    // MARK: - Lossless Wavelet-Domain Slice-Stack Transcoding

    /// Transcodes each 2D slice codestream in a `J3DS` tile payload between Part 1 and HTJ2K
    /// directly in the wavelet coefficient domain without inverse/forward DWT or Z-delta reconstruction.
    func transcodeTile(
        _ data: Data,
        toHTJ2K: Bool,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) async throws -> Data {
        var offset = 0
        guard data.count >= 20 else {
            throw J2KError.decodingError("J3DS tile header truncated (\(data.count) bytes)")
        }
        for b in Self.magic {
            guard data[data.startIndex + offset] == b else {
                throw J2KError.decodingError("Invalid J3DS magic in tile payload")
            }
            offset += 1
        }
        let version = data[data.startIndex + offset]
        offset += 1
        guard version == 1 || version == 2 else {
            throw J2KError.decodingError("Unsupported J3DS tile version \(version)")
        }
        let zDeltaMode: UInt8
        if version >= 2 {
            zDeltaMode = data[data.startIndex + offset] & 0x7F
            offset += 1
        } else {
            zDeltaMode = 0
        }
        let compCount = Int(readUInt16BE(data, at: &offset))
        let tileW = Int(readUInt32BE(data, at: &offset))
        let tileH = Int(readUInt32BE(data, at: &offset))
        let tileD = Int(readUInt32BE(data, at: &offset))
        let bitDepth = data[data.startIndex + offset]; offset += 1
        let signed = data[data.startIndex + offset]; offset += 1

        var out = Data()
        out.reserveCapacity(data.count)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        let transcodedFlags: UInt8 = (zDeltaMode & 0x7F) | (toHTJ2K ? 0x80 : 0x00)
        out.append(transcodedFlags)
        appendUInt16BE(&out, UInt16(compCount))
        appendUInt32BE(&out, UInt32(tileW))
        appendUInt32BE(&out, UInt32(tileH))
        appendUInt32BE(&out, UInt32(tileD))
        out.append(bitDepth)
        out.append(signed)

        let transcoder = try Transcoder()
        let target: TranscodeTarget = toHTJ2K ? .htj2k : .jpeg2000
        let options = TranscodeOptions(resourceLimits: limits, executionPolicy: executionPolicy)

        for _ in 0..<compCount {
            for _ in 0..<tileD {
                guard offset + 4 <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice length")
                }
                let sliceLen = Int(readUInt32BE(data, at: &offset))
                let (endPos, ov) = offset.addingReportingOverflow(sliceLen)
                guard !ov, sliceLen >= 0, endPos <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice payload")
                }
                let sliceData = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + endPos))
                offset = endPos

                let transcodedSlice = try await transcoder.transcode(sliceData, to: target, options: options).data
                appendUInt32BE(&out, UInt32(transcodedSlice.count))
                out.append(transcodedSlice)
            }
        }
        return out
    }

    // MARK: - Private Helpers

    private func shouldUseZDelta(
        slicesPerComp: [[[Int32]]],
        slicePixelCount: Int
    ) -> Bool {
        guard let comp0 = slicesPerComp.first, comp0.count >= 2, slicePixelCount > 0 else {
            return false
        }
        let s0 = comp0[0]
        let s1 = comp0[1]
        var mean: Int64 = 0
        for i in 0..<slicePixelCount {
            mean &+= Int64(s1[i])
        }
        mean /= Int64(slicePixelCount)
        var rawEnergy: Int64 = 0
        var deltaEnergy: Int64 = 0
        for i in 0..<slicePixelCount {
            rawEnergy &+= abs(Int64(s1[i]) - mean)
            deltaEnergy &+= abs(Int64(s1[i]) - Int64(s0[i]))
        }
        guard rawEnergy > 0 else { return false }
        return Double(deltaEnergy) < Double(rawEnergy) * Self.zDeltaGainThreshold
    }

    private func encodeSlice(
        samples: [Int32],
        width: Int,
        height: Int,
        bitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        compressionMode: JP3DCompressionMode,
        qualityLayers: Int,
        limits: ResourceLimits,
        executionPolicy: ExecutionPolicy
    ) throws -> Data {
        let levels = min(levelsX, levelsY)

        switch compressionMode {
        case .lossless:
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: true,
                quality: nil,
                targetBitsPerPixel: nil,
                useReversibleWavelet: true,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .losslessHTJ2K:
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: 1,
                useHTJ2K: true,
                lossless: true,
                quality: nil,
                targetBitsPerPixel: nil,
                useReversibleWavelet: true,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .lossy(let psnr):
            let quality = min(0.99, max(0.05, (psnr - 20.0) / 40.0))
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: false,
                quality: quality,
                targetBitsPerPixel: nil,
                useReversibleWavelet: false,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .lossyHTJ2K(let psnr):
            // Pre-quantise samples to a step size proportional to PSNR and encode with reversible HTJ2K
            // so the slice codestream is a valid Part 15 HTJ2K codestream (CAP 0xFF50 + HT cleanup pass).
            var minSample = Int32.max
            var maxSample = Int32.min
            for v in samples {
                if v < minSample { minSample = v }
                if v > maxSample { maxSample = v }
            }
            let actualRange = max(1, Int(maxSample) - Int(minSample))
            let qStep = max(2, min(64, Int((Double(actualRange) / pow(10.0, psnr / 20.0)).rounded())))
            let minVal = signed ? -(1 << (bitDepth - 1)) : 0
            let maxVal = signed ? ((1 << (bitDepth - 1)) - 1) : ((1 << bitDepth) - 1)
            var quantisedSamples = [Int32](repeating: 0, count: samples.count)
            let halfStep = qStep / 2
            for i in 0..<samples.count {
                let v = Int(samples[i])
                let q = v >= 0
                    ? ((v + halfStep) / qStep) * qStep
                    : -(((-v + halfStep) / qStep) * qStep)
                quantisedSamples[i] = Int32(max(minVal, min(maxVal, q)))
            }
            return try Slice2DBridge.encodeSlice(
                samples: quantisedSamples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: 1,
                useHTJ2K: true,
                lossless: true,
                quality: nil,
                targetBitsPerPixel: nil,
                useReversibleWavelet: true,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .targetBitrate(let bpv):
            let clampedBPV = max(0.05, min(Double(bitDepth), bpv))
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: false,
                quality: nil,
                targetBitsPerPixel: clampedBPV,
                useReversibleWavelet: false,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .visuallyLossless:
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: false,
                quality: 0.92,
                targetBitsPerPixel: nil,
                useReversibleWavelet: false,
                limits: limits,
                executionPolicy: executionPolicy
            )
        }
    }

    private static func cropSlice(
        _ slice: [Int32],
        srcW: Int,
        srcH: Int,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> [Int32] {
        let dstW = max(1, xRange.count)
        let dstH = max(1, yRange.count)
        var out = [Int32](repeating: 0, count: dstW * dstH)
        for dy in 0..<dstH {
            let sy = min(srcH - 1, max(0, yRange.lowerBound + dy))
            let srcRow = sy * srcW
            let dstRow = dy * dstW
            for dx in 0..<dstW {
                let sx = min(srcW - 1, max(0, xRange.lowerBound + dx))
                let idx = srcRow + sx
                if idx < slice.count {
                    out[dstRow + dx] = slice[idx]
                }
            }
        }
        return out
    }

    private static func downsampleSlice(
        _ slice: [Int32],
        srcW: Int,
        srcH: Int,
        dstW: Int,
        dstH: Int
    ) -> [Int32] {
        var out = [Int32](repeating: 0, count: dstW * dstH)
        let scaleX = max(1, srcW / dstW)
        let scaleY = max(1, srcH / dstH)
        for dy in 0..<dstH {
            let sy = min(srcH - 1, dy * scaleY)
            for dx in 0..<dstW {
                let sx = min(srcW - 1, dx * scaleX)
                let idx = sy * srcW + sx
                if idx < slice.count {
                    out[dy * dstW + dx] = slice[idx]
                }
            }
        }
        return out
    }

    private func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private func readUInt16BE(_ data: Data, at offset: inout Int) -> UInt16 {
        let s = data.startIndex + offset
        let hi = UInt16(data[s])
        let lo = UInt16(data[s + 1])
        offset += 2
        return (hi << 8) | lo
    }

    private func readUInt32BE(_ data: Data, at offset: inout Int) -> UInt32 {
        let s = data.startIndex + offset
        let b0 = UInt32(data[s])
        let b1 = UInt32(data[s + 1])
        let b2 = UInt32(data[s + 2])
        let b3 = UInt32(data[s + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
