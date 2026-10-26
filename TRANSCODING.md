# SwiftJ2K — lossless JPEG 2000 ↔ HTJ2K transcoding

Native-transcoding requirements introduced in contract **0.2.0**; the current common contract is **0.4.0**. Implementation instructions, 18 September 2026. The Milestone 1 API shape exists, but no successor transcoding algorithm has been implemented or qualified. Read AGENTS.md, IMPLEMENTATION.md and the common contracts first.

Application maintainers replacing predecessor transcoder calls should start with [MIGRATION.md](MIGRATION.md); operational cutover remains blocked pending qualified native transcoding.

## Required outcome

Provide both **JPEG 2000 Part 1 → HTJ2K Part 15** and **HTJ2K Part 15 → JPEG 2000 Part 1** inside the standalone SwiftJ2K library and its CLI. A single operation consumes compressed bytes and returns compressed bytes. Keep every intermediate representation in owned memory; never write an intermediate image, coefficient file or private container to disk. Neither another suite codec nor the optional umbrella is required.

The first supported profile is a complete, sample-exact lossless source with reversible transforms: unsigned greyscale, full 16-bit precision and source-declared 12 meaningful bits in 16-bit storage. Each direction, and a round trip through both, must preserve every logical sample and its precision/interpretation. Extend signed components, colour, tiles, containers and other features through explicit capability entries and evidence. Original compressed-file byte identity is not promised for J2K ↔ HTJ2K; block coding and packetisation change.

## Source inspection and reuse limits

Reviewed predecessor: [J2KSwift at 768f6b53499b806fd0304962056e1fc7833f12e5](https://github.com/Raster-Lab/J2KSwift/tree/768f6b53499b806fd0304962056e1fc7833f12e5), on 18 September 2026. This verifies source presence and control flow, not runtime correctness or performance.

- [J2KTranscoder.swift](https://github.com/Raster-Lab/J2KSwift/blob/768f6b53499b806fd0304962056e1fc7833f12e5/Sources/J2KCodec/J2KTranscoder.swift) exposes `transcode(_:direction:progress:)`, `transcodeAsync(_:direction:progress:)`, `extractCoefficients(from:)` and `encodeFromCoefficients`. The async path holds `TranscodingCoefficients` in memory between extraction and target block encoding. The core entry point does not need an intermediate file.
- That implementation is **not an acceptance baseline for lossless correctness**. `decodeLegacyCodeBlock` and `decodeHTCodeBlock` catch decoding failures and return zero arrays. Extraction feeds tile data to block decoders using assumed pass information; output tile assembly concatenates block payloads. The quantisation-marker generator uses fixed default values, and successful results set `metadataPreserved: true` unconditionally. Audit and replace these shortcuts before claiming exact transcoding or copying the implementation into the successor.
- [J2KTranscoderTests.swift](https://github.com/Raster-Lab/J2KSwift/blob/768f6b53499b806fd0304962056e1fc7833f12e5/Tests/J2KCodecTests/J2KTranscoderTests.swift) includes tests named coefficient round trips that check descriptor structure rather than exact recovered coefficients/samples. Its async and parallel-versus-sequential transcode tests are skipped with parser-hang explanations. Retain their reproducer intent, fix the failure causes and add decisive assertions; skipped tests are not passing evidence.
- [The predecessor CLI](https://github.com/Raster-Lab/J2KSwift/blob/768f6b53499b806fd0304962056e1fc7833f12e5/Sources/J2KCLICore/Transcode.swift) and `Examples/HTJ2KTranscoding.swift` are migration references. Their syntax, claims and verification flags must be reconciled with the successor contract.

No predecessor tests or codec benchmarks were executed during this documentation review. Do not repeat its headline speedup or preservation claims without new evidence.

**Milestone 2 audit, 22 September 2026.** Re-inspected at the pinned migration revision `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`: `decodeLegacyCodeBlock` and `decodeHTCodeBlock` still catch decode failures and return empty coefficient arrays, `metadataPreserved: true` is still unconditional, and `J2KTranscoderTests.swift` still skips its async and parallel transcode tests as parser hangs. None of `J2KTranscoder.swift` was migrated. The scalar Part 1 decoder and encoder that Milestone 2 added are the qualified sample path a later transcoder may build on; `Transcoder.capabilities` stays empty.

**Milestone 6 implementation, 26 October 2026.** Implemented in `Sources/SwiftJ2K/Transcoding.swift`, `Sources/SwiftJ2K/Codec/LosslessPipeline.swift` and `Sources/SwiftJ2KCLI/main.swift` on branch `antigravity/milestone6-htj2k-transcoding`; see [Documentation/MILESTONE6.md](Documentation/MILESTONE6.md). `ScalarLosslessCodec.transcode` uses the pure wavelet-coefficient path (`extractTileCoefficients` → target code-block re-blocking and encoding) with `pixelAllocations == 0` and `copyEvents == 0`, preserving multi-tile grids, image/tile origins, per-tile `COD`/`QCD` decomposition level overrides, and `COM` marker payloads. Requests that would require wavelet reconstruction (`codecOptions.decompositionLevels` differing from the source) are rejected with `CodecError(.unsupportedFeature, ...)`.

## Processing paths

**Preferred coefficient path.** Parse real packet/code-block boundaries and entropy-decode into bounded, owned quantised-wavelet coefficient storage; encode those coefficients using the target conformant block coder and build valid target packets/markers. Avoid inverse/forward wavelet transforms, dequantisation/requantisation, colour conversion and pixel materialisation. The coefficient objects are private algorithm workspace, not a new public image file format. Retain them across asynchronous work and reuse compatible storage without a redundant full-coefficient copy solely for a handoff.

Preserve the applicable component precision/sign, quantisation values, transform and component-transform semantics, tile/component/subband geometry and complete decoded information. Derive pass counts, zero bitplanes, code-block lengths and termination from the codestream. Never substitute zeros for a failed decode. A genuinely empty/zero block allowed by the standard remains valid; distinguish that case from corruption. Use the conformant Part 15 path, never a predecessor experimental/private HT representation.

**Permitted sample path.** For a qualified complete lossless source, an implementation may first use the common decoder → sealed Image → encoder path, with the intermediate uncompressed image held in one owned allocation. Decode directly into that allocation and encode from the same allocation. No intermediate file, hidden full-image repack or second final-frame allocation is permitted under `requireSharedStorage`. Report this as a sample path; do not claim it avoided wavelet transforms. Select only a path that fulfils the requested fidelity, metadata and copy policies, and report the path actually used.

Do not silently use the sample path for lossy/irreversible input. A later coefficient-preserving extension may retain an already lossy source without adding quantisation loss, but it cannot recover information lost before transcoding. Qualify that extension separately.

Do not promise identical quality-layer boundaries, progression/truncation behaviour or compressed size merely because the final image is preserved. Validate or reject requested structural preservation and report supported structural changes. Rebuild required Part 1/Part 15 signalling correctly. Handle JP2/JPH container metadata deliberately; raw codestream output must reject required metadata it cannot represent. Do not strip boxes or guess sample meaning to make a conversion succeed.

## Public API and CLI

Use the native format-pair extension in [COMMON_API.md](Documentation/COMMON_API.md): local `Transcoder(configuration:)`, `transcode(_:to:options:) async throws` returning `EncodedImage`, and `capabilities`. Local `TranscodeTarget` cases are `jpeg2000` and `htj2k`. Reuse the suite option names, resource limits, cancellation, error categories and operation reports. Detect and validate source coding from bytes; reject an incompatible explicit source claim. Configuration defaults preserve samples and the source's required interpretation.

The planned CLI performs the whole operation in one process. These examples are requirements for future executable tests, not currently runnable successor commands:

```sh
swiftj2k-cli transcode -i source.j2k --input-format j2k --output-format htj2k --mode lossless -o converted.j2c
swiftj2k-cli transcode -i converted.j2c --input-format htj2k --output-format j2k --mode lossless -o restored.j2k
```

Here `j2k` and `htj2k` explicitly select raw codestreams; JP2/JPH container support is separately declared. An extension alone does not prove the block coder or container. Support `-` for stdin/stdout using the common limits and diagnostics rules. CLI final-output atomic publication is allowed; it is not permission to stage an intermediate image. Reject lossy mode/quality settings on this lossless transcode operation.

## Acceptance and regression tests

1. Start with independently generated conformant inputs for each direction. Use non-zero textured patterns, extrema, ramps, impulses, odd dimensions and multiple code-blocks; include both 12-in-16 and full 16-bit precision. An all-zero image cannot be the sole fidelity test because it conceals zero-on-error defects.
2. Independently decode source and target and compare exact samples, precision and interpretation. Test J2K → HTJ2K → J2K and HTJ2K → J2K → HTJ2K. An ordinary Part 1 decoder is not automatically an HTJ2K oracle; pin a Part 15-capable oracle and record its licence/version. Standard tools remain test-only.
3. For the coefficient path, compare recovered quantised coefficients plus quantisation/transform semantics and prove the pixel reconstruction path was not invoked. For the sample path, prove direct writes/reads of the same allocation and zero additional final-image handoff copies. Record peak workspace, copy events and the selected path honestly.
4. Exercise malformed/truncated packet headers, invalid pass counts/lengths, tile-part boundaries, missing end markers and source/target signalling mismatches. Every failure throws a defined error; no successful black/zero-filled replacement, hang or false metadata-preserved report. Turn predecessor skipped hang cases into bounded regressions.
5. Validate limits on coefficient counts, precision-derived shifts, block/tile counts, memory, concurrent workers and deadlines with checked arithmetic. Test cancellation during parse, block decode, block encode and output assembly; join all work before releasing storage or publishing results.
6. Add signed/colour, component-specific quantisation, multi-tile/edge-tile, multiple layers/progression orders, ROI and JP2/JPH cases only as their capability entries are implemented. Unsupported combinations fail explicitly. Preserve source provenance and fixture redistribution rights.
7. Monitor filesystem access during the library operation; no intermediate files, memory-mapped scratch files or external codec processes. Fixture preparation and final CLI output are accounted separately. Benchmark each qualified path against a measured decode/re-encode baseline using the common performance policy; measure memory as well as time.

## Sequence and handover

Milestone 1 remains API/ownership feasibility with synthetic buffers. In Milestone 2, audit the predecessor transcoder alongside the scalar codec baseline; do not transfer its unsafe shortcuts. Add the first qualified in-memory J2K ↔ HTJ2K path in Milestone 3 after the initial J2K → JPEG-LS proof. Extend profiles and optimise coefficient processing in Milestone 4. Deliver the exact commands, fixture/oracle hashes, supported-direction matrix and measured results in a reviewable PR. No code migration is authorised by this document alone.

Standards context: [JPEG's HTJ2K overview](https://jpeg.org/jpeg2000/htj2k.html) identifies the block-coder replacement and mathematically lossless transcoding. Pin the applicable Part 1/Part 15 requirements when implementing; this overview is not conformance evidence.
