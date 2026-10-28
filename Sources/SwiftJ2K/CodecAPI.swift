// SPDX-License-Identifier: Apache-2.0
import Foundation

/// JPEG 2000 controls with explicit names and units (API-04).
public struct CodecOptions: Sendable, Equatable {
    /// Block-coding mode: Part 1 EBCOT (`.part1`, default) or Part 15 FBCOT (`.htj2k`).
    public enum BlockCoding: String, Sendable, Equatable, CaseIterable {
        case part1
        case htj2k
    }

    /// Wavelet transform filter selection (ISO/IEC 15444-1 Annex F).
    public enum WaveletTransform: String, Sendable, Equatable, CaseIterable {
        case automatic
        case reversible53
        case irreversible97
    }

    /// Multi-component colour transform selection (ISO/IEC 15444-1 Annex G).
    public enum ColourTransform: String, Sendable, Equatable, CaseIterable {
        case automatic
        case none
        case rct
        case ict
    }

    /// Packet progression order (ISO/IEC 15444-1 Table A.16).
    public enum ProgressionOrder: UInt8, Sendable, Equatable, CaseIterable {
        case lrcp = 0
        case rlcp = 1
        case rpcl = 2
        case pcrl = 3
        case cprl = 4
    }

    /// Quantisation style signalled in `QCD`/`QCC` (ISO/IEC 15444-1 Table A.28).
    public enum QuantizationStyle: String, Sendable, Equatable, CaseIterable {
        case automatic
        case none
        case scalarDerived
        case scalarExpounded
    }

    /// Output container format (raw codestream or ISO/IEC 15444-1/2/15 box container).
    public enum ContainerFormat: String, Sendable, Equatable, CaseIterable {
        case codestream
        case jp2
        case jph
        case jpx
    }

    /// Explicit precinct dimensions in power-of-two subband samples (`1...32768`).
    public struct PrecinctSize: Sendable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) throws {
            for s in [width, height] {
                guard s >= 1, s <= 32768, s & (s - 1) == 0 else {
                    throw CodecError(.invalidArgument, "Precinct dimensions must be powers of two from 1 to 32768.")
                }
            }
            self.width = width
            self.height = height
        }
    }

    /// Progression order change volume (`POC` marker segment `0xFF5F`, ISO/IEC 15444-1 Clause A.6.6).
    public struct ProgressionOrderChange: Sendable, Equatable {
        public let startResolution: Int
        public let startComponent: Int
        public let endLayer: Int
        public let endResolution: Int
        public let endComponent: Int
        public let progressionOrder: ProgressionOrder

        public init(
            startResolution: Int,
            startComponent: Int,
            endLayer: Int,
            endResolution: Int,
            endComponent: Int,
            progressionOrder: ProgressionOrder
        ) throws {
            guard startResolution >= 0, endResolution > startResolution, endResolution <= 33 else {
                throw CodecError(.invalidArgument, "POC resolution range must satisfy 0 <= startResolution < endResolution <= 33.")
            }
            guard startComponent >= 0, endComponent > startComponent, endComponent <= 16384 else {
                throw CodecError(.invalidArgument, "POC component range must satisfy 0 <= startComponent < endComponent <= 16384.")
            }
            guard endLayer >= 1, endLayer <= 65535 else {
                throw CodecError(.invalidArgument, "POC endLayer must lie in 1...65535.")
            }
            self.startResolution = startResolution
            self.startComponent = startComponent
            self.endLayer = endLayer
            self.endResolution = endResolution
            self.endComponent = endComponent
            self.progressionOrder = progressionOrder
        }
    }

    /// Rectangular Region of Interest (`RGN` marker segment `0xFF5E`, MaxShift `Srgn = 0`, ISO/IEC 15444-1 Annex H.1).
    public struct RegionOfInterest: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        /// Optional explicit MaxShift scaling factor; when `nil`, automatically computed as `max_b(M_b)`.
        public let shift: Int?

        public init(x: Int, y: Int, width: Int, height: Int, shift: Int? = nil) throws {
            guard x >= 0, y >= 0, width > 0, height > 0 else {
                throw CodecError(.invalidArgument, "Region of interest must have non-negative origin and positive dimensions.")
            }
            if let s = shift {
                guard s >= 1 && s <= 37 else {
                    throw CodecError(.invalidArgument, "Region of interest MaxShift must lie in 1...37.")
                }
            }
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.shift = shift
        }
    }

    /// Number of wavelet decomposition levels, 0...32. `nil` selects
    /// `min(5, floor(log2(min(width, height))))`, the largest count the common
    /// reference encoders accept for the image.
    public let decompositionLevels: Int?
    /// Code-block dimensions in samples: powers of two from 4 to 1024 whose
    /// product does not exceed 4096 (ISO/IEC 15444-1 Table A.18).
    public let codeBlockWidth: Int
    public let codeBlockHeight: Int
    /// Block-coding mode selected for encoding.
    public let blockCoding: BlockCoding
    /// Wavelet filter selection (`.automatic`, `.reversible53`, `.irreversible97`).
    public let wavelet: WaveletTransform
    /// Multi-component colour transform selection (`.automatic`, `.none`, `.rct`, `.ict`).
    public let colourTransform: ColourTransform
    /// Packet progression order (`.lrcp`, `.rlcp`, `.rpcl`, `.pcrl`, `.cprl`).
    public let progressionOrder: ProgressionOrder
    /// Optional progression order changes (`POC` marker segments).
    public let progressionChanges: [ProgressionOrderChange]
    /// Normalized lossy quality factor in `0.0...1.0`.
    public let quality: Double?
    /// Target compressed bitrate in bits per pixel (`> 0`).
    public let targetBitsPerPixel: Double?
    /// Number of quality layers (`1...255`).
    public let qualityLayers: Int
    /// Cumulative target bitrates (in bits per pixel, strictly positive and ascending) per quality layer.
    public let layerBitrates: [Double]
    /// Quantisation style for `QCD`/`QCC`.
    public let quantizationStyle: QuantizationStyle
    /// Guard bits in `QCD`/`QCC` (`1...7`, default `2`).
    public let guardBits: Int
    /// Optional explicit base quantisation step size in sample units (`> 0`).
    public let baseStepSize: Double?
    /// Optional explicit tile width and height in reference grid samples (`>= 1`).
    public let tileWidth: Int?
    public let tileHeight: Int?
    /// Optional explicit precinct sizes per resolution level (from `r = 0` upwards).
    public let precinctSizes: [PrecinctSize]
    /// Part 1 code-block style bits (`0x01` bypass, `0x02` reset, `0x04` terminateAll,
    /// `0x08` causal, `0x10` predictable, `0x20` segmentationSymbols).
    public let codeBlockStyleBits: UInt8
    /// Emit `SOP` (`0xFF91`) start-of-packet markers.
    public let usesSOP: Bool
    /// Emit `EPH` (`0xFF92`) end-of-packet-header markers.
    public let usesEPH: Bool
    /// Optional rectangular Region of Interest encoded via MaxShift (`RGN` `0xFF5E`).
    public let regionOfInterest: RegionOfInterest?
    /// Output container format (`.codestream` default, `.jp2`, `.jph`, or `.jpx`).
    public let containerFormat: ContainerFormat
    /// Optional capture grid resolution (`'resc'` box inside `'res '`, ISO/IEC 15444-1 I.5.3.7.1).
    public let captureResolution: JP2GridResolution?
    /// Optional default display grid resolution (`'resd'` box inside `'res '`, ISO/IEC 15444-1 I.5.3.7.2).
    public let displayResolution: JP2GridResolution?

    public init() {
        decompositionLevels = nil
        codeBlockWidth = 64
        codeBlockHeight = 64
        blockCoding = .part1
        wavelet = .automatic
        colourTransform = .automatic
        progressionOrder = .lrcp
        progressionChanges = []
        quality = nil
        targetBitsPerPixel = nil
        qualityLayers = 1
        layerBitrates = []
        quantizationStyle = .automatic
        guardBits = 2
        baseStepSize = nil
        tileWidth = nil
        tileHeight = nil
        precinctSizes = []
        codeBlockStyleBits = 0
        usesSOP = false
        usesEPH = false
        regionOfInterest = nil
        containerFormat = .codestream
        captureResolution = nil
        displayResolution = nil
    }

    public init(
        decompositionLevels: Int? = nil,
        codeBlockWidth: Int = 64,
        codeBlockHeight: Int = 64,
        blockCoding: BlockCoding = .part1,
        wavelet: WaveletTransform = .automatic,
        colourTransform: ColourTransform = .automatic,
        progressionOrder: ProgressionOrder = .lrcp,
        progressionChanges: [ProgressionOrderChange] = [],
        quality: Double? = nil,
        targetBitsPerPixel: Double? = nil,
        qualityLayers: Int = 1,
        layerBitrates: [Double] = [],
        quantizationStyle: QuantizationStyle = .automatic,
        guardBits: Int = 2,
        baseStepSize: Double? = nil,
        tileWidth: Int? = nil,
        tileHeight: Int? = nil,
        precinctSizes: [PrecinctSize] = [],
        codeBlockStyleBits: UInt8 = 0,
        usesSOP: Bool = false,
        usesEPH: Bool = false,
        regionOfInterest: RegionOfInterest? = nil,
        containerFormat: ContainerFormat = .codestream,
        captureResolution: JP2GridResolution? = nil,
        displayResolution: JP2GridResolution? = nil
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
        if let q = quality {
            guard q.isFinite, q >= 0.0, q <= 1.0 else {
                throw CodecError(.invalidArgument, "Quality must lie in 0.0...1.0.")
            }
        }
        if let bpp = targetBitsPerPixel {
            guard bpp.isFinite, bpp > 0.0 else {
                throw CodecError(.invalidArgument, "Target bits per pixel must be finite and positive.")
            }
        }
        guard qualityLayers >= 1 && qualityLayers <= 255 else {
            throw CodecError(.invalidArgument, "Quality layer count must lie in 1...255.")
        }
        if !layerBitrates.isEmpty {
            guard layerBitrates.count <= 255 else {
                throw CodecError(.invalidArgument, "Layer bitrate list must not exceed 255 layers.")
            }
            var prev = 0.0
            for rate in layerBitrates {
                guard rate.isFinite && rate > prev else {
                    throw CodecError(.invalidArgument, "Layer bitrates must be strictly positive and ascending.")
                }
                prev = rate
            }
        }
        guard guardBits >= 1 && guardBits <= 7 else {
            throw CodecError(.invalidArgument, "Guard bits must lie in 1...7.")
        }
        if let step = baseStepSize {
            guard step.isFinite && step > 0.0 else {
                throw CodecError(.invalidArgument, "Base step size must be finite and positive.")
            }
        }
        if (tileWidth == nil) != (tileHeight == nil) {
            throw CodecError(.invalidArgument, "Both tileWidth and tileHeight must be specified together.")
        }
        if let tw = tileWidth, let th = tileHeight {
            guard tw >= 1 && th >= 1 else {
                throw CodecError(.invalidArgument, "Tile dimensions must be positive.")
            }
        }
        guard (codeBlockStyleBits & 0xC0) == 0 else {
            throw CodecError(.invalidArgument, "Part 1 codeBlockStyleBits must only set bits in 0x00...0x3F.")
        }
        if wavelet == .reversible53 && colourTransform == .ict {
            throw CodecError(.invalidArgument, "ICT requires the irreversible 9/7 wavelet (ISO/IEC 15444-1 Annex G).")
        }
        if wavelet == .irreversible97 && colourTransform == .rct {
            throw CodecError(.invalidArgument, "RCT requires the reversible 5/3 wavelet (ISO/IEC 15444-1 Annex G).")
        }
        if blockCoding == .htj2k {
            guard codeBlockStyleBits == 0, regionOfInterest == nil else {
                throw CodecError(.unsupportedFeature, "HTJ2K (Part 15) does not support Part 1 code-block style overrides or RGN ROI in the lossless profile.")
            }
            guard containerFormat != .jp2 else {
                throw CodecError(.invalidArgument, "JP2 container ('jp2 ') requires Part 1 block coding; use .jph or .jpx for HTJ2K.")
            }
        }
        if containerFormat == .codestream && (captureResolution != nil || displayResolution != nil) {
            throw CodecError(.invalidArgument, "Resolution metadata boxes ('resc'/'resd') require a container format (.jp2, .jph, or .jpx).")
        }

        self.decompositionLevels = decompositionLevels
        self.codeBlockWidth = codeBlockWidth
        self.codeBlockHeight = codeBlockHeight
        self.blockCoding = blockCoding
        self.wavelet = wavelet
        self.colourTransform = colourTransform
        self.progressionOrder = progressionOrder
        self.progressionChanges = progressionChanges
        self.quality = quality
        self.targetBitsPerPixel = targetBitsPerPixel
        self.qualityLayers = !layerBitrates.isEmpty ? layerBitrates.count : qualityLayers
        self.layerBitrates = layerBitrates
        self.quantizationStyle = quantizationStyle
        self.guardBits = guardBits
        self.baseStepSize = baseStepSize
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.precinctSizes = precinctSizes
        self.codeBlockStyleBits = codeBlockStyleBits
        self.usesSOP = usesSOP
        self.usesEPH = usesEPH
        self.regionOfInterest = regionOfInterest
        self.containerFormat = containerFormat
        self.captureResolution = captureResolution
        self.displayResolution = displayResolution
    }

    internal var usesDefaultLosslessProfile: Bool {
        (wavelet == .automatic || wavelet == .reversible53) &&
        (colourTransform == .automatic || colourTransform == .none) &&
        progressionOrder == .lrcp &&
        progressionChanges.isEmpty &&
        quality == nil &&
        targetBitsPerPixel == nil &&
        qualityLayers == 1 &&
        layerBitrates.isEmpty &&
        (quantizationStyle == .automatic || quantizationStyle == .none) &&
        guardBits == 2 &&
        baseStepSize == nil &&
        tileWidth == nil &&
        tileHeight == nil &&
        precinctSizes.isEmpty &&
        codeBlockStyleBits == 0 &&
        !usesSOP &&
        !usesEPH &&
        regionOfInterest == nil
    }
}

public struct EncoderConfiguration: Sendable, Equatable {
    public let mode: CompressionMode
    public let codecOptions: CodecOptions
    public init(mode: CompressionMode = .lossless, codecOptions: CodecOptions = .init()) throws {
        if case .nearLossless(let bound) = mode, bound <= 0 {
            throw CodecError(.invalidArgument, "Near-lossless error must be positive.")
        }
        if codecOptions.blockCoding == .htj2k && mode != .lossless {
            throw CodecError(.unsupportedFeature, "HTJ2K (Part 15) currently supports lossless mode only.")
        }
        if mode == .lossless {
            guard codecOptions.wavelet != .irreversible97 else {
                throw CodecError(.invalidArgument, "Lossless mode cannot use the irreversible 9/7 wavelet.")
            }
            guard codecOptions.colourTransform != .ict else {
                throw CodecError(.invalidArgument, "Lossless mode cannot use the irreversible colour transform (ICT).")
            }
            guard codecOptions.quantizationStyle == .automatic || codecOptions.quantizationStyle == .none else {
                throw CodecError(.invalidArgument, "Lossless mode requires unquantised coding (.none or .automatic).")
            }
            guard codecOptions.quality == nil,
                  codecOptions.targetBitsPerPixel == nil,
                  codecOptions.layerBitrates.isEmpty,
                  codecOptions.baseStepSize == nil else {
                throw CodecError(.invalidArgument, "Lossless mode cannot set lossy quality, target bitrate, or step size controls.")
            }
        } else if mode == .lossy {
            if codecOptions.wavelet == .reversible53 &&
                codecOptions.targetBitsPerPixel == nil &&
                codecOptions.quality == nil &&
                codecOptions.layerBitrates.isEmpty {
                throw CodecError(.invalidArgument, "Lossy mode with the reversible 5/3 wavelet requires a target bitrate or quality control.")
            }
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
    public static let supportedLayouts: [String] = [
        sharedGreyscaleLayout,
        "signed-greyscale-16bit-single-plane",
        "unsigned-greyscale-8bit-single-plane",
        "signed-greyscale-8bit-single-plane",
        "rgb-planar",
        "rgb-interleaved",
        "multicomponent-planar"
    ]
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

/// JPEG 2000 Part 1 and Part 15 (HTJ2K) encoder.
public struct Encoder: Sendable {
    public let configuration: EncoderConfiguration
    public static var capabilities: CodecCapabilities {
        CodecCapabilities(
            formats: [
                ScalarLosslessCodec.format,
                ScalarLosslessCodec.htj2kFormat,
                JP2Container.jp2Format,
                JP2Container.jphFormat,
                JP2Container.jpxFormat
            ],
            compressionModes: [.lossless, .nearLossless(maximumAbsoluteError: 1), .lossy],
            sampleTypes: [.unsignedInteger, .signedInteger],
            meaningfulPrecision: 1...16,
            layouts: CodecCapabilities.supportedLayouts,
            availableBackends: AccelerationRuntime.availableBackends,
            canInspect: false, canEncode: true, canDecode: false)
    }
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: EncoderConfiguration = .default) throws { self.configuration = configuration }

    /// `@concurrent` explicitly selects the generic executor (available since Swift 6.2).
    /// The image's storage is borrowed only inside synchronous work (MEM-08).
    @concurrent public func encode(_ image: Image, options: EncodeOptions = .init()) async throws -> EncodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        try Task.checkCancellation()
        let resolvedBackend = try AccelerationRuntime.resolve(options.executionPolicy)
        guard image.storage.byteCount <= options.resourceLimits.maximumDecodedBytes,
              image.storage.byteCount <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image exceeds operation limits.")
        }
        let descriptor = image.descriptor
        _ = try image.metadata.validate(
            limits: options.resourceLimits,
            additionalBytes: descriptor.iccProfile?.count ?? 0
        )
        if configuration.codecOptions.containerFormat == .codestream {
            guard descriptor.iccProfile == nil, image.metadata.entries.isEmpty else {
                throw CodecError(.unsupportedFeature, "Raw codestream output cannot carry ICC or metadata; none is silently dropped.")
            }
        }
        let isDefaultGreyscale16 = descriptor.sampleType == .unsignedInteger &&
            descriptor.storageBits == 16 &&
            descriptor.components == [.grey] &&
            descriptor.planes.count == 1 &&
            descriptor.alpha == .absent

        options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
        let codestreamBytes: [UInt8]
        let workspace: Int

        if configuration.mode == .lossless && isDefaultGreyscale16 && configuration.codecOptions.usesDefaultLosslessProfile {
            let smallest = min(descriptor.width, descriptor.height)
            let deepest = Int.bitWidth - 1 - smallest.leadingZeroBitCount
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
                blockCoding: configuration.codecOptions.blockCoding,
                backend: resolvedBackend.backend)
            (codestreamBytes, workspace) = try ScalarLosslessCodec.encode(
                image: image, parameters: parameters,
                limits: options.resourceLimits, progress: options.progress
            )
        } else {
            (codestreamBytes, workspace) = try Part1Pipeline.encode(
                image: image, configuration: configuration,
                limits: options.resourceLimits, backend: resolvedBackend.backend,
                progress: options.progress
            )
        }

        let finalBytes: [UInt8]
        let outputFormat: String
        var discardedCount: Int?
        var discardedBytes: Int?
        var discardedKinds: [String] = []

        if configuration.codecOptions.containerFormat == .codestream {
            finalBytes = codestreamBytes
            outputFormat = configuration.codecOptions.blockCoding == .htj2k
                ? ScalarLosslessCodec.htj2kFormat
                : ScalarLosslessCodec.format
            if options.metadataPolicy == .discardAncillary {
                var count = 0
                var totalBytes = 0
                var kinds: [String] = []
                for (k, v) in image.metadata.entries {
                    count += 1
                    totalBytes += v.count
                    let base = k.split(separator: ".").first.map(String.init) ?? k
                    if !kinds.contains(base) { kinds.append(base) }
                }
                discardedCount = count
                discardedBytes = totalBytes
                discardedKinds = kinds
            }
        } else {
            let wrapped = try JP2Container.wrap(
                codestream: codestreamBytes,
                descriptor: descriptor,
                metadata: image.metadata,
                containerFormat: configuration.codecOptions.containerFormat,
                isLossless: configuration.mode == .lossless,
                isHTJ2K: configuration.codecOptions.blockCoding == .htj2k,
                captureResolution: configuration.codecOptions.captureResolution,
                displayResolution: configuration.codecOptions.displayResolution,
                metadataPolicy: options.metadataPolicy,
                limits: options.resourceLimits
            )
            finalBytes = wrapped.bytes
            outputFormat = wrapped.format
            if options.metadataPolicy == .discardAncillary {
                discardedCount = wrapped.discardedMetadataCount
                discardedBytes = wrapped.discardedMetadataBytes
                discardedKinds = wrapped.discardedMetadataKinds
            }
        }

        guard finalBytes.count <= options.resourceLimits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Encoded output exceeds the compressed-size limit.")
        }
        try Task.checkCancellation()
        let elapsed = clock.now - started
        let fidelity: Fidelity
        switch configuration.mode {
        case .lossless:
            fidelity = .exactSamples
        case .nearLossless(let bound):
            fidelity = .boundedError(bound)
        case .lossy:
            fidelity = .lossy
        }
        let report = OperationReport(backend: resolvedBackend.backend,
                                     fallbackReason: resolvedBackend.fallbackReason,
                                     fidelity: fidelity, copyEvents: [],
                                     pixelAllocationCount: 0, peakPixelBytes: image.storage.byteCount,
                                     peakWorkspaceBytes: workspace,
                                     elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                                     discardedMetadataCount: discardedCount,
                                     discardedMetadataBytes: discardedBytes,
                                     discardedMetadataKinds: discardedKinds)
        options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
        return EncodedImage(data: Data(finalBytes), encoding: EncodingDescription(format: outputFormat, mode: configuration.mode),
                            report: report)
    }
}

/// JPEG 2000 Part 1 and Part 15 (HTJ2K) decoder.
public struct Decoder: Sendable {
    public let configuration: DecoderConfiguration
    public static var capabilities: CodecCapabilities {
        CodecCapabilities(
            formats: [
                ScalarLosslessCodec.format,
                ScalarLosslessCodec.htj2kFormat,
                JP2Container.jp2Format,
                JP2Container.jphFormat,
                JP2Container.jpxFormat
            ],
            compressionModes: [.lossless, .nearLossless(maximumAbsoluteError: 1), .lossy],
            sampleTypes: [.unsignedInteger, .signedInteger],
            meaningfulPrecision: 1...16,
            layouts: CodecCapabilities.supportedLayouts,
            availableBackends: AccelerationRuntime.availableBackends,
            canInspect: true, canEncode: false, canDecode: true)
    }
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: DecoderConfiguration = .init()) throws { self.configuration = configuration }

    /// Bounded structural inspection: parses the container boxes and main/tile-part headers only.
    public func inspect(_ data: Data, options: DecodeOptions = .init()) throws -> ImageInfo {
        try validateInput(data, options)
        let bytes = [UInt8](data)
        if JP2Container.isContainer(bytes) {
            let reconciled = try JP2Container.inspectReconciled(
                bytes,
                limits: options.resourceLimits,
                metadataPolicy: options.metadataPolicy
            )
            return ImageInfo(
                format: reconciled.container.format,
                descriptor: reconciled.outputDescriptor,
                frameCount: 1,
                metadata: reconciled.combinedMetadata
            )
        }
        do {
            let profile = try ScalarLosslessCodec.inspect(bytes, limits: options.resourceLimits,
                                                          metadataPolicy: options.metadataPolicy)
            let descriptor = try ImageDescriptor.greyscale16(width: profile.width, height: profile.height,
                                                             meaningfulBits: profile.precision,
                                                             limits: options.resourceLimits)
            return ImageInfo(format: profile.format, descriptor: descriptor, frameCount: 1, metadata: .empty)
        } catch let error as CodecError where error.category == .unsupportedFeature {
            let part1 = try Part1Pipeline.inspect(bytes, limits: options.resourceLimits,
                                                  metadataPolicy: options.metadataPolicy)
            let descriptor = try part1.defaultDescriptor(limits: options.resourceLimits)
            return ImageInfo(format: part1.format, descriptor: descriptor, frameCount: 1, metadata: .empty)
        }
    }

    /// Allocates one final destination and decodes through the same path as
    /// caller-supplied storage (MEM-10).
    @concurrent public func decode(_ data: Data, options: DecodeOptions = .init()) async throws -> DecodedImage {
        try Task.checkCancellation()
        try validateInput(data, options)
        let bytes = [UInt8](data)
        if JP2Container.isContainer(bytes) {
            let reconciled = try JP2Container.inspectReconciled(
                bytes,
                limits: options.resourceLimits,
                metadataPolicy: options.metadataPolicy
            )
            let destination = try ImageDestination.allocate(
                descriptor: reconciled.outputDescriptor,
                limits: options.resourceLimits
            )
            return try JP2Container.decode(
                reconciled: reconciled,
                into: destination,
                options: options,
                allocations: 1
            )
        }
        do {
            let profile = try ScalarLosslessCodec.inspect(bytes, limits: options.resourceLimits,
                                                          metadataPolicy: options.metadataPolicy)
            let descriptor = try ImageDescriptor.greyscale16(width: profile.width, height: profile.height,
                                                             meaningfulBits: profile.precision,
                                                             limits: options.resourceLimits)
            let destination = try ImageDestination.allocate(descriptor: descriptor, limits: options.resourceLimits)
            return try run(bytes: bytes, profile: profile, into: destination, options: options, allocations: 1)
        } catch let error as CodecError where error.category == .unsupportedFeature {
            let part1 = try Part1Pipeline.inspect(bytes, limits: options.resourceLimits,
                                                  metadataPolicy: options.metadataPolicy)
            let descriptor = try part1.defaultDescriptor(limits: options.resourceLimits)
            let destination = try ImageDestination.allocate(descriptor: descriptor, limits: options.resourceLimits)
            return try runPart1(bytes: bytes, profile: part1, into: destination, options: options, allocations: 1)
        }
    }

    /// Decodes final samples directly into `destination`. Preflight failures
    /// leave the destination reusable; failures after writing starts invalidate it.
    @concurrent public func decode(_ data: Data, into destination: ImageDestination,
                                  options: DecodeOptions = .init()) async throws -> DecodedImage {
        try Task.checkCancellation()
        try validateInput(data, options)
        let bytes = [UInt8](data)
        if JP2Container.isContainer(bytes) {
            let reconciled = try JP2Container.inspectReconciled(
                bytes,
                limits: options.resourceLimits,
                metadataPolicy: options.metadataPolicy
            )
            return try JP2Container.decode(
                reconciled: reconciled,
                into: destination,
                options: options,
                allocations: 0
            )
        }
        let destDesc = destination.descriptor
        let isDefaultGreyscale16 = destDesc.sampleType == .unsignedInteger &&
            destDesc.storageBits == 16 &&
            destDesc.components == [.grey] &&
            destDesc.planes.count == 1
        if isDefaultGreyscale16 {
            do {
                let profile = try ScalarLosslessCodec.inspect(bytes, limits: options.resourceLimits,
                                                              metadataPolicy: options.metadataPolicy)
                return try run(bytes: bytes, profile: profile, into: destination, options: options, allocations: 0)
            } catch let error as CodecError where error.category == .unsupportedFeature {
                let part1 = try Part1Pipeline.inspect(bytes, limits: options.resourceLimits,
                                                      metadataPolicy: options.metadataPolicy)
                return try runPart1(bytes: bytes, profile: part1, into: destination, options: options, allocations: 0)
            }
        } else {
            let part1 = try Part1Pipeline.inspect(bytes, limits: options.resourceLimits,
                                                  metadataPolicy: options.metadataPolicy)
            return try runPart1(bytes: bytes, profile: part1, into: destination, options: options, allocations: 0)
        }
    }

    private func run(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                     options: DecodeOptions, allocations: Int) throws -> DecodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        let resolvedBackend = try AccelerationRuntime.resolve(options.executionPolicy)
        options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
        let (image, workspace) = try ScalarLosslessCodec.decode(
            bytes: bytes, profile: profile, into: destination,
            limits: options.resourceLimits, backend: resolvedBackend.backend,
            progress: options.progress
        )
        try Task.checkCancellation()
        let elapsed = clock.now - started
        let discardedCount = (options.metadataPolicy == .discardAncillary) ? profile.commentCount : 0
        let discardedBytes = (options.metadataPolicy == .discardAncillary) ? profile.commentPayloadBytes : 0
        let discardedKinds = (discardedCount > 0) ? ["COM"] : []
        let report = OperationReport(backend: resolvedBackend.backend,
                                     fallbackReason: resolvedBackend.fallbackReason,
                                     fidelity: .exactSamples, copyEvents: [],
                                     pixelAllocationCount: allocations, peakPixelBytes: image.storage.byteCount,
                                     peakWorkspaceBytes: workspace,
                                     elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                                     discardedMetadataCount: discardedCount,
                                     discardedMetadataBytes: discardedBytes,
                                     discardedMetadataKinds: discardedKinds)
        options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
        return DecodedImage(image: image, report: report)
    }

    private func runPart1(bytes: [UInt8], profile: Part1Profile, into destination: ImageDestination,
                          options: DecodeOptions, allocations: Int) throws -> DecodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        let resolvedBackend = try AccelerationRuntime.resolve(options.executionPolicy)
        options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
        let (image, workspace) = try Part1Pipeline.decode(
            bytes: bytes, profile: profile, into: destination,
            limits: options.resourceLimits, backend: resolvedBackend.backend,
            progress: options.progress
        )
        try Task.checkCancellation()
        let elapsed = clock.now - started
        let discardedCount = (options.metadataPolicy == .discardAncillary) ? profile.commentCount : 0
        let discardedBytes = (options.metadataPolicy == .discardAncillary) ? profile.commentPayloadBytes : 0
        let discardedKinds = (discardedCount > 0) ? ["COM"] : []
        let fidelity: Fidelity = profile.isReversibleLossless ? .exactSamples : .lossy
        let report = OperationReport(backend: resolvedBackend.backend,
                                     fallbackReason: resolvedBackend.fallbackReason,
                                     fidelity: fidelity, copyEvents: [],
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
    _ = try AccelerationRuntime.resolve(policy)
}
private func validateInput(_ data: Data, _ options: DecodeOptions) throws {
    try validateOperation(options.resourceLimits, options.executionPolicy)
    guard data.count <= options.resourceLimits.maximumCompressedBytes,
          data.count <= options.resourceLimits.maximumMemoryBytes else {
        throw CodecError(.resourceLimitExceeded, "Compressed input exceeds operation limits.")
    }
}
