# Milestone 7 — Part 1 Breadth

Executed 27 October 2026 on the owner's assignment on branch `antigravity/milestone7-part1-breadth` from `origin/main` (`ed3dec9e40abbd63d1678881498512098d2247dc`), against contract **0.10.0** and pinned predecessor [Raster-Lab/J2KSwift](https://github.com/Raster-Lab/J2KSwift) `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`.

## 1. Scope Delivered

- **Colour and multi-component images (`1...N` components, RGB, RGBA, planar and interleaved `PlaneDescriptor`s)** with Reversible Colour Transform (`RCT`, ISO/IEC 15444-1 Annex G.2) and Irreversible Colour Transform (`ICT`, ISO/IEC 15444-1 Annex G.3) in [Sources/SwiftJ2K/Codec/ColourTransform.swift](../Sources/SwiftJ2K/Codec/ColourTransform.swift), [Sources/SwiftJ2K/ImageDescriptor.swift](../Sources/SwiftJ2K/ImageDescriptor.swift) (`rgbPlanar`, `rgbInterleaved`, `multiComponentPlanar`, `signedGreyscale16`, `greyscale8`), and [Sources/SwiftJ2K/Image.swift](../Sources/SwiftJ2K/Image.swift) (`sampleInt`, `sampleUInt16`, `sampleInt16`, `writeInt16`, `writeSamples`, `loadSampleInt`, `storeSampleInt`).
- **Signed integer samples (`SampleType.signedInteger`, `Ssiz` bit 7 = `0x80`) and Part 1 DC offset / extended precision**:
  - Unsigned components apply the ISO/IEC 15444-1 Annex G.1 nominal DC level shift ($\mp 2^{R_i - 1}$); signed components (`Ssiz & 0x80 != 0`) apply zero DC level shift and preserve two's-complement range $[-2^{R_i - 1}, 2^{R_i - 1} - 1]$ across 1–16 meaningful bits in 8-bit or 16-bit storage.
  - Extended guard-bit precision (`guardBits` in `1...7`) and 64-bit internal Tier-1 bit-plane coding (`BitPlaneCoder.encodeRich` and `decodeRich` in [Sources/SwiftJ2K/Codec/BitPlaneCoder.swift](../Sources/SwiftJ2K/Codec/BitPlaneCoder.swift), supporting up to 62 magnitude bit-planes) prevent overflow across deep wavelet decompositions, RCT/ICT dynamic-range expansion, and MaxShift ROI scaling (including 16-bit images with ROI shifting `M_b + s` to 34+ bit-planes).
- **9/7 CDF irreversible wavelet (`Wavelet97`), dead-zone quantisation, midpoint reconstruction, and rate control (`.lossy`, `.nearLossless`)**:
  - [Sources/SwiftJ2K/Codec/Wavelet97.swift](../Sources/SwiftJ2K/Codec/Wavelet97.swift) implements ISO/IEC 15444-1 Annex F.3.8.2 and F.4.8.2 1D and 2D 9/7 lifting ($\alpha, \beta, \gamma, \delta, K, 1/K$) with arbitrary subband origin parity (`x0`, `y0`), periodic symmetric boundary extension, and length-1 subband conventions ($m_0 = 0 \implies X[0] = Y[0]$, $m_0 = 1 \implies X[0] = Y[0] / 2$ on analysis and $Y[0] = 2 X[0]$ on synthesis).
  - [Sources/SwiftJ2K/Codec/Quantization.swift](../Sources/SwiftJ2K/Codec/Quantization.swift) implements L2 synthesis filter norms (`Table E.1`), ISO/IEC 15444-1 Eq. E-3 step sizes ($\Delta_b = 2^{R_b - \varepsilon_b}(1 + \mu_b / 2048)$ where $R_b = R_i + \text{gain}_b$), scalar-derived (`Sqcd = 1`) and scalar-expounded (`Sqcd = 2`) `QCD`/`QCC` marker generation, midpoint dequantisation ($\hat{c} = \operatorname{sign}(q)(|q| + 0.5 \cdot 2^{p_{\text{trunc}}})\Delta_b$), and post-compression rate-distortion optimisation (`allocatePassesPCRD`) across `quality`, `targetBitsPerPixel`, `qualityLayers`, and `layerBitrates`.
  - `.nearLossless(maximumAbsoluteError: E)` enforces $\max |\hat{I} - I| \le E$ via closed-loop tile reconstruction verification and reports `Fidelity.boundedError(E)`.
- **Region of Interest (`RGN` `0xFF5E`, MaxShift `Srgn = 0`)**:
  - [Sources/SwiftJ2K/Codec/ROI.swift](../Sources/SwiftJ2K/Codec/ROI.swift) and [Sources/SwiftJ2K/Codec/Codestream.swift](../Sources/SwiftJ2K/Codec/Codestream.swift) parse, validate, and emit `RGN` (`0xFF5E`) marker segments in main and tile-part headers, compute spec-compliant MaxShift scaling $s \ge \max_b(M_b)$ (ISO/IEC 15444-1 Annex H.1), map image-space ROI rectangles into subband coordinates with wavelet synthesis filter support margins, shift foreground coefficients on encode, and descale coefficients with $|q| \ge 2^s$ on decode.
- **Multi-tile, multi-layer, explicit precincts, progression control (`LRCP`, `RLCP`, `RPCL`, `PCRL`, `CPRL`, `POC` `0xFF5F`), `SOP`/`EPH`, and all 6 code-block style bits**:
  - [Sources/SwiftJ2K/Codec/Tier2.swift](../Sources/SwiftJ2K/Codec/Tier2.swift) (`multiComponentPacketSequence`, `decodePacketsMulti`, `encodePacketsMulti`), [Sources/SwiftJ2K/Codec/Codestream.swift](../Sources/SwiftJ2K/Codec/Codestream.swift) (`POC`, `RGN`, multi-component `COC`/`QCC`), [Sources/SwiftJ2K/Codec/MQCoder.swift](../Sources/SwiftJ2K/Codec/MQCoder.swift) (`RawEncoder` with `0xFF` bit-stuffing and `finish()`), and [Sources/SwiftJ2K/Codec/Part1Pipeline.swift](../Sources/SwiftJ2K/Codec/Part1Pipeline.swift) support encoding and decoding across arbitrary tile grids, multiple quality layers, explicit precinct sizes, all five progression orders, `POC` (`0xFF5F`) progression order change volumes, `SOP`/`EPH` markers, and all six Part 1 code-block style flags (`0x01` selective arithmetic bypass, `0x02` context reset, `0x04` termination on each pass, `0x08` vertically causal stripe context, `0x10` predictable termination, `0x20` `0x0A` segmentation symbols).
- **CLI (`swiftj2k-cli`)**:
  - [Sources/SwiftJ2KCLI/main.swift](../Sources/SwiftJ2KCLI/main.swift), [CLI.md](../CLI.md), and [ManPages/swiftj2k-cli.1](../ManPages/swiftj2k-cli.1) support `--mode lossless|near-lossless|lossy` (`--lossy`), `--max-error` (`--near-lossless`), `--quality`, `--bpp`, `--layers`, `--wavelet auto|53|97`, `--mct auto|none|rct|ict`, `--progression`, `--tile-size`, `--precincts`, `--roi`, `--guard-bits`, `--qstyle`, `--sop`, `--eph`, and 2D/3D NRRD (`uint8`, `int8`, `uint16`, `int16`).

---

## 2. Predecessor Audit at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`

Every predecessor file in the Milestone 7 scope was inspected at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca` (`git show 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:<path>`).

### 2.1 Part 1 Breadth Files in Predecessor (`7acc9ae4`)

| Predecessor path (`7acc9ae4`) | Lines | Predecessor defects / findings | Successor disposition & path |
| --- | ---: | --- | --- |
| `Sources/J2KCodec/J2KColorTransform.swift` | 1,313 | Core integer RCT (`Annex G.2`) and floating-point ICT (`Annex G.3`) array math is sound, but component-level wrappers (`forwardRCT(red:green:blue:)` / `forwardICT(...)`) hardcode `component.data.count / 4` (assuming 4 bytes/sample regardless of `bitDepth`) and store ICT coefficients in `Float32` via `Float(bitPattern:)`. | **Adapted (formulas) / Rewritten (storage integration)** in [Sources/SwiftJ2K/Codec/ColourTransform.swift](../Sources/SwiftJ2K/Codec/ColourTransform.swift) operating on `[[Int32]]` and `[[Double]]` tile planes with zero intermediate `Data` copies. |
| `Sources/J2KCodec/J2KDWT1D.swift`<br>`Sources/J2KCodec/J2KDWT2D.swift`<br>`Sources/J2KCodec/J2KWaveletKernel.swift` | 853<br>1,128<br>621 | 1. **Critical lossy 9/7 encoder bug (`J2KEncoderPipeline.swift:2710–2731` vs `3549`)**: when `useReversibleFilter == false` on CPU without Metal, `applyColorAndWaveletTransforms` runs `Double` 9/7 lifting, then rounds `Double` wavelet coefficients directly to `Int32` (`Int32(val.rounded())`) and at line 3549 sets `quantized = coeff` (completely bypassing `quantizer.quantize`!), while writing non-unit step sizes into `QCD`. Any external decoder (OpenJPEG/Kakadu) multiplying by $\Delta_b \ne 1$ reconstructs wildly scaled garbage.<br>2. Assumes even subband origin `(0, 0)` (no `cas` parity for odd tile/subband origins `x0`, `y0`) and rejects length-1 subbands (`guard totalLength >= 2`).<br>3. `J2KWaveletKernel.cdf97` swaps `lowpassScale` and `highpassScale` relative to `J2KDWT1D.forwardTransform97`. | **Rewritten** in [Sources/SwiftJ2K/Codec/Wavelet97.swift](../Sources/SwiftJ2K/Codec/Wavelet97.swift) with full `x0`/`y0` parity handling, length-1 subband support, and proper dead-zone quantisation by $\Delta_b$ in [Sources/SwiftJ2K/Codec/Part1Pipeline.swift](../Sources/SwiftJ2K/Codec/Part1Pipeline.swift). |
| `Sources/J2KCodec/J2KQuantization.swift`<br>`Sources/J2KCodec/J2KRateControl.swift` | 1,290<br>2,346 | 1. `J2KStepSizeCalculator.calculateStepSize` adds a non-standard `+ 16` exponent bias (`let exp = bitDepth - rl + 1 + 16`), writing invalid `QCD` exponents unless `encodeQCDSubbandStepSize` is used.<br>2. Decoder only parses `Sqcd == 0` and `Sqcd == 2`; rejects `Sqcd == 1` (`scalarDerived`) and ignores `QCC` (`0xFF5D`).<br>3. No `.nearLossless(maximumAbsoluteError:)` mode exists. | **Rewritten** in [Sources/SwiftJ2K/Codec/Quantization.swift](../Sources/SwiftJ2K/Codec/Quantization.swift) and [Sources/SwiftJ2K/Codec/Codestream.swift](../Sources/SwiftJ2K/Codec/Codestream.swift) supporting `Sqcd = 0, 1, 2`, `QCC`, midpoint dequantisation, PCRD-opt pass allocation, and closed-loop `.nearLossless(maximumAbsoluteError:)`. |
| `Sources/J2KCodec/J2KROI.swift` | 1,009 | 1. `RGN` (`0xFF5E`) is never emitted by `J2KEncoderPipeline` or parsed by `J2KDecoderPipeline` (`J2KMarker.rgn` is only defined in an enum).<br>2. `recommendedScalingFactor(forBitDepth:)` caps the MaxShift scaling factor to `min(maxShift, 5)`, violating ISO/IEC 15444-1 Annex H.1 ($s \ge \max_b M_b$) and causing foreground and background bit-planes to overlap.<br>3. `waveletMask` uses whole-image quadrant division instead of subband coordinates and filter support margins. | **Rewritten** in [Sources/SwiftJ2K/Codec/ROI.swift](../Sources/SwiftJ2K/Codec/ROI.swift), [Sources/SwiftJ2K/Codec/Codestream.swift](../Sources/SwiftJ2K/Codec/Codestream.swift), and [Sources/SwiftJ2K/Codec/Part1Pipeline.swift](../Sources/SwiftJ2K/Codec/Part1Pipeline.swift) with `RGN` (`0xFF5E`) marker parsing/emission, $s \ge \max_b M_b$, and subband coordinate mapping with synthesis filter margins. |
| `Sources/J2KCodec/J2KMultiTileCodestream.swift`<br>`Sources/J2KCodec/J2KMultiTileEncoder.swift`<br>`Sources/J2KCodec/J2KProgressiveEncoding.swift`<br>`Sources/J2KEncodingPresets.swift`<br>`Sources/J2KAdvancedDecoding.swift` | 262<br>133<br>419<br>919<br>997 | Helper structs and presets coupled to legacy `J2KImage`/`J2KConfiguration`; `POC` (`0xFF5F`) was not wired into the predecessor's Tier-2 packet sequencer. | **Replaced** by [Sources/SwiftJ2K/CodecAPI.swift](../Sources/SwiftJ2K/CodecAPI.swift) (`CodecOptions`), [Sources/SwiftJ2K/Codec/Tier2.swift](../Sources/SwiftJ2K/Codec/Tier2.swift) (`multiComponentPacketSequence` with `POC`), and [Sources/SwiftJ2K/Codec/Part1Pipeline.swift](../Sources/SwiftJ2K/Codec/Part1Pipeline.swift). |
| `Sources/J2KCore/J2KPart1Conformance.swift`<br>`Sources/J2KCore/J2KMarker.swift`<br>`Sources/J2KCore/J2KCodestreamIntegrity.swift` | 774<br>405<br>224 | Synthetic validator/marker helper structs not wired to the real decoder (`J2KPart1Conformance` checks synthetic structs rather than decoding codestreams). | **Retired / Replaced** by [Sources/SwiftJ2K/Codec/Codestream.swift](../Sources/SwiftJ2K/Codec/Codestream.swift) and `Decoder.inspect` / `swiftj2k-cli validate`. |

### 2.2 Part 2, Perceptual, and Motion JPEG 2000 (`MJ2*`) Audit and Feature-Level Disposition (`7acc9ae4`)

| Predecessor path (`7acc9ae4`) | Lines | Category | Technical audit findings at `7acc9ae4` | Disposition |
| --- | ---: | --- | --- | --- |
| `Sources/J2KCodec/J2KArbitraryWavelet.swift` | 760 | Part 2 (ISO/IEC 15444-2) | Standalone 1D/2D convolution filter engine. Not called by `J2KEncoderPipeline` or `J2KDecoderPipeline`. `J2KADSMarker.encode()` emits marker code `0xFF74` (`MCT` in ISO/IEC 15444-2, whereas `ADS` is `0xFF73`) with a custom non-standard binary layout; `ATK` (`0xFF72`) is not implemented. | **Retire / Exclude** — non-conformant marker layout and outside Part 1 / Part 15 scope. Codestreams with Part 2 `Rsiz` bits are rejected with `CodecError(.unsupportedFeature)`. |
| `Sources/J2KCodec/J2KNonLinearTransform.swift`<br>`Sources/J2KCodec/J2KNLTMarker.swift` | 733<br>500 | Part 2 (ISO/IEC 15444-2) | Standalone point-transform math (`gamma`, `logarithmic`, `pq`, `hlg`, LUT). Disconnected from encode/decode pipelines. `J2KNLTMarkerSegment` emits marker code `0xFF70` (`DCO` in ISO/IEC 15444-2, whereas `NLT` is `0xFF76`) and serialises raw IEEE-754 floats and UTF-8 function strings that no standard decoder can parse. | **Retire / Exclude** — proprietary binary marker format and outside Part 1 / Part 15 scope. |
| `Sources/J2KCodec/J2KPart2CodestreamExtensions.swift` | 387 | Part 2 (ISO/IEC 15444-2) | Defines `Part2Capability` (`Rsiz = 0x8002`) and capability config structs. When enabled in `J2KEncoderPipeline`, sets `Rsiz = 0x8002` in `SIZ` without writing any corresponding Part 2 marker segments (`DCO`, `MCT`, `MCC`, `MCO`, `NLT`, `ATK`, `ADS`), producing non-conformant headers. Clamps extended guard bits via `min(7, extendedGuardBits)` back to the Part 1 range. | **Retire / Exclude** — non-conformant Part 2 header stub. Part 1 guard bits (`1...7`) are supported natively in `CodecOptions.guardBits`. |
| `Sources/J2KCodec/J2KMCT.swift`<br>`Sources/J2KCodec/J2KMCTMarker.swift`<br>`Sources/J2KCodec/J2KMCTDependency.swift` | 708<br>392<br>417 | Part 2 (ISO/IEC 15444-2) | Matrix / KLT multi-component transform. `J2KEncoderPipeline` applies the matrix transform to samples if configured, but **never writes `MCT`/`MCC`/`MCO` markers** into the codestream, and `J2KDecoderPipeline` never parses them — making any encoded stream undecodable. Furthermore, `J2KMCTMarker.swift` assigns wrong marker codes (`MCT = 0xFF75`, `MCC = 0xFF77`, `MCO = 0xFF76` vs ISO/IEC 15444-2 Table A.1 `MCT = 0xFF74`, `MCC = 0xFF75`, `MCO = 0xFF77`) and serialises host-endian floats via `withUnsafeBytes(of: value.bitPattern)`. | **Retire / Exclude** — broken marker codes, host-endian serialization, and unwired decoder. Part 1 `RCT` and `ICT` are supported in `ColourTransform.swift`. |
| `Sources/J2KCodec/J2KDCOffset.swift` | 642 | Part 1 Annex G.1 & Part 2 `DCO` | Mixes standard Part 1 unsigned level shift ($2^{B-1}$) with Part 2 variable DC offset (`DCO`). Not wired into `J2KEncoderPipeline` or `J2KDecoderPipeline`. Declares `J2KDCOffsetMarkerSegment.markerCode = 0xFF5C`, which **collides with the mandatory Part 1 `QCD` marker (`0xFF5C`)** instead of Part 2 `DCO` (`0xFF70`), and writes raw IEEE-754 floats. | **Retire / Exclude** (`J2KDCOffset.swift`). Standard Part 1 unsigned DC level shift ($\mp 2^{R_i - 1}$) and signed zero-shift (`Ssiz` bit 7) are implemented directly in `Part1Pipeline.swift` and `LosslessPipeline.swift`. |
| `Sources/J2KCodec/J2KExtendedROI.swift` | 747 | Part 2 (ISO/IEC 15444-2) | Arbitrary-shape (ellipse/polygon) ROI helper. Disconnected from `J2KEncoderPipeline` and `J2KDecoderPipeline`; emits non-standard `Srgn = 2` with custom geometry bytes inside `RGN`. | **Retire / Exclude** — non-standard `RGN` payload and unwired in predecessor. Standard Part 1 MaxShift ROI (`Srgn = 0`, `RGN` `0xFF5E`) is implemented in `ROI.swift` and `Part1Pipeline.swift`. |
| `Sources/J2KCodec/J2KExtendedPrecision.swift` | 427 | Part 1 / Part 2 precision | Standalone helper struct (`J2KExtendedPrecisionConfig`, `J2KDynamicRange`, `J2KGuardBitCalculator`). Disconnected from `J2KEncoderPipeline` and `J2KDecoderPipeline`. | **Retire / Exclude** (`J2KExtendedPrecision.swift`). Extended guard-bit precision (`1...7`) and 64-bit internal bit-plane coding (`BitPlaneCoder.encodeRich`/`decodeRich` up to 62 bit-planes) are implemented directly in `SwiftJ2K`. |
| `Sources/J2KCodec/J2KPerceptualEncoder.swift`<br>`Sources/J2KCodec/J2KVisualMasking.swift`<br>`Sources/J2KCodec/J2KVisualWeighting.swift`<br>`Sources/J2KCodec/J2KAdaptiveBlockSize.swift` | 466<br>459<br>366<br>501 | Perceptual / Encoder heuristics | Standalone CSF / contrast-masking / block-size heuristics. Completely disconnected from `J2KEncoderPipeline` (`J2KPerceptualEncoder.encodeVisual` computes weights using hardcoded `meanLuminance: 128.0` and `localVariance: 100.0` placeholders and never invokes the encoder). | **Retire / Exclude** — unwired placeholder heuristics with no codestream representation. Standard L2 synthesis norm weighting (`Table E.1`) and PCRD-opt rate-distortion allocation are implemented in `Quantization.swift`. |
| `Sources/J2KCodec/J2KTrellisQuantizer.swift` | 638 | Quantisation heuristic | Viterbi TCQ/RDO helper. Instantiated in one branch of `J2KEncoderPipeline` when `useTCQ == true`, but its output `.coefficients` array is immediately copied into a local variable while the actual subband data is left untouched (`J2KEncoderPipeline.swift:3552–3571`). No Part 2 TCQ marker or entropy decoder exists. | **Retire / Exclude** — dead/no-op code in predecessor and Part 2 TCQ is outside Part 1 scope. |
| `Sources/J2KCodec/J2KQualityMetrics.swift` | 527 | Validation metrics | Standalone PSNR / MSE / SSIM / MS-SSIM calculator used only by tests and CLI compare verbs. | **Exclude from shipped library** — MSE/PSNR verification lives in the test suite (`Tests/SwiftJ2KTests/Part1BreadthTests.swift`). |
| `Sources/J2KCodec/MJ2EncoderFactory.swift`<br>`Sources/J2KCodec/MJ2SoftwareEncoder.swift`<br>`Sources/J2KCodec/MJ2VideoConfiguration.swift`<br>`Sources/J2KCodec/MJ2VideoEncoderProtocol.swift`<br>`Sources/J2KCodec/MJ2VideoToolbox.swift`<br>`Sources/J2KMetal/MJ2MetalPreprocessing.swift` | 209<br>298<br>214<br>276<br>734<br>605 | Motion JPEG 2000 / H.264 / HEVC stubs | Despite the `MJ2*` prefix, these files are **not** an ISO/IEC 15444-3 (`.mj2` container) implementation; they are unfinished H.264/HEVC video transcoding stubs (`MJ2VideoCodec = .h264 | .hevc`). Every `encode`/`decode` method in `MJ2SoftwareEncoder` and `MJ2VideoToolbox` throws `J2KError.notImplemented("... integration pending")` or returns a `nil` placeholder buffer. Worse, `MJ2SoftwareEncoder.checkFFmpegAvailability()` spawns `/usr/bin/env sh -c "which ffmpeg"` via `Foundation.Process`, violating `AGENTS.md` ("No runtime fallback to an external reference codec or shell executable") and the single-image contract (`API-13`). | **Retire / Exclude** — non-functional H.264/HEVC stubs and shell-outs that violate `AGENTS.md` and `SUITE_POLICY.md`. |

---

## 3. Per-Feature OpenJPEG 2.5.4 and Kakadu 8.4.1 Cross-Decode Fixtures

Generated deterministically by [Scripts/generate-part1-breadth-fixtures.py](../Scripts/generate-part1-breadth-fixtures.py) using OpenJPEG `2.5.4` and Kakadu `v8.4.1` and stored with SHA-256 provenance in [Tests/SwiftJ2KTests/Fixtures/Part1Breadth/manifest.json](../Tests/SwiftJ2KTests/Fixtures/Part1Breadth/manifest.json). Every fixture is inspected and decoded by `SwiftJ2K` in `independentPart1BreadthFixturesDecodeCorrectly` ([Tests/SwiftJ2KTests/Part1BreadthTests.swift](../Tests/SwiftJ2KTests/Part1BreadthTests.swift)), and `SwiftJ2K`-encoded Part 1 breadth codestreams are cross-decoded by both `opj_decompress` and `kdu_expand` in `independentOraclesCrossDecodePart1BreadthEncodings`.

| Fixture file | Tool | Geometry & type | Feature coverage | Bytes | SHA-256 (prefix) | Oracle / SwiftJ2K result |
| --- | --- | --- | --- | ---: | --- | --- |
| `rgb8_64x48_gradient.opj_rct.j2k` | OpenJPEG 2.5.4 | `64×48×3` `uint8` | 3-comp RGB, 5/3 lossless + RCT | 4,530 | `2ca4d3085413…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgb8_64x48_gradient.kdu_rct.j2k` | Kakadu 8.4.1 | `64×48×3` `uint8` | 3-comp RGB, 5/3 lossless + RCT | 4,542 | `996c2939c70f…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgb8_64x48_gradient.kdu_nomct.j2k` | Kakadu 8.4.1 | `64×48×3` `uint8` | 3-comp RGB, 5/3 lossless, no MCT (`Cycc=no`) | 3,844 | `e2135a83e9ba…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgb8_64x48_gradient.opj_ict.j2k` | OpenJPEG 2.5.4 | `64×48×3` `uint8` | 3-comp RGB, 9/7 irreversible + ICT (`-I -q 45`) | 1,356 | `647b59a3a830…` | Lossy (`PSNR = 44.68 dB`, `maxErr = 7`, `.lossy`) |
| `rgb8_64x48_gradient.kdu_ict.j2k` | Kakadu 8.4.1 | `64×48×3` `uint8` | 3-comp RGB, 9/7 irreversible + ICT (`-rate 3.0`) | 1,136 | `f9823c97ef5c…` | Lossy (`PSNR = 44.02 dB`, `maxErr = 6`, `.lossy`) |
| `rgb8_64x48_gradient.opj_tiles_layers.j2k` | OpenJPEG 2.5.4 | `64×48×3` `uint8` | Multi-tile (`32×24`) + 3 layers + `PCRL` + `SOP`/`EPH` | 6,111 | `b9a544a9c469…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgb8_64x48_gradient.opj_layers_poc.j2k` | OpenJPEG 2.5.4 | `64×48×3` `uint8` | 3 layers + `POC` (`0xFF5F` `RLCP`/`LRCP`) + `SOP`/`EPH` | 4,825 | `21983f96537c…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgb8_64x48_gradient.kdu_tiles_layers_precincts.j2k` | Kakadu 8.4.1 | `64×48×3` `uint8` | Multi-tile (`32×24`) + 3 layers + precincts (`16×16`) + `RPCL` + `SOP`/`EPH` + `BYPASS\|RESTART\|SEGMARK` | 10,310 | `32f1e1586c97…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgba8_32x24_pattern.kdu.j2k` | Kakadu 8.4.1 | `32×24×4` `uint8` | 4-comp RGBA lossless (`Cycc=no`) | 1,565 | `0f89a385bf2b…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `rgb12_33x25_pattern.kdu_rct.j2k` | Kakadu 8.4.1 | `33×25×3` `uint12` | 3-comp 12-bit RGB lossless + RCT | 2,656 | `e841f7510b15…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s08_37x23_signed.opj_rev.j2k` | OpenJPEG 2.5.4 | `37×23×1` `int8` | Signed 8-bit (`Ssiz = 0x87`) lossless 5/3 | 799 | `81177d4847a8…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s08_37x23_signed.kdu_rev.j2k` | Kakadu 8.4.1 | `37×23×1` `int8` | Signed 8-bit (`Ssiz = 0x87`) lossless 5/3 | 882 | `3f86bc445334…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s12_45x31_signed.opj_rev.j2k` | OpenJPEG 2.5.4 | `45×31×1` `int12` | Signed 12-bit (`Ssiz = 0x8B`) lossless 5/3 | 1,345 | `230037067131…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s12_45x31_signed.kdu_rev.j2k` | Kakadu 8.4.1 | `45×31×1` `int12` | Signed 12-bit (`Ssiz = 0x8B`) lossless 5/3 | 1,435 | `89c0d68126be…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s16_64x48_signed.opj_rev.j2k` | OpenJPEG 2.5.4 | `64×48×1` `int16` | Signed 16-bit (`Ssiz = 0x8F`) lossless 5/3 | 3,470 | `87cb441a0d73…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s16_64x48_signed.kdu_rev.j2k` | Kakadu 8.4.1 | `64×48×1` `int16` | Signed 16-bit (`Ssiz = 0x8F`) lossless 5/3 | 3,546 | `01ff74999746…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `s16_64x48_signed.kdu_irrev.j2k` | Kakadu 8.4.1 | `64×48×1` `int16` | Signed 16-bit (`Ssiz = 0x8F`) 9/7 irreversible (`-rate 4.0`) | 1,182 | `79825c89e4e2…` | Lossy (`PSNR = 79.17 dB`, `maxErr = 28`, `.lossy`) |
| `g16_64x64_smooth.opj_expounded.j2k` | OpenJPEG 2.5.4 | `64×64×1` `uint16` | 16-bit 9/7 irreversible, scalar-expounded (`Sqcd = 2`) | 263 | `772206a78d57…` | Lossy (`PSNR = 44.17 dB`, `maxErr = 2681`, `.lossy`) |
| `g16_64x64_smooth.kdu_derived.j2k` | Kakadu 8.4.1 | `64×64×1` `uint16` | 16-bit 9/7 irreversible, scalar-derived (`Sqcd = 1`, `Qderived=yes`) | 1,279 | `3707d6d5355a…` | Lossy (`PSNR = 79.46 dB`, `maxErr = 23`, `.lossy`) |
| `g16_64x64_smooth.kdu_expounded_gb4.j2k` | Kakadu 8.4.1 | `64×64×1` `uint16` | 16-bit 9/7 irreversible, scalar-expounded (`Sqcd = 2`), 4 guard bits (`Qguard=4`) | 1,267 | `55084b92e1be…` | Lossy (`PSNR = 79.17 dB`, `maxErr = 24`, `.lossy`) |
| `g08_64x64_smooth.opj_roi.j2k` | OpenJPEG 2.5.4 | `64×64×1` `uint8` | MaxShift ROI (`RGN` `0xFF5E`, `Srgn = 0`, shift = 11) | 1,936 | `f090ca4381cb…` | Exact (`maxErr = 0`, `.exactSamples`) |
| `g08_64x64_smooth.kdu_roi.j2k` | Kakadu 8.4.1 | `64×64×1` `uint8` | MaxShift ROI (`RGN` `0xFF5E`, `Srgn = 0`, `Rshift=11`) | 2,431 | `ca83f9653411…` | Exact (`maxErr = 0`, `.exactSamples`) |

---

## 4. Rate-Distortion Tables

Measured using `.build/out/Products/Release/swiftj2k-cli` on `g16_256x256_smooth` (`256×256`, 16-bit unsigned greyscale, `131,072` raw sample bytes) and `rgb8_64x48_gradient` (`64×48`, 8-bit 3-component RGB, `9,216` raw sample bytes).

### 4.1 16-bit Greyscale (`g16_256x256_smooth`, `256×256`, peak = `65535`)

| Mode / Control | Wavelet / Quantisation | Output bytes | Actual bpp | MSE | PSNR (dB) | Max abs error | Reported `Fidelity` |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `.lossy` (`targetBitsPerPixel: 0.25`) | 9/7 irreversible (`Sqcd = 2`) | 2,218 | 0.271 | 2,091.91 | 63.12 | 293 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 0.50`) | 9/7 irreversible (`Sqcd = 2`) | 4,273 | 0.522 | 481.44 | 69.50 | 100 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 1.00`) | 9/7 irreversible (`Sqcd = 2`) | 8,379 | 1.023 | 307.27 | 71.45 | 81 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 2.00`) | 9/7 irreversible (`Sqcd = 2`) | 16,584 | 2.024 | 130.29 | 75.18 | 46 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 4.00`) | 9/7 irreversible (`Sqcd = 2`) | 32,972 | 4.025 | 9.20 | 86.69 | 13 | `.lossy` |
| `.lossy` (`quality: 0.25`) | 9/7 irreversible (`Sqcd = 2`) | 28,214 | 3.444 | 16.83 | 84.07 | 17 | `.lossy` |
| `.lossy` (`quality: 0.50`) | 9/7 irreversible (`Sqcd = 2`) | 42,727 | 5.216 | 1.54 | 94.45 | 5 | `.lossy` |
| `.lossy` (`quality: 0.75`) | 9/7 irreversible (`Sqcd = 2`) | 56,195 | 6.860 | 0.20 | 103.34 | 2 | `.lossy` |
| `.lossy` (`quality: 0.90`) | 9/7 irreversible (`Sqcd = 2`) | 64,098 | 7.824 | 0.01 | 116.30 | 1 | `.lossy` |
| `.nearLossless(maximumAbsoluteError: 5)` | 5/3 reversible + bounded rounding | 58,741 | 7.171 | 0.95 | 96.57 | 4 ($\le 5$) | `.boundedError(5)` |
| `.nearLossless(maximumAbsoluteError: 2)` | 5/3 reversible + bounded rounding | 64,328 | 7.853 | 0.00 | $\infty$ | 0 ($\le 2$) | `.boundedError(2)` |
| `.nearLossless(maximumAbsoluteError: 1)` | 5/3 reversible + bounded rounding | 64,328 | 7.853 | 0.00 | $\infty$ | 0 ($\le 1$) | `.boundedError(1)` |
| `.lossless` | 5/3 reversible (`Sqcd = 0`) | 64,328 | 7.853 | 0.00 | $\infty$ | 0 | `.exactSamples` |

### 4.2 8-bit 3-Component RGB (`rgb8_64x48_gradient`, `64×48×3`, peak = `255`)

| Mode / Control | Wavelet / MCT | Output bytes | Actual bpp | MSE | PSNR (dB) | Max abs error | Reported `Fidelity` |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `.lossy` (`targetBitsPerPixel: 0.50`) | 9/7 + ICT | 342 | 0.891 | 7.51 | 39.37 | 17 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 1.00`) | 9/7 + ICT | 551 | 1.435 | 4.51 | 41.59 | 9 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 2.00`) | 9/7 + ICT | 951 | 2.477 | 3.04 | 43.31 | 8 | `.lossy` |
| `.lossy` (`targetBitsPerPixel: 4.00`) | 9/7 + ICT | 1,734 | 4.516 | 1.84 | 45.47 | 5 | `.lossy` |
| `.lossy` (`quality: 0.25`) | 9/7 + ICT | 352 | 0.917 | 6.75 | 39.84 | 13 | `.lossy` |
| `.lossy` (`quality: 0.50`) | 9/7 + ICT | 747 | 1.945 | 3.08 | 43.25 | 7 | `.lossy` |
| `.lossy` (`quality: 0.75`) | 9/7 + ICT | 2,421 | 6.305 | 0.97 | 48.26 | 5 | `.lossy` |
| `.lossy` (`quality: 0.90`) | 9/7 + ICT | 3,778 | 9.839 | 0.30 | 53.37 | 2 | `.lossy` |
| `.nearLossless(maximumAbsoluteError: 5)` | 5/3 (no MCT) | 2,519 | 6.560 | 0.76 | 49.32 | 4 ($\le 5$) | `.boundedError(5)` |
| `.lossless` | 5/3 + RCT | 4,431 | 11.539 | 0.00 | $\infty$ | 0 | `.exactSamples` |

---

## 5. Capability Matrix

| Feature | Decode | Encode | Transcode (`J2K ↔ HTJ2K`) |
| --- | --- | --- | --- |
| Sample types & bit depths | Unsigned & signed (`1...16` meaningful bits in 8-bit or 16-bit storage) | Unsigned & signed (`1...16` meaningful bits in 8-bit or 16-bit storage) | Unsigned 1–16 bits in 16-bit storage (lossless coefficient path) |
| Component counts & layouts | `1...N` components (greyscale, RGB planar/interleaved, RGBA, multi-component) | `1...N` components (greyscale, RGB planar/interleaved, RGBA, multi-component) | Single-component lossless profile |
| Colour transforms | None (`0`), Part 1 `RCT` (5/3), Part 1 `ICT` (9/7) | `.automatic`, `.none`, `.rct` (5/3), `.ict` (9/7) | None (`0`) |
| Wavelets | 5/3 reversible & 9/7 irreversible (`0...32` levels, arbitrary origins) | `.automatic`, `.reversible53`, `.irreversible97` (`0...32` levels) | 5/3 reversible (preserved in coefficient domain) |
| Quantisation & guard bits | Unquantised (`Sqcd = 0`), scalar-derived (`Sqcd = 1`), scalar-expounded (`Sqcd = 2`), `QCC`, `1...7` guard bits, 64-bit bit-plane coding | `.automatic`, `.none`, `.scalarDerived`, `.scalarExpounded`, `1...7` guard bits, `baseStepSize` | Unquantised (`Sqcd = 0`) |
| Compression modes & rate control | `.lossless` (`.exactSamples`) & `.lossy` | `.lossless`, `.nearLossless(maximumAbsoluteError:)` (`.boundedError`), `.lossy` (`quality`, `targetBitsPerPixel`, `qualityLayers`, `layerBitrates`) | `.lossless` (`pixelAllocations == 0`, `copyEvents == 0`) |
| Region of Interest (ROI) | `RGN` (`0xFF5E`, MaxShift `Srgn = 0`, main & tile-part headers) | `CodecOptions.RegionOfInterest` (`RGN` `0xFF5E`, MaxShift $s \ge \max_b M_b$) | Rejected (`unsupportedFeature`) |
| Tiles, layers, precincts, progressions, `POC` | Arbitrary tiles/origins, `1...255` layers, explicit precincts, `LRCP`/`RLCP`/`RPCL`/`PCRL`/`CPRL`, `POC` (`0xFF5F`), `SOP`/`EPH`, tile-parts | Configurable `tileWidth`/`tileHeight`, `qualityLayers`/`layerBitrates`, `precinctSizes`, all 5 progressions, `progressionChanges` (`POC`), `usesSOP`/`usesEPH` | Preserves tiles, origins, decomposition levels, and `COM` metadata |
| Code-block styles | Part 1 all 6 bits (`0x01...0x20`); Part 15 HT (`0x40`, `0xC0` mixed cleanup) | Part 1 all 6 bits (`codeBlockStyleBits`); Part 15 HT (`0x40`) | Re-encoded in target block coding (`--code-block` supported) |
| Unsupported features (rejected with `unsupportedFeature`) | Sub-sampled components (`XRsiz`/`YRsiz != 1`), `PPM`/`PPT`, Part 2 (`Rsiz` extensions), HT `SigProp`/`MagRef` & multiple HT sets, JP2/JPH/JPX containers | Sub-sampled components, HT lossy/multi-component/ROI, Part 2, JP2/JPH/JPX containers | Lossy/quantised, multi-component, ROI, `POC`, changing decomposition levels |
| Acceleration | Scalar CPU only (`.scalarCPU`) | Scalar CPU only (`.scalarCPU`) | Scalar CPU only (`.scalarCPU`) |

---

## 6. Executed Validation and Benchmark Evidence

Executed on Apple Silicon (`arm64`), macOS, with OpenJPEG `2.5.4` (`/opt/homebrew/bin/opj_compress`, `/opt/homebrew/bin/opj_decompress`) and Kakadu `v8.4.1` (`/usr/local/bin/kdu_compress`, `/usr/local/bin/kdu_expand`).

| Gate | Command | Result |
| --- | --- | --- |
| Common contract byte-identity | `cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt` | **7 of 7 `OK`** |
| Debug test suite | `swift test` | **108 of 108 passed** in 2 suites (`7.675 s`, `0` failures, `0` skips) |
| Release test suite | `swift test -c release --disable-xctest` | **108 of 108 passed** in 2 suites (`0.302 s`, `0` failures, `0` skips) |
| Part 1 breadth fixture matrix | `swift test --filter Part1Breadth` | **22 of 22 OpenJPEG 2.5.4 and Kakadu 8.4.1 fixtures** decoded and verified (`0.404 s`), plus round-trip and oracle cross-decode tests (`10 of 10` test declarations passed) |
| CLI conformance suite | `python3 Scripts/test-cli.py --binary .build/out/Products/Release/swiftj2k-cli --output <dir>` | **184 of 184 process checks passed** (exit `0`), including 9/7 validation, Part 2 rejection (exit `4`), 3D RGB NRRD lossless (5/3+RCT) & lossy (9/7+ICT), and signed `int16` near-lossless + ROI |

### Release Benchmarks (`256×256`, 5 warm-ups + 20 timed runs, `.build/out/Products/Release/swiftj2k-cli`)

| Workload | CLI wall-clock median (`p95`) | In-process API median (`p95`) | Peak workspace bytes | Copy events |
| --- | ---: | ---: | ---: | ---: |
| `RGB8 256×256` Lossless (`5/3 + RCT`) encode | `29.46 ms` (`30.25 ms`) | `22.86 ms` (`23.31 ms`) | `864,516 B` | `0` |
| `RGB8 256×256` Lossless (`5/3 + RCT`) decode | `30.72 ms` (`33.34 ms`) | `24.03 ms` (`26.25 ms`) | `898,702 B` | `0` |
| `RGB8 256×256` Lossy (`9/7 + ICT`, `quality = 0.85`) encode | `28.06 ms` (`30.90 ms`) | `21.57 ms` (`24.06 ms`) | `1,650,948 B` | `0` |
| `RGB8 256×256` Lossy (`9/7 + ICT`, `quality = 0.85`) decode | `28.17 ms` (`28.53 ms`) | `21.68 ms` (`21.86 ms`) | `1,672,680 B` | `0` |
| `Grey16 256×256` Lossy (`9/7`, `bpp = 2.0`) encode | `29.62 ms` (`30.42 ms`) | `23.24 ms` (`23.61 ms`) | `602,372 B` | `0` |
| `Grey16 256×256` Lossy (`9/7`, `bpp = 2.0`) decode | `14.11 ms` (`15.39 ms`) | `7.86 ms` (`8.91 ms`) | `618,844 B` | `0` |
