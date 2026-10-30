// SPDX-License-Identifier: Apache-2.0
//
// LegacyImageBridge.swift
// SwiftJ2K
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/J2KCore/J2KCore.swift (J2KImage, J2KComponent, J2KColorSpace, J2KConfiguration,
//     J2KProgressionOrder, J2KSubband)
//   - Sources/J2KCore/J2KApplePlatform.swift (J2KQualityOfService)
//   - Sources/J2KFileFormat/J2KFileFormat.swift (J2KFormat, J2KFormatDetector)
//   - Sources/J2KCodec/J2KCodec.swift & J2KEncodingPresets.swift (J2KEncoder, J2KDecoder,
//     J2KEncodingConfiguration, J2KEncodingPreset, J2KBitrateMode)
//   - Sources/J2KCodec/J2KTranscoder.swift (J2KTranscoder, TranscodingConfiguration,
//     TranscodingDirection, TranscodingStage, TranscodingProgressUpdate, TranscodingResult)
//
// Changes relative to the predecessor:
//   - Backed J2KEncoder, J2KDecoder, and J2KTranscoder directly with SwiftJ2K's
//     contract-aligned Part1Pipeline, ScalarLosslessCodec, and JP2Container.
//   - Added bidirectional conversion between J2KImage and SwiftJ2K.Image so
//     SwiftJ2KJPIP and DICOMKit consumers interoperate seamlessly with the
//     common contract API.
//   - Replaced unchecked Data subscripting in J2KFormatDetector with startIndex-safe
//     checked arithmetic.

import Foundation
import Dispatch

// MARK: - J2KColorSpace

/// Represents the colour space of an image.
public enum J2KColorSpace: Sendable, Equatable {
    /// Standard RGB colour space (sRGB).
    case sRGB

    /// Greyscale (single channel).
    case grayscale

    /// YCbCr colour space (luminance and chrominance).
    case yCbCr

    /// Custom ICC profile.
    case iccProfile(Data)

    /// Unknown or unspecified colour space.
    case unknown
}

// MARK: - J2KComponent

/// Represents a single component (channel) of a JPEG 2000 image.
public struct J2KComponent: Sendable, Equatable {
    /// The index of this component (0-based).
    public let index: Int

    /// The bit depth of this component (1-38 bits).
    public let bitDepth: Int

    /// Whether this component uses signed values.
    public let signed: Bool

    /// The width of this component in pixels.
    public let width: Int

    /// The height of this component in pixels.
    public let height: Int

    /// The horizontal subsampling factor relative to the reference grid.
    public let subsamplingX: Int

    /// The vertical subsampling factor relative to the reference grid.
    public let subsamplingY: Int

    /// The raw pixel data for this component.
    public var data: Data

    /// Creates a new image component with the specified parameters.
    public init(
        index: Int,
        bitDepth: Int,
        signed: Bool = false,
        width: Int,
        height: Int,
        subsamplingX: Int = 1,
        subsamplingY: Int = 1,
        data: Data = Data()
    ) {
        self.index = index
        self.bitDepth = bitDepth
        self.signed = signed
        self.width = width
        self.height = height
        self.subsamplingX = subsamplingX
        self.subsamplingY = subsamplingY
        self.data = data
    }

    /// The total number of pixels in this component.
    public var pixelCount: Int {
        width * height
    }

    /// Returns `true` if this component is subsampled.
    public var isSubsampled: Bool {
        subsamplingX > 1 || subsamplingY > 1
    }

    /// The maximum value that can be represented by this component's bit depth.
    public var maxValue: Int {
        if signed {
            return (1 << (bitDepth - 1)) - 1
        } else {
            return (1 << bitDepth) - 1
        }
    }

    /// The minimum value that can be represented by this component's bit depth.
    public var minValue: Int {
        if signed {
            return -(1 << (bitDepth - 1))
        } else {
            return 0
        }
    }

    /// Number of storage bytes per sample.
    public var bytesPerSample: Int {
        (bitDepth + 7) / 8
    }
}

// MARK: - J2KImage

/// Represents a JPEG 2000 image with metadata and component data.
public struct J2KImage: Sendable, Equatable {
    /// The width of the image in pixels.
    public let width: Int

    /// The height of the image in pixels.
    public let height: Int

    /// The image components (colour channels).
    public let components: [J2KComponent]

    /// The horizontal offset of the image in the reference grid.
    public let offsetX: Int

    /// The vertical offset of the image in the reference grid.
    public let offsetY: Int

    /// The width of a tile in pixels (0 if untiled).
    public let tileWidth: Int

    /// The height of a tile in pixels (0 if untiled).
    public let tileHeight: Int

    /// The horizontal offset of the first tile.
    public let tileOffsetX: Int

    /// The vertical offset of the first tile.
    public let tileOffsetY: Int

    /// The colour space of the image.
    public let colorSpace: J2KColorSpace

    /// The alpha interpretation of the image (`.absent`, `.straight`, or `.premultiplied`).
    ///
    /// Alpha semantics are carried explicitly and are never inferred solely from component count.
    public let alpha: AlphaInterpretation

    /// Preserved contract colour interpretation when bridged from an ``Image`` or container decode.
    package let preservedColourInterpretation: ColourInterpretation?

    /// Preserved contract component roles when bridged from an ``Image`` or container decode.
    package let preservedComponentRoles: [ComponentRole]?

    /// Required sample interpretation and ancillary metadata retained across public adapters.
    package let preservedMetadata: ImageMetadata

    /// Creates a new image with the specified parameters.
    public init(
        width: Int,
        height: Int,
        components: [J2KComponent],
        offsetX: Int = 0,
        offsetY: Int = 0,
        tileWidth: Int = 0,
        tileHeight: Int = 0,
        tileOffsetX: Int = 0,
        tileOffsetY: Int = 0,
        colorSpace: J2KColorSpace = .sRGB,
        alpha: AlphaInterpretation = .absent
    ) {
        self.init(
            width: width,
            height: height,
            components: components,
            offsetX: offsetX,
            offsetY: offsetY,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            tileOffsetX: tileOffsetX,
            tileOffsetY: tileOffsetY,
            colorSpace: colorSpace,
            alpha: alpha,
            preservedColourInterpretation: nil,
            preservedComponentRoles: nil
        )
    }

    package init(
        width: Int,
        height: Int,
        components: [J2KComponent],
        offsetX: Int = 0,
        offsetY: Int = 0,
        tileWidth: Int = 0,
        tileHeight: Int = 0,
        tileOffsetX: Int = 0,
        tileOffsetY: Int = 0,
        colorSpace: J2KColorSpace = .sRGB,
        alpha: AlphaInterpretation = .absent,
        preservedColourInterpretation: ColourInterpretation?,
        preservedComponentRoles: [ComponentRole]?,
        preservedMetadata: ImageMetadata = .empty
    ) {
        self.width = width
        self.height = height
        self.components = components
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.tileOffsetX = tileOffsetX
        self.tileOffsetY = tileOffsetY
        self.colorSpace = colorSpace
        self.alpha = alpha
        self.preservedColourInterpretation = preservedColourInterpretation
        self.preservedComponentRoles = preservedComponentRoles
        self.preservedMetadata = preservedMetadata
    }

    /// Convenience initialiser for simple images without tiling.
    public init(
        width: Int,
        height: Int,
        components: Int,
        bitDepth: Int = 8,
        signed: Bool = false,
        alpha: AlphaInterpretation = .absent
    ) {
        let validWidth = max(1, width)
        let validHeight = max(1, height)
        let validComponents = max(1, components)
        let validBitDepth = max(1, min(38, bitDepth))
        let bps = (validBitDepth + 7) / 8
        let byteCount = validWidth * validHeight * bps

        let imageComponents = (0..<validComponents).map { index in
            J2KComponent(
                index: index,
                bitDepth: validBitDepth,
                signed: signed,
                width: validWidth,
                height: validHeight,
                data: Data(count: byteCount)
            )
        }

        let cs: J2KColorSpace
        if validComponents == 1 || (validComponents == 2 && alpha != .absent) {
            cs = .grayscale
        } else if validComponents == 3 || (validComponents == 4 && alpha != .absent) {
            cs = .sRGB
        } else {
            cs = .unknown
        }
        self.init(
            width: validWidth,
            height: validHeight,
            components: imageComponents,
            colorSpace: cs,
            alpha: alpha
        )
    }

    /// The total number of pixels in the image.
    public var pixelCount: Int {
        width * height
    }

    /// The number of components in the image.
    public var componentCount: Int {
        components.count
    }

    /// Returns `true` if the image uses tiling.
    public var isTiled: Bool {
        tileWidth > 0 && tileHeight > 0
    }

    /// Returns `true` if the image is greyscale (single component).
    public var isGrayscale: Bool {
        components.count == 1 && colorSpace == .grayscale
    }

    /// The number of tiles horizontally.
    public var tileGridWidth: Int {
        guard isTiled else { return 1 }
        return (width + tileWidth - 1) / tileWidth
    }

    /// The number of tiles vertically.
    public var tileGridHeight: Int {
        guard isTiled else { return 1 }
        return (height + tileHeight - 1) / tileHeight
    }

    /// The total number of tiles in the image.
    public var tileCount: Int {
        tileGridWidth * tileGridHeight
    }

    /// Validates that the image has valid dimensions and components.
    public func validate() throws {
        guard width > 0 && height > 0 else {
            throw J2KError.invalidDimensions("Image dimensions must be positive: \(width)x\(height)")
        }
        guard !components.isEmpty else {
            throw J2KError.invalidComponentConfiguration("Image must have at least one component")
        }
        for component in components {
            guard component.bitDepth >= 1 && component.bitDepth <= 38 else {
                throw J2KError.invalidBitDepth("Component \(component.index) has invalid bit depth: \(component.bitDepth)")
            }
            guard component.width > 0 && component.height > 0 else {
                throw J2KError.invalidDimensions(
                    "Component \(component.index) dimensions must be positive: \(component.width)x\(component.height)"
                )
            }
            guard component.subsamplingX > 0 && component.subsamplingY > 0 else {
                throw J2KError.invalidComponentConfiguration(
                    "Component \(component.index) subsampling factors must be positive"
                )
            }
        }
        if isTiled {
            guard tileWidth > 0 && tileHeight > 0 else {
                throw J2KError.invalidTileConfiguration("Tile dimensions must be positive: \(tileWidth)x\(tileHeight)")
            }
        }
    }

    // MARK: - Conversion to and from SwiftJ2K Contract Image

    /// Converts this ``J2KImage`` into a contract-aligned ``Image``.
    public func toContractImage(limits: ResourceLimits = .default) throws -> Image {
        try toContractImage(
            colourOverride: nil,
            alphaOverride: nil,
            iccProfileOverride: nil,
            metadata: preservedMetadata,
            limits: limits
        )
    }

    /// Converts this ``J2KImage`` into a contract-aligned ``Image`` while preserving
    /// container-reconciled colour, alpha, ICC profile, and ancillary metadata.
    package func toContractImage(
        colourOverride: ColourInterpretation?,
        alphaOverride: AlphaInterpretation?,
        iccProfileOverride: Data?,
        metadata: ImageMetadata,
        limits: ResourceLimits = .default,
        retainedBytes: Int = 0
    ) throws -> Image {
        try validate()
        let compCount = components.count
        let first = components[0]
        let clampedBitDepth = max(1, min(16, first.bitDepth))
        let signed = first.signed
        let sampleType: SampleType = signed ? .signedInteger : .unsignedInteger
        let storageBits: Int = (compCount == 1) ? 16 : (clampedBitDepth <= 8 ? 8 : 16)
        let dstBytesPerSample = storageBits / 8
        let srcBytesPerSample = (clampedBitDepth + 7) / 8

        let effectiveICC: Data?
        if let iccOverride = iccProfileOverride {
            effectiveICC = iccOverride
        } else if case .iccProfile(let icc) = colorSpace {
            effectiveICC = icc
        } else {
            effectiveICC = nil
        }

        let effectiveAlpha: AlphaInterpretation = alphaOverride ?? self.alpha
        let resolvedColour: ColourInterpretation
        let resolvedAlpha: AlphaInterpretation
        let resolvedRoles: [ComponentRole]

        if let preservedRoles = self.preservedComponentRoles,
           preservedRoles.count == compCount,
           let preservedColour = self.preservedColourInterpretation,
           (colourOverride == nil || colourOverride == preservedColour),
           (alphaOverride == nil || alphaOverride == self.alpha),
           (effectiveAlpha == .absent) == !preservedRoles.contains(.alpha) {
            resolvedColour = preservedColour
            resolvedAlpha = effectiveAlpha
            resolvedRoles = preservedRoles
        } else {
            let rawColour: ColourInterpretation
            if let explicitColour = colourOverride {
                rawColour = explicitColour
            } else if let preservedColour = self.preservedColourInterpretation {
                rawColour = preservedColour
            } else {
                switch colorSpace {
                case .grayscale:
                    rawColour = .greyscale
                case .sRGB:
                    rawColour = .rgb
                case .yCbCr:
                    throw CodecError(.unsupportedFeature, "The legacy YCbCr label does not identify an enumerated colour model. Supply a container with its colour specification; YCbCr samples are not RGB.")
                case .unknown:
                    rawColour = .unknown
                case .iccProfile:
                    if compCount == 1 || (compCount == 2 && effectiveAlpha != .absent) {
                        rawColour = .greyscale
                    } else if compCount == 3 || (compCount == 4 && effectiveAlpha != .absent) {
                        rawColour = .rgb
                    } else {
                        rawColour = .unknown
                    }
                }
            }

            if compCount == 1 {
                if effectiveAlpha != .absent {
                    resolvedColour = .unknown
                    resolvedAlpha = effectiveAlpha
                    resolvedRoles = [.alpha]
                } else if rawColour == .unknown {
                    resolvedColour = .unknown
                    resolvedAlpha = .absent
                    resolvedRoles = [.uninterpreted("c0")]
                } else {
                    resolvedColour = .greyscale
                    resolvedAlpha = .absent
                    resolvedRoles = [.grey]
                }
            } else if compCount == 2 {
                if effectiveAlpha != .absent {
                    if rawColour == .unknown {
                        resolvedColour = .unknown
                        resolvedAlpha = effectiveAlpha
                        resolvedRoles = [.uninterpreted("c0"), .alpha]
                    } else {
                        resolvedColour = .greyscale
                        resolvedAlpha = effectiveAlpha
                        resolvedRoles = [.grey, .alpha]
                    }
                } else if rawColour == .greyscale {
                    resolvedColour = .greyscale
                    resolvedAlpha = .absent
                    resolvedRoles = [.grey, .uninterpreted("c1")]
                } else {
                    resolvedColour = .unknown
                    resolvedAlpha = .absent
                    resolvedRoles = [.uninterpreted("c0"), .uninterpreted("c1")]
                }
            } else if compCount == 3 {
                if effectiveAlpha != .absent {
                    if rawColour == .greyscale {
                        resolvedColour = .greyscale
                        resolvedAlpha = effectiveAlpha
                        resolvedRoles = [.grey, .uninterpreted("c1"), .alpha]
                    } else {
                        resolvedColour = .unknown
                        resolvedAlpha = effectiveAlpha
                        resolvedRoles = [.uninterpreted("c0"), .uninterpreted("c1"), .alpha]
                    }
                } else if rawColour == .rgb {
                    resolvedColour = .rgb
                    resolvedAlpha = .absent
                    resolvedRoles = [.red, .green, .blue]
                } else if rawColour == .greyscale {
                    resolvedColour = .greyscale
                    resolvedAlpha = .absent
                    resolvedRoles = [.grey, .uninterpreted("c1"), .uninterpreted("c2")]
                } else {
                    resolvedColour = .unknown
                    resolvedAlpha = .absent
                    resolvedRoles = [.uninterpreted("c0"), .uninterpreted("c1"), .uninterpreted("c2")]
                }
            } else {
                resolvedAlpha = effectiveAlpha
                let colourSlotCount = (effectiveAlpha == .absent) ? compCount : (compCount - 1)
                if rawColour == .rgb && colourSlotCount >= 3 {
                    resolvedColour = .rgb
                    var roles: [ComponentRole] = [.red, .green, .blue]
                    for idx in 3..<colourSlotCount {
                        roles.append(.uninterpreted("c\(idx)"))
                    }
                    if effectiveAlpha != .absent {
                        roles.append(.alpha)
                    }
                    resolvedRoles = roles
                } else if rawColour == .greyscale && colourSlotCount >= 1 {
                    resolvedColour = .greyscale
                    var roles: [ComponentRole] = [.grey]
                    for idx in 1..<colourSlotCount {
                        roles.append(.uninterpreted("c\(idx)"))
                    }
                    if effectiveAlpha != .absent {
                        roles.append(.alpha)
                    }
                    resolvedRoles = roles
                } else {
                    resolvedColour = .unknown
                    var roles: [ComponentRole] = (0..<colourSlotCount).map { .uninterpreted("c\($0)") }
                    if effectiveAlpha != .absent {
                        roles.append(.alpha)
                    }
                    resolvedRoles = roles
                }
            }
        }

        let rowBytes = try checkedMultiply(width, dstBytesPerSample)
        let planeBytes = try checkedMultiply(rowBytes, height)
        var planes: [PlaneDescriptor] = []
        planes.reserveCapacity(compCount)
        for index in 0..<compCount {
            let planeOffset = try checkedMultiply(index, planeBytes)
            let planeEnd = try checkedAdd(planeOffset, planeBytes)
            planes.append(
                try PlaneDescriptor(
                    width: width,
                    height: height,
                    components: [index],
                    offset: planeOffset,
                    sampleStride: dstBytesPerSample,
                    pixelStride: dstBytesPerSample,
                    rowBytes: rowBytes,
                    byteCount: planeEnd
                )
            )
        }

        let descriptor = try ImageDescriptor(
            width: width,
            height: height,
            sampleType: sampleType,
            storageBits: storageBits,
            meaningfulBits: clampedBitDepth,
            byteOrder: .littleEndian,
            components: resolvedRoles,
            colour: resolvedColour,
            alpha: resolvedAlpha,
            planes: planes,
            iccProfile: effectiveICC,
            limits: limits
        )

        let metadataBytes = try metadata.validate(limits: limits, additionalBytes: effectiveICC?.count ?? 0)
        guard retainedBytes >= 0,
              try checkedAdd(retainedBytes, checkedAdd(descriptor.requiredByteCount, metadataBytes)) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Legacy image conversion exceeds the combined live-storage budget.")
        }
        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
        let pixelCount = width * height
        let rawImage = try destination.write { dst in
            for (cIdx, comp) in components.enumerated() {
                let plane = descriptor.planes[cIdx]
                comp.data.withUnsafeBytes { (compBytes: UnsafeRawBufferPointer) in
                    for i in 0..<pixelCount {
                        let sampleValue: Int
                        if srcBytesPerSample == 1 {
                            if i < compBytes.count {
                                if comp.signed {
                                    sampleValue = Int(Int8(bitPattern: compBytes[i]))
                                } else {
                                    sampleValue = Int(compBytes[i])
                                }
                            } else {
                                sampleValue = 0
                            }
                        } else {
                            let byteIdx = i * 2
                            if byteIdx + 1 < compBytes.count {
                                let lo = UInt16(compBytes[byteIdx])
                                let hi = UInt16(compBytes[byteIdx + 1]) << 8
                                let word = lo | hi
                                if comp.signed {
                                    sampleValue = Int(Int16(bitPattern: word))
                                } else {
                                    sampleValue = Int(word)
                                }
                            } else if i < compBytes.count {
                                sampleValue = comp.signed ? Int(Int8(bitPattern: compBytes[i])) : Int(compBytes[i])
                            } else {
                                sampleValue = 0
                            }
                        }

                        let dstOffset = plane.offset + (i / width) * plane.rowBytes + (i % width) * plane.pixelStride
                        if dstBytesPerSample == 1 {
                            if signed {
                                dst[dstOffset] = UInt8(bitPattern: Int8(clamping: sampleValue))
                            } else {
                                dst[dstOffset] = UInt8(clamping: max(0, sampleValue))
                            }
                        } else {
                            let word: UInt16
                            if signed {
                                word = UInt16(bitPattern: Int16(clamping: sampleValue))
                            } else {
                                word = UInt16(clamping: max(0, sampleValue))
                            }
                            if descriptor.byteOrder == .littleEndian {
                                dst[dstOffset] = UInt8(truncatingIfNeeded: word & 0xFF)
                                dst[dstOffset + 1] = UInt8(truncatingIfNeeded: word >> 8)
                            } else {
                                dst[dstOffset] = UInt8(truncatingIfNeeded: word >> 8)
                                dst[dstOffset + 1] = UInt8(truncatingIfNeeded: word & 0xFF)
                            }
                        }
                    }
                }
            }
        }
        if metadata.entries.isEmpty && metadata.requiredKeys.isEmpty {
            return rawImage
        }
        return try Image(
            descriptor: rawImage.descriptor,
            storage: rawImage.storage,
            metadata: metadata,
            limits: limits
        )
    }

    /// Creates a ``J2KImage`` from a contract-aligned ``Image``.
    public init(contractImage: Image) throws {
        let desc = contractImage.descriptor
        let w = desc.width
        let h = desc.height
        let bitDepth = desc.meaningfulBits
        let signed = desc.sampleType == .signedInteger
        let outBytesPerSample = (bitDepth + 7) / 8
        let srcBytesPerSample = desc.storageBits / 8
        let compCount = desc.components.count

        var builtComponents: [J2KComponent] = []
        builtComponents.reserveCapacity(compCount)

        try contractImage.storage.withUnsafeBytes { raw in
            for cIdx in 0..<compCount {
                let planeIdx = min(cIdx, desc.planes.count - 1)
                let plane = desc.planes[planeIdx]
                let compSampleOffset: Int
                if desc.planes.count == 1 && compCount > 1 {
                    compSampleOffset = cIdx * plane.sampleStride
                } else {
                    compSampleOffset = 0
                }
                var outBytes = Data(count: w * h * outBytesPerSample)
                for y in 0..<h {
                    let rowStart = plane.offset + y * plane.rowBytes
                    for x in 0..<w {
                        let srcOffset = rowStart + x * plane.pixelStride + compSampleOffset
                        let sampleVal: Int
                        if srcBytesPerSample == 1 {
                            if signed {
                                sampleVal = Int(Int8(bitPattern: raw[srcOffset]))
                            } else {
                                sampleVal = Int(raw[srcOffset])
                            }
                        } else {
                            let b0 = UInt16(raw[srcOffset])
                            let b1 = UInt16(raw[srcOffset + 1])
                            let word = (desc.byteOrder == .littleEndian) ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
                            if signed {
                                sampleVal = Int(Int16(bitPattern: word))
                            } else {
                                sampleVal = Int(word)
                            }
                        }

                        let dstIdx = y * w + x
                        if outBytesPerSample == 1 {
                            if signed {
                                outBytes[dstIdx] = UInt8(bitPattern: Int8(clamping: sampleVal))
                            } else {
                                outBytes[dstIdx] = UInt8(clamping: max(0, sampleVal))
                            }
                        } else {
                            let word: UInt16
                            if signed {
                                word = UInt16(bitPattern: Int16(clamping: sampleVal))
                            } else {
                                word = UInt16(clamping: max(0, sampleVal))
                            }
                            outBytes[dstIdx * 2] = UInt8(truncatingIfNeeded: word & 0xFF)
                            outBytes[dstIdx * 2 + 1] = UInt8(truncatingIfNeeded: word >> 8)
                        }
                    }
                }
                builtComponents.append(
                    J2KComponent(
                        index: cIdx,
                        bitDepth: bitDepth,
                        signed: signed,
                        width: w,
                        height: h,
                        data: outBytes
                    )
                )
            }
        }

        let cs: J2KColorSpace
        if let icc = desc.iccProfile {
            cs = .iccProfile(icc)
        } else if desc.colour == .greyscale {
            cs = .grayscale
        } else if desc.colour == .rgb {
            cs = .sRGB
        } else {
            cs = .unknown
        }
        self.init(
            width: w,
            height: h,
            components: builtComponents,
            colorSpace: cs,
            alpha: desc.alpha,
            preservedColourInterpretation: desc.colour,
            preservedComponentRoles: desc.components,
            preservedMetadata: contractImage.metadata
        )
    }
}

// MARK: - J2KConfiguration, J2KProgressionOrder, J2KSubband

/// Basic configuration options for JPEG 2000 encoding and decoding.
public struct J2KConfiguration: Sendable, Equatable {
    /// The quality factor for lossy compression (0.0 to 1.0).
    public let quality: Double

    /// Whether to use lossless compression.
    public let lossless: Bool

    /// Creates a new configuration with the specified parameters.
    public init(quality: Double = 0.9, lossless: Bool = false) {
        self.quality = max(0.0, min(1.0, quality))
        self.lossless = lossless
    }

    public static let lossless = J2KConfiguration(quality: 1.0, lossless: true)
    public static let highQuality = J2KConfiguration(quality: 0.95, lossless: false)
    public static let balanced = J2KConfiguration(quality: 0.85, lossless: false)
    public static let fast = J2KConfiguration(quality: 0.70, lossless: false)
}

/// Progression order for JPEG 2000 codestreams.
public enum J2KProgressionOrder: String, Sendable, Equatable, CaseIterable {
    case lrcp = "LRCP"
    case rlcp = "RLCP"
    case rpcl = "RPCL"
    case pcrl = "PCRL"
    case cprl = "CPRL"

    package var contractProgressionOrder: CodecOptions.ProgressionOrder {
        switch self {
        case .lrcp: return .lrcp
        case .rlcp: return .rlcp
        case .rpcl: return .rpcl
        case .pcrl: return .pcrl
        case .cprl: return .cprl
        }
    }
}

/// Wavelet subband types.
public enum J2KSubband: String, Sendable, Equatable, CaseIterable {
    case ll = "LL"
    case hl = "HL"
    case lh = "LH"
    case hh = "HH"
}

// MARK: - J2KQualityOfService

/// Quality of Service levels for Apple platforms.
public enum J2KQualityOfService: Sendable, Equatable {
    case userInteractive
    case userInitiated
    case utility
    case background
    case `default`

    public var dispatchQoS: DispatchQoS {
        switch self {
        case .userInteractive: return .userInteractive
        case .userInitiated: return .userInitiated
        case .utility: return .utility
        case .background: return .background
        case .default: return .default
        }
    }

    public var taskPriority: TaskPriority {
        switch self {
        case .userInteractive, .userInitiated: return .high
        case .utility, .default: return .medium
        case .background: return .low
        }
    }
}

// MARK: - J2KFormat & J2KFormatDetector

/// Supported JPEG 2000 file formats.
public enum J2KFormat: String, Sendable, Equatable, CaseIterable {
    /// JP2 format (JPEG 2000 Part 1).
    case jp2
    /// J2K codestream format.
    case j2k
    /// JPX format (JPEG 2000 Part 2).
    case jpx
    /// JPM format (JPEG 2000 Part 6).
    case jpm
    /// JPH format (HTJ2K - JPEG 2000 Part 15).
    case jph

    /// Returns the typical file extension for this format.
    public var fileExtension: String {
        rawValue
    }

    /// Returns the MIME type for this format.
    public var mimeType: String {
        "image/\(rawValue)"
    }
}

/// Detects JPEG 2000 file formats from file signatures.
public struct J2KFormatDetector: Sendable {
    private static let jp2SignatureLength: UInt32 = 0x0000_000C
    private static let jp2SignatureType: [UInt8] = [0x6A, 0x50, 0x20, 0x20] // "jP  "
    private static let jp2SignatureContent: [UInt8] = [0x0D, 0x0A, 0x87, 0x0A]
    private static let ftypType: [UInt8] = [0x66, 0x74, 0x79, 0x70] // "ftyp"
    private static let jp2Brand: [UInt8] = [0x6A, 0x70, 0x32, 0x20] // "jp2 "
    private static let jpxBrand: [UInt8] = [0x6A, 0x70, 0x78, 0x20] // "jpx "
    private static let jpmBrand: [UInt8] = [0x6A, 0x70, 0x6D, 0x20] // "jpm "
    private static let jphBrand: [UInt8] = [0x6A, 0x70, 0x68, 0x20] // "jph "
    private static let socMarker: [UInt8] = [0xFF, 0x4F]

    public init() {}

    /// Detects the format of JPEG 2000 data.
    public func detect(data: Data) throws -> J2KFormat {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            throw J2KError.fileFormatError("Data too small to detect format (need at least 2 bytes)")
        }

        if bytes[0] == Self.socMarker[0] && bytes[1] == Self.socMarker[1] {
            return .j2k
        }

        guard bytes.count >= 12 else {
            throw J2KError.fileFormatError("Data too small for box-based format detection")
        }

        guard hasJP2Signature(bytes) else {
            throw J2KError.fileFormatError("Invalid or unrecognized JPEG 2000 file format")
        }

        if let brand = extractFiletypeBrand(from: bytes) {
            if brand == Self.jpxBrand { return .jpx }
            if brand == Self.jpmBrand { return .jpm }
            if brand == Self.jphBrand { return .jph }
            if brand == Self.jp2Brand { return .jp2 }
        }

        return .jp2
    }

    /// Detects the format of a file at the specified URL.
    public func detect(at url: URL) throws -> J2KFormat {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        guard let data = try fileHandle.read(upToCount: 256) else {
            throw J2KError.ioError("Failed to read file header from \(url.path)")
        }
        return try detect(data: data)
    }

    /// Validates that data appears to be a valid JPEG 2000 file.
    public func isValidJPEG2000(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(32))
        guard bytes.count >= 2 else { return false }
        if bytes[0] == Self.socMarker[0] && bytes[1] == Self.socMarker[1] {
            return true
        }
        return hasJP2Signature(bytes)
    }

    private func hasJP2Signature(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12 else { return false }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard length == Self.jp2SignatureLength else { return false }
        guard Array(bytes[4..<8]) == Self.jp2SignatureType else { return false }
        guard Array(bytes[8..<12]) == Self.jp2SignatureContent else { return false }
        return true
    }

    private func extractFiletypeBrand(from bytes: [UInt8]) -> [UInt8]? {
        var offset = 12
        while offset <= bytes.count - 8 {
            let lengthU32 = (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
            let length = Int(lengthU32)
            if Array(bytes[(offset + 4)..<(offset + 8)]) == Self.ftypType {
                guard offset <= bytes.count - 12 else { return nil }
                return Array(bytes[(offset + 8)..<(offset + 12)])
            }
            guard length >= 8 else { break }
            let (nextOffset, overflow) = offset.addingReportingOverflow(length)
            if overflow { break }
            offset = nextOffset
        }
        return nil
    }
}

// MARK: - J2KEncodingConfiguration, J2KBitrateMode, J2KEncodingPreset

/// Bitrate control mode for ``J2KEncodingConfiguration``.
public enum J2KBitrateMode: Sendable, Equatable {
    case constantQuality
    case constantBitrate(Double)
    case variableBitrate(minQuality: Double, maxBitsPerPixel: Double)
    case lossless
}

/// Comprehensive configuration for JPEG 2000 encoding.
public struct J2KEncodingConfiguration: Sendable {
    public var quality: Double
    public var lossless: Bool {
        didSet {
            if lossless {
                useReversibleFilter = true
            }
        }
    }
    public var decompositionLevels: Int
    public var codeBlockSize: (width: Int, height: Int)
    public var qualityLayers: Int
    public var selectiveArithmeticBypass: Bool = false
    public var progressionOrder: J2KProgressionOrder
    public var enableVisualWeighting: Bool
    public var tileSize: (width: Int, height: Int)
    public var bitrateMode: J2KBitrateMode
    public var maxThreads: Int
    public var useHTJ2K: Bool
    public var useReversibleFilter: Bool

    public init(
        quality: Double = 0.9,
        lossless: Bool = false,
        decompositionLevels: Int = 5,
        codeBlockSize: (width: Int, height: Int) = (32, 32),
        qualityLayers: Int = 5,
        progressionOrder: J2KProgressionOrder = .rpcl,
        enableVisualWeighting: Bool = true,
        tileSize: (width: Int, height: Int) = (0, 0),
        bitrateMode: J2KBitrateMode = .constantQuality,
        maxThreads: Int = 0,
        useHTJ2K: Bool = false,
        useReversibleFilter: Bool? = nil
    ) {
        self.quality = max(0.0, min(1.0, quality))
        self.lossless = lossless
        self.decompositionLevels = max(0, min(10, decompositionLevels))
        self.codeBlockSize = codeBlockSize
        self.qualityLayers = max(1, min(20, qualityLayers))
        self.progressionOrder = progressionOrder
        self.enableVisualWeighting = enableVisualWeighting
        self.tileSize = tileSize
        self.bitrateMode = lossless ? .lossless : bitrateMode
        self.maxThreads = max(0, maxThreads)
        self.useHTJ2K = useHTJ2K
        self.useReversibleFilter = useReversibleFilter ?? lossless
    }
}

/// Predefined encoding preset types.
public enum J2KEncodingPreset: String, Sendable, CaseIterable {
    case fast
    case balanced
    case quality

    public func configuration(quality: Double = 0.9, lossless: Bool = false) -> J2KEncodingConfiguration {
        switch self {
        case .fast:
            return J2KEncodingConfiguration(
                quality: quality, lossless: lossless, decompositionLevels: 3,
                codeBlockSize: (64, 64), qualityLayers: 3, progressionOrder: .lrcp,
                enableVisualWeighting: false, tileSize: (512, 512), maxThreads: 1
            )
        case .balanced:
            return J2KEncodingConfiguration(
                quality: quality, lossless: lossless, decompositionLevels: 5,
                codeBlockSize: (32, 32), qualityLayers: 5, progressionOrder: .rpcl,
                enableVisualWeighting: quality < 1.0, tileSize: (1024, 1024), maxThreads: 0
            )
        case .quality:
            return J2KEncodingConfiguration(
                quality: quality, lossless: lossless, decompositionLevels: 6,
                codeBlockSize: (32, 32), qualityLayers: 10, progressionOrder: .rpcl,
                enableVisualWeighting: quality < 1.0, tileSize: (2048, 2048), maxThreads: 0
            )
        }
    }
}

// MARK: - J2KEncoder & J2KDecoder

/// Predecessor compatibility encoder backed by ``Part1Pipeline``.
public struct J2KEncoder: Sendable {
    public let configuration: J2KConfiguration
    public let encodingConfiguration: J2KEncodingConfiguration

    public init(configuration: J2KConfiguration = J2KConfiguration()) {
        self.configuration = configuration
        self.encodingConfiguration = J2KEncodingConfiguration(
            quality: configuration.quality,
            lossless: configuration.lossless
        )
    }

    public init(encodingConfiguration: J2KEncodingConfiguration) {
        self.configuration = J2KConfiguration(
            quality: encodingConfiguration.quality,
            lossless: encodingConfiguration.lossless
        )
        self.encodingConfiguration = encodingConfiguration
    }

    /// Encodes a ``J2KImage`` into a JPEG 2000 Part 1 or Part 15 (HTJ2K) codestream.
    public func encode(_ image: J2KImage) async throws -> Data {
        try encodeSync(image)
    }

    /// Synchronous helper for encoding a ``J2KImage``.
    public func encodeSync(_ image: J2KImage) throws -> Data {
        let contractImage: Image
        do {
            contractImage = try image.toContractImage()
        } catch let error as J2KError {
            throw error
        } catch let error as CodecError {
            throw J2KError(error)
        }

        let minDim = max(1, min(image.width, image.height))
        let maxLevels = max(0, Int(floor(log2(Double(minDim)))))
        let effectiveLevels = max(0, min(encodingConfiguration.decompositionLevels, maxLevels))
        let cbW = validPowerOfTwoCodeBlockDim(encodingConfiguration.codeBlockSize.width)
        let cbH = validPowerOfTwoCodeBlockDim(encodingConfiguration.codeBlockSize.height)
        let isHT = encodingConfiguration.useHTJ2K
        let isLossless = encodingConfiguration.lossless || isHT
        let mode: CompressionMode = isLossless ? .lossless : .lossy
        let wavelet: CodecOptions.WaveletTransform = (isLossless || encodingConfiguration.useReversibleFilter)
            ? .reversible53
            : .irreversible97
        let layers = isHT ? 1 : max(1, min(255, encodingConfiguration.qualityLayers))
        let tileW: Int? = encodingConfiguration.tileSize.width > 0 ? encodingConfiguration.tileSize.width : nil
        let tileH: Int? = encodingConfiguration.tileSize.height > 0 ? encodingConfiguration.tileSize.height : nil

        let targetBpp: Double?
        if case .constantBitrate(let bpp) = encodingConfiguration.bitrateMode, !isLossless {
            targetBpp = bpp
        } else {
            targetBpp = nil
        }

        do {
            let codecOptions = try CodecOptions(
                decompositionLevels: effectiveLevels,
                codeBlockWidth: cbW,
                codeBlockHeight: cbH,
                blockCoding: isHT ? .htj2k : .part1,
                wavelet: wavelet,
                progressionOrder: encodingConfiguration.progressionOrder.contractProgressionOrder,
                quality: (!isLossless && targetBpp == nil) ? encodingConfiguration.quality : nil,
                targetBitsPerPixel: targetBpp,
                qualityLayers: layers,
                tileWidth: tileW,
                tileHeight: tileH,
                codeBlockStyleBits: (!isHT && encodingConfiguration.selectiveArithmeticBypass) ? 0x01 : 0
            )
            let config = try EncoderConfiguration(mode: mode, codecOptions: codecOptions)
            let resolvedBackend = try AccelerationRuntime.resolve(.automatic)
            let (bytes, _) = try Part1Pipeline.encode(
                image: contractImage,
                configuration: config,
                limits: .default,
                backend: resolvedBackend.backend,
                progress: nil
            )
            return Data(bytes)
        } catch let error as CodecError {
            throw J2KError(error)
        }
    }

    private func validPowerOfTwoCodeBlockDim(_ value: Int) -> Int {
        let clamped = max(4, min(64, value))
        var p = 4
        while p * 2 <= clamped {
            p *= 2
        }
        return p
    }
}

/// Predecessor compatibility decoder backed by ``Part1Pipeline`` and ``JP2Container``.
public struct J2KDecoder: Sendable {
    public init() {}

    /// Decodes a JPEG 2000 codestream or JP2/JPH/JPX container into a ``J2KImage``.
    public func decode(_ data: Data) async throws -> J2KImage {
        try Self.decodeSync(data)
    }

    /// Decoded codestream metadata alongside the decoded ``J2KImage``.
    package struct DecodedCodestreamInfo: Sendable {
        package let image: J2KImage
        package let contractImage: Image?
        package let colourInterpretation: ColourInterpretation
        package let alphaInterpretation: AlphaInterpretation
        package let iccProfile: Data?
        package let metadata: ImageMetadata
        package let discardedMetadataCount: Int
        package let discardedMetadataBytes: Int
        package let discardedMetadataKinds: [String]
        package let isReversibleLossless: Bool
        package let totalQualityLayers: Int
        package let totalComponents: Int
        package let backend: Backend
        package let fallbackReason: String?
        package private(set) var peakWorkspaceBytes: Int
        package let pixelAccounting: LegacyPixelAccounting

        package func includingAdditionalWorkspacePeak(_ bytes: Int) -> Self {
            var result = self
            result.peakWorkspaceBytes = max(result.peakWorkspaceBytes, bytes)
            return result
        }
    }

    /// Synchronous helper for decoding a JPEG 2000 codestream or container with optional JPIP view-window parameters.
    public static func decodeSync(
        _ data: Data,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int? = nil,
        components: [Int]? = nil,
        region: (x: Int, y: Int, width: Int, height: Int)? = nil
    ) throws -> J2KImage {
        do {
            return try decodeWithInfo(
                data,
                maxQualityLayers: maxQualityLayers,
                resolutionLevel: resolutionLevel,
                components: components,
                region: region,
                limits: .default,
                executionPolicy: .automatic,
                metadataPolicy: .preserve
            ).image
        } catch let error as CodecError {
            throw J2KError(error)
        }
    }

    /// Decodes a JPEG 2000 codestream or container with pre-allocation resource admission and codestream fidelity inspection.
    package static func decodeWithInfo(
        _ data: Data,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int? = nil,
        components: [Int]? = nil,
        region: (x: Int, y: Int, width: Int, height: Int)? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic,
        metadataPolicy: MetadataPolicy = .preserve,
        retainedExternalBytes: Int = 0
    ) throws -> DecodedCodestreamInfo {
        guard !data.isEmpty else {
            throw J2KError.decodingError("Cannot decode empty data")
        }

        do {
            let work = WorkGuard(limits: limits)
            try work.check()
            let resolvedBackend = try AccelerationRuntime.resolve(executionPolicy)
            guard retainedExternalBytes >= 0,
                  data.count <= limits.maximumCompressedBytes,
                  data.count <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Compressed input exceeds operation limits.")
            }
            if let resLevel = resolutionLevel {
                guard (0...32).contains(resLevel) else {
                    throw CodecError(.invalidArgument, "Resolution level must lie in 0...32.")
                }
            }
            if let reg = region {
                guard reg.x >= 0, reg.y >= 0, reg.width > 0, reg.height > 0,
                      !reg.x.addingReportingOverflow(reg.width).overflow,
                      !reg.y.addingReportingOverflow(reg.height).overflow else {
                    throw CodecError(.invalidArgument, "Region bounds are negative, non-positive, or overflow Int.")
                }
            }

            let inputCopyBytes = try checkedAdd(32, data.count)
            guard inputCopyBytes <= limits.maximumWorkspaceBytes,
                  try checkedAdd(retainedExternalBytes, checkedAdd(data.count, inputCopyBytes)) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Compressed input workspace copy exceeds operation limits.")
            }

            let outerWorkspace = try checkedAdd(inputCopyBytes, retainedExternalBytes)
            let pipelineLimits = try limits.reserving(workspaceBytes: outerWorkspace,
                memoryBytes: checkedAdd(data.count, outerWorkspace))

            let effectiveLayers: Int?
            if let q = maxQualityLayers, q > 0 {
                effectiveLayers = q
            } else {
                effectiveLayers = nil
            }

            let rawBytes = [UInt8](data)
            let contractImage: Image
            let workspace: Int
            let isReversibleLossless: Bool
            let totalLayers: Int
            let totalComponents: Int
            let discardedCount: Int
            let discardedBytes: Int
            let discardedKinds: [String]

            if JP2Container.isContainer(rawBytes) {
                let reconciled = try JP2Container.inspectReconciled(
                    rawBytes,
                    limits: pipelineLimits,
                    metadataPolicy: metadataPolicy
                )
                let profile = reconciled.part1Profile
                let descriptor = reconciled.outputDescriptor
                let minDecodedBytes = descriptor.requiredByteCount
                let containerWorkspace = try JP2Container.decodeWorkspaceBytes(
                    reconciled: reconciled, limits: pipelineLimits,
                    metadataPolicy: metadataPolicy, maxQualityLayers: effectiveLayers)
                let combinedWorkspace = try checkedAdd(outerWorkspace, containerWorkspace)
                guard minDecodedBytes <= limits.maximumDecodedBytes,
                      combinedWorkspace <= limits.maximumWorkspaceBytes,
                      try checkedAdd(data.count, checkedAdd(minDecodedBytes, combinedWorkspace)) <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, "Decoded container image and workspace exceed operation limits.")
                }

                let destination = try ImageDestination.allocate(descriptor: descriptor, limits: pipelineLimits)
                let decodeOpts = DecodeOptions(
                    resourceLimits: pipelineLimits,
                    executionPolicy: executionPolicy,
                    copyPolicy: .allowCopy,
                    metadataPolicy: metadataPolicy
                )
                let decoded = try JP2Container.decode(
                    reconciled: reconciled,
                    into: destination,
                    options: decodeOpts,
                    allocations: 1,
                    maxQualityLayers: effectiveLayers
                )
                contractImage = decoded.image
                workspace = try checkedAdd(outerWorkspace, decoded.report.peakWorkspaceBytes ?? 0)
                isReversibleLossless = profile.isReversibleLossless
                totalLayers = max(1, profile.tiles.map(\.defaultCodingStyle.layers).max() ?? 1)
                totalComponents = descriptor.components.count
                discardedCount = (metadataPolicy == .discardAncillary) ? reconciled.discardedMetadataCount : 0
                discardedBytes = (metadataPolicy == .discardAncillary) ? reconciled.discardedMetadataBytes : 0
                discardedKinds = (metadataPolicy == .discardAncillary) ? reconciled.discardedMetadataKinds : []
            } else {
                guard let socOffset = findSOCOffset(in: rawBytes) else {
                    throw J2KError.decodingError("No JPEG 2000 SOC marker (0xFF4F) found in input data")
                }
                let codestreamCopyBytes = try checkedAdd(32, rawBytes.count - socOffset)
                // The core includes its codestream payload in memory admission; reserve only
                // this array's header there, and its whole copied payload in workspace.
                let rawLimits = try pipelineLimits.reserving(workspaceBytes: codestreamCopyBytes, memoryBytes: 32)
                let codestreamBytes = Array(rawBytes[socOffset...])
                let profile = try Part1Pipeline.inspect(codestreamBytes, limits: rawLimits, metadataPolicy: metadataPolicy)
                let descriptor = try profile.defaultDescriptor(limits: rawLimits)
                let minDecodedBytes = descriptor.requiredByteCount
                let estWorkspace = try checkedAdd(
                    try Part1Pipeline.workspaceBytes(
                        planePixels: profile.largestTilePixels,
                        componentCount: profile.componentCount,
                        bytesPerCoeff: profile.isReversibleLossless ? 4 : 8,
                        joinedBytes: profile.largestTileBytes
                    ),
                    profile.retainedMetadataBytes
                )
                let combinedWorkspace = try checkedAdd(outerWorkspace, checkedAdd(codestreamCopyBytes, estWorkspace))
                guard minDecodedBytes <= limits.maximumDecodedBytes,
                      combinedWorkspace <= limits.maximumWorkspaceBytes,
                      try checkedAdd(data.count, checkedAdd(minDecodedBytes, combinedWorkspace)) <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, "Decoded image and workspace exceed operation limits.")
                }

                let destination = try ImageDestination.allocate(descriptor: descriptor, limits: rawLimits)
                do {
                    let decoded = try Part1Pipeline.decode(
                        bytes: codestreamBytes,
                        profile: profile,
                        into: destination,
                        limits: rawLimits,
                        backend: resolvedBackend.backend,
                        progress: nil,
                        maxQualityLayers: effectiveLayers
                    )
                    contractImage = decoded.0
                    workspace = try checkedAdd(outerWorkspace, checkedAdd(codestreamCopyBytes, decoded.1))
                } catch {
                    destination.invalidateAfterFailure()
                    throw error
                }
                isReversibleLossless = profile.isReversibleLossless
                totalLayers = max(1, profile.tiles.map(\.defaultCodingStyle.layers).max() ?? 1)
                totalComponents = profile.componentCount
                discardedCount = (metadataPolicy == .discardAncillary) ? profile.commentCount : 0
                discardedBytes = (metadataPolicy == .discardAncillary) ? profile.commentPayloadBytes : 0
                discardedKinds = (discardedCount > 0) ? ["COM"] : []
            }

            try work.check()
            let fullLegacyBytes = try checkedMultiply(
                checkedMultiply(contractImage.descriptor.width, contractImage.descriptor.height),
                checkedMultiply(contractImage.descriptor.components.count, (contractImage.descriptor.meaningfulBits + 7) / 8)
            )
            let metadataBytes = try contractImage.metadata.validate(limits: limits, additionalBytes: contractImage.descriptor.iccProfile?.count ?? 0)
            let bridgeResidentBytes = try checkedAdd(retainedExternalBytes, checkedAdd(data.count, checkedAdd(inputCopyBytes, metadataBytes)))
            var pixelAccounting = LegacyPixelAccounting(decodedBytes: contractImage.storage.byteCount)
            try pixelAccounting.recordAllocation(bytes: fullLegacyBytes, count: contractImage.descriptor.components.count,
                liveBefore: contractImage.storage.byteCount, residentBytes: bridgeResidentBytes,
                reason: "Materialise decoded contract samples as legacy component buffers", limits: limits)
            let fullLegacyImage = try J2KImage(contractImage: contractImage)
            // These explicit owners make the accounted live set independent of optimiser lifetime shortening.
            defer { withExtendedLifetime((contractImage, fullLegacyImage, rawBytes)) {} }
            let retainedPixelBytes = try checkedAdd(contractImage.storage.byteCount, fullLegacyBytes)
            var projectedPixelBytes = 0
            var image = fullLegacyImage
            var wasViewWindowTransformed = false
            var outColour = contractImage.descriptor.colour
            var outAlpha = contractImage.descriptor.alpha
            var outICC = contractImage.descriptor.iccProfile
            var outMetadata = contractImage.metadata

            // 1. Apply strict component validation & selection if requested.
            if let selectedComponents = components, !selectedComponents.isEmpty {
                var filtered: [J2KComponent] = []
                filtered.reserveCapacity(selectedComponents.count)
                for idx in selectedComponents {
                    guard idx >= 0 && idx < image.components.count else {
                        throw CodecError(
                            .invalidArgument,
                            "Requested component index \(idx) is out of range 0..<\(image.components.count)."
                        )
                    }
                    filtered.append(image.components[idx])
                }
                guard Set(selectedComponents).count == selectedComponents.count else {
                    throw CodecError(.invalidArgument, "Component selections must not repeat a component.")
                }
                let mappedRoles = selectedComponents.map { contractImage.descriptor.components[$0] }
                let keepsAlpha = mappedRoles.contains(.alpha)
                let keepsAllComponents = selectedComponents.count == image.components.count
                let selectsColour = mappedRoles.contains { role in
                    if role == .alpha { return false }
                    if case .uninterpreted = role {
                        return contractImage.descriptor.colour == .unknown
                    }
                    return true
                }
                if contractImage.descriptor.alpha == .premultiplied && !keepsAlpha && selectsColour {
                    throw CodecError(.unsupportedFeature, "A premultiplied colour view must retain its opacity component; removing it would change sample interpretation.")
                }
                if selectedComponents != Array(0..<image.components.count) {
                    wasViewWindowTransformed = true
                    outAlpha = keepsAlpha ? contractImage.descriptor.alpha : .absent
                    if mappedRoles.contains(.red), mappedRoles.contains(.green), mappedRoles.contains(.blue) {
                        outColour = .rgb
                    } else if mappedRoles.contains(.grey),
                              !mappedRoles.contains(.red), !mappedRoles.contains(.green), !mappedRoles.contains(.blue) {
                        outColour = .greyscale
                    } else {
                        outColour = .unknown
                    }
                    if !keepsAllComponents {
                        // An ICC profile describes its complete colour tuple, never an arbitrary subset.
                        let sourceColourRoles = contractImage.descriptor.components.filter { $0 != .alpha }
                        if !sourceColourRoles.allSatisfy(mappedRoles.contains) { outICC = nil }
                    }
                    var entries = outMetadata.entries
                    var required = outMetadata.requiredKeys
                    // Reader requirements describe the source container; the encoder regenerates them.
                    entries.removeValue(forKey: "rreq")
                    required.remove("rreq")
                    if mappedRoles.allSatisfy({ $0 == .alpha }) {
                        for key in entries.keys.filter({ $0 == "colr" || $0.hasPrefix("colr.") }) {
                            entries.removeValue(forKey: key)
                            required.remove(key)
                        }
                    }
                    outMetadata = ImageMetadata(entries: entries, requiredKeys: required)
                }
                let reindexed = filtered.enumerated().map { newIdx, comp in
                    J2KComponent(
                        index: newIdx,
                        bitDepth: comp.bitDepth,
                        signed: comp.signed,
                        width: comp.width,
                        height: comp.height,
                        subsamplingX: comp.subsamplingX,
                        subsamplingY: comp.subsamplingY,
                        data: comp.data
                    )
                }
                let resolvedCS: J2KColorSpace
                if let icc = outICC {
                    resolvedCS = .iccProfile(icc)
                } else if outColour == .greyscale {
                    resolvedCS = .grayscale
                } else if outColour == .rgb {
                    resolvedCS = .sRGB
                } else {
                    resolvedCS = .unknown
                }
                image = J2KImage(
                    width: image.width,
                    height: image.height,
                    components: reindexed,
                    colorSpace: resolvedCS,
                    alpha: outAlpha,
                    preservedColourInterpretation: outColour,
                    preservedComponentRoles: mappedRoles,
                    preservedMetadata: outMetadata
                )
            }

            // 2. Apply spatial region cropping in full-resolution reference grid coordinates
            // BEFORE resolution-level downsampling, rejecting out-of-bounds regions cleanly.
            if let reg = region {
                let (endX, ovX) = reg.x.addingReportingOverflow(reg.width)
                let (endY, ovY) = reg.y.addingReportingOverflow(reg.height)
                guard !ovX, !ovY,
                      reg.x >= 0, reg.y >= 0, reg.width > 0, reg.height > 0,
                      endX <= image.width, endY <= image.height else {
                    throw CodecError(
                        .invalidArgument,
                        "Requested region (\(reg.x), \(reg.y), \(reg.width)x\(reg.height)) exceeds image bounds \(image.width)x\(image.height)."
                    )
                }
                if reg.x != 0 || reg.y != 0 || reg.width != image.width || reg.height != image.height {
                    wasViewWindowTransformed = true
                    let nextBytes = try image.pixelBytes(width: reg.width, height: reg.height)
                    try pixelAccounting.recordAllocation(bytes: nextBytes, count: image.components.count,
                        liveBefore: checkedAdd(retainedPixelBytes, projectedPixelBytes), residentBytes: bridgeResidentBytes,
                        reason: "Materialise cropped legacy component buffers", limits: limits)
                    image = try cropImage(image, region: reg)
                    projectedPixelBytes = nextBytes
                }
            }

            // 3. Apply resolution level reduction after full-resolution region cropping.
            // Convention (per JPIPClient and DICOMJPIPClient):
            // resolutionLevel == 0 is full resolution; higher values halve dimensions by 2^level.
            if let resLevel = resolutionLevel, resLevel > 0 {
                wasViewWindowTransformed = true
                let factor = 1 << min(30, resLevel)
                let nextWidth = max(1, (image.width + factor - 1) / factor)
                let nextHeight = max(1, (image.height + factor - 1) / factor)
                let nextBytes = try image.pixelBytes(width: nextWidth, height: nextHeight)
                try pixelAccounting.recordAllocation(bytes: nextBytes, count: image.components.count,
                    liveBefore: checkedAdd(retainedPixelBytes, projectedPixelBytes), residentBytes: bridgeResidentBytes,
                    reason: "Materialise reduced-resolution legacy component buffers", limits: limits)
                image = downsampleImage(image, factor: factor)
                projectedPixelBytes = nextBytes
            }

            return DecodedCodestreamInfo(
                image: image,
                contractImage: wasViewWindowTransformed ? nil : contractImage,
                colourInterpretation: outColour,
                alphaInterpretation: outAlpha,
                iccProfile: outICC,
                metadata: outMetadata,
                discardedMetadataCount: discardedCount,
                discardedMetadataBytes: discardedBytes,
                discardedMetadataKinds: discardedKinds,
                isReversibleLossless: isReversibleLossless,
                totalQualityLayers: totalLayers,
                totalComponents: totalComponents,
                backend: resolvedBackend.backend,
                fallbackReason: resolvedBackend.fallbackReason,
                peakWorkspaceBytes: workspace,
                pixelAccounting: pixelAccounting
            )
        } catch let error as J2KError {
            throw error
        }
    }

    private static func findSOCOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == 0xFF && bytes[i + 1] == 0x4F {
                return i
            }
        }
        return nil
    }

    private static func downsampleImage(_ image: J2KImage, factor: Int) -> J2KImage {
        guard factor > 1 else { return image }
        let newW = max(1, (image.width + factor - 1) / factor)
        let newH = max(1, (image.height + factor - 1) / factor)
        let newComponents = image.components.map { comp -> J2KComponent in
            let bps = comp.bytesPerSample
            var dstBytes = Data(count: newW * newH * bps)
            comp.data.withUnsafeBytes { (srcBytes: UnsafeRawBufferPointer) in
                for y in 0..<newH {
                    let srcY = min(comp.height - 1, y * factor)
                    for x in 0..<newW {
                        let srcX = min(comp.width - 1, x * factor)
                        let srcIdx = (srcY * comp.width + srcX) * bps
                        let dstIdx = (y * newW + x) * bps
                        for b in 0..<bps where srcIdx + b < srcBytes.count {
                            dstBytes[dstIdx + b] = srcBytes[srcIdx + b]
                        }
                    }
                }
            }
            return J2KComponent(
                index: comp.index,
                bitDepth: comp.bitDepth,
                signed: comp.signed,
                width: newW,
                height: newH,
                subsamplingX: comp.subsamplingX,
                subsamplingY: comp.subsamplingY,
                data: dstBytes
            )
        }
        return J2KImage(
            width: newW,
            height: newH,
            components: newComponents,
            colorSpace: image.colorSpace,
            alpha: image.alpha,
            preservedColourInterpretation: image.preservedColourInterpretation,
            preservedComponentRoles: image.preservedComponentRoles,
            preservedMetadata: image.preservedMetadata
        )
    }

    private static func cropImage(
        _ image: J2KImage,
        region: (x: Int, y: Int, width: Int, height: Int)
    ) throws -> J2KImage {
        guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              !region.x.addingReportingOverflow(region.width).overflow,
              !region.y.addingReportingOverflow(region.height).overflow else {
            throw J2KError.invalidDimensions(
                "Invalid region (\(region.x), \(region.y), \(region.width)x\(region.height))"
            )
        }
        let x0 = min(region.x, image.width - 1)
        let y0 = min(region.y, image.height - 1)
        let (rawX1, ovX1) = x0.addingReportingOverflow(region.width)
        let (rawY1, ovY1) = y0.addingReportingOverflow(region.height)
        let x1 = ovX1 ? image.width : min(image.width, rawX1)
        let y1 = ovY1 ? image.height : min(image.height, rawY1)
        let cropW = max(1, x1 - x0)
        let cropH = max(1, y1 - y0)

        let croppedComponents = image.components.map { comp -> J2KComponent in
            let bps = comp.bytesPerSample
            var dstBytes = Data(count: cropW * cropH * bps)
            comp.data.withUnsafeBytes { (srcBytes: UnsafeRawBufferPointer) in
                for row in 0..<cropH {
                    let srcRow = y0 + row
                    for col in 0..<cropW {
                        let srcCol = x0 + col
                        let srcIdx = (srcRow * comp.width + srcCol) * bps
                        let dstIdx = (row * cropW + col) * bps
                        for b in 0..<bps where srcIdx + b < srcBytes.count {
                            dstBytes[dstIdx + b] = srcBytes[srcIdx + b]
                        }
                    }
                }
            }
            return J2KComponent(
                index: comp.index,
                bitDepth: comp.bitDepth,
                signed: comp.signed,
                width: cropW,
                height: cropH,
                subsamplingX: comp.subsamplingX,
                subsamplingY: comp.subsamplingY,
                data: dstBytes
            )
        }
        return J2KImage(
            width: cropW,
            height: cropH,
            components: croppedComponents,
            offsetX: x0,
            offsetY: y0,
            colorSpace: image.colorSpace,
            alpha: image.alpha,
            preservedColourInterpretation: image.preservedColourInterpretation,
            preservedComponentRoles: image.preservedComponentRoles,
            preservedMetadata: image.preservedMetadata
        )
    }
}

// MARK: - Transcoding Bridge (J2KTranscoder, TranscodingConfiguration, TranscodingDirection, TranscodingResult)

/// Configuration options for transcoding operations.
public struct TranscodingConfiguration: Sendable, Equatable {
    public let enableParallelProcessing: Bool
    public let maxConcurrency: Int

    public init(enableParallelProcessing: Bool = true, maxConcurrency: Int = 0) {
        self.enableParallelProcessing = enableParallelProcessing
        self.maxConcurrency = maxConcurrency <= 0 ? ProcessInfo.processInfo.processorCount : maxConcurrency
    }

    public static let `default` = TranscodingConfiguration()
    public static let sequential = TranscodingConfiguration(enableParallelProcessing: false)
}

/// The direction of transcoding between JPEG 2000 formats.
public enum TranscodingDirection: String, Sendable, Equatable, CaseIterable {
    /// Transcode from legacy JPEG 2000 (Part 1) to HTJ2K (Part 15).
    case legacyToHT = "JPEG 2000 → HTJ2K"

    /// Transcode from HTJ2K (Part 15) to legacy JPEG 2000 (Part 1).
    case htToLegacy = "HTJ2K → JPEG 2000"
}

/// Stages of the transcoding pipeline.
public enum TranscodingStage: String, Sendable, Equatable, CaseIterable {
    case parsing = "Parsing"
    case coefficientExtraction = "Coefficient Extraction"
    case validation = "Validation"
    case reEncoding = "Re-encoding"
    case codestreamGeneration = "Codestream Generation"
}

/// Reports progress during a transcoding operation.
public struct TranscodingProgressUpdate: Sendable, Equatable {
    public let stage: TranscodingStage
    public let progress: Double
    public let overallProgress: Double
    public let direction: TranscodingDirection

    public init(
        stage: TranscodingStage,
        progress: Double,
        overallProgress: Double,
        direction: TranscodingDirection
    ) {
        self.stage = stage
        self.progress = progress
        self.overallProgress = overallProgress
        self.direction = direction
    }
}

/// The result of a transcoding operation.
public struct TranscodingResult: Sendable, Equatable {
    public let data: Data
    public let direction: TranscodingDirection
    public let codeBlocksTranscoded: Int
    public let tilesProcessed: Int
    public let transcodingTime: TimeInterval
    public let metadataPreserved: Bool

    public init(
        data: Data,
        direction: TranscodingDirection,
        codeBlocksTranscoded: Int,
        tilesProcessed: Int,
        transcodingTime: TimeInterval,
        metadataPreserved: Bool
    ) {
        self.data = data
        self.direction = direction
        self.codeBlocksTranscoded = codeBlocksTranscoded
        self.tilesProcessed = tilesProcessed
        self.transcodingTime = transcodingTime
        self.metadataPreserved = metadataPreserved
    }
}

/// Lossless transcoder between JPEG 2000 (Part 1) and HTJ2K (Part 15),
/// backed by ``ScalarLosslessCodec`` (for single-component coefficient-domain transcoding)
/// and ``Part1Pipeline`` (for general multi-component reversible codestreams).
public struct J2KTranscoder: Sendable {
    public let configuration: TranscodingConfiguration

    public init(configuration: TranscodingConfiguration = .default) {
        self.configuration = configuration
    }

    /// Detects whether a JPEG 2000 codestream or JP2/JPH/JPX container uses HTJ2K (Part 15) coding.
    ///
    /// Scans the main header for a `CAP` marker (`0xFF50`) or the HT bit (`0x40`)
    /// in the `COD` marker coding style byte.
    public func isHTJ2K(_ data: Data) throws -> Bool {
        let rawBytes = [UInt8](data)
        guard rawBytes.count >= 4 else {
            throw J2KError.decodingError("Codestream too short to detect format")
        }

        let bytes: [UInt8]
        if JP2Container.isContainer(rawBytes) {
            do {
                let parsed = try JP2Container.parse(rawBytes, limits: .default, metadataPolicy: .preserve)
                if parsed.format == JP2Container.jphFormat {
                    return true
                }
                bytes = Array(rawBytes[parsed.codestreamRange])
            } catch let error as CodecError {
                throw J2KError(error)
            }
            guard bytes.count >= 4 else {
                throw J2KError.decodingError("Container codestream too short to detect format")
            }
        } else {
            bytes = rawBytes
        }

        let socMarker = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard socMarker == 0xFF4F else {
            throw J2KError.decodingError("Missing SOC marker")
        }

        var offset = 2
        while offset < bytes.count - 1 {
            let marker = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            if marker == 0xFF50 {
                // CAP marker — HTJ2K
                return true
            }
            if marker == 0xFF90 || marker == 0xFF93 || marker == 0xFFD9 {
                break
            }
            offset += 2
            // Standalone markers without length field: SOC (0xFF4F), SOD (0xFF93), EOC (0xFFD9), EPH (0xFF92), 0xFF30...0xFF3F
            let hasLength = marker != 0xFF4F && marker != 0xFF93 && marker != 0xFFD9
                && marker != 0xFF92 && !(marker >= 0xFF30 && marker <= 0xFF3F)
            if hasLength {
                guard offset + 1 < bytes.count else { break }
                let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                guard length >= 2 else { break }
                if marker == 0xFF52 && offset + 9 < bytes.count {
                    // COD marker: offset+2 is Scod, +3 is SGcod (4 bytes), +7 is SPcod (decomp, xcb, ycb, style)
                    let styleByte = bytes[offset + 2 + 1 + 4 + 3]
                    if (styleByte & 0x40) != 0 {
                        return true
                    }
                }
                let (nextOffset, overflow) = offset.addingReportingOverflow(length)
                if overflow { break }
                offset = nextOffset
            }
        }
        return false
    }

    /// Synchronously transcodes a JPEG 2000 codestream or container between legacy Part 1 and HTJ2K Part 15.
    public func transcode(
        _ data: Data,
        direction: TranscodingDirection,
        progress: (@Sendable (TranscodingProgressUpdate) -> Void)? = nil
    ) throws -> TranscodingResult {
        let startTime = DispatchTime.now()
        let rawBytes = [UInt8](data)
        guard rawBytes.count >= 2 else {
            throw J2KError.decodingError("Codestream data is too short to transcode (\(rawBytes.count) bytes)")
        }

        progress?(TranscodingProgressUpdate(
            stage: .parsing, progress: 0.0, overallProgress: 0.0, direction: direction
        ))

        let codestreamBytes: [UInt8]
        var reconciledContainer: JP2Container.ReconciledContainerProfile? = nil
        do {
            if JP2Container.isContainer(rawBytes) {
                let rec = try JP2Container.inspectReconciled(rawBytes, limits: .default, metadataPolicy: .preserve)
                reconciledContainer = rec
                codestreamBytes = rec.codestreamBytes
            } else {
                codestreamBytes = rawBytes
            }

            let part1Profile = try reconciledContainer?.part1Profile
                ?? Part1Pipeline.inspect(codestreamBytes, limits: .default, metadataPolicy: .preserve)
            progress?(TranscodingProgressUpdate(
                stage: .parsing, progress: 1.0, overallProgress: 0.2, direction: direction
            ))

            let targetIsHT = (direction == .legacyToHT)
            let codeBlockCount = max(1, part1Profile.codeBlockCount)
            let tileCount = max(1, part1Profile.tiles.count)

            progress?(TranscodingProgressUpdate(
                stage: .coefficientExtraction, progress: 0.5, overallProgress: 0.4, direction: direction
            ))
            progress?(TranscodingProgressUpdate(
                stage: .validation, progress: 1.0, overallProgress: 0.6, direction: direction
            ))

            let transcodedCodestream: [UInt8]
            if part1Profile.isHTJ2K == targetIsHT {
                // Already in the requested coding mode; re-emit valid codestream unchanged.
                transcodedCodestream = codestreamBytes
            } else if part1Profile.componentCount == 1 && !part1Profile.signed && part1Profile.isReversibleLossless,
                      let losslessProfile = try? ScalarLosslessCodec.inspect(
                          codestreamBytes, limits: .default, metadataPolicy: .preserve
                      ) {
                let firstCOD = losslessProfile.tiles[0].codingStyle
                let opts = try CodecOptions(
                    decompositionLevels: firstCOD.decompositionLevels,
                    codeBlockWidth: 1 << firstCOD.codeBlockWidthExponent,
                    codeBlockHeight: 1 << firstCOD.codeBlockHeightExponent,
                    blockCoding: targetIsHT ? .htj2k : .part1,
                    wavelet: .reversible53
                )
                let (outData, _) = try ScalarLosslessCodec.transcode(
                    bytes: codestreamBytes,
                    profile: losslessProfile,
                    to: targetIsHT ? .htj2k : .jpeg2000,
                    codecOptions: opts,
                    metadataPolicy: .preserve,
                    limits: .default,
                    backend: .scalarCPU,
                    progress: nil
                )
                transcodedCodestream = [UInt8](outData)
            } else {
                // Multi-component or general codestream: preserve raw codestream component layout
                // and decomposition geometry, then re-encode with the target Tier-1 block coder.
                let descriptor = try part1Profile.defaultDescriptor(limits: .default)
                let destination = try ImageDestination.allocate(descriptor: descriptor, limits: .default)
                let resolvedBackend = try AccelerationRuntime.resolve(.automatic)
                let (decodedImage, _) = try Part1Pipeline.decode(
                    bytes: codestreamBytes,
                    profile: part1Profile,
                    into: destination,
                    limits: .default,
                    backend: resolvedBackend.backend,
                    progress: nil
                )
                let firstTile = part1Profile.tiles[0]
                let firstCOD = firstTile.defaultCodingStyle
                let cbW = max(4, min(64, 1 << firstCOD.codeBlockWidthExponent))
                let cbH = max(4, min(64, 1 << firstCOD.codeBlockHeightExponent))
                let progOrder = CodecOptions.ProgressionOrder(rawValue: firstCOD.progression) ?? .lrcp
                let opts = try CodecOptions(
                    decompositionLevels: firstCOD.decompositionLevels,
                    codeBlockWidth: cbW,
                    codeBlockHeight: cbH,
                    blockCoding: targetIsHT ? .htj2k : .part1,
                    wavelet: .reversible53,
                    progressionOrder: progOrder,
                    qualityLayers: targetIsHT ? 1 : max(1, firstCOD.layers),
                    tileWidth: part1Profile.tileWidth,
                    tileHeight: part1Profile.tileHeight
                )
                let encConfig = try EncoderConfiguration(mode: .lossless, codecOptions: opts)
                let (encodedBytes, _) = try Part1Pipeline.encode(
                    image: decodedImage,
                    configuration: encConfig,
                    limits: .default,
                    backend: resolvedBackend.backend,
                    progress: nil
                )
                transcodedCodestream = encodedBytes
            }

            let transcodedData: Data
            if let rec = reconciledContainer {
                let wrapped = try JP2Container.rewrapPreservingHeader(
                    reconciled: rec,
                    codestream: transcodedCodestream,
                    targetIsHT: targetIsHT,
                    limits: .default
                )
                transcodedData = Data(wrapped)
            } else {
                transcodedData = Data(transcodedCodestream)
            }

            progress?(TranscodingProgressUpdate(
                stage: .reEncoding, progress: 1.0, overallProgress: 0.9, direction: direction
            ))
            progress?(TranscodingProgressUpdate(
                stage: .codestreamGeneration, progress: 1.0, overallProgress: 1.0, direction: direction
            ))

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000.0
            return TranscodingResult(
                data: transcodedData,
                direction: direction,
                codeBlocksTranscoded: codeBlockCount,
                tilesProcessed: tileCount,
                transcodingTime: elapsed,
                metadataPreserved: true
            )
        } catch let error as J2KError {
            throw error
        } catch let error as CodecError {
            throw J2KError(error)
        }
    }

    /// Asynchronously transcodes a JPEG 2000 codestream between legacy Part 1 and HTJ2K Part 15.
    public func transcodeAsync(
        _ data: Data,
        direction: TranscodingDirection,
        progress: (@Sendable (TranscodingProgressUpdate) -> Void)? = nil
    ) async throws -> TranscodingResult {
        try transcode(data, direction: direction, progress: progress)
    }
}
