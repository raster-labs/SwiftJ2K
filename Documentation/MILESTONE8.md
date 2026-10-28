# Milestone 8 — JP2, JPH and JPX Containers, Box Metadata and Resource Limits

**Status:** Implemented on branch `antigravity/milestone8-containers` from `origin/main` (`ec1d39c5ca671c0377c1eb1f895bd2d08f888565`) against pinned predecessor `Raster-Lab/J2KSwift` [`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`](https://github.com/Raster-Lab/J2KSwift/commit/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca).
**Contract:** `0.10.0` (verified byte-identical against `Documentation/COMMON_CONTRACT_SHA256.txt`).
**Toolchain:** Apple Swift `6.4-dev` (`Swift 6` language mode, complete concurrency checking) on macOS 26.4 (`arm64-apple-macosx26.0`, Apple M3 Max).

---

## 1. Scope and Summary

Milestone 8 implements ISO/IEC 15444-1 Annex I (`JP2`), ISO/IEC 15444-15 Annex A (`JPH`), and ISO/IEC 15444-2 Annex M single-codestream (`JPX`) file format containers across the `SwiftJ2K` library, `Transcoder`, and `swiftj2k-cli`:

1. **Box Reader, Writer, and Recursive Superbox Bounds (`JP2BoxReaderWriter.swift`)**:
   - Standard 8-byte (`LBox >= 8`), 16-byte extended (`LBox == 1`, `XLBox >= 16`), and to-end-of-container (`LBox == 0`) ISO/IEC 15444-1 Annex I box framing with checked arithmetic;
   - Recursive superbox traversal enforcing `ResourceLimits.maximumNestingDepth` (default `16`) and `ResourceLimits.maximumInputBytes`.
2. **Container Brand Detection and Reader Requirements (`JP2ReaderRequirements.swift`, `JP2Boxes.swift`)**:
   - ISO/IEC 15444-1 `jP  ` (`0x6A502020`, `\r\n\x87\n`) 12-byte signature box (`JP2SignatureBox`);
   - File Type box (`ftyp`, `JP2FileTypeBox`) distinguishing `.jp2` (`brand = "jp2 "`), `.jph` (`brand = "jph "`), and `.jpx` (`brand = "jpx "` / `"jpxb"`, compatible brands `["jpx ", "jp2 ", "jpxb"]` or `["jpx ", "jph ", "jpxb"]`);
   - Reader Requirements box (`rreq`, `JP2ReaderRequirementsBox`) supporting arbitrary 16-bit standard feature codes (`SF`, preserving unknown/Kakadu feature codes such as `SF=45, 8, 31, 20`) alongside vendor masks (`VF`) and full `FUAM`/`DCM` bitmask evaluation.
3. **JP2 Header Superbox (`jp2h`) and Pixel Pipeline Integration (`JP2Boxes.swift`, `JP2Container.swift`)**:
   - Image Header (`ihdr`, `JP2ImageHeaderBox`) and Bits Per Component (`bpcc`, `JP2BitsPerComponentBox`) cross-validated against embedded codestream `SIZ` dimensions, component counts, bit depths, and signedness;
   - Colour Specification (`colr`, `JP2ColourSpecificationBox`): enumerated colourspaces (`sRGB = 16`, `greyscale = 17`, `sYCC = 18`, `esRGB = 20`, `rommRGB = 21`, `YPbPr60 = 22`, `YPbPr50 = 23`, `esYCC = 24`, plus JPH `METH = 1`/`3` compatibility) and Restricted/Any ICC profiles (`METH = 2` / `METH = 3`) bounded by `ResourceLimits.maximumICCBytes` and exposed in `ImageMetadata.iccProfile`;
   - Palette (`pclr`, `JP2PaletteBox`) and Component Mapping (`cmap`, `JP2ComponentMappingBox`): full LUT expansion (`direct` and `palette` column mapping) on decode into expanded multi-component `Image` planes with per-column bit depth and signedness;
   - Channel Definition (`cdef`, `JP2ChannelDefinitionBox`): colour channel association ordering (`Asoc = 1...N`), straight opacity (`Typ = 1`, `AlphaMode.straight`), and premultiplied opacity (`Typ = 2`, `AlphaMode.premultiplied`) mapped into `ImageDescriptor.alpha` and `PixelLayout`;
   - Resolution superbox (`res `, `JP2ResolutionBox`): standard 10-byte Capture (`resc`) and Default Display (`resd`) grid resolution boxes (`VRN`, `VRD`, `HRN`, `HRD`, `VRE`, `HRE`) exposed in `ImageMetadata.codecMetadata["jp2.resc"]` and `"jp2.resd"`.
4. **Ancillary Metadata and Resource Limits (`JP2Boxes.swift`, `JP2Container.swift`)**:
   - Top-level and nested `xml ` (`JP2XMLBox`), `uuid` (`JP2UUIDBox`), `uinf`/`ulst`/`url ` (`JP2UUIDInfoBox`), `jp2i` (`JP2IntellectualPropertyBox`), and `asoc`/`lbl ` (`JP2AssociationBox`, `JP2LabelBox`) parsing and round-trip serialisation;
   - Strict enforcement of `ResourceLimits.maximumMetadataBytes`, `ResourceLimits.maximumICCBytes`, and `ResourceLimits.maximumNestingDepth` with deterministic `CodecError.resourceLimitExceeded`;
   - Full `MetadataPolicy.preserve` versus `MetadataPolicy.discardAncillary` support on `Encoder.encode`, `Decoder.decode`, and `Transcoder.transcode`, recording discarded ancillary bytes and box counts in `OperationReport` (`metadata.ancillary.discarded.bytes`, `metadata.ancillary.discarded.boxes`).
5. **Codec, Transcoder, and CLI Integration**:
   - `CodecOptions.ContainerFormat` (`.codestream`, `.jp2`, `.jph`, `.jpx`) and `CodecOptions.resolution` (`ResolutionMetadata`);
   - `Decoder.inspect`, `Decoder.validate`, and `Decoder.decode` automatically detect and unwrap `.jp2`, `.jph`, and `.jpx` containers, cross-validating `jp2h` against `SIZ` and applying palette LUTs, channel definitions, ICC profiles, and ancillary metadata;
   - `Transcoder.transcode` supports all 6 formats (`jpeg2000-codestream`, `htj2k-codestream`, `jp2`, `jph`, `jpx`, `jpx-htj2k`) in any lossless combination directly in the wavelet coefficient domain (`pixelAllocations == 0`, `copyEvents == 0`), migrating or stripping container boxes according to `MetadataPolicy`;
   - `swiftj2k-cli` supports `--format j2k|htj2k|jp2|jph|jpx` on `encode`, container auto-detection on `decode`/`inspect`/`validate`, and `--from`/`--to j2k|htj2k|jp2|jph|jpx|jpx-htj2k` on `transcode`.

---

## 2. Predecessor `Sources/J2KFileFormat/` Audit (`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`)

In accordance with `IMPLEMENTATION.md` line 67 and `AGENTS.md`, all 9 files (`7,374` lines) in `Sources/J2KFileFormat/` and 9 test files (`4,725` lines) in `Tests/J2KFileFormatTests/` at pinned predecessor SHA `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca` were audited.

### 2.1 File-by-File Inventory and Disposition

| Predecessor path (`7acc9ae4`) | Lines | Git blob SHA | Disposition | Successor path & notes |
| --- | ---: | --- | --- | --- |
| `Sources/J2KFileFormat/J2KBox.swift` | 459 | `7454cce4f9fd6cd4eb16667c8475a6168dd49a16` | **Adapted** | `Sources/SwiftJ2K/Container/JP2BoxReaderWriter.swift`. Replaced unchecked `UInt64` to `Int` casts, fixed `LBox == 1` extended-length validation (`XLBox < 16` caused infinite loops or negative Range traps), and added `ResourceLimits.maximumNestingDepth`. |
| `Sources/J2KFileFormat/J2KReaderRequirements.swift` | 742 | `af5396d49160c1ef3c43195462da1d33c349350b` | **Adapted** | `Sources/SwiftJ2K/Container/JP2ReaderRequirements.swift`. Replaced closed 15-case enum rejection of unknown standard features (`SF`) with raw `UInt16` feature storage + optional enum mapping so Kakadu `.jpx` (`SF = 45, 8, 31, 20`) parses cleanly. |
| `Sources/J2KFileFormat/J2KBoxes.swift` | 2,981 | `e68211ec42ebdb0f3c651203121ebefbe39f8961` | **Adapted** | `Sources/SwiftJ2K/Container/JP2Boxes.swift`. Adapted `jP  `, `ftyp`, `ihdr`, `bpcc`, `colr`, `pclr`, `cmap`, `cdef`, `res `/`resc`/`resd`, `xml `, `uuid`, `uinf`/`ulst`/`url `. Fixed 19-byte non-standard `resc`/`resd` layout to the 10-byte ISO/IEC 15444-1 Annex I.5.3.7 layout and fixed `pclr` 32–38-bit integer shift overflow. |
| `Sources/J2KFileFormat/J2KPart2Boxes.swift` | 994 | `cb94f96a69d1b8783c6ae11b2a083686f340c037` | **Partially Adapted (`jp2i`, `asoc`, `lbl `); Remainder Retired** | `Sources/SwiftJ2K/Container/JP2Boxes.swift` adapts `jp2i` (`JP2IntellectualPropertyBox`), `asoc` (`JP2AssociationBox`), and `lbl ` (`JP2LabelBox`). Unwired/invented Part 2 & Part 6 JPM boxes (`ftbl`, `flst`, `dcof`, `pcol`, `page`, `lobj`, `nlst`, `cref`, `dsig`, `roid`) are excluded. |
| `Sources/J2KFileFormat/J2KFileFormat.swift` | 777 | `ee885c1b0b6e8405edfbcb376da513322beee1df` | **Adapted** | `Sources/SwiftJ2K/Container/JP2Container.swift`. Replaced codestream-only extraction with full `jp2h` validation, palette LUT expansion, channel definition mapping, ICC/metadata limit enforcement, and `MetadataPolicy` handling. |
| `Sources/J2KFileFormat/J2KDecoder+FileFormatSupport.swift` | 80 | `54dcb4103a7d1e42a9d224f50d0044b195725ac9` | **Adapted** | Folded into `Sources/SwiftJ2K/Container/JP2Container.swift` and `Sources/SwiftJ2K/CodecAPI.swift`. |
| `Sources/J2KFileFormat/J2KEncoder+FileFormatSupport.swift` | 89 | `db4bd77decf6c4c63580c369054694cc031309ec` | **Adapted** | Folded into `Sources/SwiftJ2K/Container/JP2Container.swift` and `Sources/SwiftJ2K/CodecAPI.swift`. |
| `Sources/J2KFileFormat/J2KJPXAnimation.swift` | 1,201 | `d6e56e77de67d263839b18f385a8f6f2247329d3` | **Retired / Excluded** | Multi-frame JPX animation/compositor (`comp`, `copt`, `inst`, `oplb`) is outside the single-image contract (`SUITE_POLICY.md`), had zero connection to `J2KFileReader`/`J2KFileWriter`, and used non-standard box layouts (`inst` omitted `ITyp`/`REPT`/`TICK`; `comp` omitted `chd `). |
| `Sources/J2KFileFormat/J2KFileFormat.docc/J2KFileFormat.md` | 51 | `5a3ac8ba8a4489056c26ab586f77b2cc314ed218` | **Retired / Excluded** | Predecessor DocC landing page referencing legacy `J2KSwift` types. |

### 2.2 Six Predecessor `J2KFileFormat` Defects Discovered and Fixed

1. **`LBox == 1` (`XLBox < 16`) Infinite Loop and Fatal Range Trap in `J2KBoxReader`**:
   - In `Sources/J2KFileFormat/J2KBox.swift` lines 255–265, `peekNextBox()` read the 8-byte `XLBox` when `LBox == 1` without checking `XLBox >= 16`. Setting `XLBox = 0` caused `while let boxInfo = try reader.nextBox()` to loop forever (`currentOffset += 0`), while `XLBox in 1...15` produced a negative `contentLength = totalLength - 16`, trapping in `data.subdata(in:)`.
   - **Fix**: `JP2BoxReader.nextBox()` in `Sources/SwiftJ2K/Container/JP2BoxReaderWriter.swift` validates `xlBox >= 16` with checked arithmetic and throws `CodecError.corruptBitstream`.
2. **`J2KFileReader.extractCodestream` Fatal Crash on `LBox == 1` `jp2c` Boxes**:
   - In `Sources/J2KFileFormat/J2KFileFormat.swift` lines 407–424, `extractCodestream(from:)` manually parsed only the 8-byte standard box header (`length = UInt32(...)`, `boxDataEnd = offset + Int(length)`) and sliced `data.subdata(in: contentStart..<boxDataEnd)`. Because Kakadu `kdu_compress` always writes `jp2c` with a 16-byte extended header (`LBox == 1`) in `.jpx` files, `contentStart` (`offset + 8`) exceeded `boxDataEnd` (`offset + 1`), crashing at runtime.
   - **Fix**: `JP2Container.parseContainer(from:limits:)` uses `JP2BoxReader` for all top-level and nested boxes, handling `LBox == 0`, `LBox >= 8`, and `LBox == 1` (`XLBox >= 16`) uniformly.
3. **`J2KReaderRequirementsBox` Rejected Valid Kakadu `.jpx` Files**:
   - In `Sources/J2KFileFormat/J2KReaderRequirements.swift` line 408, `J2KStandardFeature(rawValue: featureValue)` threw `invalidBoxContent` on any standard feature code outside its 15 enum cases. Kakadu `8.4.1` emits `SF = 45, 8, 31, 20` in `.jpx` files.
   - **Fix**: `JP2ReaderRequirementsBox.FeatureEntry` in `Sources/SwiftJ2K/Container/JP2ReaderRequirements.swift` stores the raw `UInt16` `featureCode` alongside an optional `JP2StandardFeature(rawValue:)`.
4. **Non-Standard 19-Byte `resc`/`resd` Resolution Box Layout**:
   - In `Sources/J2KFileFormat/J2KBoxes.swift` lines 1344–1536, `J2KCaptureResolutionBox` and `J2KDisplayResolutionBox` read and wrote a 19-byte payload (`UInt32` numerators/denominators + trailing `unit` byte) instead of the 10-byte ISO/IEC 15444-1 Annex I.5.3.7 layout (`VRN: UInt16`, `VRD: UInt16`, `HRN: UInt16`, `HRD: UInt16`, `VRE: Int8`, `HRE: Int8`), rejecting every standard `resc`/`resd` box produced by OpenJPEG or Kakadu.
   - **Fix**: `JP2GridResolution` (`resc` and `resd`) in `Sources/SwiftJ2K/Container/JP2Boxes.swift` implements the exact 10-byte ISO/IEC 15444-1 Annex I.5.3.7 binary format.
5. **Broken `ihdr` `BPC` Encoding and Ignored `jp2h` Metadata in `J2KFileWriter`/`J2KFileReader`**:
   - In `Sources/J2KFileFormat/J2KFileFormat.swift` lines 651–671 and 724–748, `writeJP2HeaderBox` wrote raw `image.components[0].bitDepth` (`8` instead of `7 = 8 - 1`) without signedness or `0xFF` (`bpcc` indicator), omitted `'jp2 '` from `ftyp.compatibleBrands`, and `J2KFileReader.read(from:)` discarded the entire `jp2h` superbox (`ihdr`, `bpcc`, `colr`, `pclr`, `cmap`, `cdef`, `res `) and decoded only the raw `jp2c` bytes.
   - **Fix**: `JP2Container` encodes standard `(bitDepth - 1) | (isSigned ? 0x80 : 0x00)` (or `0xFF` + `bpcc`), includes required compatible brands, cross-validates `ihdr`/`bpcc` against codestream `SIZ`, expands `pclr`+`cmap` palettes, applies `cdef` channel roles/ordering, and propagates `colr` ICC profiles and `res ` metadata.
6. **Integer Shift Overflow in `J2KPaletteBox.write()`**:
   - In `Sources/J2KFileFormat/J2KBoxes.swift` line 935, `UInt32(1) << bits` trapped in Swift when a palette column used 32–38 bits (allowed by ISO/IEC 15444-1 I.5.3.4).
   - **Fix**: `JP2PaletteBox` uses 64-bit checked arithmetic (`Int64`/`UInt64`).

---

## 3. Box Support Matrix

| Box Type | 4CC | ISO/IEC Standard | Read / Validate | Write / Transcode | Resource Limit / Policy |
| --- | --- | --- | :---: | :---: | --- |
| JPEG 2000 Signature | `'jP  '` | 15444-1 I.5.1 | Yes | Yes | Must be first box (12 bytes: `0x0000000C 6A502020 0D0A870A`) |
| File Type | `'ftyp'` | 15444-1 I.5.2 / 15444-15 A.2 / 15444-2 M.11.1 | Yes | Yes | Must follow `'jP  '`; resolves `.jp2`, `.jph`, `.jpx`, `.jpx-htj2k` |
| Reader Requirements | `'rreq'` | 15444-2 M.11.1 | Yes | Yes (`.jpx`) | Preserves arbitrary `UInt16` `SF` codes and vendor masks |
| JP2 Header Superbox | `'jp2h'` | 15444-1 I.5.3 | Yes | Yes | Checked against `ResourceLimits.maximumNestingDepth` |
| Image Header | `'ihdr'` | 15444-1 I.5.3.1 | Yes | Yes | Must be first inside `'jp2h'`; cross-checked against `SIZ` |
| Bits Per Component | `'bpcc'` | 15444-1 I.5.3.2 | Yes | Yes | Required when `ihdr.bpc == 0xFF` |
| Colour Specification | `'colr'` | 15444-1 I.5.3.3 / 15444-15 A.3 | Yes | Yes | Enumerated (`METH=1`) & ICC (`METH=2,3`); ICC bounded by `maximumICCBytes` |
| Palette | `'pclr'` | 15444-1 I.5.3.4 | Yes | Yes | Up to 1024 entries, 1–38 bits/column; LUT applied on decode |
| Component Mapping | `'cmap'` | 15444-1 I.5.3.5 | Yes | Yes | Maps codestream components directly or through `'pclr'` columns |
| Channel Definition | `'cdef'` | 15444-1 I.5.3.6 | Yes | Yes | Maps colour (`Typ=0`), straight alpha (`Typ=1`), premultiplied alpha (`Typ=2`) |
| Resolution Superbox | `'res '` | 15444-1 I.5.3.7 | Yes | Yes | Contains `'resc'` and/or `'resd'` |
| Capture Resolution | `'resc'` | 15444-1 I.5.3.7.1 | Yes | Yes | 10-byte standard grid resolution (`VRN, VRD, HRN, HRD, VRE, HRE`) |
| Default Display Resolution | `'resd'` | 15444-1 I.5.3.7.2 | Yes | Yes | 10-byte standard grid resolution (`VRN, VRD, HRN, HRD, VRE, HRE`) |
| Contiguous Codestream | `'jp2c'` | 15444-1 I.5.4 | Yes | Yes | Standard 8-byte, 16-byte extended (`LBox == 1`), or `LBox == 0` |
| XML | `'xml '` | 15444-1 I.7.1 | Yes | Yes | Ancillary: bounded by `maximumMetadataBytes`; stripped by `.discardAncillary` |
| UUID | `'uuid'` | 15444-1 I.7.2 | Yes | Yes | Ancillary: 16-byte UUID + payload; bounded by `maximumMetadataBytes` |
| UUID Info / List / URL | `'uinf'`, `'ulst'`, `'url '` | 15444-1 I.7.3 | Yes | Yes | Ancillary superbox: bounded by `maximumMetadataBytes` & `maximumNestingDepth` |
| Intellectual Property | `'jp2i'` | 15444-1 I.6 | Yes | Yes | Ancillary IPR box: bounded by `maximumMetadataBytes` |
| Association / Label | `'asoc'`, `'lbl '` | 15444-2 M.11.11 | Yes | Yes | Recursive superbox: bounded by `maximumMetadataBytes` & `maximumNestingDepth` |

---

## 4. OpenJPEG 2.5.4 and Kakadu 8.4.1 Container Fixtures

`Scripts/generate-container-fixtures.py` deterministically generates 16 container fixtures across `.jp2`, `.jph`, and `.jpx` using OpenJPEG `2.5.4` (`opj_compress` / `opj_decompress`) and Kakadu `v8.4.1` (`kdu_compress` / `kdu_expand`). All 16 fixtures and their reference pixel samples and SHA-256 digests are recorded in `Tests/SwiftJ2KTests/Fixtures/Containers/manifest.json`:

| Fixture file | Generator | Format | Geometry | Precision & Sign | Mode | Bytes | SHA-256 |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| `jp2_g16_lossless.opj.jp2` | OpenJPEG 2.5.4 | `jp2` | `16x12x1` | 12-bit unsigned | lossless | 295 B | `a8a9a107587265cd8d7bd0eeaea8a99afba1cc4db3ce4d3c78fc50b27501d54e` |
| `jp2_g16_lossless.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `16x12x1` | 12-bit unsigned | lossless | 394 B | `f3e62da4effbd7a1d7b4e34043940fb2f9a352c0bd4556a28f680db26f5f5a72` |
| `jp2_s16_lossless.opj.jp2` | OpenJPEG 2.5.4 | `jp2` | `16x12x1` | 12-bit signed | lossless | 275 B | `09b35cb5bba828894c00417d9919501565d7f79e0913d649b0e51a630412b794` |
| `jp2_s16_lossless.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `16x12x1` | 12-bit signed | lossless | 365 B | `e085afe80688f93a70669f87e143aee6cf9c5d432c16f82e0f5f3a9bc8edc34d` |
| `jp2_rgb8_rct.opj.jp2` | OpenJPEG 2.5.4 | `jp2` | `16x12x3` | 8-bit unsigned | lossless | 682 B | `7c8bd1d761162677b3c375124353a0543b02ed9995a3bf03679f368920d60c63` |
| `jp2_rgb8_rct.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `16x12x3` | 8-bit unsigned | lossless | 830 B | `34447afd2dcea953f9a04f6c78764c740e2f60cbceba35f89755b59426928ceb` |
| `jp2_rgb8_ict_lossy.opj.jp2` | OpenJPEG 2.5.4 | `jp2` | `32x24x3` | 8-bit unsigned | lossy | 413 B | `36a7eb6d7608d00d9021f6e198f80f872bc87faf258f80094e1d054e85b698a0` |
| `jp2_rgb8_ict_lossy.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `32x24x3` | 8-bit unsigned | lossy | 467 B | `022daff1944fc6038929d15b87c25198eaee4c7a82ae88c37142e3d02d1f7237` |
| `jp2_rgba8_cdef.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `16x12x4` | 8-bit unsigned | lossless | 1032 B | `b0433e919c6ea06905eadb7d50104f9dbd365d2a0e3748fb896fd2a1e2cdf269` |
| `jp2_rgb8_icc_res_meta.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `16x12x3` | 8-bit unsigned | lossless | 1683 B | `7424ff68ae060baaddcdbd36c603914c43c35692a6ef383be2b34671766d1fa5` |
| `jp2_pal8_pclr_cmap_resc.kdu.jp2` | Kakadu 8.4.1 | `jp2` | `16x12x3` | 8-bit unsigned | lossless (palette) | 1246 B | `ed20cce9182746bc64b7786dd51b899be90b7a7cd1b649a0d127d832a16b7410` |
| `jph_g16_lossless.kdu.jph` | Kakadu 8.4.1 | `jph` | `16x12x1` | 12-bit unsigned | lossless (HTJ2K) | 451 B | `06c02bd2f5a717175cb470920206aabfe55f570f022eeacc67de8ede48185424` |
| `jph_rgb8_rct.kdu.jph` | Kakadu 8.4.1 | `jph` | `16x12x3` | 8-bit unsigned | lossless (HTJ2K) | 1029 B | `7bec8d9ab0277e56c3dda7d0b7ccad6c84e4df61e8bd66223067ea88e732d0b6` |
| `jph_rgba8_cdef.kdu.jph` | Kakadu 8.4.1 | `jph` | `16x12x4` | 8-bit unsigned | lossless (HTJ2K) | 1281 B | `53448d3d750d453cb4978f3589474095de3924c7dba0ded2f33f0132a823f233` |
| `jpx_rgb8_part1.kdu.jpx` | Kakadu 8.4.1 | `jpx` | `16x12x3` | 8-bit unsigned | lossless | 911 B | `f7fc8503a86f5083fd893efefc2ab6ce889020175b6f4ee3610670b78791d5c5` |
| `jpx_rgb8_htj2k.kdu.jpx` | Kakadu 8.4.1 | `jpx` | `16x12x3` | 8-bit unsigned | lossless (HTJ2K) | 1106 B | `e7da3b016f2a0ea76e17a5a12d8e8c8f9fa2f19cd9f779cb026b8f391b44bb3f` |

---

## 5. Verification Evidence

- **Common Contract Integrity**: `cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt` — all 7 contract documents verified `OK`.
- **Unit & Regression Test Suite (`swift test` and `swift test -c release --disable-xctest`)**:
  - `ContainerTests.swift` covers all 16 OpenJPEG and Kakadu fixtures (`inspect`, `validate`, `decode`), `.jp2`/`.jph`/`.jpx` encoding round-trips, palette (`pclr` + `cmap`) expansion (including zero-pixel-allocation `Decoder.decode(_:into:)` into caller-owned `ImageDestination`), channel definitions (`cdef` straight/premultiplied alpha & association reordering), ICC and resolution (`resc`/`resd`) preservation, ancillary boxes (`xml `, `uuid`, `uinf`/`ulst`/`url `, `jp2i`, `asoc`/`lbl `), `MetadataPolicy.preserve` vs `.discardAncillary`, `ResourceLimits` (`maximumMetadataBytes`, `maximumICCBytes`, `maximumNestingDepth`), malformed container rejection (`LBox == 1` with `XLBox < 16`, mismatched `ihdr`/`SIZ`), and container-to-container/codestream transcoding (`jp2 ↔ jph ↔ jpx ↔ j2k ↔ htj2k`) with zero pixel allocations (`pixelAllocations == 0`, `copyEvents == 0`).
- **CLI Conformance Suite (`Scripts/test-cli.py`)**:
  - `193` of `193` black-box process checks passed, including `encode --format jp2|jph|jpx`, `inspect --json`, `validate --json`, `decode`, and `transcode --from jp2 --to jph` / `--from jph --to jpx-htj2k` / `--from jpx-htj2k --to j2k`.
