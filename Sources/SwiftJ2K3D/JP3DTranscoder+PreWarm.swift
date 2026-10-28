// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2K3D/JP3DTranscoder+PreWarm.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation

extension JP3DTranscoder {
    /// Warms the shared acceleration runtime before the first JP3D transcode in a process.
    public static func preWarm(includeWarmupDispatch: Bool = false) async {
        await JP3DDecoder.preWarm(includeWarmupDispatch: includeWarmupDispatch)
    }
}
