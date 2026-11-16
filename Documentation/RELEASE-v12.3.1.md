# SwiftJ2K `v12.3.1` (`12.3.1`) — Release Gate Record

Executed on **16 November 2026** following [RELEASE.md](RELEASE.md), [RELEASE-v12.3.0.md](RELEASE-v12.3.0.md), and [STATUS.md](Engineering/Remediation/STATUS.md) (`VERSION` = `12.3.1`, shared contract = `0.11.0`, `MIT` licence, Apple OS deployment floor = `26.0`, Swift `6.2` tools minimum / Swift `6.4` qualified in Swift `6` language mode), preserving published tag `v12.3.0` immutable.

---

## 1. Release Scope (`12.3.1`)

1. **Swift `6.2` / `6.3.3` (`Xcode 26.6`) `sending` closure compatibility (`Sources/SwiftJ2K/Codec/BoundedParallelPool.swift`):** Encapsulates `BoundedParallelPool.forEachAsync`'s `~Copyable` `Atomic<Int>` cursor and `Atomic<Bool>` abort flag inside a `Sendable` reference class (`AsyncWorkState`), resolving `#SendingClosureRisksDataRace` on pre-6.4 Swift 6 compilers (`Xcode 26.6` / Swift `6.3.3` hosted Apple CI and `swift-tools-version: 6.2` consumers) with zero per-job allocation or runtime behaviour change.
2. **Full `12.3.0` feature parity:** Retains 100% of `v12.3.0`'s `BoundedParallelPool` multi-worker coding, synchronous `encodeSynchronously`/`decodeSynchronously`/`transcodeSynchronously` fast paths, `CodecOptions.resolutionReductionLevels` reduced-resolution decode, multi-candidate HTJ2K PCRD rate control, and vectorised SIMD/Accelerate (`vDSP`) Tier-1 EBCOT / MQ / clean-room ITU-T Rec. T.814 HTJ2K / DWT / RCT / ICT kernels across all `1,395` macOS declarations (`0` held).

---

## 2. Executed Gates for `12.3.1`

| Gate | Command / Run | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.11.0`) |
| **Parallel, synchronous, & reduced-resolution Release suite** | `swift test -c release --filter ParallelSyncAndReducedDecodeTests` | **PASSED** (`10/10` tests passed) |
| **CLI conformance & staged UNIX manual installation** | `python3 Scripts/test-cli.py --binary <release/swiftj2k-cli>` | **PASSED** (`246/246` process checks passed; `swiftj2k-cli 12.3.1`) |
| **Hosted Apple CI (`Xcode 26.6` / Swift `6.3.3`)** | GitHub Actions `Milestone 1 contract` on `raster-labs/SwiftJ2K` `main` | **VERIFIED** |

See [RELEASE-v12.3.0.md](RELEASE-v12.3.0.md) and [RELEASE-v12.2.0.md](RELEASE-v12.2.0.md) for the full `1,395`-declaration test reconciliation and explicit owner-held/unexecuted boundary disclosures.
