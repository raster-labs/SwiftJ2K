// SPDX-License-Identifier: Apache-2.0
import Foundation

/// JPEG 2000 controls with explicit names and units (API-04).
public struct CodecOptions: Sendable, Equatable {
    /// Block-coding mode: Part 1 EBCOT (`.part1`, default) or Part 15 FBCOT (`.htj2k`).
    public enum BlockCoding: String, Sendable, Equatable, CaseIterable {
        case part1
        case htj2k
    }

    /// Number of 5/3 wavelet decomposition levels, 0...32. `nil` selects
    /// `min(5, floor(log2(min(width, height))))`, the largest count the common
    /// reference encoders accept for the image.
    public let decompositionLevels: Int?
    /// Code-block dimensions in samples: powers of two from 4 to 1024 whose
    /// product does not exceed 4096 (ISO/IEC 15444-1 Table A.18).
    public let codeBlockWidth: Int
    public let codeBlockHeight: Int
    /// Block-coding mode selected for encoding.
    public let blockCoding: BlockCoding

    public init() {
        decompositionLevels = nil; codeBlockWidth = 64; codeBlockHeight = 64; blockCoding = .part1
    }

    public init(
        decompositionLevels: Int? = nil,
        codeBlockWidth: Int = 64,
        codeBlockHeight: Int = 64,
        blockCoding: BlockCoding = .part1
    ) throws {
        if let levels = decompositionLevels {
            guard levels >= 0, levels <= 32 else {
                throw CodecError(.invalidArgument, "Decomposition levels must lie in 0...32.")
            }
        }
        for size in [codeBlockWidth, codeBlockHeight] {
            guard size >= 4, size <= 1024, size & (size - 1) == 0 else {
                throw CodecError(.invalidArgument, "Code-block dimensions must be powers of two from 4 to 1024.")
            }
        }
        guard codeBlockWidth * codeBlockHeight <= 4096 else {
            throw CodecError(.invalidArgument, "Code-block area must not exceed 4096 samples.")
        }
        self.decompositionLevels = decompositionLevels
        self.codeBlockWidth = codeBlockWidth
        self.codeBlockHeight = codeBlockHeight
        self.blockCoding = blockCoding
    }
}

public struct EncoderConfiguration: Sendable, Equatable {
    public let mode: CompressionMode
    public let codecOptions: CodecOptions
    public init(mode: CompressionMode = .lossless, codecOptions: CodecOptions = .init()) throws {
        if case .nearLossless(let bound) = mode, bound <= 0 {
            throw CodecError(.invalidArgument, "Near-lossless error must be positive.")
        }
        guard mode == .lossless else {
            throw CodecError(.unsupportedFeature, "Only lossless encoding is implemented; lossy and near-lossless modes are not available.")
        }
        self.mode = mode; self.codecOptions = codecOptions
    }
    private init() { mode = .lossless; codecOptions = .init() }
    public static let `default` = Self()
}
public struct DecoderConfiguration: Sendable, Equatable {
    public let codecOptions: CodecOptions
    public init(codecOptions: CodecOptions = .init()) { self.codecOptions = codecOptions }
}

public struct CodecCapabilities: Sendable, Equatable {
    public let formats: [String]
    public let compressionModes: [CompressionMode]
    public let sampleTypes: [SampleType]
    public let meaningfulPrecision: ClosedRange<Int>?
    public let layouts: [String]
    public let availableBackends: [Backend]
    public let canInspect: Bool
    public let canEncode: Bool
    public let canDecode: Bool
    public static let contractOnly = Self(formats: [], compressionModes: [], sampleTypes: [],
        meaningfulPrecision: nil, layouts: [], availableBackends: [],
        canInspect: false, canEncode: false, canDecode: false)

    /// The shared layout every operation accepts: MEM-03 with 16-bit storage.
    public static let sharedGreyscaleLayout = "unsigned-greyscale-16bit-single-plane"
}

public struct CopyEvent: Sendable, Equatable {
    public let reason: String
    public let bytesMoved: Int
    public let sourceLayout: String
    public let destinationLayout: String
    public init(reason: String, bytesMoved: Int, sourceLayout: String, destinationLayout: String) throws {
        guard bytesMoved >= 0 else { throw CodecError(.invalidArgument, "Copy byte count must not be negative.") }
        self.reason = reason; self.bytesMoved = bytesMoved
        self.sourceLayout = sourceLayout; self.destinationLayout = destinationLayout
    }
}
public enum Fidelity: Sendable, Equatable { case exactSamples, boundedError(Int), lossy, originalBitstream }
public struct OperationReport: Sendable, Equatable {
    public let backend: Backend
    public let fallbackReason: String?
    public let fidelity: Fidelity
    public let copyEvents: [CopyEvent]
    public let pixelAllocationCount: Int?
    public let peakPixelBytes: Int?
    public let peakWorkspaceBytes: Int?
    public let elapsedSeconds: Double?
    public let discardedMetadataCount: Int?
    public let discardedMetadataBytes: Int?
    public let discardedMetadataKinds: [String]
    public init(backend: Backend, fallbackReason: String? = nil, fidelity: Fidelity,
                copyEvents: [CopyEvent] = [], pixelAllocationCount: Int? = nil,
                peakPixelBytes: Int? = nil, peakWorkspaceBytes: Int? = nil, elapsedSeconds: Double? = nil,
                discardedMetadataCount: Int? = nil, discardedMetadataBytes: Int? = nil,
                discardedMetadataKinds: [String] = []) {
        self.backend = backend; self.fallbackReason = fallbackReason; self.fidelity = fidelity
        self.copyEvents = copyEvents; self.pixelAllocationCount = pixelAllocationCount
        self.peakPixelBytes = peakPixelBytes; self.peakWorkspaceBytes = peakWorkspaceBytes
        self.elapsedSeconds = elapsedSeconds
        self.discardedMetadataCount = discardedMetadataCount
        self.discardedMetadataBytes = discardedMetadataBytes
        self.discardedMetadataKinds = discardedMetadataKinds
    }
}
public struct ImageInfo: Sendable {
    public let format: String
    public let descriptor: ImageDescriptor
    public let frameCount: Int
    public let metadata: ImageMetadata
}
public struct EncodingDescription: Sendable, Equatable {
    public let format: String
    public let mode: CompressionMode
}
public struct EncodedImage: Sendable {
    public let data: Data
    public let encoding: EncodingDescription
    public let report: OperationReport
}
public struct DecodedImage: Sendable {
    public let image: Image
    public let report: OperationReport
}

/// Scalar lossless JPEG 2000 Part 1 and Part 15 (HTJ2K) encoder for the shared greyscale profile.
public struct Encoder: Sendable {
    public let configuration: EncoderConfiguration
    public static let capabilities = CodecCapabilities(
        formats: [ScalarLosslessCodec.format, ScalarLosslessCodec.htj2kFormat], compressionModes: [.lossless],
        sampleTypes: [.unsignedInteger], meaningfulPrecision: 1...16,
        layouts: [CodecCapabilities.sharedGreyscaleLayout], availableBackends: [.scalarCPU],
        canInspect: false, canEncode: true, canDecode: false)
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: EncoderConfiguration = .default) throws { self.configuration = configuration }

    /// `@concurrent` explicitly selects the generic executor (available since Swift 6.2).
    /// The image's storage is borrowed only inside synchronous work (MEM-08).
    @concurrent public func encode(_ image: Image, options: EncodeOptions = .init()) async throws -> EncodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        try Task.checkCancellation()
        try validateOperation(options.resourceLimits, options.executionPolicy)
        guard image.storage.byteCount <= options.resourceLimits.maximumDecodedBytes,
              image.storage.byteCount <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image exceeds operation limits.")
        }
        let descriptor = image.descriptor
        let smallest = min(descriptor.width, descriptor.height)
        let deepest = Int.bitWidth - 1 - smallest.leadingZeroBitCount   // floor(log2(smallest))
        let levels: Int
        if let requested = configuration.codecOptions.decompositionLevels {
            guard requested <= deepest else {
                throw CodecError(.invalidArgument, "Decomposition levels exceed floor(log2(min(width, height))) = \(deepest) for this image.")
            }
            levels = requested
        } else {
            levels = min(5, deepest)
        }
        let parameters = ScalarLosslessCodec.EncodeParameters(
            decompositionLevels: levels,
            codeBlockWidthExponent: configuration.codecOptions.codeBlockWidth.trailingZeroBitCount,
            codeBlockHeightExponent: configuration.codecOptions.codeBlockHeight.trailingZeroBitCount,
            blockCoding: configuration.codecOptions.blockCoding)
        options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
        let (bytes, workspace) = try ScalarLosslessCodec.encode(image: image, parameters: parameters,
                                                                limits: options.resourceLimits, progress: options.progress)
        guard bytes.count <= options.resourceLimits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Encoded output exceeds the compressed-size limit.")
        }
        try Task.checkCancellation()
        let elapsed = clock.now - started
        let report = OperationReport(backend: .scalarCPU, fidelity: .exactSamples, copyEvents: [],
                                     pixelAllocationCount: 0, peakPixelBytes: image.storage.byteCount,
                                     peakWorkspaceBytes: workspace,
                                     elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
        let outputFormat = configuration.codecOptions.blockCoding == .htj2k
            ? ScalarLosslessCodec.htj2kFormat
            : ScalarLosslessCodec.format
        return EncodedImage(data: Data(bytes), encoding: EncodingDescription(format: outputFormat, mode: .lossless),
                            report: report)
    }
}

/// Scalar lossless JPEG 2000 Part 1 and Part 15 (HTJ2K) decoder for the shared greyscale profile.
public struct Decoder: Sendable {
    public let configuration: DecoderConfiguration
    public static let capabilities = CodecCapabilities(
        formats: [ScalarLosslessCodec.format, ScalarLosslessCodec.htj2kFormat], compressionModes: [.lossless],
        sampleTypes: [.unsignedInteger], meaningfulPrecision: 1...16,
        layouts: [CodecCapabilities.sharedGreyscaleLayout], availableBackends: [.scalarCPU],
        canInspect: true, canEncode: false, canDecode: true)
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: DecoderConfiguration = .init()) throws { self.configuration = configuration }

    /// Bounded structural inspection: parses the main and tile-part headers only.
    public func inspect(_ data: Data, options: DecodeOptions = .init()) throws -> ImageInfo {
        try validateInput(data, options)
        let profile = try ScalarLosslessCodec.inspect([UInt8](data), limits: options.resourceLimits,
                                                      metadataPolicy: options.metadataPolicy)
        let descriptor = try ImageDescriptor.greyscale16(width: profile.width, height: profile.height,
                                                         meaningfulBits: profile.precision,
                                                         limits: options.resourceLimits)
        return ImageInfo(format: profile.format, descriptor: descriptor, frameCount: 1, metadata: .empty)
    }

    /// Allocates one final destination and decodes through the same path as
    /// caller-supplied storage (MEM-10).
    @concurrent public func decode(_ data: Data, options: DecodeOptions = .init()) async throws -> DecodedImage {
        try Task.checkCancellation()
        try validateInput(data, options)
        let bytes = [UInt8](data)
        let profile = try ScalarLosslessCodec.inspect(bytes, limits: options.resourceLimits,
                                                      metadataPolicy: options.metadataPolicy)
        let descriptor = try ImageDescriptor.greyscale16(width: profile.width, height: profile.height,
                                                         meaningfulBits: profile.precision,
                                                         limits: options.resourceLimits)
        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: options.resourceLimits)
        return try run(bytes: bytes, profile: profile, into: destination, options: options, allocations: 1)
    }

    /// Decodes final samples directly into `destination`. Preflight failures
    /// leave the destination reusable; failures after writing starts invalidate it.
    @concurrent public func decode(_ data: Data, into destination: ImageDestination,
                                  options: DecodeOptions = .init()) async throws -> DecodedImage {
        try Task.checkCancellation()
        try validateInput(data, options)
        let bytes = [UInt8](data)
        let profile = try ScalarLosslessCodec.inspect(bytes, limits: options.resourceLimits,
                                                      metadataPolicy: options.metadataPolicy)
        return try run(bytes: bytes, profile: profile, into: destination, options: options, allocations: 0)
    }

    private func run(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                     options: DecodeOptions, allocations: Int) throws -> DecodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
        let (image, workspace) = try ScalarLosslessCodec.decode(bytes: bytes, profile: profile, into: destination,
                                                                limits: options.resourceLimits, progress: options.progress)
        try Task.checkCancellation()
        let elapsed = clock.now - started
        let discardedCount = (options.metadataPolicy == .discardAncillary) ? profile.commentCount : 0
        let discardedBytes = (options.metadataPolicy == .discardAncillary) ? profile.commentPayloadBytes : 0
        let discardedKinds = (discardedCount > 0) ? ["COM"] : []
        let report = OperationReport(backend: .scalarCPU, fidelity: .exactSamples, copyEvents: [],
                                     pixelAllocationCount: allocations, peakPixelBytes: image.storage.byteCount,
                                     peakWorkspaceBytes: workspace,
                                     elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                                     discardedMetadataCount: discardedCount,
                                     discardedMetadataBytes: discardedBytes,
                                     discardedMetadataKinds: discardedKinds)
        options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
        return DecodedImage(image: image, report: report)
    }
}

private func validateOperation(_ limits: ResourceLimits, _ policy: ExecutionPolicy) throws {
    if case .required(.accelerated) = policy {
        throw CodecError(.backendUnavailable, "No accelerated backend is implemented.")
    }
}
private func validateInput(_ data: Data, _ options: DecodeOptions) throws {
    try validateOperation(options.resourceLimits, options.executionPolicy)
    guard data.count <= options.resourceLimits.maximumCompressedBytes,
          data.count <= options.resourceLimits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "Compressed input exceeds operation limits.")
    }
}
