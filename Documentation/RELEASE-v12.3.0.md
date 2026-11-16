# SwiftJ2K `v12.3.0` (`12.3.0`) — Release Gate Record

Executed on **16 November 2026** following [RELEASE.md](RELEASE.md), [STATUS.md](Engineering/Remediation/STATUS.md), and the owner's release directive (`VERSION` = `12.3.0`, shared contract = `0.11.0`, `MIT` licence, Apple OS deployment floor = `26.0`, Swift `6.2` tools minimum / Swift `6.4` qualified in Swift `6` language mode).

*(Note: Historical [RELEASE-v12.2.0.md](RELEASE-v12.2.0.md) preserves the 11 November 2026 `v12.2.0` release gate record, [RELEASE-v12.1.0.md](RELEASE-v12.1.0.md) preserves the 6 November 2026 `v12.1.0` 2D stable release gate record, and [RELEASE-12.1.0.md](RELEASE-12.1.0.md) preserves the 22 September 2026 Milestone 5 pre-migration preparation record byte-for-byte.)*

---

## 1. Release Scope (`12.3.0`)

1. **Bounded parallel pool & deterministic multi-worker execution (`BoundedParallelPool.swift`):** Parallelises multi-tile and single-tile intra-subband code-block encoding, decoding, and wavelet-domain `J2K ↔ HTJ2K` transcoding strictly within `ResourceLimits.maximumWorkers` while preserving bit-for-bit `1T == 8T` codestream determinism.
2. **Synchronous zero-task-spawn codec entry points & reduced-resolution decode (`CodecAPI.swift`, `Transcoding.swift`):** Adds `encodeSynchronously`, `decodeSynchronously`, and `transcodeSynchronously` synchronous fast paths for zero-actor-hop integration with synchronous callers (`DICOMKit`), plus `CodecOptions.resolutionReductionLevels` reduced-resolution wavelet subband decode skipping unneeded `HL`/`LH`/`HH` Tier-2/Tier-1/IDWT work.
3. **SIMD / Accelerate (`vDSP`) & allocation-free Tier-1 / DWT / PCRD acceleration:** Accelerates 5/3 & 9/7 DWT lifting, RCT/ICT colour transforms, dead-zone quantisation + Annex E midpoint reconstruction, EBCOT pass coding (`BitPlaneCoder.swift`, `MQCoder.swift`), clean-room ITU-T Rec. T.814 HTJ2K cleanup & refinement coding (`HTBlockCoder.swift`, `SIMDAcceleration.swift`), and L2-weighted multi-candidate HTJ2K PCRD rate allocation (`Part1Pipeline.swift`, `Tier2.swift`).
4. **Validation ledger expansion (`1,395` macOS declarations, `0` held):** Adds `ParallelSyncAndReducedDecodeTests.swift` (`+10` declarations) and updates [R3_HELD_VALIDATION_LEDGER.json](Engineering/Remediation/R3_HELD_VALIDATION_LEDGER.json) (`1,395` macOS declarations across `[660, 735]` sanitizer partitions; `1,385` iOS Simulator declarations; `0` held declarations).

---

## 2. Executed Gates for `12.3.0`

| Gate | Command / Run | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.11.0`) |
| **Compiled test inventory & ledger reconciliation** | `python3 Scripts/verify-sanitizer-inventory.py` against `R3_HELD_VALIDATION_LEDGER.json` | **PASSED** (`1,395` macOS declarations, `[660, 735]` partitions, `0` held) |
| **Local macOS Release test suite + external-oracle interoperability** | `swift test -c release` (including `ParallelSyncAndReducedDecodeTests`, `CleanRoomT814Tests`, and Kakadu `8.4.1` / OpenJPEG / OpenJPH oracle checks) | **PASSED** |
| **CLI conformance & staged UNIX manual installation** | `python3 Scripts/test-cli.py --binary <release/swiftj2k-cli>` | **PASSED** (`swiftj2k-cli 12.3.0`) |

---

## 3. Unexecuted and Deferred Gates (Disclosed Explicitly per `RELEASE.md`)

Per [RELEASE.md](RELEASE.md) (*"Anything unexecuted is recorded as unexecuted in the release notes, never as passed"*), the following items remain **unexecuted or deferred by the owner** on `v12.3.0`:

1. **Five direct third-party external interoperability gates (`EXT-INTEROP-01`..`05`)**: **`ON_HOLD_BY_OWNER / DEFERRED / UNEXECUTED`** per explicit owner scope decision ([R3_CAPABILITY_MATRIX.md](Engineering/Remediation/R3_CAPABILITY_MATRIX.md)).
2. **Tag-time `3,600s`-per-entry release fuzz campaigns**: **Unexecuted at `3,600s`/entry** (`9 × 120s` = `5,025,480` iterations retained in [RELEASE-v12.2.0.md](RELEASE-v12.2.0.md)).
3. **Linux container builds and tests (`ubuntu-24.04` arm64/x86_64)**: **`OUT_OF_CURRENT_SCOPE_BY_OWNER`** under the 2 November 2026 Apple-only CI scope directive.
4. **Uninstalled Apple SDKs and physical devices (`tvOS`, `watchOS`, `visionOS`, macOS `x86_64` Rosetta, physical iPhone/iPad)**: **Unexecuted** on the release host.
