# History and provenance — SwiftJ2K

## Documentation foundation — 17 September 2026

The owner chose four fresh repositories under Raster-Lab, with independent codecs, a common API and memory contract, MIT licensing and an optional adapter-based umbrella. The previous proposal for a new shared-foundation package, SwiftCompressionFamily 2.0.0, was superseded. The intended first stable release here is 12.0.0; no library version has been released or tagged by this foundation.

| Item | Recorded source |
| --- | --- |
| Predecessor | [Raster-Lab/J2KSwift](https://github.com/Raster-Lab/J2KSwift) |
| Default branch observed | main |
| Inspected source snapshot | [768f6b53499b806fd0304962056e1fc7833f12e5](https://github.com/Raster-Lab/J2KSwift/commit/768f6b53499b806fd0304962056e1fc7833f12e5) |
| Highest stable-shaped tag observed | [v11.0.3](https://github.com/Raster-Lab/J2KSwift/tree/v11.0.3) |
| Source-tree licence observed | MIT |
| Successor licence | Apache-2.0, for owner-authorised in-house material (contract 0.8.0) |
| Inspection date | 2026-09-17 |

The tag and the inspected branch snapshot are separate references; this record does not assert they resolve to the same commit. Before migrating a tagged baseline, resolve annotated tags to commits and record the exact chosen SHA. The pinned snapshot above was read for documentation preparation; it was not independently built or regression-tested in this task.

## Migration provenance requirements

The coding agent must record source repository, commit, original path and successor path for each migrated subsystem, and distinguish copied/adapted in-house material from new implementation. Record retained tests, fixture licences and explicit product/feature dispositions. Keep predecessor bug history accessible through links. Do not import old tags, rewrite predecessor history or imply all historical commits have been relicensed.

The owner states the implementation is in-house and has authorised Apache-2.0 relicensing (contract 0.8.0; the foundation recorded this as MIT). Preserve accurate original copyright years and ownership. Audit any third-party dependencies, tools or fixtures separately. The root licence is not authority to remove another party's notices.

The originals are intended to become maintenance projects while new development moves here. No predecessor settings, README, branch, release, licence or archive flag was changed during this documentation preparation. Maintenance announcements and downstream DICOMKit/Voxelia migration are separate work.

## Native transcoding source review — 18 September 2026

Re-inspected the same pinned predecessor snapshot for the owner-requested native transcoding instructions. [TRANSCODING.md](TRANSCODING.md) records concrete entry points, test assertions, known limitations and required successor corrections. Source presence/control flow were reviewed; no codec build, test or benchmark was executed. No predecessor files were changed.

## Swift 6.4 development upgrade — 19 September 2026

The owner assigned the successor upgrade before Milestone 2 and requested version increments. Starting from `6d5b88d661ad88d1762f038273e0fec2f618b622`, the candidate requires Swift tools 6.4 in Swift 6 language mode, advances shared contract 0.2.1 to 0.3.0 and advances the unreleased 12.0.0 target to 12.1.0 (`12.1.0-dev.1` development identifier). Platform floors, public API signatures, licensing and codec milestone scope are preserved. This is not a release/tag. The [upgrade record](Documentation/Engineering/Swift64/README.md) keeps current evidence separate from the earlier historical reports.

## OS 27 and CLI foundation — 19 September 2026

Owner-authorised Apple platform floors now use 27.0. Development version 12.1.0-dev.2, common contract 0.4.0. The standalone `swiftj2k` provides help/version/capabilities, five diagnostic levels and a matching section 1 manual installed/updated with the binary. Codec commands remain unavailable. Endian-aware span overloads use the new floor without changing public ownership semantics. See [qualification and limitations](Documentation/Engineering/OS27CLI/README.md). Historical evidence and supplied documents remain unchanged.
## Apple floor restored to 26.0 — 20 September 2026

Contract 0.5.0 reverses the 0.4.0 raise of the Apple deployment floors to 27.0 and returns them to 26.0. Verification found that no generally available Xcode ships OS 27 SDKs, that no stable `macos-27` continuous-integration runner exists, and that Swift 6.4.0 rejects a 27.0 deployment target because its supported range ends at 26.5.x. Every OS 27 qualification claim was therefore unreproducible.

The raise was not an independent platform decision. Contract 0.4.0 adopted the OS-27-gated byte-order span overloads, and the floor moved so that they would compile. Contract 0.3.0 had already specified the correct treatment, explicit fixed-width integer endian conversion without raising the runtime floor, and that rule is restored. The compiler minimum returns to Swift 6.2 with Swift 6.4 retained as the qualified primary toolchain, because a manifest floor constrains consumer resolution and every current consumer resolves at 6.2.

Public signatures, ownership and fidelity semantics, milestone boundaries and Linux scope are unchanged. The OS 27 and Swift 6.4 records remain as history, marked superseded where they assert a platform baseline.

## Shared-storage rules refined from measurement — 20 September 2026

Contract 0.6.0 amends seven memory rules and adds one testing rule. Exploratory spikes ran the caller-storage question against all four predecessor codecs in both directions before any migration work, and every amendment comes from something those spikes measured or broke rather than from anticipated design.

The central finding reverses a standing assumption. `CopyPolicy.requireSharedStorage` is reachable in every codec, and each library reaches caller samples through exactly one stage, so pointing that stage at caller memory is small and local. What blocks the policy is the container each library exposes — `Data` per component, a packed `[UInt8]` with no row stride, a `[[Int]]` façade over an already-flat interior, or an initialiser that rejects any buffer that is not the packed frame size. A caller holding a padded plane cannot describe an image without first copying it. The `Image`/`ImageDescriptor` layer is therefore not packaging around working codecs; it is the Milestone 3 work.

This codec drives three of the seven amendments. Its encode and decode are `async`, so a pointer parameter cannot satisfy MEM-08 and the owner requirement in MEM-06 follows from it. Its decoder emits big-endian 16-bit samples against the shared layout's little-endian, which MEM-12 now requires it to convert on the shared path. Its spatial-domain `[Double]` workspace is four times the final frame, which MEM-10 now requires it to state.

Measured effects, all from a developer machine: live heap held after one JPEG 2000 decode fell from 16 MB in 6 blocks to 1 KB in 2 at 2048×2048, and for JPEG XL from 2 MB to nothing at 1024×1024; the JPEG 2000 output stage ran 9–35% faster writing the caller's plane; and on the encode side the copy a caller must make today costs 5.5 ms and 8 MB at 2048×2048 while the widening loop costs the same either way. Four defects surfaced during the work: inferred plane origins shearing padded multi-plane output, a shared encode that dropped its container wrapper and was caught only by comparing bytes rather than samples, a harness that bound an owner to storage released on the same line, and an address-sanitizer run reporting 100 MB live on a path holding nothing, which a probe traced to the sanitizer quarantining freed blocks.

The spikes are exploratory and are not proposed for merge into the predecessor repositories. No platform, milestone, release or CLI decision changes, and continuous integration remains blocked, so none of these results is a release gate.

## Decision D1 — codec libraries stay where they are, 20 September 2026

Contract 0.7.0 settles the programme's open architectural question. The shipping codec libraries are the existing repositories; the four contract repositories hold the shared documents, the reference implementation of the shared image layer and the cross-codec conformance harness. No codec source is relocated and nothing is deleted.

The Milestone 3 spikes decided it. All four codec interiors proved contract-capable through single-point changes, and the obstacle to caller-owned storage is the public image type rather than the codec, so the remaining work is additive and identical in size wherever it is done. Migration would have paid, on top of that identical work, the relocation of roughly 219,000 lines of codec source and 184,000 lines of tests together with fixtures and cross-codec oracles, with no continuous integration available to catch what such a move breaks. The contract repositories hold about 1,000 lines of source each, so little built work is given up; three in-house consumers already resolve the existing libraries by URL at pinned released versions, and none references a contract repository.

J2KSwift keeps its codec, its 144,755 lines of source and its 129,822 lines of tests. It carries the largest in-place obligations: thirteen products including a daemon to inventory and split under POL-05, and a CompressionFamily dependency confined to two conformance files to extract so the core library resolves alone. DICOMKit and CompressionFamily both consume it by URL at pinned released versions.

Two matters are referred to the owner rather than assumed: the Apache-2.0 and MIT split between the existing libraries and the contract repositories, which POL-07 authorises resolving but which should be a deliberate choice; and the inventory and splitting of auxiliary predecessor products under POL-05. The decision rests on documentation evidence gathered on one machine and authorises no codec milestone or release.

## Decision D2 — codec libraries relocate here, 22 September 2026

Contract 0.8.0 supersedes Decision D1. The owner has reaffirmed the repository foundation v0.1.0 as the guidance for this migration and instructed that the codecs move into the successor repositories. Under document precedence rule 1 the owner's current explicit decision outranks a previous contract revision.

J2KSwift relocates here: 144,755 lines of source and 129,822 lines of tests, with its fixtures and oracles. The predecessor source is MIT-licensed and is relicensed to Apache-2.0 under POL-07 as amended; Raster Images Private Limited holds that copyright, and third-party fixtures and dependencies keep their own terms. It carries the largest obligations: thirteen products including a daemon to inventory and split under POL-05, a CompressionFamily dependency confined to two conformance files to extract, 226 MB of test fixtures with no Git LFS configured and whose provenance must be audited before they enter this history, and no CI workflow of any kind. DICOMKit and CompressionFamily both consume it by URL.

The sequence is a final J2KSwift release at v12.0.0, then relocation, then a first stable 12.1.0 here once the TEST-07 gates pass, then a maintenance window on the predecessor, then its archive. J2KSwift is not renamed or deleted: this repository's HISTORY.md and MIGRATION.md pin its commits and source files by permalink, and those links are the provenance record.

D1's measurements are retained as the risk register rather than discarded. The continuous-integration objection is unresolved and becomes a precondition: the organisation's Actions billing remains locked, a re-run of JLSwift's CI on 22 September 2026 completed with `steps=0`, and no codec source moves before CI executes and passes here. This record authorises no codec milestone and no release.

## Contract 0.9.0 — floor decision and programme sequence, 22 September 2026

Decision D3 keeps the Apple deployment floor at 26.0 and places the cost of adoption on each consumer at its own cutover. DICOMKit consumes J2KSwift from 11.0.3 at macOS 15 / iOS 18 / tvOS 18 / visionOS 2; CompressionFamily (floor macOS 13 / iOS 16) declares no dependency on J2KSwift and is never re-pointed. J2KSwift is the supported route for those consumers until they raise their floors and re-point, and it is archived only after the last of them has moved.

This repository is last in sequence, and its migration is preceded by the CompressionFamily conformance extraction (0.8.0 item 4) and the fixture provenance audit, both done in or about J2KSwift before any source moves. The predecessor's current release candidate is v12.0.0-rc.1; its promotion is the predecessor's own release task and is not authorised here.

The continuous-integration precondition from 0.8.0 stands. Actions billing remained locked on 22 September 2026, so every workflow in the suite is written and unexecuted. No codec source moves here before CI executes and passes here.

## Milestone 2 — scalar lossless migration baseline, 22 September 2026

The owner assigned Milestone 2 for this repository on 22 September 2026, ahead of the 0.9.0 programme sequence that placed SwiftJ2K last. Under document precedence rule 1 that assignment governs; the work stays on branch `milestone2/scalar-lossless-j2k` and the unmet gates below are recorded rather than waived.

| Item | Recorded source |
| --- | --- |
| Pinned predecessor revision | [7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca](https://github.com/Raster-Lab/J2KSwift/commit/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca) (`origin/main`, `v12.0.0-rc.1-6`, the CompressionFamily extraction of contract 0.8.0 item 4) |
| Contract | 0.9.0 |
| Successor base | `c390b50e7a96c4e7bb598e69bd8b7c047a1350eb` |
| Licence of migrated material | MIT at source; Apache-2.0 here under POL-07, copyright Raster Images Private Limited / Raster-Lab; SPDX identifiers added |

**Continuous-integration gate.** Contract 0.9.0 requires CI to execute and pass on this repository before codec source moves in. On 22 September 2026 every GitHub Actions job on `Raster-Lab/SwiftJ2K` (run 35702137934) and on the predecessor still ended with `steps=0` under the billing lock. The precondition is therefore unmet; this migration is a feature branch with local evidence only, not a merge candidate until a workflow run shows non-zero steps.

**Inventory finding.** The predecessor has no separable scalar core. Its Part 1 path lives inside `J2KEncoderPipeline.swift` (7,692 lines) and `J2KDecoderPipeline.swift` (6,239 lines), which also hold HTJ2K, Metal, multi-tile, multi-layer, ROI and rate-control code, import `J2KMetal` unconditionally, and declare their own `SubbandInfo` twice. The standalone `J2KTier2Coding.swift` MQ-codes packet headers, which B.10 does not allow, and is referenced only by its own tests. The migration therefore takes the self-contained algorithm files and writes the syntax, tier-2 and pipeline layers new against the Milestone 1 image types.

| Successor file | Disposition | Predecessor source (at `7acc9ae4`) |
| --- | --- | --- |
| `Sources/SwiftJ2K/Codec/MQCoder.swift` | Adapted | `Sources/J2KCodec/J2KMQCoder.swift` — table, CODEMPS/CODELPS/BYTEOUT/FLUSH, software-conventions decoder; raw-pointer buffers, checkpoints, bypass coders and tracing removed |
| `Sources/SwiftJ2K/Codec/ContextModeling.swift` | Adapted | `Sources/J2KCodec/J2KContextModeling.swift` — label grouping, significance and sign tables, initial states; unaligned raw loads replaced by a padded state plane |
| `Sources/SwiftJ2K/Codec/BitPlaneCoder.swift` | Adapted | `Sources/J2KCodec/J2KBitPlaneCoder.swift` — three-pass scan and run-length rules only; bypass, per-pass segments, distortion accounting, SIMD, scratch pools, tracing not migrated |
| `Sources/SwiftJ2K/Codec/TagTree.swift` | Adapted | `Sources/J2KCodec/J2KTagTree.swift` |
| `Sources/SwiftJ2K/Codec/Wavelet53.swift` | Adapted kernels, new 2-D driver | `Sources/J2KCodec/J2KDWT1D.swift` (`forwardTransform53`, `inverseTransform53`, symmetric extension) |
| `Sources/SwiftJ2K/Codec/BitIO.swift` | New | `Sources/J2KCore/J2KBitReader.swift` / `J2KBitWriter.swift` inspected only |
| `Sources/SwiftJ2K/Codec/Codestream.swift` | New | pipeline marker parsers inspected for field order and defect history |
| `Sources/SwiftJ2K/Codec/Tier2.swift` | New | `writePacket` / `extractTileData` inspected; `J2KTier2Coding.swift` rejected |
| `Sources/SwiftJ2K/Codec/LosslessPipeline.swift` | New | replaces `EncoderPipeline` / `DecoderPipeline` for the scalar profile |

**Predecessor baseline (TEST-04).** At `7acc9ae4` on this host the predecessor's own `J2KCodecTests` target does not compile: `Tests/J2KCodecTests/V8_8_DaemonOverheadDecomposition.swift` imports `J2KDaemonClient`, which the target does not declare. With that one file set aside in a scratch worktree, the seventeen suites that cover the scalar path (DWT, MQ termination, tier-2, marker, integrity, bit-plane, byte-order, PGM round trip, lossless stress and medical gate) executed 211 XCTest cases with 0 failures and 11 skips in 1,629 s; the skips are the predecessor's own PNG/TIFF and HTJ2K variants. The raw log and xUnit file are under [Documentation/Engineering/Milestone2/Evidence](Documentation/Engineering/Milestone2/Evidence). Existing test totals remain historical, not successor acceptance evidence.

**Fixtures.** No predecessor fixture was copied. `Scripts/generate-lossless-fixtures.py` produces ten deterministic synthetic greyscale images (XorShift32 seeds recorded) and encodes them with OpenJPEG 2.5.4 and Kakadu 8.4.1 into 51 lossless codestreams, each cross-decoded exactly by both tools before it is admitted; the manifest records SHA-256 values, geometry, precision and sample digests. Kakadu is a test oracle only and ships nothing into the package.

**Milestone 3 — shared-storage proof, 22 September 2026.** Assigned by the owner on the same day, on branch `milestone3/shared-storage-proof` from the Milestone 2 merge `9c1ae00a5b864c77c93aa09318b866b6dde5bf10`. No predecessor source was migrated; the milestone adds instrumentation (`Sources/SwiftJ2K/Telemetry.swift`, new), the shared-storage test suite (`Tests/SwiftJ2KTests/SharedStorageTests.swift`, new) and the real-codestream experiment in `Integration/ContractHarness` (new code, same package). Evidence: [Documentation/MILESTONE3.md](Documentation/MILESTONE3.md). The JPEG-LS leg of the suite's first end-to-end proof is recorded as unexecuted because SwiftJLS has no encoder at this date. The continuous-integration precondition of contract 0.9.0 remained unmet.

**Milestone 4 — feature, CLI and platform coverage, 22 September 2026.** Assigned by the owner the same day, on branch `milestone4/feature-platform-coverage` from the Milestone 3 merge `560fe5eb069ee4f962763375adb3c108548768e8`. No further predecessor source was migrated: the tier-2 layer, the general-origin wavelet driver, the style-aware block decoder and the multi-tile pipeline are new code in the files recorded for Milestone 2 (their provenance headers name what was adapted and what is new), and the CLI codec verbs are new. `Sources/SwiftJ2K/ImageStorage.swift` gained an atomic reentrancy guard after the Linux run showed that Swift's Linux `Mutex.withLockIfAvailable` traps on same-thread reentry, and `Sources/SwiftJ2KCLI/main.swift` publishes output files with POSIX `rename(2)` after the same run showed that swift-corelibs-foundation's `FileManager.replaceItemAt` fails on Linux. `Tests/SwiftJ2KTests/OwnershipTests.swift` starts the concurrent-borrow writer on a dedicated thread after the full parallel suite starved the global dispatch queue past the test's timeout on macOS. Evidence: [Documentation/MILESTONE4.md](Documentation/MILESTONE4.md). The continuous-integration precondition of contract 0.9.0 remained unmet.

**Milestone 5 — release preparation, 22 September 2026.** Assigned by the owner the same day, on branch `milestone5/release-preparation` from the Milestone 4 merge `45a36992f2daab547cc058097b648f71053e3cab`. No codec source changed and nothing further was migrated. Added: `Examples/MigrationExample` (the program in MIGRATION.md), `Integration/FuzzHarness` (development-only mutation fuzzing of the decode entry points), `THIRD_PARTY_NOTICES.md`, `Documentation/RELEASE.md` and `Documentation/MILESTONE5.md`; MIGRATION.md and SECURITY.md rewritten to the current state; `Scripts/validate-swift64.py`'s generated consumer returned to tools 6.2, macOS 26.0 and a real round trip; SPDX headers added to `Examples/Consumer/Package.swift`, `Integration/ContractHarness/Package.swift` and `Scripts/generate-lossless-fixtures.py`. The Swift 6.4 toolchain executed the Swift Build engine, both sanitizers and SBOM generation that Swift 6.2.3 could not. Development version 12.1.0-dev.6; no tag. The continuous-integration precondition of contract 0.9.0 remained unmet.

**Release 12.1.0 task — 22 September 2026.** Assigned explicitly by the owner after the Milestone 5 merge `a964b7c34fef7ee58b3954ffaec813c1258376d1`, on branch `release/12.1.0`. Commit `67273dbb5a195c1b2a1f47f311d9a1e4cd7f9203` changed only the version strings and the CHANGELOG, and every gate of `Documentation/RELEASE.md` was executed on it (evidence in git history at `3da1665`). Contract 0.10.0 then landed on `main` (pull request 19, 23 September 2026) and renamed the executables; on the owner's decision that this is a new library with no legacy name to carry, the executable product became `swiftj2k-cli` (with its manual `ManPages/swiftj2k-cli.1`, the installer, the reported tool name and the CLI documentation; the library module `SwiftJ2K` and the NRRD key `swiftj2k.meaningfulbits` unchanged) and the gates were re-run on the renamed commit, recorded in `Documentation/RELEASE-12.1.0.md` with evidence under `Documentation/Engineering/Release-12.1.0/Evidence`. Tag state is recorded there. On 25 September 2026 the owner ruled that no release is created until the migration of J2KSwift is complete; the remaining inventory and Milestones 6 to 13 are in IMPLEMENTATION.md.

**Transcoder audit (TRANSCODING.md, Milestone 2 item).** Re-inspected `Sources/J2KCodec/J2KTranscoder.swift` at `7acc9ae4`: `decodeLegacyCodeBlock` and `decodeHTCodeBlock` still catch failures and return empty coefficient arrays, `metadataPreserved: true` is still set unconditionally, and `J2KTranscoderTests.swift` still skips its async and parallel transcode tests with parser-hang explanations. None of that code was transferred.

## Milestone 6 — HTJ2K and native J2K ↔ HTJ2K transcoding, 26 October 2026

Assigned by the owner on branch `antigravity/milestone6-htj2k-transcoding` (created from `origin/milestone6/htj2k` `682fd7a3f60c9ec5b56c0a7cb0eb052e1558a0ce`, merge-base `be4e7a3ad352759e7a78a90f6a2e2c3b7aa0f748`). Following the owner's 26 October 2026 decision ("Adapt the existing coder with its notices (recommended)"), the predecessor's OpenJPH-derived conformant Part 15 block coder at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca` was adapted with OpenJPH's BSD-2-Clause licence notice retained in the source files and disclosed in `THIRD_PARTY_NOTICES.md`. The predecessor's custom HT coder (`J2KHTBlockCoder.swift` / `J2KHTCodec.swift`) and broken transcoder (`J2KTranscoder.swift`) were excluded. Evidence: [Documentation/MILESTONE6.md](Documentation/MILESTONE6.md).

| Successor file | Disposition | Predecessor source (at `7acc9ae4`) |
| --- | --- | --- |
| `Sources/SwiftJ2K/Codec/HTTables.swift` | Adapted (`Apache-2.0 AND BSD-2-Clause`) | `Sources/J2KCodec/J2KHTConformantTables.swift` (derived from OpenJPH `ojph_block_common.c` / `ojph_block_decoder32.c`, Copyright (c) 2019-2024 Aous Naman) |
| `Sources/SwiftJ2K/Codec/HTBlockCoder.swift` | Adapted (`Apache-2.0 AND BSD-2-Clause`) | `Sources/J2KCodec/J2KHTConformantMELCoder.swift`, `J2KHTConformantVLCCoder.swift`, `J2KHTConformantMagSgnCoder.swift`, `J2KHTConformantBitStream.swift`, `J2KHTConformantBlockLayout.swift`, `J2KHTConformantBlockEncoder.swift`, `J2KHTConformantBlockDecoder.swift` (derived from OpenJPH `ojph_block_encoder.cpp` / `ojph_block_decoder32.cpp`, Copyright (c) 2019-2024 Aous Naman); fixed `Lcup <= 65535`, `fuseMELAndVLC` bit-7 preservation, `HTMELDecoder.read()` boundary unstuffing, and `kMax` magnitude bounds |
| `Sources/SwiftJ2K/Codec/Codestream.swift` | Extended (new Part 15 code) | `CAP` (`0xFF50`) and `CPF` (`0xFF59`) parsing/writing, `Ccap15` validation, `COD`/`COC` HT style bits |
| `Sources/SwiftJ2K/Codec/Tier2.swift` | Extended (new Part 15 code) | `CodeBlockStyle.ht` (`0x40`) and `htMixed` (`0x80`), Clause B.10.6 per-block `isHT` detection, HT codeword segment parsing (`Lcup`/`Lref`) |
| `Sources/SwiftJ2K/Codec/LosslessPipeline.swift` | Extended (new Part 15 and transcode code) | HT lossless encode/decode/inspect, placeholder-pass accounting, `extractTileCoefficients` and pure wavelet-coefficient `ScalarLosslessCodec.transcode` |
| `Sources/SwiftJ2K/Transcoding.swift` & `Sources/SwiftJ2KCLI/main.swift` | Extended (new code) | `Transcoder` capabilities/operations and `swiftj2k-cli` `htj2k` / `transcode` support |
