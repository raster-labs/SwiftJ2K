# Third-party and provenance notices

SwiftJ2K ships under Apache-2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). The declared package products (`SwiftJ2K`, `SwiftJ2K3D`, and `SwiftJ2KJPIP` libraries — with `SwiftJ2K3D` and `SwiftJ2KJPIP` validation/enhancement currently held per [Documentation/MILESTONE13.md](Documentation/MILESTONE13.md) — and the `swiftj2k-cli` executable) declare no external package dependency; `swift package show-dependencies` on a consumer resolves this repository alone. Everything below is either in-house material whose provenance the contract requires to be recorded, or a development tool that never enters the shipped dependency graph (SUITE_POLICY.md POL-01, POL-07).

## In-house predecessor code

Files under `Sources/SwiftJ2K/Codec/`, `Sources/SwiftJ2K/Container/`, `Sources/SwiftJ2K/Acceleration/`, `Sources/SwiftJ2K3D/`, `Sources/SwiftJ2KJPIP/`, and `Sources/SwiftJ2KCLI/` whose provenance header names Raster-Lab/J2KSwift were adapted from that repository at commit `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`. `Sources/SwiftJ2K/Codec/HTTables.swift` and `Sources/SwiftJ2K/Codec/HTBlockCoder.swift` (and the cleanup bitstream multiplexer used by `SIMDHTBlockCoder` in `Sources/SwiftJ2K/Acceleration/SIMDAcceleration.swift`) are clean-room in-house implementations authored directly from ITU-T Rec. T.814 (06/2019) | ISO/IEC 15444-15:2019, containing no third-party or BSD-2-Clause adapted source code. J2KSwift is MIT-licensed and its copyright is held by Raster Images Private Limited, which authorised relicensing of in-house predecessor code under Apache-2.0 (contract revision 0.8.0, POL-07). Original authorship is preserved in the provenance headers and in [HISTORY.md](HISTORY.md), which records what was adapted and what is new. Published J2KSwift tags keep their MIT licence text unchanged.

## Test fixtures

`Tests/SwiftJ2KTests/Fixtures/Lossless/`, `Tests/SwiftJ2KTests/Fixtures/HTJ2K/`, `Tests/SwiftJ2KTests/Fixtures/Part1Breadth/` and `Tests/SwiftJ2KTests/Fixtures/Containers/` are synthetic and in-house: the source images are generated deterministically by `Scripts/generate-lossless-fixtures.py`, `Scripts/generate-htj2k-fixtures.py`, `Scripts/generate-part1-breadth-fixtures.py` and `Scripts/generate-container-fixtures.py` (seeds recorded in each directory's `manifest.json`), and every codestream or container file is an *output* of a reference encoder run on those images. No fixture contains clinical, personal or third-party image data. The fixtures are Apache-2.0 with the repository. Each `manifest.json` records each file's SHA-256 and the tool and arguments that produced it.

## Development tools (oracles and generators, never linked or shipped)

| Tool | Version used | Licence | Use |
| --- | --- | --- | --- |
| OpenJPEG (`opj_compress`, `opj_decompress`) | 2.5.4 | BSD-2-Clause | Fixture generation; independent decode oracle in tests, the contract harness and the benchmark |
| Kakadu (`kdu_compress`, `kdu_expand`) | 8.4.1 | Proprietary; licensed to the owner for the host it runs on | Fixture generation; independent decode oracle in tests, the contract harness and the benchmark |
| OpenJPH (`ojph_compress`, `ojph_expand`) | 0.30.1 | BSD-2-Clause | HTJ2K fixture generation; independent HTJ2K encode/decode oracle in tests and cross-codec benchmark comparisons |
| Grok (`grk_compress`, `grk_decompress`) | 20.3.7 | AGPL-3.0 | Cross-codec benchmark comparisons only |
| Swift toolchains, Xcode, Docker image `swift:6.2-noble` | recorded per milestone | Apple / swift.org / Docker terms | Build, test and Linux container evidence |

The oracles are invoked as separate processes by tests that skip when a tool is absent (`.enabled(if: Oracle.available)`). No oracle output is redistributed except the synthetic fixtures described above, and no oracle code is compiled into any product. Their licences govern the tools themselves, not this repository's code or fixtures.

## Archived evidence copies

`Documentation/Engineering/**/Evidence` and `Probes` keep verbatim copies of scripts, probe sources and generated consumer manifests exactly as they ran, including files without SPDX headers and manifests that still name the withdrawn OS 27 floor. They are historical evidence under the repository licence and are not built, shipped or maintained.
