// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DStreamWriter+ProgressStream.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation

extension JP3DStreamWriter {
    /// Returns an `AsyncStream` that yields the same `JP3DStreamProgress`
    /// values that would otherwise be delivered to ``setProgressCallback(_:)``.
    public func progressStream() async -> AsyncStream<JP3DStreamProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: JP3DStreamProgress.self)
        self.setProgressCallback { progress in
            continuation.yield(progress)
        }
        return stream
    }
}
