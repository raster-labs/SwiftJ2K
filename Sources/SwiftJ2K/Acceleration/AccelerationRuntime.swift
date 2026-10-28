// SPDX-License-Identifier: Apache-2.0
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
enum AccelerationRuntime {
    /// Task-local override used by tests to deterministically exercise
    /// fallback and `.backendUnavailable` paths even on hardware where
    /// Metal and SIMD/NEON acceleration are present, without leaking across
    /// concurrent test tasks.
    @TaskLocal static var forceUnavailable: Bool = false

    /// Cached check whether a Metal GPU device is available on this host.
    /// Adapted from `J2KMetalDevice.isAvailable` (Raster-Lab/J2KSwift 7acc9ae4).
    static let hasHardwareMetalDevice: Bool = {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }()

    /// Whether CPU vector acceleration (ARM64 NEON / x86_64 SIMD / Accelerate)
    /// is compiled into this target.
    static var hasHardwareSIMD: Bool {
        #if arch(arm64) || arch(x86_64) || canImport(Accelerate)
        return true
        #else
        return false
        #endif
    }

    /// Whether Metal hardware is present and not simulated as unavailable.
    static var isMetalDevicePermitted: Bool {
        guard !isSimulatedUnavailable else { return false }
        return hasHardwareMetalDevice
    }

    /// Whether Metal GPU compute acceleration is currently available.
    static var isMetalAvailable: Bool {
        guard isMetalDevicePermitted else { return false }
        return MetalAccelerationEngine.shared.isAvailable
    }

    /// Whether NEON / SIMD vector acceleration is currently available.
    static var isSIMDAvailable: Bool {
        guard !isSimulatedUnavailable else { return false }
        return hasHardwareSIMD
    }

    /// Whether the `.accelerated` backend is available on the current runtime.
    static var isAvailable: Bool {
        guard !isSimulatedUnavailable else { return false }
        return hasHardwareSIMD || hasHardwareMetalDevice
    }

    private static var isSimulatedUnavailable: Bool {
        forceUnavailable
    }

    /// Backends advertised by `Encoder.capabilities` and `Decoder.capabilities`.
    static var availableBackends: [Backend] {
        isAvailable ? [.scalarCPU, .accelerated] : [.scalarCPU]
    }

    /// Result of resolving an `ExecutionPolicy` for an operation.
    struct ResolvedExecution: Sendable, Equatable {
        let backend: Backend
        let fallbackReason: String?
    }

    /// Resolves `policy` against current runtime availability per `API-07` and `PLAT-05`.
    /// - Throws: `CodecError(.backendUnavailable, ...)` when `.required(.accelerated)`
    ///   is requested and no accelerated backend is available.
    static func resolve(_ policy: ExecutionPolicy) throws -> ResolvedExecution {
        switch policy {
        case .scalarCPU, .preferred(.scalarCPU), .required(.scalarCPU):
            return ResolvedExecution(backend: .scalarCPU, fallbackReason: nil)
        case .automatic:
            if isAvailable {
                return ResolvedExecution(backend: .accelerated, fallbackReason: nil)
            }
            return ResolvedExecution(backend: .scalarCPU, fallbackReason: nil)
        case .preferred(.accelerated):
            if isAvailable {
                return ResolvedExecution(backend: .accelerated, fallbackReason: nil)
            }
            return ResolvedExecution(
                backend: .scalarCPU,
                fallbackReason: "Accelerated backend is unavailable on this runtime; fell back to scalarCPU."
            )
        case .required(.accelerated):
            guard isAvailable else {
                throw CodecError(.backendUnavailable, "No accelerated backend is available on this platform or device.")
            }
            return ResolvedExecution(backend: .accelerated, fallbackReason: nil)
        }
    }

    /// Runs `body` with hardware acceleration simulated as unavailable on the current task.
    static func withSimulatedUnavailable<R>(_ body: () throws -> R) rethrows -> R {
        try $forceUnavailable.withValue(true, operation: body)
    }

    /// Runs async `body` with hardware acceleration simulated as unavailable on the current task.
    static func withSimulatedUnavailable<R>(_ body: () async throws -> R) async rethrows -> R {
        try await $forceUnavailable.withValue(true) {
            try await body()
        }
    }
}
