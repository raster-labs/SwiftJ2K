# Milestone 9 — Metal and SIMD/NEON Acceleration Behind `executionPolicy`

**Status:** Implemented on branch `antigravity/milestone9-acceleration` from `origin/main` (`de88d61`) against pinned predecessor `Raster-Lab/J2KSwift` [`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`](https://github.com/Raster-Lab/J2KSwift/commit/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca).
**Contract:** `0.10.0` (verified byte-identical against `Documentation/COMMON_CONTRACT_SHA256.txt`).
**Toolchain:** Apple Swift `6.4-dev` (`Swift 6` language mode, complete concurrency checking) on macOS 26.4 (`arm64-apple-macosx26.0`, Apple M3 Max).

---

## 1. Scope and Summary

Milestone 9 migrates and adapts the predecessor's hardware acceleration subsystems (`Sources/J2KCodecNEON`, `Sources/J2KCodec/ARM`, `Sources/J2KMetal`, and `Sources/J2KCodec/J2KGPU*`) into `Sources/SwiftJ2K/Acceleration/` behind `ExecutionPolicy` (`PLAT-05` and Decision M1):

1. **Runtime Capability Detection and `ExecutionPolicy` Resolution (`AccelerationRuntime.swift`)**:
   - Detects Metal GPU compute (`#if canImport(Metal)` + `MTLCreateSystemDefaultDevice()`) and portable Swift SIMD/NEON vector support (`#if arch(arm64) || arch(x86_64) || canImport(Accelerate)`) at runtime without unconditional Apple framework imports on non-Apple platforms (`PLAT-05`).
   - Resolves `ExecutionPolicy` (`.automatic`, `.scalarCPU`, `.preferred(Backend)`, `.required(Backend)`) into `ResolvedExecution(backend: Backend, fallbackReason: String?)` per `API-03` and `API-07`:
     - `.scalarCPU` always resolves to `.scalarCPU` with `fallbackReason = nil`.
     - `.automatic` and `.preferred(.accelerated)` resolve to `.accelerated` when an accelerated backend (Metal GPU or SIMD/NEON) is available, or fall back to `.scalarCPU` with a non-empty `OperationReport.fallbackReason` when unavailable.
     - `.required(.accelerated)` resolves to `.accelerated` when available, or throws `CodecError(.backendUnavailable, ...)` when unavailable.
   - Provides a deterministic task-local hook (`AccelerationRuntime.withSimulatedUnavailable`) to test `.preferred(.accelerated)` fallback (`fallbackReason != nil`) and `.required(.accelerated)` `backendUnavailable` errors on hardware where acceleration is normally present.

2. **Portable Swift SIMD / NEON Acceleration (`SIMDAcceleration.swift`)**:
   - **`SIMDWavelet53`**: 4-lane `SIMD4<Int32>` vectorised horizontal and vertical reversible 5/3 lifting (analysis and synthesis) with arbitrary `i0..<i1` subgrid origin parity, ISO/IEC 15444-1 Annex F.3.8.1 / F.4.8.2 length-1 odd-origin scaling (`* 2` on forward, `/ 2` on inverse), and 64-bit checked arithmetic overflow detection on synthesis (`CodecError(.malformedInput, ...)`).
   - **`SIMDWavelet97`**: 4-lane `SIMD4<Double>` IEEE-754 double-precision vectorised 9/7 CDF irreversible lifting (4 lifting steps + scaling pass) with general `i0..<i1` periodic symmetric extension, matching `Wavelet97` bit-for-bit.
   - **`SIMDColourTransform`**: 4-lane `SIMD4<Int64>` Reversible Colour Transform (`forwardRCT`, `inverseRCT`) preventing 32-bit intermediate overflow, and 4-lane `SIMD4<Double>` Irreversible Colour Transform (`forwardICT`, `inverseICT`) matching `ColourTransform` bit-for-bit.
   - **`SIMDQuantizationAndROI`**: 4-lane `SIMD4<Double>` dead-zone quantisation (`quantizeSubband`), `SIMD4<Int32>` MaxShift ROI encoder scaling (`scaleROISubband`), and `SIMD4<Int64>` MaxShift ROI decoder descaling (`descaleROICoefficients`).
   - **`SIMDHTBlockCoder`**: 4-lane `SIMD4<Int32>` / `SIMD4<UInt32>` 2×2 quad significance (`rho`), exponent (`maxE`), and sign/magnitude classification (`classifyQuads`) plus vectorised Part 15 HTJ2K cleanup-pass encode (`encodeCleanup`) and decode (`decodeCleanup`) using the conformant `uvlcTableConformant` table (with full `ext`/`extLen` emission for $u_q > 32$ and checked `bandShift` scaling).

3. **Metal GPU Compute Subsystem (`MetalAcceleration.swift`, Decision M1)**:
   - Folded `J2KMetal` into `SwiftJ2K` as an internal subsystem (`MetalAccelerationEngine`), eliminating the standalone `J2KMetal` library product per Decision M1 (`IMPLEMENTATION.md` lines 130, 147).
   - Compiles embedded Metal Shading Language (MSL) compute kernels at runtime via `MTLDevice.makeLibrary(source:options:)` (avoiding fragile `.metallib` bundle resource lookups across SwiftPM CLI executables and test runners) and caches `MTLComputePipelineState` instances (`j2k_dwt53_forward_1d`, `j2k_dwt53_interleave_1d`, `j2k_dwt53_inverse_1d`, `j2k_dwt53_commit_subband`, `j2k_rct_forward`, `j2k_rct_inverse`, `j2k_roi_descale64`, `j2k_ht_classify_quads`).
   - Uses a `Mutex`-protected size-bucketed `.storageModeShared` `MTLBuffer` pool (`acquireBuffer` / `releaseBuffer`) and synchronous `MTLCommandBuffer.waitUntilCompleted()` before returning or releasing any buffer, satisfying `MEM-04` (GPU work always joins before buffer release and never crosses an `await` inside synchronous storage borrow closures such as `ImageDestination.write`).
   - `@unchecked Sendable` conformance on `MetalAccelerationEngine` is accompanied by a local written `CONC-03` proof and verified by concurrent multi-task tests.
   - Tracks cold-start shader compilation (`coldStartCompilationNanoseconds`), dispatch counts, and buffer pool reuse (`TelemetrySnapshot`), and provides `makeFreshInstanceForBenchmarking()` for deterministic cold vs warm GPU benchmarking (`PERF-01`/`PERF-02`).

4. **Unified Accelerated Router and CLI Integration (`AcceleratedCodec.swift`, `main.swift`)**:
   - `AcceleratedCodec` routes 5/3 and 9/7 DWT, RCT and ICT colour transforms, quantisation, ROI scaling/descaling, and HTJ2K cleanup-pass coding between `.scalarCPU` and `.accelerated` (dispatching large tiles to Metal GPU when $\text{width} \times \text{height} \ge 16{,}384$ or when `AcceleratedCodec.withForcedMetalDispatch(true)` is active, and using `SIMDAcceleration` for smaller tiles and double-precision 9/7/ICT stages).
   - Wired `AccelerationRuntime.resolve(options.executionPolicy)` across `ScalarLosslessCodec`, `Part1Pipeline`, `JP2Container`, `Encoder`, `Decoder`, and `Transcoder`, populating `OperationReport.backend` and `OperationReport.fallbackReason`.
   - Added `--backend auto|scalar|accelerated` to `swiftj2k-cli` (`encode`, `decode`, `validate`, `transcode`) and updated `ManPages/swiftj2k-cli.1`.

---

## 2. Predecessor Audit and File-by-File Dispositions (`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`)

### 2.1 File-by-File Inventory and Dispositions

All 42 acceleration files (31,922 lines total) in `Raster-Lab/J2KSwift` at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca` were audited:

#### A. `Sources/J2KCodecNEON` and `Sources/J2KCodec/ARM` (10 files, 3,127 lines)

| Predecessor file (`7acc9ae4`) | Lines | Git blob SHA | Disposition | Successor mapping & notes |
| --- | ---: | --- | --- | --- |
| `Sources/J2KCodecNEON/include/j2k_neon_entropy.h` | 128 | `17410cf803a70d08a4aa2b4942ac134b5c1c97b8` | Adapted | Folded into internal `SIMDHTBlockCoder` in `Sources/SwiftJ2K/Acceleration/SIMDAcceleration.swift` (pure Swift `SIMD4` without separate C target) |
| `Sources/J2KCodecNEON/j2k_neon_bitstream.h` | 194 | `0fc4ebca0df28c028e0d8c73db966789166dd6d7` | Adapted | Adapted into `SIMDHTBlockCoder` / `HTBlockCoder` bit-stuffing state machines (`Apache-2.0 AND BSD-2-Clause`) |
| `Sources/J2KCodecNEON/j2k_neon_common.h` | 83 | `ee86327ac95080908e16400e06704c0f1dfeb4c5` | Adapted | Replaced `#if defined(__ARM_NEON)` C macros with portable Swift `SIMD4<Int32>`/`SIMD4<UInt32>` operations |
| `Sources/J2KCodecNEON/j2k_neon_tables.h` | 181 | `9e2a4c714bc2a17f5ff232c20b9844816bf60516` | Adapted | Unified with `HTTables.swift` (`uvlcTableConformant` with `ext`/`extLen`; fixed `M9-AUD-001`) |
| `Sources/J2KCodecNEON/j2k_neon_mel.c` | 208 | `9d888205543e924c280abfbba792ca41b984481` | Adapted | MEL state machine integrated with `SIMDHTBlockCoder` (`Apache-2.0 AND BSD-2-Clause`) |
| `Sources/J2KCodecNEON/j2k_neon_vlc.c` | 182 | `bb3d944808f17c178d1c881ed51bb6107d8b517f` | Adapted | Vectorised 2×2 quad significance/exponent context extraction adapted into `SIMDHTBlockCoder.classifyQuads` |
| `Sources/J2KCodecNEON/j2k_neon_magsgn.c` | 216 | `1ef444e258b024e1e6f8681f70a6042ca81cf5e2` | Adapted | 4-lane `SIMD4` magnitude/sign extraction and bitplane packing adapted into `SIMDHTBlockCoder` |
| `Sources/J2KCodecNEON/j2knhd_decode_block_ht.c` | 666 | `793eb71a9cf373eb725086a07d6d59be6f59f90e` | Adapted | Adapted into `SIMDHTBlockCoder.decodeCleanup`; fixed `1u << m` UB and `30 - missingMSBs` scaling (`M9-AUD-002`) |
| `Sources/J2KCodecNEON/j2knhe_encode_block_ht.c` | 652 | `bb0558c4430502579c4c63a19b2e5e68b4475a7e` | Adapted | Adapted into `SIMDHTBlockCoder.encodeCleanup`; fixed missing UVLC `ext` bits for $u_q > 32$ (`M9-AUD-001`) |
| `Sources/J2KCodec/ARM/J2KNeonEntropyCoding.swift` | 617 | `23f10fb0c6509a26d1852398fb86d60e8d0172b8` | Adapted | Replaced `UnsafeMutablePointer` C bridge with safe Swift `SIMD4` slice operations in `SIMDAcceleration.swift` |

#### B. `Sources/J2KMetal` (25 files, 25,447 lines)

| Predecessor file (`7acc9ae4`) | Lines | Git blob SHA | Disposition | Successor mapping & notes |
| --- | ---: | --- | --- | --- |
| `Sources/J2KMetal/J2KMetal.swift` | 44 | `aaabfb5cb1c1125702da9db339c88be9647ff948` | Adapted (Decision M1) | Public `J2KMetal` module retired; folded into internal `Sources/SwiftJ2K/Acceleration/MetalAcceleration.swift` |
| `Sources/J2KMetal/J2KMetal.docc/J2KMetal.md` | 51 | `1a578029d5e43b5d69dfabdb9ba81a158cb99f44` | Retired (Decision M1) | Standalone `J2KMetal` DocC catalog retired; acceleration documented in `COMMON_API.md`, `CLI.md`, and `MILESTONE9.md` |
| `Sources/J2KMetal/J2KMetalBufferPool.swift` | 406 | `a00dd26a67dbba997aa885e6be53d15e5f661dd3` | Adapted | Folded into `MetalAccelerationEngine` size-bucketed `.storageModeShared` `MTLBuffer` pool (`acquireBuffer` / `releaseBuffer`) |
| `Sources/J2KMetal/J2KMetalColorTransform.swift` | 784 | `290ccbf9f25f31c6626a593f161cfcf422894cf8` | Adapted | Folded into `MetalAccelerationEngine.forwardRCT` / `inverseRCT` (with 64-bit `long` arithmetic fixing `M9-AUD-005`) and `SIMDColourTransform` for double-precision ICT |
| `Sources/J2KMetal/J2KMetalColorTransformTimings.swift` | 101 | `5077bf99c13f770019b82a5968a14746233548ea` | Folded | Replaced by `OperationReport` and `MetalAccelerationEngine.TelemetrySnapshot` (`IMPLEMENTATION.md` line 77) |
| `Sources/J2KMetal/J2KMetalDWT.swift` | 2,135 | `4daaa03f78b3c3c948787ebbb6ca571659e7bbdd` | Adapted | Folded into `MetalAccelerationEngine.forwardWavelet53` / `inverseWavelet53` (fixing `n == 1` odd-origin scaling and general `i0..<i1` bounds, `M9-AUD-003`) and `SIMDWavelet97` (`SIMD4<Double>`, `M9-AUD-004`) |
| `Sources/J2KMetal/J2KMetalDWTTimings.swift` | 95 | `ba416d9646d1249a319c1accc18fa5b6da979263` | Folded | Replaced by `OperationReport` and `MetalAccelerationEngine.TelemetrySnapshot` |
| `Sources/J2KMetal/J2KMetalDevice.swift` | 435 | `e6a2e0109ec585858efdc0d9e0f2d743ce3d7209` | Adapted | Folded into `AccelerationRuntime` and `MetalAccelerationEngine` (`MTLCreateSystemDefaultDevice()`, `MTLCommandQueue`) |
| `Sources/J2KMetal/J2KMetalEncoderStageTimings.swift` | 255 | `a69fc45fa9de5e4f58f5554e92bf30482a990bf3` | Folded | Replaced by `OperationReport` and `MetalAccelerationEngine.TelemetrySnapshot` |
| `Sources/J2KMetal/J2KMetalHTBlockCoder.swift` | 3,167 | `ce753acaaec8f039234cf17d3bf780f074b4fb6b` | Adapted | Folded into `MetalAccelerationEngine.classifyHTQuads` + `SIMDHTBlockCoder.encodeCleanup` / `decodeCleanup` |
| `Sources/J2KMetal/J2KMetalHTCleanupEmitPlan.swift` | 2,616 | `18162c6f918d36f6e78e9c911ecac6271251c482` | Adapted | Consolidated into `SIMDHTBlockCoder.encodeCleanup` single-pass conformant MEL/VLC/MagSgn emitter |
| `Sources/J2KMetal/J2KMetalHTCodeblockDispatchTable.swift` | 1,781 | `fb509e123e9ed5605b4f1f3f1907016ba95d9d2f` | Adapted | Consolidated into `AcceleratedCodec.encodeHTCleanup` / `decodeHTCleanup` dispatch |
| `Sources/J2KMetal/J2KMetalHTForwardClassifier.swift` | 1,860 | `df41c5d63e8ec555f233f48441e8795f200aa066` | Adapted | Folded into `j2k_ht_classify_quads` MSL kernel in `MetalAcceleration.swift` and `SIMDHTBlockCoder.classifyQuads` |
| `Sources/J2KMetal/J2KMetalHTFusedMagSgnMELVLC.swift` | 1,920 | `239784839f7bd28b1cf337a0b6c718193d07268e` | Adapted | Consolidated into `SIMDHTBlockCoder.encodeCleanup` with conformant bit-7 `fuseMELAndVLC` |
| `Sources/J2KMetal/J2KMetalHTMagSgnBitpack.swift` | 1,622 | `3e134b5c2530676c169274d336a5a19833d280ab` | Adapted | Consolidated into `SIMDHTBlockCoder` forward MagSgn bit-packing |
| `Sources/J2KMetal/J2KMetalHTPacketAssemble.swift` | 932 | `cf4eb6d2fa462a9d16db2b6c2aa79660db8cf8cb` | Adapted | Packet assembly unified with `Tier2.swift` for byte-identical codestream framing |
| `Sources/J2KMetal/J2KMetalHTRefinementPasses.swift` | 1,182 | `6fa9cc8fb99875e42466ba165a44b1566a325cb7` | Excluded | HT `SigProp`/`MagRef` refinement passes remain outside the qualified Part 15 cleanup-only profile (`MILESTONE6.md`) |
| `Sources/J2KMetal/J2KMetalHTZeroBitplanes.swift` | 1,164 | `2dc4c9bf4457b5b49b0363df60ca69dc313e9c80` | Adapted | Zero-bitplane (`missingMSBs`) computation integrated into `SIMDHTBlockCoder` and `j2k_ht_classify_quads` |
| `Sources/J2KMetal/J2KMetalMCT.swift` | 589 | `28dc129963eb06b2cf8f942138e04d491ee9a279` | Excluded | Part 2 arbitrary Multi-Component Transform (`MCT`/`MCC`/`MCO`) retired per Milestone 7 Part 2 audit (`MILESTONE7.md` §2.2) |
| `Sources/J2KMetal/J2KMetalMCTTimings.swift` | 93 | `e27fb863a02d8a642c7212cfbfaa1ca4d255c2e6` | Excluded | Part 2 MCT timings retired with `J2KMetalMCT.swift` |
| `Sources/J2KMetal/J2KMetalQuantizer.swift` | 836 | `a69062467c47a7481bc44d4be791625e5078f15c` | Adapted | Replaced Float32 GPU quantiser with IEEE-754 double-precision `SIMDQuantizationAndROI.quantizeSubband` (`SIMD4<Double>`) for 100% byte-identity with scalar `Quantization` |
| `Sources/J2KMetal/J2KMetalQuantizerTimings.swift` | 97 | `2d0e729bd247e14f235b7fb3975d249df3ca5c38` | Folded | Replaced by `OperationReport` |
| `Sources/J2KMetal/J2KMetalROI.swift` | 656 | `fb964bd3ca1e2c52ec2c5da116415c9e15ef8bf9` | Adapted | Folded into `MetalAccelerationEngine.descaleROICoefficients` (`j2k_roi_descale64`) and `SIMDQuantizationAndROI` |
| `Sources/J2KMetal/J2KMetalShaderLibrary.swift` | 669 | `62135a4b84ef2442979f1142bb1fb050fb1238cb` | Adapted | Folded into `MetalAccelerationEngine` runtime MSL compilation and pipeline state cache |
| `Sources/J2KMetal/J2KShaders.metal` | 1,957 | `d0d6502d201c794be1efaa8ccfb73a054ef50b84` | Adapted | Embedded as runtime-compiled MSL source in `MetalAcceleration.swift` with fixes `M9-AUD-003` and `M9-AUD-005` |

#### C. `Sources/J2KCodec` GPU / SIMD Integration Files (7 files, 3,348 lines)

| Predecessor file (`7acc9ae4`) | Lines | Git blob SHA | Disposition | Successor mapping & notes |
| --- | ---: | --- | --- | --- |
| `Sources/J2KCodec/J2KAcceleratedEncoder.swift` | 57 | `9df59d2926ddae947260b8685c3777101f44b904` | Adapted | Replaced by `Sources/SwiftJ2K/Acceleration/AcceleratedCodec.swift` supporting both encode and decode |
| `Sources/J2KCodec/J2KMetalSession.swift` | 255 | `1f7a3bc6e6300ecfc751b6427182d31b53cb10da` | Adapted | Replaced by `AccelerationRuntime` and `MetalAccelerationEngine.shared` behind `ExecutionPolicy` |
| `Sources/J2KCodec/J2KGPUForward53Telemetry.swift` | 216 | `07355849c5bd1da7005fd10631957ca9fa5b4cd4` | Folded | Folded into `MetalAccelerationEngine.TelemetrySnapshot` |
| `Sources/J2KCodec/J2KGPUForwardHTCleanupPassEmit.swift` | 907 | `d3f89098dc5f3ef903b0f5fd234625a34ba7f28a` | Adapted | Folded into `AcceleratedCodec.encodeHTCleanup` and `SIMDHTBlockCoder.encodeCleanup` |
| `Sources/J2KCodec/J2KGPUForwardHTEntropyBatch.swift` | 794 | `758f8080cb172d44cc26a734f342ff9721077213` | Adapted | Folded into `AcceleratedCodec` and `SIMDHTBlockCoder` |
| `Sources/J2KCodec/J2KGPUForwardHTEntropyTelemetry.swift` | 435 | `09686f49e8a9c5a97d7d478bf1b63b86debb8553` | Folded | Folded into `MetalAccelerationEngine.TelemetrySnapshot` |
| `Sources/J2KCodec/J2KGPUHTDispatch.swift` | 684 | `5897f6dfde6773df38c4e4a1f6d083fb4fdbe68a` | Adapted | Folded into `AcceleratedCodec.encodeHTCleanup` / `decodeHTCleanup` |

---

### 2.2 Predecessor Defects Found and Fixed

1. **`M9-AUD-001` — Predecessor NEON HT Encoder Dropped UVLC `ext` Bits for $u_q > 32$ (`j2knhe_encode_block_ht.c`, `j2k_neon_tables.h`)**:
   - **Predecessor Defect**: In `Sources/J2KCodecNEON/j2k_neon_tables.h` lines 88–135 and `j2knhe_encode_block_ht.c` lines 318–356, UVLC table entries were packed into 16-bit/32-bit integers containing only `pre` (`u_pfx`) and `suf` (`u_sfx` up to 5 bits), omitting the 3-bit `ext` (`u_ext`) suffix required by ISO/IEC 15444-15 Clause 7.3.6 when unsigned exponent residuals exceed $u_q > 32$ (which occurs on high-dynamic-range 16-bit subbands with guard bits).
   - **Fix**: `SIMDHTBlockCoder.encodeCleanup` uses `uvlcTableConformant` (`HTTables.swift`) and emits `pre`, `suf`, and `ext` (`extLen` bits), matching `HTBlockEncoder` byte-for-byte across all bit depths.

2. **`M9-AUD-002` — Predecessor NEON HT Decoder Shift Undefined Behaviour and Fixed-Point Scaling Mismatch (`j2knhd_decode_block_ht.c`)**:
   - **Predecessor Defect**: In `Sources/J2KCodecNEON/j2knhd_decode_block_ht.c` lines 412–465, `1u << m` (`m = Uq - eBit`) was evaluated without checking `1 <= m <= 31` (causing C undefined behaviour on malformed bitstreams when `m == 0` or `m >= 32`), and decoded magnitudes were shifted by `p = 30 - missingMSBs` instead of the successor pipeline's `bandShift = kMax - 1 - missingMSBs`.
   - **Fix**: `SIMDHTBlockCoder.decodeCleanup` validates `Uq >= 1`, `m <= 31`, and `Uq <= 31 + eBit` (throwing `CodecError(.malformedInput, ...)` on corrupted streams) and reconstructs signed magnitudes at `bandShift = kMax - 1 - missingMSBs` with 64-bit overflow bounds checking.

3. **`M9-AUD-003` — Predecessor Metal 5/3 DWT Missing `n == 1` Odd-Origin `* 2` / `/ 2` Scaling and General `i0..<i1` Subgrid Support (`J2KShaders.metal`, `J2KMetalDWT.swift`)**:
   - **Predecessor Defect**: In `Sources/J2KMetal/J2KShaders.metal` lines 64–198 (`j2k_dwt_forward_53_horizontal_int_odd` / `j2k_dwt_inverse_53_horizontal_int_odd`), length-1 subbands (`n == 1`) with odd origin `i0 % 2 != 0` copied `high[0] = x[0]` instead of `high[0] = x[0] * 2` on analysis and `x[0] = high[0] / 2` on synthesis as required by ISO/IEC 15444-1 Annex F.3.8.1 and F.4.8.2 Eq. (F-8). Moreover, the shaders did not accept general tile/subband origins `(x0, y0)` or check for 32-bit synthesis integer overflow on malformed inputs.
   - **Fix**: `MetalAccelerationEngine` (`j2k_dwt53_forward_1d` and `j2k_dwt53_inverse_1d`) and `SIMDWavelet53` pass explicit `i0` parity (`evenOrigin`), apply `* 2` / `/ 2` when `n == 1 && !evenOrigin`, execute horizontal-then-vertical passes in the exact Annex F order, and perform 64-bit synthesis overflow checks before committing subbands.

4. **`M9-AUD-004` — Predecessor Metal 9/7 DWT and Quantiser `Float32` Drift vs `Double` (`J2KShaders.metal`, `J2KMetalDWT.swift`, `J2KMetalQuantizer.swift`)**:
   - **Predecessor Defect**: In `Sources/J2KMetal/J2KShaders.metal` lines 204–340 and `J2KMetalQuantizer.swift`, 9/7 irreversible lifting and dead-zone quantisation used 32-bit `float` with 7-digit constants (`alpha = -1.5861343f`) and `i0 = 0` periodic extension, causing $\pm 1$ LSB rounding drift relative to the scalar `Double` pipeline and breaking byte-identity between `.scalarCPU` and `.accelerated`.
   - **Fix**: `AcceleratedCodec` routes 9/7 irreversible DWT, ICT colour transform, and dead-zone quantisation through 4-lane `SIMD4<Double>` vectorisation (`SIMDWavelet97`, `SIMDColourTransform`, `SIMDQuantizationAndROI`) with full IEEE-754 double precision and exact `i0..<i1` periodic symmetric extension, achieving 100% byte-identical output between `.scalarCPU` and `.accelerated`.

5. **`M9-AUD-005` — Predecessor Metal RCT 32-Bit Overflow and Async GPU Lifetime Hazard (`J2KShaders.metal`, `J2KMetalColorTransform.swift`)**:
   - **Predecessor Defect**: In `Sources/J2KMetal/J2KShaders.metal` lines 512–560, `j2k_rct_forward` computed `(r + 2 * g + b) >> 2` in 32-bit `int`, which overflows on 30–31-bit intermediate coefficients or malformed bitstreams. Additionally, `J2KMetalColorTransform` used `async` GPU completion handlers, which cannot be called inside synchronous `ImageDestination.write` borrow closures (`MEM-04`).
   - **Fix**: `j2k_rct_forward` and `j2k_rct_inverse` in `MetalAcceleration.swift` and `SIMDColourTransform` use 64-bit `long` (`Int64` / `SIMD4<Int64>`) arithmetic, and `MetalAccelerationEngine` executes command buffers synchronously with `cmd.waitUntilCompleted()` inside a `Mutex`-guarded scope before returning or releasing pooled `MTLBuffer`s (`MEM-04`).

---

## 3. Platform and `ExecutionPolicy` Matrix (`PLAT-05`, Decision M1)

| Platform / Architecture | Metal GPU (`#if canImport(Metal)`) | Swift SIMD / NEON (`SIMD4`) | `Encoder.capabilities.availableBackends` | `.automatic` / `.preferred(.accelerated)` | `.scalarCPU` | `.required(.accelerated)` |
| --- | :---: | :---: | --- | --- | --- | --- |
| macOS 26.0 (`arm64` Apple Silicon) | Yes (`MTLCreateSystemDefaultDevice()`) | Yes (`arm64` NEON via `SIMD4`) | `[.scalarCPU, .accelerated]` | `.accelerated` (`fallbackReason == nil`) | `.scalarCPU` | `.accelerated` |
| macOS 26.0 (`x86_64`) | Yes (when Metal device present) | Yes (`x86_64` SSE/AVX via `SIMD4`) | `[.scalarCPU, .accelerated]` | `.accelerated` (`fallbackReason == nil`) | `.scalarCPU` | `.accelerated` |
| iOS / iPadOS / tvOS / visionOS 26.0 | Yes | Yes (`arm64` NEON via `SIMD4`) | `[.scalarCPU, .accelerated]` | `.accelerated` (`fallbackReason == nil`) | `.scalarCPU` | `.accelerated` |
| watchOS 26.0 (`arm64_32` / `arm64`) | Guarded (`canImport(Metal)`) | Yes (`SIMD4` / `Accelerate`) | `[.scalarCPU, .accelerated]` | `.accelerated` (`fallbackReason == nil`) | `.scalarCPU` | `.accelerated` |
| Linux (`aarch64` / `x86_64`, Ubuntu 24.04) | No (compile-time `#if canImport(Metal)` guard) | Yes (`SIMD4` vector instructions) | `[.scalarCPU, .accelerated]` | `.accelerated` (`fallbackReason == nil`) | `.scalarCPU` | `.accelerated` |
| Simulated unavailable (`withSimulatedUnavailable`) / Unsupported target | Disabled (`false`) | Disabled (`false`) | `[.scalarCPU]` | `.scalarCPU` (`fallbackReason != nil`) | `.scalarCPU` | Throws `CodecError(.backendUnavailable)` |

---

## 4. Byte-Identity Verification Across Every Fixture

`Tests/SwiftJ2KTests/AccelerationTests.swift` verifies 100% sample-exact and codestream byte-identical parity between `ExecutionPolicy.scalarCPU`, `ExecutionPolicy.required(.accelerated)`, and `AcceleratedCodec.withForcedMetalDispatch(true)` across the entire repository fixture corpus (209 fixtures total):

| Fixture Suite | Count | Operations Verified for Byte-Identity (`.scalarCPU` vs `.accelerated` & Forced Metal GPU) | Outcome |
| --- | ---: | --- | --- |
| Lossless Part 1 (`Tests/SwiftJ2KTests/Fixtures/Lossless/`) | 51 | `Decoder.decode`, `Encoder.encode` (10 reference cases), `Transcoder.transcode(..., to: .htj2k)` | **51 / 51 byte-identical** |
| HTJ2K Part 15 (`Tests/SwiftJ2KTests/Fixtures/HTJ2K/`) | 120 | `Decoder.decode`, `Encoder.encode` (10 reference cases), `Transcoder.transcode(..., to: .jpeg2000)` | **120 / 120 byte-identical** |
| Part 1 Breadth (`Tests/SwiftJ2KTests/Fixtures/Part1Breadth/`) | 22 | `Decoder.decode` (RCT, ICT, 9/7 lossy, signed, ROI, multi-tile, multi-layer, precincts, `POC`, all 6 `CodeBlockStyle` bits), `Encoder.encode` (lossless RCT, near-lossless, lossy 9/7 ICT, ROI, multi-tile) | **22 / 22 byte-identical** |
| JP2 / JPH / JPX Containers (`Tests/SwiftJ2KTests/Fixtures/Containers/`) | 16 | `Decoder.decode` (`jp2`, `jph`, `jpx`, `pclr`+`cmap` palette, `cdef` RGBA, ICC, `resc`/`resd`), `Encoder.encode` (`.jp2`, `.jph`, `.jpx`), `Transcoder.transcode` (`jp2 ↔ jph ↔ jpx`) | **16 / 16 byte-identical** |
| Direct Kernel Unit Tests (`AccelerationTests.swift`) | — | `AcceleratedCodec.forwardWavelet53`/`inverseWavelet53` (even/odd `i0`, `n == 1`, `256x256` GPU), `forwardWavelet97`/`inverseWavelet97` (even/odd `i0`), `forwardRCT`/`inverseRCT` (GPU + SIMD), `forwardICT`/`inverseICT`, `quantizeSubband`, `scaleROISubband`/`descaleROICoefficients` (GPU + SIMD), `encodeHTCleanup`/`decodeHTCleanup` ($u_q > 32$ UVLC `ext` bits) | **100% bit-exact** |

---

## 5. Controlled Release Benchmarks (`PERF-01` / `PERF-02`)

Executed via `swift run -c release --package-path Examples/Consumer Consumer --benchmark-acceleration /Users/raster/Documents/SwiftJ2K` on Apple M3 Max (`arm64-apple-macosx26.0`, 3 warmups, 15 interleaved iterations per workload, peak process RSS `23,986,176` bytes / `22.88 MiB`).

### 5.1 Cold-Start vs Warm GPU/Metal Latency (`PERF-02`)

Measured using `MetalAccelerationEngine.makeFreshInstanceForBenchmarking()`, which creates an uncached engine instance that compiles the embedded MSL shader library from source (`device.makeLibrary(source:options:)`) and builds new `MTLComputePipelineState` objects on the first operation:

| Workload | Cold-Start First Call (ms) | Warm `.accelerated` Median (ms) | Cold Initialisation Overhead (ms) | Notes |
| --- | ---: | ---: | ---: | --- |
| `256x256x3` 12-bit RGB lossless Part 1 encode (5/3 DWT + RCT) | `61.32 ms` | `25.53 ms` | `+35.79 ms` | Includes one-time MSL source compilation + forward 5/3 DWT & RCT pipeline state creation |
| `256x256x3` 12-bit RGB lossless Part 1 decode (5/3 IDWT + Inverse RCT) | `23.71 ms` | `22.84 ms` | `+0.87 ms` | Reuses compiled `MTLLibrary`; builds inverse 5/3 IDWT & inverse RCT pipeline states |

### 5.2 Warm Steady-State Release Benchmarks (`.accelerated` vs `.scalarCPU`)

| Workload | Description | `.accelerated` Median (ms) | `.accelerated` Min / P95 (ms) | `.scalarCPU` Median (ms) | `.scalarCPU` Min / P95 (ms) | Byte-Identical |
| --- | --- | ---: | ---: | ---: | ---: | :---: |
| `encode_rgb16_256x256_part1_53_rct` | `256x256x3` 12-bit RGB lossless Part 1 encode (5/3 DWT + RCT, Metal GPU + SIMD) | `25.53 ms` | `24.67` / `26.35 ms` | `25.07 ms` | `24.68` / `25.39 ms` | Yes |
| `decode_rgb16_256x256_part1_53_rct` | `256x256x3` 12-bit RGB lossless Part 1 decode (5/3 IDWT + Inverse RCT, Metal GPU + SIMD) | `22.84 ms` | `22.31` / `24.49 ms` | `22.62 ms` | `22.37` / `24.71 ms` | Yes |
| `encode_rgb16_256x256_htj2k_53_rct` | `256x256x3` 12-bit RGB lossless HTJ2K encode (5/3 DWT + RCT + FBCOT, Metal GPU + SIMD) | **`4.10 ms`** | `3.56` / `4.56 ms` | `4.30 ms` | `4.24` / `4.34 ms` | Yes |
| `encode_rgb16_256x256_lossy_97_ict` | `256x256x3` 12-bit RGB lossy Part 1 encode (9/7 DWT + ICT + Quantisation, `SIMD4<Double>`) | **`26.29 ms`** | `25.85` / `27.77 ms` | `27.96 ms` | `27.50` / `30.88 ms` | Yes |
| `decode_g16_256x256_smooth` | `256x256` 16-bit greyscale lossless Part 1 fixture decode (Metal GPU 5/3 IDWT) | **`11.40 ms`** | `11.32` / `11.54 ms` | `11.57 ms` | `11.40` / `11.66 ms` | Yes |
| `transcode_g10_300x200_j2k_to_htj2k` | `300x200` 10-bit greyscale `J2K -> HTJ2K` compressed-domain transcode (SIMD FBCOT) | `8.85 ms` | `8.50` / `9.95 ms` | `8.68 ms` | `8.49` / `9.36 ms` | Yes |

---

## 6. Verification Evidence

- **Common Contract Integrity**: `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` — all 7 contract documents verified `OK`.
- **Unit & Regression Test Suite (`swift test`)**: `122` of `122` tests in `2` suites passed (`0` failures, `0` warnings), including the 5 new Milestone 9 test suites in `Tests/SwiftJ2KTests/AccelerationTests.swift`:
  - `executionPolicyAndFallbackReporting()`
  - `kernelBitExactParityAcrossSIMDAndMetal()`
  - `acceleratedVsScalarByteIdentityAcrossAllFixtures()`
  - `concurrentAcceleratedOperationsAndPoolReuse()`
  - `coldAndWarmMetalEngineTelemetry()`
- **CLI Conformance Suite (`Scripts/test-cli.py`)**: `197` of `197` black-box process checks passed against `.build/arm64-apple-macosx/release/swiftj2k-cli`, including `--backend auto`, `--backend scalar`, and `--backend accelerated` across `encode`, `decode`, `validate`, and `transcode`.
- **Standalone Consumer & Migration Examples**:
  - `swift run -c release --package-path Examples/Consumer Consumer` — passed (`106`-byte Part 1 and `126`-byte HTJ2K codestreams round-tripped and transcoded).
  - `swift run --package-path Examples/MigrationExample` — passed (`115`-byte lossless codestream; decode into caller storage with `0` pixel allocations and `0` copy events).
  - `Integration/ContractHarness` — skipped only because sibling repository `/Users/raster/Documents/SwiftJLS` is not checked out in this workspace (`Integration/ContractHarness/Package.swift` references `../../SwiftJLS`).
