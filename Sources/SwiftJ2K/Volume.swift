// SPDX-License-Identifier: Apache-2.0
//
// Volume.swift
// SwiftJ2K
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/J2KCore/J2KVolume.swift
//   - Sources/J2KCore/J2KVolumeMetadata.swift
//   - Sources/J2KCore/J2KError.swift (bridged to CodecError for JP3D & DICOMKit compatibility)
//
// Changes relative to the predecessor:
//   - Retained exact J2KVolume, J2KVolumeComponent, J2KVolumeMetadata, J2KVolumeModality,
//     and J2KError signatures and cases so predecessor JP3DTests and DICOMKit consumers
//     compile unchanged.
//   - Provided package-scoped Slice2DBridge so SwiftJ2K3D's slice-stack codec and
//     transcoder delegate directly to SwiftJ2K's Part 1 and Part 15 (HTJ2K) pipelines.

import Foundation

// MARK: - J2KError Bridge

/// Predecessor error type retained for JP3D and DICOMKit consumer compatibility,
/// with deterministic conversion to and from ``CodecError``.
public enum J2KError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidParameter(String)
    case invalidDimensions(String)
    case invalidBitDepth(String)
    case invalidComponentCount(String)
    case invalidComponentConfiguration(String)
    case invalidTileConfiguration(String)
    case invalidConfiguration(String)
    case invalidState(String)
    case invalidData(String)
    case encodingError(String)
    case decodingError(String)
    case ioError(String)
    case notImplemented(String)
    case internalError(String)
    case fileFormatError(String)
    case unsupportedFeature(String)

    public var description: String {
        switch self {
        case .invalidParameter(let msg): return "Invalid parameter: \(msg)"
        case .invalidDimensions(let msg): return "Invalid dimensions: \(msg)"
        case .invalidBitDepth(let msg): return "Invalid bit depth: \(msg)"
        case .invalidComponentCount(let msg): return "Invalid component count: \(msg)"
        case .invalidComponentConfiguration(let msg): return "Invalid component configuration: \(msg)"
        case .invalidTileConfiguration(let msg): return "Invalid tile configuration: \(msg)"
        case .invalidConfiguration(let msg): return "Invalid configuration: \(msg)"
        case .invalidState(let msg): return "Invalid state: \(msg)"
        case .invalidData(let msg): return "Invalid data: \(msg)"
        case .encodingError(let msg): return "Encoding error: \(msg)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .ioError(let msg): return "I/O error: \(msg)"
        case .notImplemented(let msg): return "Not implemented: \(msg)"
        case .internalError(let msg): return "Internal error: \(msg)"
        case .fileFormatError(let msg): return "File format error: \(msg)"
        case .unsupportedFeature(let msg): return "Unsupported feature: \(msg)"
        }
    }

    public var errorDescription: String? { description }

    /// Converts this ``J2KError`` into the common contract ``CodecError``.
    public var codecError: CodecError {
        switch self {
        case .invalidParameter(let msg),
             .invalidDimensions(let msg),
             .invalidBitDepth(let msg),
             .invalidComponentCount(let msg),
             .invalidComponentConfiguration(let msg),
             .invalidTileConfiguration(let msg),
             .invalidConfiguration(let msg),
             .invalidState(let msg):
            return CodecError(.invalidArgument, msg)
        case .encodingError(let msg),
             .internalError(let msg):
            return CodecError(.internalFailure, msg)
        case .decodingError(let msg),
             .fileFormatError(let msg),
             .invalidData(let msg):
            return CodecError(.malformedInput, msg)
        case .ioError(let msg):
            return CodecError(.ioFailure, msg)
        case .notImplemented(let msg),
             .unsupportedFeature(let msg):
            return CodecError(.unsupportedFeature, msg)
        }
    }

    /// Alias for ``codecError``.
    public var asCodecError: CodecError { codecError }

    /// Maps a ``CodecError`` to the corresponding ``J2KError``.
    public init(_ codecError: CodecError) {
        switch codecError.category {
        case .invalidArgument, .incompatibleImageLayout:
            self = .invalidParameter(codecError.message)
        case .malformedInput, .unsupportedFormat:
            self = .decodingError(codecError.message)
        case .unsupportedFeature, .backendUnavailable:
            self = .unsupportedFeature(codecError.message)
        case .resourceLimitExceeded, .storageUnavailable:
            self = .invalidParameter(codecError.message)
        case .ioFailure:
            self = .ioError(codecError.message)
        case .internalFailure:
            self = .internalError(codecError.message)
        }
    }
}

// MARK: - J2KVolume & J2KVolumeComponent

/// Represents a three-dimensional volumetric image for JP3D encoding/decoding.
///
/// A `J2KVolume` describes a 3D dataset with width, height, and depth dimensions,
/// along with component information and optional voxel spacing metadata. It supports
/// bit depths from 1 to 38 bits per sample, both signed and unsigned data, and
/// per-component subsampling.
public struct J2KVolume: Sendable, Equatable {
    /// The width of the volume in voxels (X-axis).
    public let width: Int

    /// The height of the volume in voxels (Y-axis).
    public let height: Int

    /// The depth of the volume in voxels (Z-axis / slices).
    public let depth: Int

    /// The volume components (channels).
    public let components: [J2KVolumeComponent]

    /// The voxel spacing along the X-axis in physical units (e.g., millimetres).
    /// A value of zero indicates unset/unknown spacing.
    public let spacingX: Double

    /// The voxel spacing along the Y-axis in physical units.
    /// A value of zero indicates unset/unknown spacing.
    public let spacingY: Double

    /// The voxel spacing along the Z-axis in physical units.
    /// A value of zero indicates unset/unknown spacing.
    public let spacingZ: Double

    /// The origin X coordinate in physical space.
    public let originX: Double

    /// The origin Y coordinate in physical space.
    public let originY: Double

    /// The origin Z coordinate in physical space.
    public let originZ: Double

    /// Creates a new volume with the specified parameters.
    public init(
        width: Int,
        height: Int,
        depth: Int,
        components: [J2KVolumeComponent],
        spacingX: Double = 0,
        spacingY: Double = 0,
        spacingZ: Double = 0,
        originX: Double = 0,
        originY: Double = 0,
        originZ: Double = 0
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.components = components
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.spacingZ = spacingZ
        self.originX = originX
        self.originY = originY
        self.originZ = originZ
    }

    /// Convenience initialiser for simple volumes.
    public init(
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        bitDepth: Int = 8,
        signed: Bool = false
    ) {
        let validWidth = max(1, width)
        let validHeight = max(1, height)
        let validDepth = max(1, depth)
        let validComponents = max(1, componentCount)
        let validBitDepth = max(1, min(38, bitDepth))

        let volumeComponents = (0..<validComponents).map { index in
            J2KVolumeComponent(
                index: index,
                bitDepth: validBitDepth,
                signed: signed,
                width: validWidth,
                height: validHeight,
                depth: validDepth
            )
        }

        self.init(
            width: validWidth,
            height: validHeight,
            depth: validDepth,
            components: volumeComponents
        )
    }

    /// Convenience initialiser that also populates component data.
    public init(
        width: Int,
        height: Int,
        depth: Int,
        componentCount: Int,
        bitDepth: Int,
        signed: Bool = false,
        data: Data
    ) {
        let validWidth = max(1, width)
        let validHeight = max(1, height)
        let validDepth = max(1, depth)
        let validComponents = max(1, componentCount)
        let validBitDepth = max(1, min(38, bitDepth))
        let bytesPerSample = (validBitDepth + 7) / 8
        let bytesPerComp = validWidth * validHeight * validDepth * bytesPerSample

        let volumeComponents = (0..<validComponents).map { index -> J2KVolumeComponent in
            let compData: Data
            if !data.isEmpty && data.count >= (index + 1) * bytesPerComp {
                compData = data.subdata(in: (index * bytesPerComp)..<((index + 1) * bytesPerComp))
            } else if !data.isEmpty && validComponents == 1 {
                compData = data
            } else {
                compData = Data(count: bytesPerComp)
            }
            return J2KVolumeComponent(
                index: index,
                bitDepth: validBitDepth,
                signed: signed,
                width: validWidth,
                height: validHeight,
                depth: validDepth,
                data: compData
            )
        }

        self.init(
            width: validWidth,
            height: validHeight,
            depth: validDepth,
            components: volumeComponents
        )
    }

    // MARK: - Convenience Properties

    /// The total number of voxels in the volume.
    public var voxelCount: Int {
        width * height * depth
    }

    /// The number of components in the volume.
    public var componentCount: Int {
        components.count
    }

    /// Returns true if the volume is a single slice (`depth == 1`), making it effectively 2D.
    public var isSingleSlice: Bool {
        depth == 1
    }

    /// Returns true if voxel spacing has been set for all axes.
    public var hasSpacing: Bool {
        spacingX > 0 && spacingY > 0 && spacingZ > 0
    }

    /// Whether the volume has equal dimensions (or equal spacing when set) along all three axes.
    public var isIsotropic: Bool {
        if hasSpacing {
            return abs(spacingX - spacingY) < 1e-6 && abs(spacingY - spacingZ) < 1e-6
        }
        return width == height && height == depth
    }

    /// Number of bytes per sample for the primary component.
    public var bytesPerSample: Int {
        guard let first = components.first else { return 0 }
        return first.bytesPerSample
    }

    /// The estimated memory size in bytes for the entire volume data across all components.
    public var estimatedMemorySize: Int {
        var total = 0
        for component in components {
            let bytesPerSample = (component.bitDepth + 7) / 8
            total += component.width * component.height * component.depth * bytesPerSample
        }
        return total
    }

    /// Checked total uncompressed size in bytes across all components.
    public var sizeInBytes: Int {
        get throws {
            var total = 0
            for component in components {
                let (wh, o1) = component.width.multipliedReportingOverflow(by: component.height)
                let (voxels, o2) = wh.multipliedReportingOverflow(by: component.depth)
                let bps = (component.bitDepth + 7) / 8
                let (compBytes, o3) = voxels.multipliedReportingOverflow(by: bps)
                let (nextTotal, o4) = total.addingReportingOverflow(compBytes)
                if o1 || o2 || o3 || o4 {
                    throw J2KError.invalidDimensions("Volume byte size overflows Int")
                }
                total = nextTotal
            }
            return total
        }
    }

    // MARK: - Validation

    /// Validates that the volume has valid dimensions, components, and metadata.
    public func validate() throws {
        guard width > 0 && height > 0 && depth > 0 else {
            throw J2KError.invalidDimensions(
                "Volume dimensions must be positive: \(width)×\(height)×\(depth)"
            )
        }

        guard !components.isEmpty else {
            throw J2KError.invalidComponentConfiguration(
                "Volume must have at least one component"
            )
        }

        for component in components {
            guard component.bitDepth >= 1 && component.bitDepth <= 38 else {
                throw J2KError.invalidBitDepth(
                    "Component \(component.index) has invalid bit depth: \(component.bitDepth)"
                )
            }
            guard component.width > 0 && component.height > 0 && component.depth > 0 else {
                throw J2KError.invalidDimensions(
                    "Component \(component.index) dimensions must be positive: "
                    + "\(component.width)×\(component.height)×\(component.depth)"
                )
            }
            guard component.subsamplingX > 0 && component.subsamplingY > 0
                && component.subsamplingZ > 0
            else {
                throw J2KError.invalidComponentConfiguration(
                    "Component \(component.index) subsampling factors must be positive"
                )
            }
        }

        if spacingX < 0 || spacingY < 0 || spacingZ < 0 {
            throw J2KError.invalidParameter(
                "Voxel spacing must be non-negative: (\(spacingX), \(spacingY), \(spacingZ))"
            )
        }

        let maxDimProduct = Int.max / max(1, components.count)
        let widthTimesHeight = width.multipliedReportingOverflow(by: height)
        if widthTimesHeight.overflow {
            throw J2KError.invalidDimensions(
                "Volume dimensions cause integer overflow: \(width)×\(height)×\(depth)"
            )
        }
        let totalVoxels = widthTimesHeight.partialValue.multipliedReportingOverflow(by: depth)
        if totalVoxels.overflow || totalVoxels.partialValue > maxDimProduct {
            throw J2KError.invalidDimensions(
                "Volume size exceeds maximum: \(width)×\(height)×\(depth)×\(components.count)"
            )
        }
    }
}

/// Represents a single component (channel) of a volumetric image.
public struct J2KVolumeComponent: Sendable, Equatable {
    /// The index of this component (0-based).
    public let index: Int

    /// The bit depth of this component (1-38 bits).
    public let bitDepth: Int

    /// Whether this component uses signed values.
    public let signed: Bool

    /// The width of this component in voxels.
    public let width: Int

    /// The height of this component in voxels.
    public let height: Int

    /// The depth of this component in voxels.
    public let depth: Int

    /// The horizontal subsampling factor relative to the reference grid.
    public let subsamplingX: Int

    /// The vertical subsampling factor relative to the reference grid.
    public let subsamplingY: Int

    /// The depth subsampling factor relative to the reference grid.
    public let subsamplingZ: Int

    /// The voxel data for this component.
    public var data: Data

    /// Creates a new volume component with the specified parameters.
    public init(
        index: Int,
        bitDepth: Int,
        signed: Bool,
        width: Int,
        height: Int,
        depth: Int,
        subsamplingX: Int = 1,
        subsamplingY: Int = 1,
        subsamplingZ: Int = 1,
        data: Data = Data()
    ) {
        self.index = index
        self.bitDepth = bitDepth
        self.signed = signed
        self.width = width
        self.height = height
        self.depth = depth
        self.subsamplingX = subsamplingX
        self.subsamplingY = subsamplingY
        self.subsamplingZ = subsamplingZ
        self.data = data
    }

    // MARK: - Convenience Properties

    /// The total number of voxels in this component.
    public var voxelCount: Int {
        width * height * depth
    }

    /// Returns true if this component is subsampled in any axis.
    public var isSubsampled: Bool {
        subsamplingX > 1 || subsamplingY > 1 || subsamplingZ > 1
    }

    /// The maximum representable value for this component's bit depth.
    public var maxValue: Int {
        if signed {
            return (1 << (bitDepth - 1)) - 1
        }
        return (1 << bitDepth) - 1
    }

    /// The minimum representable value for this component's bit depth.
    public var minValue: Int {
        if signed {
            return -(1 << (bitDepth - 1))
        }
        return 0
    }

    /// The number of bytes per sample for this component.
    public var bytesPerSample: Int {
        (bitDepth + 7) / 8
    }
}

// MARK: - J2KVolumeMetadata & J2KVolumeModality

/// Metadata describing a volumetric dataset.
public struct J2KVolumeMetadata: Sendable, Equatable {
    /// The imaging modality used to acquire the volume.
    public let modality: J2KVolumeModality

    /// The patient identifier (anonymised or pseudonymised).
    public let patientID: String?

    /// A description of the study.
    public let studyDescription: String?

    /// A description of the series within the study.
    public let seriesDescription: String?

    /// The institution where the volume was acquired.
    public let institution: String?

    /// The date and time of acquisition.
    public let acquisitionDate: Date?

    /// The slice thickness in physical units (e.g., millimetres).
    public let sliceThickness: Double?

    /// Window centre for display (Hounsfield units for CT).
    public let windowCenter: Double?

    /// Window width for display.
    public let windowWidth: Double?

    /// The number of bits allocated per sample in the source data.
    public let bitsAllocated: Int?

    /// The number of bits stored per sample in the source data.
    public let bitsStored: Int?

    /// The high bit position.
    public let highBit: Int?

    /// Custom key-value metadata.
    public let customMetadata: [String: String]

    /// Creates volume metadata with the specified parameters.
    public init(
        modality: J2KVolumeModality = .unknown,
        patientID: String? = nil,
        studyDescription: String? = nil,
        seriesDescription: String? = nil,
        institution: String? = nil,
        acquisitionDate: Date? = nil,
        sliceThickness: Double? = nil,
        windowCenter: Double? = nil,
        windowWidth: Double? = nil,
        bitsAllocated: Int? = nil,
        bitsStored: Int? = nil,
        highBit: Int? = nil,
        customMetadata: [String: String] = [:]
    ) {
        self.modality = modality
        self.patientID = patientID
        self.studyDescription = studyDescription
        self.seriesDescription = seriesDescription
        self.institution = institution
        self.acquisitionDate = acquisitionDate
        self.sliceThickness = sliceThickness
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.customMetadata = customMetadata
    }

    /// An empty metadata instance with no fields set.
    public static var empty: J2KVolumeMetadata {
        J2KVolumeMetadata()
    }
}

/// Imaging modality for volumetric data acquisition.
public enum J2KVolumeModality: String, Sendable, Equatable, CaseIterable {
    /// Computed Tomography.
    case ct = "CT"

    /// Magnetic Resonance Imaging.
    case mri = "MR"

    /// Positron Emission Tomography.
    case pet = "PT"

    /// Ultrasound.
    case ultrasound = "US"

    /// X-Ray Angiography.
    case xrayAngiography = "XA"

    /// Nuclear Medicine.
    case nuclearMedicine = "NM"

    /// Microscopy.
    case microscopy = "SM"

    /// Optical Coherence Tomography.
    case oct = "OCT"

    /// Scientific visualisation / generic 3D data.
    case scientific = "SC"

    /// Geospatial raster data.
    case geospatial = "GEO"

    /// Unknown or unspecified modality.
    case unknown = "OT"
}

// MARK: - Package 2D Slice Bridge for SwiftJ2K3D

package enum Slice2DBridge {
    /// Encodes a single-component 2D slice of `width * height` samples into a Part 1 or HTJ2K codestream.
    package static func encodeSlice(
        samples: [Int32],
        width: Int,
        height: Int,
        bitDepth: Int,
        signed: Bool,
        levels: Int,
        qualityLayers: Int,
        useHTJ2K: Bool,
        lossless: Bool,
        quality: Double?,
        targetBitsPerPixel: Double?,
        useReversibleWavelet: Bool,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> Data {
        let clampedBitDepth = max(1, min(16, bitDepth))
        let sampleType: SampleType = signed ? .signedInteger : .unsignedInteger
        let storageBits = clampedBitDepth <= 8 ? 8 : 16
        let bytesPerSample = storageBits / 8
        let rowBytes = width * bytesPerSample
        let plane = try PlaneDescriptor(
            width: width,
            height: height,
            components: [0],
            offset: 0,
            sampleStride: bytesPerSample,
            pixelStride: bytesPerSample,
            rowBytes: rowBytes,
            byteCount: height * rowBytes
        )
        let descriptor = try ImageDescriptor(
            width: width,
            height: height,
            sampleType: sampleType,
            storageBits: storageBits,
            meaningfulBits: clampedBitDepth,
            components: [.grey],
            planes: [plane],
            limits: limits
        )
        let minVal = signed ? -(1 << (clampedBitDepth - 1)) : 0
        let maxVal = signed ? ((1 << (clampedBitDepth - 1)) - 1) : ((1 << clampedBitDepth) - 1)

        var rawBytes = [UInt8](repeating: 0, count: width * height * bytesPerSample)
        if storageBits == 8 {
            if signed {
                for i in 0..<(width * height) {
                    let v = Int8(clamping: max(minVal, min(maxVal, Int(samples[i]))))
                    rawBytes[i] = UInt8(bitPattern: v)
                }
            } else {
                for i in 0..<(width * height) {
                    let v = max(0, min(maxVal, Int(samples[i])))
                    rawBytes[i] = UInt8(truncatingIfNeeded: v)
                }
            }
        } else {
            if signed {
                for i in 0..<(width * height) {
                    let v = Int16(clamping: max(minVal, min(maxVal, Int(samples[i]))))
                    let u = UInt16(bitPattern: v)
                    rawBytes[i * 2] = UInt8(truncatingIfNeeded: u & 0xFF)
                    rawBytes[i * 2 + 1] = UInt8(truncatingIfNeeded: u >> 8)
                }
            } else {
                for i in 0..<(width * height) {
                    let v = UInt16(clamping: max(0, min(maxVal, Int(samples[i]))))
                    rawBytes[i * 2] = UInt8(truncatingIfNeeded: v & 0xFF)
                    rawBytes[i * 2 + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
            }
        }

        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
        let image = try destination.write { dst in
            rawBytes.withUnsafeBytes { src in
                dst.copyMemory(from: src)
            }
        }
        let maxAllowedLevels = max(0, min(levels, Int(floor(log2(Double(max(1, min(width, height))))))))

        let mode: CompressionMode = (lossless || useHTJ2K) ? .lossless : .lossy
        let wavelet: CodecOptions.WaveletTransform
        if mode == .lossless {
            wavelet = .reversible53
        } else {
            wavelet = useReversibleWavelet ? .reversible53 : .irreversible97
        }
        let effectiveLayers = useHTJ2K ? 1 : max(1, min(255, qualityLayers))
        let codecOptions = try CodecOptions(
            decompositionLevels: maxAllowedLevels,
            blockCoding: useHTJ2K ? .htj2k : .part1,
            wavelet: wavelet,
            quality: mode == .lossy ? quality : nil,
            targetBitsPerPixel: mode == .lossy ? targetBitsPerPixel : nil,
            qualityLayers: effectiveLayers
        )
        let config = try EncoderConfiguration(mode: mode, codecOptions: codecOptions)
        let resolvedBackend = try AccelerationRuntime.resolve(executionPolicy)
        let (encodedBytes, _) = try Part1Pipeline.encode(
            image: image,
            configuration: config,
            limits: limits,
            backend: resolvedBackend.backend,
            progress: nil
        )
        return Data(encodedBytes)
    }

    /// Decodes a single-component 2D slice codestream back into `[Int32]` samples.
    package static func decodeSlice(
        data: Data,
        maxQualityLayers: Int? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> (samples: [Int32], width: Int, height: Int, bitDepth: Int, signed: Bool) {
        let bytes = [UInt8](data)
        let resolvedBackend = try AccelerationRuntime.resolve(executionPolicy)
        let profile = try Part1Pipeline.inspect(bytes, limits: limits, metadataPolicy: .preserve)
        let descriptor = try profile.defaultDescriptor(limits: limits)
        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
        let (image, _) = try Part1Pipeline.decode(
            bytes: bytes,
            profile: profile,
            into: destination,
            limits: limits,
            backend: resolvedBackend.backend,
            progress: nil,
            maxQualityLayers: maxQualityLayers
        )
        let w = profile.width
        let h = profile.height
        let count = w * h
        var out = [Int32](repeating: 0, count: count)
        try image.storage.withUnsafeBytes { raw in
            if descriptor.storageBits == 8 {
                if profile.signed {
                    for i in 0..<count {
                        out[i] = Int32(Int8(bitPattern: raw[i]))
                    }
                } else {
                    for i in 0..<count {
                        out[i] = Int32(raw[i])
                    }
                }
            } else {
                if profile.signed {
                    for i in 0..<count {
                        let lo = UInt16(raw[i * 2])
                        let hi = UInt16(raw[i * 2 + 1]) << 8
                        out[i] = Int32(Int16(bitPattern: lo | hi))
                    }
                } else {
                    for i in 0..<count {
                        let lo = UInt16(raw[i * 2])
                        let hi = UInt16(raw[i * 2 + 1]) << 8
                        out[i] = Int32(lo | hi)
                    }
                }
            }
        }
        return (out, w, h, profile.precision, profile.signed)
    }
}
