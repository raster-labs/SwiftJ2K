// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Contract API-13 Interactive Streaming Extension Surface for SwiftJ2KJPIP
// Predecessor reference: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K
import SwiftJ2K3D

// MARK: - API-13 Interactive Streaming Extension Rationale

/// Contract **API-13** Interactive Streaming Extension Surface (`SwiftJ2KJPIP`).
///
/// The common single-image contract (`SwiftJ2K.Encoder` / `SwiftJ2K.Decoder`) models stateless,
/// single-shot in-memory encode and decode operations over complete codestreams or containers.
/// ISO/IEC 15444-9 (JPIP — JPEG 2000 Interactive Protocol) is a stateful, session-oriented
/// progressive streaming protocol that manages:
/// - persistent sessions and channels (`cid`, `cnew`, `cclose`);
/// - spatial view-window and resolution queries (`fsiz`, `roff`, `rsiz`, `layers`, `comps`);
/// - incremental header, tile-header, precinct, and metadata data-bin framing (`JPIPDataBin`);
/// - client-side cache modelling (`model`) and server-side cache state deduplication;
/// - bandwidth estimation, priority queues, predictive prefetching, and server push;
/// - on-the-fly Part 1 (EBCOT) ↔ Part 15 (HTJ2K) transcoding negotiation (`JPIPCodingPreference`); and
/// - 3D volumetric viewport streaming (`JP3DViewport`, `JP3DStreamingRegion`, `JP3DDataBin`).
///
/// Because interactive protocol state machines, incremental data-bin caches, and network sessions
/// cannot be expressed as stateless single-shot `Encoder`/`Decoder` calls, **API-13** defines
/// ``JPIPSessionConfiguration``, ``JPIPStreamingOptions``, ``JPIPViewWindow``,
/// ``JPIPDeliveredImage``, ``JPIPDeliveredVolumeSliceBins``, and ``JPIPStreamingSession`` to bridge
/// JPIP streaming with the common contract's owning ``Image``, ``ResourceLimits``,
/// ``ExecutionPolicy``, ``CopyPolicy``, ``MetadataPolicy``, ``ProgressUpdate``, and
/// ``OperationReport`` telemetry, alongside the retained `JPIPClient` / `JPIPServer` actors
/// required by `DICOMKit` (`DICOMJPIPClient` and `dicom-jpip`).

// MARK: - JPIPSessionConfiguration & JPIPStreamingOptions

/// Delivery mode for a ``JPIPStreamingSession``.
public enum JPIPDeliveryMode: String, Sendable, Equatable, CaseIterable {
    /// Incremental data-bin delivery (header, tile-header, precinct, and metadata bins).
    case incremental
    /// Full codestream or reassembled image delivery.
    case full
}

/// Validated, immutable configuration for ``JPIPStreamingSession``.
public struct JPIPSessionConfiguration: Sendable, Equatable {
    /// Preferred coding format (`none`, `htj2k`, or `standard`) for JPIP capability negotiation.
    public let codingPreference: JPIPCodingPreference
    /// Delivery mode (`full` or `incremental` precinct/tile data-bin streaming).
    public let deliveryMode: JPIPDeliveryMode
    /// Maximum number of data bins retained in the session cache.
    public let maxCachedDataBins: Int
    /// Maximum byte capacity of the session data-bin cache.
    public let maxCacheSizeBytes: Int

    /// Creates and validates a JPIP streaming session configuration.
    public init(
        codingPreference: JPIPCodingPreference = .none,
        deliveryMode: JPIPDeliveryMode = .incremental,
        maxCachedDataBins: Int = 10_000,
        maxCacheSizeBytes: Int = 100 * 1024 * 1024
    ) throws {
        guard maxCachedDataBins >= 1 else {
            throw CodecError(
                .invalidArgument,
                "JPIPSessionConfiguration: maxCachedDataBins must be >= 1"
            )
        }
        guard maxCacheSizeBytes >= 1024 else {
            throw CodecError(
                .invalidArgument,
                "JPIPSessionConfiguration: maxCacheSizeBytes must be >= 1024"
            )
        }
        self.codingPreference = codingPreference
        self.deliveryMode = deliveryMode
        self.maxCachedDataBins = maxCachedDataBins
        self.maxCacheSizeBytes = maxCacheSizeBytes
    }
}

/// Per-operation options for ``JPIPStreamingSession`` requests.
public struct JPIPStreamingOptions: Sendable {
    /// Resource limits enforced on delivered images, codestreams, and metadata.
    public var resourceLimits: ResourceLimits
    /// Execution policy for acceleration vs. scalar CPU reference during reconstruction.
    public var executionPolicy: ExecutionPolicy
    /// Copy policy for reconstructed image buffers.
    public var copyPolicy: CopyPolicy
    /// Metadata preservation policy.
    public var metadataPolicy: MetadataPolicy
    /// Optional progress callback.
    public var progress: (@Sendable (ProgressUpdate) -> Void)?

    public init(
        resourceLimits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic,
        copyPolicy: CopyPolicy = .allowCopy,
        metadataPolicy: MetadataPolicy = .preserve,
        progress: (@Sendable (ProgressUpdate) -> Void)? = nil
    ) {
        self.resourceLimits = resourceLimits
        self.executionPolicy = executionPolicy
        self.copyPolicy = copyPolicy
        self.metadataPolicy = metadataPolicy
        self.progress = progress
    }
}

// MARK: - JPIPViewWindow

/// Validated 2D spatial, resolution, quality, and component view window for JPIP requests.
public struct JPIPViewWindow: Sendable, Equatable {
    /// Optional spatial sub-region `(x, y, width, height)` in full-resolution reference grid coordinates.
    public let regionOriginX: Int?
    public let regionOriginY: Int?
    public let regionWidth: Int?
    public let regionHeight: Int?
    /// Optional resolution reduction level (`0` = full resolution, `1` = half, `2` = quarter, etc.).
    public let resolutionLevel: Int?
    /// Optional maximum number of quality layers to decode (`>= 1`).
    public let maxQualityLayers: Int?
    /// Optional subset of component indices (`>= 0`).
    public let components: [Int]?

    /// Creates and validates a 2D JPIP view window.
    public init(
        region: (x: Int, y: Int, width: Int, height: Int)? = nil,
        resolutionLevel: Int? = nil,
        maxQualityLayers: Int? = nil,
        components: [Int]? = nil
    ) throws {
        if let region = region {
            guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                  !region.x.addingReportingOverflow(region.width).overflow,
                  !region.y.addingReportingOverflow(region.height).overflow else {
                throw CodecError(
                    .invalidArgument,
                    "JPIPViewWindow: region must have non-negative origin, positive dimensions, and non-overflowing bounds"
                )
            }
            self.regionOriginX = region.x
            self.regionOriginY = region.y
            self.regionWidth = region.width
            self.regionHeight = region.height
        } else {
            self.regionOriginX = nil
            self.regionOriginY = nil
            self.regionWidth = nil
            self.regionHeight = nil
        }

        if let level = resolutionLevel {
            guard (0...32).contains(level) else {
                throw CodecError(
                    .invalidArgument,
                    "JPIPViewWindow: resolutionLevel must be in 0...32"
                )
            }
        }
        self.resolutionLevel = resolutionLevel

        if let layers = maxQualityLayers {
            guard layers >= 1 else {
                throw CodecError(
                    .invalidArgument,
                    "JPIPViewWindow: maxQualityLayers must be >= 1"
                )
            }
        }
        self.maxQualityLayers = maxQualityLayers

        if let comps = components {
            guard !comps.isEmpty, comps.allSatisfy({ $0 >= 0 }) else {
                throw CodecError(
                    .invalidArgument,
                    "JPIPViewWindow: components must be non-empty and non-negative"
                )
            }
        }
        self.components = components
    }
}

// MARK: - Delivered Results

/// Result of a contract-aligned 2D JPIP image or view-window delivery.
public struct JPIPDeliveredImage: Sendable {
    /// Contract-aligned owning `Image` reconstructed from the JPIP response and session cache.
    public let image: Image
    /// Legacy `J2KImage` representation for compatibility with existing `JPIP` consumers.
    public let legacyImage: J2KImage
    /// Active JPIP channel identifier (`cid`), if a stateful session channel was established.
    public let channelID: String?
    /// Total number of data bins currently stored in the client session cache.
    public let cachedDataBins: Int
    /// Total byte size currently stored in the client session cache.
    public let cachedBytes: Int
    /// Operation report detailing execution backend, fidelity, and memory usage.
    public let report: OperationReport

    public init(
        image: Image,
        legacyImage: J2KImage,
        channelID: String?,
        cachedDataBins: Int,
        cachedBytes: Int,
        report: OperationReport
    ) {
        self.image = image
        self.legacyImage = legacyImage
        self.channelID = channelID
        self.cachedDataBins = cachedDataBins
        self.cachedBytes = cachedBytes
        self.report = report
    }
}

/// Result of a contract-aligned 3D JP3D JPIP volumetric region delivery.
public struct JPIPDeliveredVolumeSliceBins: Sendable {
    /// Requested 3D streaming region.
    public let region: JP3DStreamingRegion
    /// Delivered 3D precinct/tile/header data bins (`JP3DDataBin`).
    public let bins: [JP3DDataBin]
    /// Operation report detailing execution backend, fidelity, and memory usage.
    public let report: OperationReport

    public init(
        region: JP3DStreamingRegion,
        bins: [JP3DDataBin],
        report: OperationReport
    ) {
        self.region = region
        self.bins = bins
        self.report = report
    }
}

// MARK: - JPIPStreamingSession

/// Contract **API-13** actor for interactive 2D and 3D JPIP streaming sessions.
public actor JPIPStreamingSession {
    /// Immutable streaming configuration.
    public nonisolated let configuration: JPIPSessionConfiguration
    /// Target server URL.
    public nonisolated let serverURL: URL

    private let client: JPIPClient
    private let jp3dClient: JP3DJPIPClient

    /// Creates a JPIP streaming session connected to a remote or loopback URL.
    public init(
        serverURL: URL,
        configuration: JPIPSessionConfiguration = try! JPIPSessionConfiguration()
    ) {
        self.serverURL = serverURL
        self.configuration = configuration
        self.client = JPIPClient(
            serverURL: serverURL,
            configuration: configuration
        )
        self.jp3dClient = JP3DJPIPClient(serverURL: serverURL)
    }

    /// Creates a JPIP streaming session bound directly to an in-process ``JPIPServer``.
    public init(
        server: JPIPServer,
        port: Int = 8080,
        configuration: JPIPSessionConfiguration = try! JPIPSessionConfiguration()
    ) {
        let url = URL(string: "http://localhost:\(port)")!
        self.serverURL = url
        self.configuration = configuration
        self.client = JPIPClient(
            server: server,
            serverURL: url,
            configuration: configuration
        )
        self.jp3dClient = JP3DJPIPClient(
            server: server,
            serverURL: url
        )
    }

    /// Delivers a full 2D image or a constrained ``JPIPViewWindow`` from the JPIP server.
    public func deliverImage(
        imageID: String,
        viewWindow: JPIPViewWindow? = nil,
        options: JPIPStreamingOptions = JPIPStreamingOptions()
    ) async throws -> JPIPDeliveredImage {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(
            by: .seconds(options.resourceLimits.deadlineSeconds)
        )
        @inline(__always)
        func checkWork() throws {
            try Task.checkCancellation()
            if ContinuousClock.now > deadline {
                throw CodecError(.resourceLimitExceeded, "JPIP streaming deadline elapsed.")
            }
        }

        try checkWork()
        _ = try AccelerationRuntime.resolve(options.executionPolicy)
        guard options.copyPolicy == .allowCopy else {
            throw CodecError(
                .incompatibleImageLayout,
                "JPIPStreamingSession.deliverImage materialises both contract Image and legacy J2KImage sample buffers, requiring a buffer copy; pass copyPolicy: .allowCopy."
            )
        }

        if let p = try? ProgressUpdate(phase: .inspecting, completedUnits: 0, totalUnits: 3) {
            options.progress?(p)
        }
        try checkWork()

        if let p = try? ProgressUpdate(phase: .processing, completedUnits: 1, totalUnits: 3) {
            options.progress?(p)
        }
        try checkWork()

        let decodedInfo: J2KDecoder.DecodedCodestreamInfo
        do {
            decodedInfo = try await client.requestDeliveredImage(
                imageID: imageID,
                viewWindow: viewWindow,
                limits: options.resourceLimits,
                executionPolicy: options.executionPolicy,
                metadataPolicy: options.metadataPolicy,
                deadline: deadline
            )
        } catch let error as J2KError {
            throw error.asCodecError
        }

        let legacyImage = decodedInfo.image
        try checkWork()
        try validateDeliveredLegacyImage(legacyImage, limits: options.resourceLimits)

        let legacyPixelBytes = try legacyImage.pixelBytes()
        let stats = await client.getSessionStats()
        let cachedBytes = stats?.cacheSize ?? 0
        let cachedStorageBytes = try jpipCheckedSum(cachedBytes,
            jpipCheckedProduct([stats?.cachedBins ?? 0, MemoryLayout<JPIPCacheModel.CacheEntry>.stride]))
        var accounting = decodedInfo.pixelAccounting
        let contractImage: Image
        if let directContract = decodedInfo.contractImage {
            contractImage = directContract
        } else {
            let componentCount = legacyImage.components.count
            let storageBytes = componentCount == 1 ? 2 : ((legacyImage.components[0].bitDepth <= 8) ? 1 : 2)
            let contractBytes = try jpipCheckedProduct([legacyImage.width, legacyImage.height, componentCount, storageBytes])
            let metadataBytes = try decodedInfo.metadata.entries.reduce(0) {
                try jpipCheckedSum($0, jpipCheckedSum($1.key.utf8.count, $1.value.count))
            }
            try accounting.recordAllocation(bytes: contractBytes, count: 1,
                liveBefore: legacyPixelBytes,
                residentBytes: jpipCheckedSum(cachedStorageBytes, jpipCheckedSum(metadataBytes, decodedInfo.iccProfile?.count ?? 0)),
                reason: "Materialise projected legacy samples as contract Image", limits: options.resourceLimits)
            contractImage = try legacyImage.toContractImage(
                colourOverride: decodedInfo.colourInterpretation,
                alphaOverride: decodedInfo.alphaInterpretation,
                iccProfileOverride: decodedInfo.iccProfile,
                metadata: decodedInfo.metadata,
                limits: options.resourceLimits,
                retainedBytes: jpipCheckedSum(legacyPixelBytes, cachedStorageBytes)
            )
        }

        try checkWork()
        if let p = try? ProgressUpdate(phase: .completed, completedUnits: 3, totalUnits: 3) {
            options.progress?(p)
        }
        try checkWork()

        let hasReducedResolution = (viewWindow?.resolutionLevel ?? 0) > 0
        let hasReducedLayers: Bool
        if let reqLayers = viewWindow?.maxQualityLayers {
            hasReducedLayers = reqLayers < decodedInfo.totalQualityLayers
        } else {
            hasReducedLayers = false
        }
        let hasSubsetComponents: Bool
        if let reqComps = viewWindow?.components {
            hasSubsetComponents = reqComps != Array(0..<decodedInfo.totalComponents)
        } else {
            hasSubsetComponents = false
        }
        let isExact = decodedInfo.isReversibleLossless
            && !hasReducedResolution
            && !hasReducedLayers
            && !hasSubsetComponents
        let peakWorkspace = max(decodedInfo.peakWorkspaceBytes, cachedStorageBytes)
        let elapsed = clock.now - started
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let report = OperationReport(
            backend: decodedInfo.backend,
            fallbackReason: decodedInfo.fallbackReason,
            fidelity: isExact ? .exactSamples : .lossy,
            copyEvents: accounting.copyEvents,
            pixelAllocationCount: accounting.allocationCount,
            peakPixelBytes: accounting.peakBytes,
            peakWorkspaceBytes: peakWorkspace,
            elapsedSeconds: elapsedSeconds,
            discardedMetadataCount: options.metadataPolicy == .discardAncillary ? decodedInfo.discardedMetadataCount : nil,
            discardedMetadataBytes: options.metadataPolicy == .discardAncillary ? decodedInfo.discardedMetadataBytes : nil,
            discardedMetadataKinds: options.metadataPolicy == .discardAncillary ? decodedInfo.discardedMetadataKinds : []
        )

        return JPIPDeliveredImage(
            image: contractImage,
            legacyImage: legacyImage,
            channelID: stats?.channelID,
            cachedDataBins: stats?.cachedBins ?? 0,
            cachedBytes: stats?.cacheSize ?? 0,
            report: report
        )
    }

    /// Delivers a 3D volumetric streaming region (`JP3DStreamingRegion`) as normative `JP3DDataBin` packets.
    public func deliverVolumeRegion(
        volumeID: String,
        region: JP3DStreamingRegion,
        options: JPIPStreamingOptions = JPIPStreamingOptions()
    ) async throws -> JPIPDeliveredVolumeSliceBins {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(
            by: .seconds(options.resourceLimits.deadlineSeconds)
        )
        @inline(__always)
        func checkWork() throws {
            try Task.checkCancellation()
            if ContinuousClock.now > deadline {
                throw CodecError(.resourceLimitExceeded, "JPIP volumetric streaming deadline elapsed.")
            }
        }

        try checkWork()
        let resolvedBackend = try AccelerationRuntime.resolve(options.executionPolicy)

        let width = region.xRange.count
        let height = region.yRange.count
        let depth = region.zRange.count
        let limits = options.resourceLimits
        let maxDim = limits.maximumDimension
        guard width > 0, height > 0, depth > 0 else {
            throw CodecError(
                .invalidArgument,
                "3D streaming region dimensions (\(width)x\(height)x\(depth)) must be positive"
            )
        }
        guard width <= maxDim, height <= maxDim, depth <= maxDim,
              depth <= limits.maximumFrames else {
            throw CodecError(
                .resourceLimitExceeded,
                "3D streaming region dimensions (\(width)x\(height)x\(depth)) exceed resource limits"
            )
        }
        let (wh, o1) = width.multipliedReportingOverflow(by: height)
        let (voxels, o2) = wh.multipliedReportingOverflow(by: depth)
        guard !o1, !o2, voxels <= limits.maximumPixels else {
            throw CodecError(
                .resourceLimitExceeded,
                "3D streaming region voxel count exceeds pixel limit \(limits.maximumPixels)"
            )
        }

        if let p = try? ProgressUpdate(phase: .inspecting, completedUnits: 0, totalUnits: 2) {
            options.progress?(p)
        }
        try checkWork()

        let bins: [JP3DDataBin]
        do {
            try await jp3dClient.connect()
            try await jp3dClient.createSession(volumeID: volumeID, limits: limits)
            bins = try await jp3dClient.requestRegion(region, limits: limits)
        } catch let codecError as CodecError {
            throw codecError
        } catch let cancelError as CancellationError {
            throw cancelError
        } catch let error as J2KError {
            throw error.asCodecError
        } catch let error as JP3DClientError {
            switch error {
            case .invalidRegion(let msg), .unknownVolume(let msg):
                throw CodecError(.invalidArgument, msg)
            case .notConnected, .noSession, .serverError, .networkError:
                throw CodecError(.internalFailure, "\(error)")
            }
        }

        try checkWork()

        let totalBinBytes = try bins.reduce(0) { try jpipCheckedSum($0, $1.data.count) }
        guard totalBinBytes <= limits.maximumCompressedBytes,
              totalBinBytes <= limits.maximumWorkspaceBytes,
              totalBinBytes <= limits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "Delivered 3D data-bin payload (\(totalBinBytes) bytes) exceeds resource limits"
            )
        }

        // Substantiate 3D stream integrity, completeness, workspace footprint, and sample fidelity
        let wireBins = await jp3dClient.cachedWireDataBins()
        guard let mhBin = wireBins.first(where: { $0.binClass == .mainHeader }),
              mhBin.isComplete,
              JP3DJPIPIndexer.isJP3DCodestream(mhBin.data) else {
            throw CodecError(
                .malformedInput,
                "Delivered 3D JPIP stream is missing a complete Part 10 JP3D main header."
            )
        }

        let reconstructed: Data
        do {
            reconstructed = try await jp3dClient.reconstructCodestream(limits: limits)
        } catch let codecError as CodecError {
            throw codecError
        } catch let j2kError as J2KError {
            throw j2kError.asCodecError
        } catch {
            throw CodecError(.malformedInput, "Failed to reconstruct 3D JPIP codestream: \(error)")
        }

        let decodeOptions = VolumeDecodeOptions(
            resourceLimits: limits,
            executionPolicy: options.executionPolicy,
            regionOfInterest: JP3DRegion(
                x: region.xRange,
                y: region.yRange,
                z: region.zRange
            )
        )
        let volInfo = try VolumeDecoder().inspect(reconstructed, options: decodeOptions)

        let lastEOR = await jp3dClient.lastEORReason
        let eorCompleted = (lastEOR == .imageDone || lastEOR == .windowDone)
        let payloadBins = wireBins.filter {
            $0.binClass == .precinct
                || $0.binClass == .extendedPrecinct
                || $0.binClass == .tile
                || $0.binClass == .extendedTile
        }
        let allWireBinsComplete = !payloadBins.isEmpty && wireBins.allSatisfy(\.isComplete)
        let reducedResolution = region.resolutionLevel > 0
        let reducedQualityLayers = region.qualityLayer > 0 && region.qualityLayer < volInfo.qualityLayers
        let candidateExact = volInfo.isLossless
            && eorCompleted
            && allWireBinsComplete
            && !reducedResolution
            && !reducedQualityLayers

        let verifyDecoder = try VolumeDecoder(
            configuration: VolumeDecoderConfiguration(
                maxQualityLayers: region.qualityLayer,
                resolutionLevel: region.resolutionLevel,
                tolerateTruncation: !candidateExact
            )
        )
        let verifyDecoded = try await verifyDecoder.decode(reconstructed, options: decodeOptions)
        let isExact3D = candidateExact && (verifyDecoded.report.fidelity == Fidelity.exactSamples)

        let clientCacheWorkspace = await jp3dClient.lastPeakWorkspaceBytes
        let retainedStreamWorkspace = try jpipCheckedSum(max(clientCacheWorkspace, totalBinBytes), reconstructed.count)
        let measuredPeakWorkspace = try jpipCheckedSum(retainedStreamWorkspace, verifyDecoded.report.peakWorkspaceBytes ?? 0)
        guard measuredPeakWorkspace <= limits.maximumWorkspaceBytes,
              measuredPeakWorkspace <= limits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "3D JPIP streaming + verification workspace (\(measuredPeakWorkspace) bytes) exceeds resource limits."
            )
        }

        try checkWork()
        if let p = try? ProgressUpdate(phase: .completed, completedUnits: 2, totalUnits: 2) {
            options.progress?(p)
        }
        try checkWork()

        let elapsed = clock.now - started
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let report = OperationReport(
            backend: verifyDecoded.report.backend,
            fallbackReason: verifyDecoded.report.fallbackReason ?? resolvedBackend.fallbackReason,
            fidelity: isExact3D ? .exactSamples : .lossy,
            copyEvents: [],
            pixelAllocationCount: 0,
            peakPixelBytes: 0,
            peakWorkspaceBytes: measuredPeakWorkspace,
            elapsedSeconds: elapsedSeconds
        )

        return JPIPDeliveredVolumeSliceBins(
            region: region,
            bins: bins,
            report: report
        )
    }

    /// Closes the underlying 2D and 3D JPIP sessions and releases transport resources.
    public func close() async throws {
        do {
            try await client.close()
        } catch let error as J2KError {
            throw error.asCodecError
        }
        await jp3dClient.disconnect()
    }

    private func validateDeliveredLegacyImage(
        _ image: J2KImage,
        limits: ResourceLimits
    ) throws {
        let maxDim = limits.maximumDimension
        guard image.width <= maxDim, image.height <= maxDim else {
            throw CodecError(
                .resourceLimitExceeded,
                "Delivered JPIP image dimensions (\(image.width)x\(image.height)) exceed limit \(maxDim)"
            )
        }
        let (pixels, ov) = image.width.multipliedReportingOverflow(by: image.height)
        guard !ov, pixels <= limits.maximumPixels else {
            throw CodecError(
                .resourceLimitExceeded,
                "Delivered JPIP image pixel count exceeds limit \(limits.maximumPixels)"
            )
        }
        let totalBytes = image.components.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= limits.maximumDecodedBytes,
              totalBytes <= limits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "Delivered JPIP image byte size \(totalBytes) exceeds memory limit"
            )
        }
    }
}

private func jpipDescriptorLayoutName(_ descriptor: ImageDescriptor) -> String {
    if descriptor.components == [.grey] && descriptor.planes.count == 1 {
        if descriptor.storageBits == 16 {
            return descriptor.sampleType == .signedInteger
                ? "signed-greyscale-16bit-single-plane"
                : CodecCapabilities.sharedGreyscaleLayout
        }
        return descriptor.sampleType == .signedInteger
            ? "signed-greyscale-8bit-single-plane"
            : "unsigned-greyscale-8bit-single-plane"
    }
    if descriptor.colour == .rgb {
        return descriptor.planes.count == 1 ? "rgb-interleaved" : "rgb-planar"
    }
    return "multicomponent-planar"
}

/// Checked admission arithmetic for the streaming adapter's simultaneously retained buffers.
private func jpipCheckedSum(_ a: Int, _ b: Int) throws -> Int {
    let (result, overflow) = a.addingReportingOverflow(b)
    guard a >= 0, b >= 0, !overflow else { throw CodecError(.resourceLimitExceeded, "JPIP live-storage arithmetic overflow.") }
    return result
}

private func jpipCheckedProduct(_ values: [Int]) throws -> Int {
    try values.reduce(1) { value, next in
        let (result, overflow) = value.multipliedReportingOverflow(by: next)
        guard next >= 0, !overflow else { throw CodecError(.resourceLimitExceeded, "JPIP pixel-storage arithmetic overflow.") }
        return result
    }
}
