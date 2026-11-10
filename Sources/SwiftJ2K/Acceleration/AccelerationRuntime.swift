// SPDX-License-Identifier: MIT
//
// Internal runtime capability detection and ExecutionPolicy resolution for
// hardware-accelerated JPEG 2000 Part 1 and HTJ2K Part 15 paths (COMMON_API
// API-07, PLATFORMS PLAT-03..PLAT-05, PERFORMANCE PERF-03, Decision M1).

import Foundation
import Synchronization

#if canImport(Metal)
import Metal
#endif

/// Internal runtime dispatcher and availability registry for accelerated backends.
package enum AccelerationRuntime {
    /// Task-local override used by tests to deterministically exercise
    /// fallback and `.backendUnavailable` paths even on hardware where
    /// Metal and SIMD/NEON acceleration are present, without leaking across
    /// concurrent test tasks.
    @TaskLocal package static var forceUnavailable: Bool = false
    /// Task-local override used by tests to simulate Metal GPU unavailability while leaving CPU SIMD active.
    @TaskLocal package static var forceMetalUnavailable: Bool = false

    /// Cached check whether a Metal GPU device is available on this host.
    /// Adapted from `J2KMetalDevice.isAvailable` (Raster-Lab/J2KSwift 7acc9ae4).
    package static let hasHardwareMetalDevice: Bool = {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }()

    /// Whether CPU vector acceleration (ARM64 NEON / x86_64 SIMD / Accelerate)
    /// is compiled into this target.
    package static var hasHardwareSIMD: Bool {
        #if arch(arm64) || arch(x86_64) || canImport(Accelerate)
        return true
        #else
        return false
        #endif
    }

    /// Whether Metal hardware is present and not simulated as unavailable.
    package static var isMetalDevicePermitted: Bool {
        guard !isSimulatedUnavailable && !forceMetalUnavailable else { return false }
        return hasHardwareMetalDevice
    }

    /// Whether Metal GPU compute acceleration is currently available.
    package static var isMetalAvailable: Bool {
        guard isMetalDevicePermitted else { return false }
        return MetalAccelerationEngine.shared.isAvailable
    }

    /// Whether NEON / SIMD vector acceleration is currently available.
    package static var isSIMDAvailable: Bool {
        guard !isSimulatedUnavailable else { return false }
        return hasHardwareSIMD
    }

    /// Whether the `.accelerated` backend is available on the current runtime.
    package static var isAvailable: Bool {
        isSIMDAvailable || isMetalAvailable
    }

    private static var isSimulatedUnavailable: Bool {
        forceUnavailable
    }

    /// Backends advertised by `Encoder.capabilities` and `Decoder.capabilities`.
    package static var availableBackends: [Backend] {
        isAvailable ? [.scalarCPU, .accelerated] : [.scalarCPU]
    }

    /// Concrete engine routing mode resolved for an operation.
    package enum EngineMode: Sendable, Equatable {
        case none
        case automatic
        case cpuSIMD
        case metalGPU
    }

    /// Result of resolving an `ExecutionPolicy` and `AcceleratedEnginePreference` for an operation.
    package struct ResolvedExecution: Sendable, Equatable {
        package let backend: Backend
        package let engineMode: EngineMode
        package let fallbackReason: String?

        package init(backend: Backend, engineMode: EngineMode = .none, fallbackReason: String?) {
            self.backend = backend
            self.engineMode = engineMode
            self.fallbackReason = fallbackReason
        }
    }

    /// Resolves `policy` and `enginePreference` against current runtime availability per `API-07` and `PLAT-05`.
    /// - Throws: `CodecError(.backendUnavailable, ...)` when `.required(.accelerated)`
    ///   (or a required concrete accelerated engine) is requested and unavailable.
    package static func resolve(
        _ policy: ExecutionPolicy,
        enginePreference: AcceleratedEnginePreference = .automatic
    ) throws -> ResolvedExecution {
        switch policy {
        case .scalarCPU, .preferred(.scalarCPU), .required(.scalarCPU):
            return ResolvedExecution(backend: .scalarCPU, engineMode: .none, fallbackReason: nil)

        case .automatic:
            switch enginePreference {
            case .automatic:
                if isAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .automatic, fallbackReason: nil)
                }
                return ResolvedExecution(backend: .scalarCPU, engineMode: .none, fallbackReason: nil)
            case .cpuSIMD:
                if isSIMDAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .cpuSIMD, fallbackReason: nil)
                }
                if isMetalAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .metalGPU, fallbackReason: nil)
                }
                return ResolvedExecution(backend: .scalarCPU, engineMode: .none, fallbackReason: nil)
            case .metalGPU:
                if isMetalAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .metalGPU, fallbackReason: nil)
                }
                if isSIMDAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .cpuSIMD, fallbackReason: nil)
                }
                return ResolvedExecution(backend: .scalarCPU, engineMode: .none, fallbackReason: nil)
            }

        case .preferred(.accelerated):
            switch enginePreference {
            case .automatic:
                if isAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .automatic, fallbackReason: nil)
                }
                return ResolvedExecution(
                    backend: .scalarCPU,
                    engineMode: .none,
                    fallbackReason: "Accelerated backend is unavailable on this runtime; fell back to scalarCPU."
                )
            case .cpuSIMD:
                if isSIMDAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .cpuSIMD, fallbackReason: nil)
                }
                if isMetalAvailable {
                    return ResolvedExecution(
                        backend: .accelerated,
                        engineMode: .metalGPU,
                        fallbackReason: "CPU SIMD engine is unavailable on this runtime; fell back to Metal GPU."
                    )
                }
                return ResolvedExecution(
                    backend: .scalarCPU,
                    engineMode: .none,
                    fallbackReason: "Accelerated backend is unavailable on this runtime; fell back to scalarCPU."
                )
            case .metalGPU:
                if isMetalAvailable {
                    return ResolvedExecution(backend: .accelerated, engineMode: .metalGPU, fallbackReason: nil)
                }
                if isSIMDAvailable {
                    return ResolvedExecution(
                        backend: .accelerated,
                        engineMode: .cpuSIMD,
                        fallbackReason: "Metal GPU engine is unavailable on this runtime; fell back to CPU SIMD."
                    )
                }
                return ResolvedExecution(
                    backend: .scalarCPU,
                    engineMode: .none,
                    fallbackReason: "Accelerated backend is unavailable on this runtime; fell back to scalarCPU."
                )
            }

        case .required(.accelerated):
            switch enginePreference {
            case .automatic:
                guard isAvailable else {
                    throw CodecError(.backendUnavailable, "No accelerated backend is available on this platform or device.")
                }
                return ResolvedExecution(backend: .accelerated, engineMode: .automatic, fallbackReason: nil)
            case .cpuSIMD:
                guard isSIMDAvailable else {
                    throw CodecError(.backendUnavailable, "CPU SIMD acceleration engine is unavailable on this platform or device.")
                }
                return ResolvedExecution(backend: .accelerated, engineMode: .cpuSIMD, fallbackReason: nil)
            case .metalGPU:
                guard isMetalAvailable else {
                    throw CodecError(.backendUnavailable, "Metal GPU acceleration engine is unavailable on this platform or device.")
                }
                return ResolvedExecution(backend: .accelerated, engineMode: .metalGPU, fallbackReason: nil)
            }
        }
    }

    /// Runs `body` with hardware acceleration simulated as unavailable on the current task.
    package static func withSimulatedUnavailable<R>(_ body: () throws -> R) rethrows -> R {
        try $forceUnavailable.withValue(true, operation: body)
    }

    /// Runs async `body` with hardware acceleration simulated as unavailable on the current task.
    package static func withSimulatedUnavailable<R>(_ body: () async throws -> R) async rethrows -> R {
        try await $forceUnavailable.withValue(true) {
            try await body()
        }
    }

    /// Runs `body` with Metal GPU simulated as unavailable while CPU SIMD remains available.
    package static func withSimulatedMetalUnavailable<R>(_ body: () throws -> R) rethrows -> R {
        try $forceMetalUnavailable.withValue(true, operation: body)
    }

    /// Runs async `body` with Metal GPU simulated as unavailable while CPU SIMD remains available.
    package static func withSimulatedMetalUnavailable<R>(_ body: () async throws -> R) async rethrows -> R {
        try await $forceMetalUnavailable.withValue(true) {
            try await body()
        }
    }
}
