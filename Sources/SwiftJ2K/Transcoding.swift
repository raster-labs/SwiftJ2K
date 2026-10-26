// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Native compressed endpoints for JPEG 2000 Part 1 and Part 15 (HTJ2K).
public enum TranscodeTarget: String, Sendable, Equatable, CaseIterable {
    case jpeg2000, htj2k
}

/// These fidelity guarantees are distinct; sample preservation differs from bitstream restoration.
public enum TranscodePreservation: Sendable, Equatable {
    case exactSamples, originalBitstream
}

/// A qualified native format-pair path.
public enum TranscodeProcessingPath: Sendable, Equatable {
    case coefficients, reconstruction, sharedSamples
}

/// Describes a qualified native compressed-to-compressed transcoding direction.
public struct TranscodeCapability: Sendable, Equatable {
    public let source: TranscodeTarget
    public let target: TranscodeTarget
    public let preservation: TranscodePreservation
    public let profileLimits: [String]
    public let processingPaths: [TranscodeProcessingPath]

    public init(
        source: TranscodeTarget,
        target: TranscodeTarget,
        preservation: TranscodePreservation,
        profileLimits: [String],
        processingPaths: [TranscodeProcessingPath]
    ) {
        self.source = source
        self.target = target
        self.preservation = preservation
        self.profileLimits = profileLimits
        self.processingPaths = processingPaths
    }
}

/// Immutable lossless transcoding policy and structural codec options.
public struct TranscoderConfiguration: Sendable, Equatable {
    public let mode: CompressionMode
    public let codecOptions: CodecOptions

    public init(mode: CompressionMode = .lossless, codecOptions: CodecOptions = .init()) throws {
        if case .nearLossless(let bound) = mode, bound <= 0 {
            throw CodecError(.invalidArgument, "Near-lossless error must be positive.")
        }
        guard mode == .lossless else {
            throw CodecError(.unsupportedFeature, "Native transcoding requires the lossless preservation policy.")
        }
        self.mode = mode
        self.codecOptions = codecOptions
    }

    private init(lossless: Bool) {
        mode = .lossless
        codecOptions = .init()
    }
    public static let `default` = Self(lossless: true)
}

/// The common operation policies have the encode option vocabulary.
public typealias TranscodeOptions = EncodeOptions

/// Native lossless compressed-to-compressed `J2K <-> HTJ2K` transcoder.
public struct Transcoder: Sendable {
    public let configuration: TranscoderConfiguration
    public static let capabilities: [TranscodeCapability] = [
        TranscodeCapability(
            source: .jpeg2000,
            target: .htj2k,
            preservation: .exactSamples,
            profileLimits: [CodecCapabilities.sharedGreyscaleLayout],
            processingPaths: [.coefficients]
        ),
        TranscodeCapability(
            source: .htj2k,
            target: .jpeg2000,
            preservation: .exactSamples,
            profileLimits: [CodecCapabilities.sharedGreyscaleLayout],
            processingPaths: [.coefficients]
        )
    ]
    public var capabilities: [TranscodeCapability] { Self.capabilities }

    public init(configuration: TranscoderConfiguration = .default) throws {
        self.configuration = configuration
    }

    /// Transcodes a lossless JPEG 2000 Part 1 or Part 15 (HTJ2K) codestream to `target`
    /// in the wavelet coefficient domain without allocating an intermediate `Image`.
    @concurrent
    public func transcode(_ data: Data, to target: TranscodeTarget,
                          options: TranscodeOptions = .init()) async throws -> EncodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        try Task.checkCancellation()
        guard data.count <= options.resourceLimits.maximumCompressedBytes,
              data.count <= options.resourceLimits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input exceeds the admission budget.")
        }
        if case .required(.accelerated) = options.executionPolicy {
            throw CodecError(.backendUnavailable, "No accelerated backend is implemented.")
        }
        let bytes = [UInt8](data)
        options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
        let profile = try ScalarLosslessCodec.inspect(bytes, limits: options.resourceLimits)
        let (outputBytes, workspace) = try ScalarLosslessCodec.transcode(
            bytes: bytes,
            profile: profile,
            to: target,
            codecOptions: configuration.codecOptions,
            limits: options.resourceLimits,
            progress: options.progress
        )
        guard outputBytes.count <= options.resourceLimits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoded output exceeds the compressed-size limit.")
        }
        try Task.checkCancellation()
        let elapsed = clock.now - started
        let report = OperationReport(
            backend: .scalarCPU,
            fidelity: .exactSamples,
            copyEvents: [],
            pixelAllocationCount: 0,
            peakPixelBytes: 0,
            peakWorkspaceBytes: workspace,
            elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
        options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
        let outputFormat = (target == .htj2k) ? ScalarLosslessCodec.htj2kFormat : ScalarLosslessCodec.format
        return EncodedImage(
            data: Data(outputBytes),
            encoding: EncodingDescription(format: outputFormat, mode: .lossless),
            report: report
        )
    }
}
