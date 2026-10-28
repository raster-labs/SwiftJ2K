// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DEncoder+ProgressStream.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation

extension JP3DEncoder {
    /// Returns an `AsyncStream` that yields the same `JP3DEncoderProgress`
    /// values that would otherwise be delivered to ``setProgressCallback(_:)``.
    public func progressStream() async -> AsyncStream<JP3DEncoderProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: JP3DEncoderProgress.self)
        self.setProgressCallback { progress in
            continuation.yield(progress)
        }
        return stream
    }
}
