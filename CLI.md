# swiftj2k-cli: help, diagnostics and installation

Version **12.1.0**; Swift 6.2 minimum with Swift 6.4 qualified / Swift 6, Apple OS minimum **26.0**. The CLI targets macOS and Linux; Linux execution remains a qualification requirement. No external parser package or sibling codec is required. Since Milestone 4 the `encode`, `decode`, `inspect` and `validate` verbs operate through the NRRD interchange profile below; Milestone 6 adds Part 15 HTJ2K (`htj2k`) and native compressed-domain `transcode` (`j2k` ↔ `htj2k`); Milestone 7 adds Part 1 breadth (`--mode lossless|near-lossless|lossy`, `--max-error`, `--quality`, `--bpp`, `--layers`, `--wavelet auto|53|97`, `--mct auto|none|rct|ict`, `--progression`, `--tile-size`, `--precincts`, `--roi`, `--guard-bits`, `--qstyle`, `--sop`, `--eph`, and 2D/3D `uint8`/`int8`/`uint16`/`int16` NRRD); Milestone 8 adds JP2 (`jp2`), JPH (`jph`), and JPX (`jpx`) container formats (`--input-format`, `--output-format`, `--container codestream|jp2|jph|jpx`) and `--max-metadata BYTES`; Milestone 9 adds hardware acceleration (`--backend auto|scalar|accelerated`, mapping to `ExecutionPolicy.automatic`, `.scalarCPU`, and `.required(.accelerated)`); Milestone 12 adds multi-format image I/O (`pgm`, `ppm`, `pnm`, `png`, `tiff`, `raw` alongside `nrrd`) and the full command breadth: `convert`, `compare` (2D and 3D), `batch` (`encode`, `decode`, `transcode`, `encode3d`, `decode3d`), `encode3d`, `decode3d`, `jpip` (`client` and `server`), in-process `benchmark`, and shell `completions` (`bash`, `zsh`, `fish`); `capabilities` reports the library's actual support including `availableBackends`.

```sh
swift run swiftj2k-cli --help
swift run swiftj2k-cli -h
swift run swiftj2k-cli help capabilities
swift run swiftj2k-cli capabilities --help
swift run swiftj2k-cli --version
swift run swiftj2k-cli capabilities --json
swift run swiftj2k-cli capabilities -vv
swift run swiftj2k-cli capabilities -verbose: 3
swift run swiftj2k-cli capabilities --verbose=+++++
```

Both global and command-local help include availability, examples, option ranges/defaults, streams, errors and manual discovery. No arguments also show help. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` with the qualified Xcode on macOS.

## Codec commands and image I/O formats (CLI-01..CLI-08)

```sh
swiftj2k-cli encode -i slice.nrrd -o slice.j2k --precision 12 [--output-format j2k|htj2k|jp2|jph|jpx] [--levels N] [--code-block WxH]
swiftj2k-cli encode -i slice.png -o slice.jph --output-format jph
swiftj2k-cli encode -i rgb.nrrd -o rgb.j2k --mode lossy --quality 0.85 --wavelet 97 --mct ict
swiftj2k-cli decode -i slice.j2k -o slice.nrrd [--overwrite]
swiftj2k-cli decode -i slice.j2k -o slice.tiff [--overwrite]
swiftj2k-cli transcode -i source.j2k --input-format j2k --output-format htj2k --mode lossless -o converted.j2c
swiftj2k-cli transcode -i converted.j2c --input-format htj2k --output-format j2k --mode lossless -o restored.j2k
swiftj2k-cli inspect -i slice.j2k --json
swiftj2k-cli validate -i slice.j2k
swiftj2k-cli convert -i slice.pgm -o slice.png [--bit-depth 8|16]
swiftj2k-cli compare -i original.pgm -r decoded.png --bit-exact --json
swiftj2k-cli batch encode -i ./inputs -o ./outputs --filter '*.pgm' --threads 4 --json
swiftj2k-cli encode3d -i ./slices -o volume.j3d --codec htj2k-lossless --tile-size 128x128x16 --levels 2,2,1
swiftj2k-cli decode3d -i volume.j3d -o volume.nrrd [--region X,Y,Z,W,H,D] [--slice-range START:END]
swiftj2k-cli jpip client --single-file image.jp2 -o preview.png --region 0,0,128,128 --json
swiftj2k-cli jpip server --data-dir ./images --port 8080 [--once]
swiftj2k-cli benchmark -i slice.nrrd --runs 5 --warmup 1 --compare-all --json
swiftj2k-cli completions zsh
swiftj2k-cli decode -i - -o - < slice.j2k | swiftj2k-cli encode -i - --input-format nrrd -o - > copy.j2k
```

`-i`/`--input` and `-o`/`--output` accept `-` for standard input (read completely) and binary standard output. `--input-format` and `--output-format` take compressed formats `j2k` (raw JPEG 2000 Part 1 codestream), `htj2k` (raw HTJ2K Part 15 codestream), `jp2` (ISO/IEC 15444-1 Annex I JP2 container), `jph` (ISO/IEC 15444-15 Annex A JPH container), `jpx` (ISO/IEC 15444-2 Annex M JPX container) and uncompressed image formats `nrrd`, `pgm`, `ppm`, `pnm`, `png`, `tiff`, or `raw` (with `--dimensions WxH[xD]`, `--bit-depth 1..16`, `--components 1..16`, and `--signed`); `--container codestream|jp2|jph|jpx` selects the container wrapper on `encode` and `transcode`. A format declaration is checked against the bytes and a mismatch is exit 4, and without one the format is detected from the bytes (or output extension for uncompressed file outputs). File output goes to a sibling temporary file and is renamed into place; an existing file is refused with exit 6 unless `--overwrite` is given, and nothing partial remains after a failure. `--json` puts a JSON document on stdout for `inspect`, `validate`, `compare`, `batch`, `jpip` (when not writing binary stdout) and `benchmark`, and a JSON report on stderr for `encode`, `decode`, `transcode`, `convert`, `encode3d` and `decode3d` so binary stdout stays clean. `--mode lossless|near-lossless|lossy` (`--lossy` shorthand) is supported on `encode` (`decode`, `validate` and `transcode` accept `lossless` only; `compare` accepts `2d` or `3d`); `--backend auto|scalar|accelerated` selects `ExecutionPolicy.automatic` (default), `.scalarCPU`, or `.required(.accelerated)`; `--copy-policy`, `--metadata-policy` (`preserve` default, or `discard-ancillary` for `COM` marker segments and ancillary `xml `/`uuid`/`uinf`/`jp2i`/`asoc` container boxes), `--threads` (1..8), `--max-memory` (bytes), `--max-metadata` (bytes) and `--timeout` (seconds, exit 5) map to the library's options and limits. Every option value is validated before any input is opened.

**Encoder and transcoder options.** `--container codestream|jp2|jph|jpx` (default `codestream`, or inferred from `--output-format jp2|jph|jpx`), `--levels 0..32` (default `min(5, floor(log2(min(width, height))))` on `encode`; on `transcode` the default preserves each tile's source levels, and a `--levels` value that differs from the source is rejected with exit 4 because the coefficient path performs no wavelet reconstruction), `--code-block WxH` with powers of two from 4 to 1024 and area at most 4096 (default 64x64), `--precision 1..16` (`encode` only) for the meaningful bits when the input header carries none, `--mode lossless|near-lossless|lossy`, `--max-error E` (`--near-lossless E`), `--quality Q` (`0.0..1.0`), `--bpp RATE` (`> 0`), `--layers N` (`1..255`), `--wavelet auto|53|97`, `--mct auto|none|rct|ict`, `--progression lrcp|rlcp|rpcl|pcrl|cprl`, `--tile-size WxH`, `--precincts WxH`, `--roi X,Y,W,H[,SHIFT]`, `--guard-bits 1..7`, `--qstyle auto|none|derived|expounded`, `--sop`, and `--eph`. `transcode` operates directly on the wavelet coefficients in memory without allocating an intermediate pixel image or writing temporary files.

**Multi-format image I/O (`convert`, `compare`, `batch`, `encode3d`, `decode3d`, `jpip`, `benchmark`).**
- `convert` converts between uncompressed 2D image formats (`nrrd`, `pgm`, `ppm`, `pnm`, `png`, `tiff`, `raw`) with optional `--bit-depth 8|16` sample scaling; compressed inputs/outputs or identical source/target formats return exit 4.
- `compare` computes per-component and overall MSE, MAE, MaxError, PSNR, and bit-exactness between `-i/--input` and `-r/--reference` (`--distorted`) in `--mode 2d|3d`; threshold flags `--bit-exact`, `--max-error N`, and `--min-psnr DB` return exit 3 if violated.
- `batch` executes `encode`, `decode`, `transcode`, `encode3d`, or `decode3d` across a directory, comma-separated file list, glob pattern, or `--input-list FILE` with bounded `withTaskGroup` parallelism (`--threads 1..8`), `--recursive`, `--filter GLOB`, `--exclude GLOB`, `--output-suffix EXT`, `--continue-on-error`, and `--progress`.
- `encode3d` and `decode3d` compress and decompress 3D volumetric datasets (slice directories, 3D NRRD volumes, or 3D RAW volumes) via `SwiftJ2K3D` (`--codec j2k-lossless|j2k-lossy|htj2k-lossless|htj2k-lossy`, `--tile-size WxHxD`, `--levels N|X,Y,Z`, `--progression lrcps|rlcps|pcrls|slrcp|cprls`, `--spacing X,Y,Z`, `--origin X,Y,Z`, `--slice-range START:END`, `--region X,Y,Z,W,H,D`, `--resolution-level/--scale R`, `--layers N`, `--slice-naming PATTERN`).
- `jpip` provides `jpip client` and `jpip server` backed by `SwiftJ2KJPIP` (`--server URL`, `--target NAME`, `--single-file PATH`, `--data-dir DIR`, `--port PORT`, `--region X,Y,W,H`, `--resolution-level R`, `--quality-layers N`, `--components C0,C1`, `--coding-preference none|htj2k|standard`, `--metadata-only`, `--once`).
- `benchmark` runs in-process encode and decode performance timing (`--runs/-r N`, `--warmup N`, `--encode-only`, `--decode-only`, `--htj2k`, `--compare-all`, `--format text|json|csv`) with zero external process invocations (`POL-01`).
- `completions` emits shell completion scripts for `bash`, `zsh`, or `fish`.

**Decoder coverage.** Raw codestreams (`j2k`, `htj2k`) and box containers (`jp2`, `jph`, `jpx` including `rreq`, `ihdr`, `bpcc`, `colr` enumerated and ICC profiles, `pclr`+`cmap` palette expansion, `cdef` channel definition and alpha, `res `/`resc`/`resd` resolution, `jpch`/`jplh`, and `xml `/`uuid`/`uinf`/`jp2i`/`asoc` metadata), unsigned and signed integer samples, 1..16 meaningful bits in 8-bit or 16-bit storage, `1..N` components (greyscale, RGB, RGBA, multi-component), reversible 5/3 and irreversible 9/7 wavelets, `RCT` and `ICT` colour transforms, unquantised (`Sqcd = 0`), scalar-derived (`Sqcd = 1`) and scalar-expounded (`Sqcd = 2`) `QCD`/`QCC` quantisation, `RGN` (`0xFF5E`) MaxShift ROI, any tile grid and image or tile origin, any number of quality layers, Part 1 and Part 15 (HTJ2K cleanup pass, including placeholder passes and mixed HT/Part 1 mode), every Part 1 code-block style bit (bypass, reset, termination on each pass, vertically causal, predictable termination, segmentation symbols), every progression order plus `POC` (`0xFF5F`), precincts, `SOP`/`EPH` markers, several tile-parts and tile-part header overrides. Rejected with exit 4: HT refinement passes (`SigProp`/`MagRef`) and multiple HT sets per code-block, sub-sampled components (`XRsiz`/`YRsiz != 1`), `PPM`/`PPT`, Part 2 (`Rsiz` extensions), and multi-codestream JPX compositing (`jpxb` / `comp`).

**NRRD profile (CLI-04, pinned to the NRRD format specification at teem.sourceforge.net/nrrd/format.html).** Attached header ending in an empty line; magic `NRRD0001`..`NRRD0005`; fields `type: uint8|int8|uint16|int16` (and standard NRRD aliases), `dimension: 2` (`sizes: W H`), `dimension: 3` (`sizes: C W H` sample-interleaved, `sizes: W H C` planar with `kinds`, or `sizes: W H D` for 3D volumes), or `dimension: 4` (`sizes: C W H D` for multi-component 3D volumes), `encoding: raw` and `endian: little` or `big` (required for 16-bit types); the standard key/value line `swiftj2k.meaningfulbits:=N` (1..16) records the declared precision, which `decode` always writes and `encode` reads back (a contradicting `--precision` is a usage error). `data file`, `line skip`, `byte skip`, `block size`, other types, dimensions and encodings are refused with exit 4; a mismatched data byte length is malformed (exit 3); comments are ignored. `decode` writes little-endian samples.

## Verbosity

| Level | Cumulative stderr diagnostics |
| --- | --- |
| 0 (default) | Errors only |
| 1 | Version/operation summary |
| 2 | Command stages |
| 3 | Capability/configuration details |
| 4 | Elapsed timing |
| 5 | Bounded execution trace |

`-v` increments, `-vv` through `-vvvvv` group increments, and `--verbose LEVEL`, `--verbose=LEVEL`, `-verbose: LEVEL` or `-verbose:LEVEL` set an explicit level. Digits 1..5 and `+`..`+++++` are equivalent. Bare `--verbose` / `-verbose` increment once. Options apply in order; exceeding 5 or supplying an invalid level returns 2. `--quiet` / `-q` conflicts with any positive verbosity. Errors still print in quiet mode. Help, version and capability output remain stdout data. Diagnostics never contaminate JSON or log payload bytes, metadata, raw addresses or input/output paths.

## Install or update the binary and UNIX manual

Run the installer from this source checkout. It builds the release executable and installs both the binary and matching manual every time; rerunning updates both. No administrator command runs automatically.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/install-cli.sh --prefix "$HOME/.local"
"$HOME/.local/bin/swiftj2k-cli" --help
man -M "$HOME/.local/share/man" swiftj2k-cli
```

Default prefix is `/usr/local`; choose an absolute writable prefix. Add its `bin` directory to PATH. For ordinary `man swiftj2k-cli` lookup with a custom prefix, configure MANPATH to include `PREFIX/share/man` while retaining system defaults (for example `export MANPATH="$HOME/.local/share/man:${MANPATH:-}"`). Direct `man -M` needs no index refresh. The page is [ManPages/swiftj2k-cli.1](ManPages/swiftj2k-cli.1). A packaging recipe must install both `PREFIX/bin/swiftj2k-cli` (0755) and `PREFIX/share/man/man1/swiftj2k-cli.1` (0644).

`--destdir /absolute/staging` (or DESTDIR) stages those same prefix-relative locations for packaging. `--binary /absolute/built/swiftj2k-cli` avoids a rebuild and verifies `--version` against VERSION before writing. `--scratch-path` selects a build directory; `--disable-package-sandbox` is only an explicit workaround for nested sandbox restrictions. An existing destination symlink/directory is refused. Merely copying the executable does not install its manual.

## Exit codes and validation

Exit statuses: 0 success; 2 invalid usage or argument (including a library `invalidArgument`); 3 malformed input or failed comparison threshold; 4 unsupported format, feature, layout or backend; 5 resource limit or deadline; 6 I/O or storage failure, including an existing output without `--overwrite` and a closed pipe; 7 internal failure; 130 interrupted by SIGINT with nothing published. The mapping from `CodecError` categories is fixed in the executable; library errors cannot terminate the host application, and exit handling exists only here.

`Scripts/test-cli.py --binary /absolute/built/swiftj2k-cli --output /new/evidence/directory` checks the real executable across 246 process checks: help, verbosity, JSON separation, every codec and utility verb (`encode`, `decode`, `transcode`, `inspect`, `validate`, `convert`, `compare`, `batch`, `encode3d`, `decode3d`, `jpip`, `benchmark`, `completions`) against the repository Part 1, Part 15 HTJ2K, container, volumetric, and multi-format fixtures (`NRRD`, `PGM`, `PPM`, `PNG`, `TIFF`, `RAW`), overwrite refusal and atomic replacement, format declarations, NRRD profile rejections, every exit status including SIGINT, closed pipes and staged manual install/update/rendering. [Qualification](Documentation/Engineering/OS27CLI/README.md) and [Milestone 12](Documentation/MILESTONE12.md) record exact executed commands and platform limits.
