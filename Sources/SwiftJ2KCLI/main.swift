// SPDX-License-Identifier: Apache-2.0
//
// swiftj2k-cli: the standalone executable of the SwiftJ2K library (CLI_CONTRACT
// CLI-01..CLI-04, CLI-06..CLI-09). Milestone 4 wired encode, decode, inspect
// and validate over the NRRD interchange profile; Milestone 6 added Part 15
// HTJ2K and native compressed-domain J2K <-> HTJ2K transcode; Milestone 7 adds
// Part 1 breadth (lossy/near-lossless, 9/7 wavelet, signed/8-bit/multi-component
// NRRD, RCT/ICT, progression orders, multi-tile, multi-layer, precincts, and ROI).
// Library errors map to exit statuses here and nowhere else; the library never
// terminates the process.
import Foundation
import Synchronization
import SwiftJ2K
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let tool = "swiftj2k-cli"
private let version = "12.1.0"
private let codecCommands = ["encode", "decode", "inspect", "validate", "transcode"]
private let valueOptions: Set<String> = [
    "--input", "-i", "--output", "-o", "--input-format", "--output-format",
    "--container", "--mode", "--max-error", "--near-lossless", "--backend", "--copy-policy",
    "--metadata-policy", "--threads", "--max-memory", "--max-metadata", "--timeout",
    "--levels", "--code-block", "--precision",
    "--quality", "--bpp", "--layers", "--wavelet", "--mct", "--colour-transform",
    "--progression", "--tile-size", "--precincts", "--roi", "--guard-bits", "--qstyle"
]

private struct UsageError: Error { let message: String }
private struct ExitFailure: Error { let status: Int32; let message: String }

private struct Options {
    var command: String? = nil
    var help = false
    var version = false
    var json = false
    var quiet = false
    var verbosity = 0
    var overwrite = false
    var sop = false
    var eph = false
    var values: [String: String] = [:]
    var codecOptions: Bool { !values.isEmpty || overwrite || sop || eph }
}

private func parse(_ args: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var positionalOnly = false
    func level(_ value: String) throws -> Int {
        let number: Int?
        if !value.isEmpty && value.allSatisfy({ $0 == "+" }) { number = value.count }
        else if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) { number = Int(value) }
        else { number = nil }
        guard let number, (1...5).contains(number) else {
            throw UsageError(message: "Verbosity must be 1 through 5, or + through +++++.")
        }
        return number
    }
    func consumeValue() throws -> String {
        guard index + 1 < args.count, args[index + 1] == "-" || !args[index + 1].hasPrefix("-") else {
            throw UsageError(message: "An option is missing its value. Use --help for syntax.")
        }
        index += 1
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        if !positionalOnly && arg == "--" { positionalOnly = true }
        else if !positionalOnly && ["-h", "--help"].contains(arg) { options.help = true }
        else if !positionalOnly && arg == "--version" { options.version = true }
        else if !positionalOnly && arg == "--json" { options.json = true }
        else if !positionalOnly && ["-q", "--quiet"].contains(arg) { options.quiet = true }
        else if !positionalOnly && ["-v", "--verbose", "-verbose"].contains(arg) {
            if index + 1 < args.count, let first = args[index + 1].first, first.isNumber || first == "+" {
                index += 1; options.verbosity = try level(args[index])
            } else { options.verbosity += 1 }
        } else if !positionalOnly,
                  let prefix = ["--verbose=", "--verbose:", "-verbose=", "-verbose:"].first(where: { arg.hasPrefix($0) }) {
            let attached = String(arg.dropFirst(prefix.count))
            options.verbosity = try level(attached.isEmpty ? consumeValue() : attached)
        } else if !positionalOnly && arg.hasPrefix("-v") && arg.count > 2 && arg.dropFirst().allSatisfy({ $0 == "v" }) {
            options.verbosity += arg.count - 1
        } else if !positionalOnly && valueOptions.contains(arg) {
            let canonical: String
            switch arg {
            case "-i": canonical = "--input"
            case "-o": canonical = "--output"
            case "--colour-transform": canonical = "--mct"
            case "--near-lossless": canonical = "--max-error"
            default: canonical = arg
            }
            let value = try consumeValue()
            guard options.values[canonical] == nil else { throw UsageError(message: "\(canonical) was given twice.") }
            options.values[canonical] = value
            if arg == "--near-lossless" && options.values["--mode"] == nil {
                options.values["--mode"] = "near-lossless"
            }
        } else if !positionalOnly && arg == "--lossy" {
            guard options.values["--mode"] == nil else { throw UsageError(message: "--mode was given twice.") }
            options.values["--mode"] = "lossy"
        } else if !positionalOnly && arg == "--overwrite" { options.overwrite = true }
        else if !positionalOnly && arg == "--sop" { options.sop = true }
        else if !positionalOnly && arg == "--eph" { options.eph = true }
        else if !positionalOnly && arg.hasPrefix("-") {
            throw UsageError(message: "Unknown option. Use \(tool) --help.")
        } else if options.command == nil { options.command = arg }
        else if options.command == "help" && !options.help { options.command = arg; options.help = true }
        else { throw UsageError(message: "Unexpected positional argument. Use --input and --output.") }
        guard options.verbosity <= 5 else { throw UsageError(message: "Verbosity exceeds the maximum level 5.") }
        index += 1
    }
    if options.command == "help" { options.command = nil; options.help = true }
    if options.command == "version" { options.command = nil; options.version = true }
    if let command = options.command, command != "capabilities" && !codecCommands.contains(command) {
        throw UsageError(message: "Unknown command. Use \(tool) --help.")
    }
    if options.quiet && options.verbosity > 0 { throw UsageError(message: "--quiet and verbosity cannot be combined.") }
    if options.version && (options.command != nil || options.codecOptions || options.json) {
        throw UsageError(message: "--version cannot be combined with a command or command options.")
    }
    if options.codecOptions && (options.command == nil || options.command == "capabilities") {
        throw UsageError(message: "Input/output and codec options require a codec command.")
    }
    if options.json && options.command == nil { throw UsageError(message: "--json requires capabilities or a codec command.") }
    return options
}

// MARK: - Help

private func help(_ command: String?) -> String {
    let common = """
    OPTIONS
      -h, --help                 Show this help; also: help [command].
      --version                  Show the development version.
      -v, -vv ... -vvvvv         Increase verbosity (maximum 5).
      --verbose LEVEL           Set verbosity to 1..5 or + through +++++.
      --verbose=LEVEL            Equivalent explicit form; -verbose: LEVEL is accepted.
      -q, --quiet                Suppress optional diagnostics; errors remain visible.

    VERBOSITY (stderr only; default 0)
      1 summary; 2 command stages; 3 capability/configuration details; 4 elapsed timing;
      5 bounded diagnostic trace. Levels are cumulative. Quiet conflicts with verbosity.
      Payload bytes, metadata, raw addresses and input/output paths are never logged.

    EXIT STATUS
      0 success; 2 invalid usage or argument; 3 malformed input; 4 unsupported format,
      feature, layout or backend; 5 resource limit or deadline; 6 I/O or storage failure
      (including an existing output without --overwrite and a closed pipe); 7 internal
      failure; 130 interrupted (SIGINT).

    MANUAL
      man \(tool) (installed with the executable by Scripts/install-cli.sh).
    """
    let io = """
    INPUT AND OUTPUT
      -i, --input PATH           Input file, or '-' for standard input (read completely).
      -o, --output PATH          Final output file, or '-' for binary standard output.
      --input-format FORMAT     j2k, htj2k, jp2, jph, jpx or nrrd; checked against the bytes.
      --output-format FORMAT    j2k, htj2k, jp2, jph, jpx or nrrd; the default follows the command.
      --container FORMAT        codestream (default), jp2, jph or jpx (encode/transcode).
      --overwrite               Replace an existing output file. Output is written to a sibling
                                temporary file and renamed into place; nothing partial remains.
      --json                    Structured report on stderr (encode/decode/transcode) or stdout (inspect/validate).

    LIMITS AND POLICIES
      --mode MODE               lossless (default), near-lossless or lossy (encode only).
      --max-error E             Maximum absolute sample error E >= 1 for near-lossless mode.
      --backend NAME            scalar (default); accelerated backends are unavailable (exit 4).
      --copy-policy POLICY      require-sharing (default) or allow-copy; neither copies here.
      --metadata-policy POLICY  preserve (default) or discard-ancillary (COM and ancillary boxes).
      --threads N               Worker limit (1..8; the scalar path uses one).
      --max-memory BYTES        Admission budget for input, output and workspace.
      --max-metadata BYTES      Admission budget for container/codestream metadata (default 64 MiB).
      --timeout SECONDS         Operation deadline (exit 5 when exceeded).

    NRRD PROFILE (CLI.md)
      Attached header, 2-D greyscale or 3-D multi-component, type uint8/int8/uint16/int16,
      encoding raw, explicit endian for 16-bit, no detached data.
      A key 'swiftj2k.meaningfulbits:=N' carries 1..16 meaningful bits; on encode
      --precision N supplies it when the header has none.
    """
    if let command {
        switch command {
        case "capabilities":
            return """
            USAGE: \(tool) capabilities [--json] [OPTIONS]

            Report this library's current encode/decode/inspect/transcode support without reading files.
            --json writes one JSON document to stdout; diagnostics stay on stderr.

            \(common)

            EXAMPLES
              \(tool) capabilities --json
              \(tool) capabilities --verbose=+++
            """ + "\n"
        case "encode":
            return """
            USAGE: \(tool) encode -i IMAGE.nrrd -o OUT.j2k [--output-format j2k|htj2k|jp2|jph|jpx] [--container codestream|jp2|jph|jpx] [CODEC OPTIONS] [OPTIONS]

            Encode an NRRD image (unsigned or signed 1..16-bit greyscale, RGB, or multi-component)
            to a JPEG 2000 Part 1 (j2k) or HTJ2K Part 15 (htj2k) codestream or JP2/JPH/JPX container.

            CODEC OPTIONS
              --container FORMAT        codestream (default), jp2, jph or jpx.
              --mode MODE               lossless (default), near-lossless or lossy; --lossy is a shorthand.
              --max-error E             Positive error bound for near-lossless (--near-lossless E).
              --quality Q               Lossy quality factor in 0.0..1.0.
              --bpp RATE                Target compressed bitrate in bits per pixel (> 0).
              --layers N                Number of quality layers 1..255 (default 1).
              --wavelet auto|53|97      Wavelet transform filter (default auto).
              --mct auto|none|rct|ict   Multi-component colour transform (default auto).
              --progression ORDER       lrcp (default), rlcp, rpcl, pcrl or cprl.
              --tile-size WxH           Tile dimensions in reference grid samples.
              --precincts WxH           Precinct size, powers of two 1..32768.
              --roi X,Y,W,H[,SHIFT]     Rectangular Region of Interest encoded via RGN MaxShift.
              --guard-bits N            Guard bits 1..7 (default 2).
              --qstyle STYLE            auto, none, derived or expounded.
              --sop / --eph             Emit SOP (0xFF91) / EPH (0xFF92) packet markers.
              --levels N                Decomposition levels 0..32; default min(5, floor(log2(min(w, h)))).
              --code-block WxH          Code-block size, powers of two 4..1024 with W*H <= 4096; default 64x64.
              --precision N             Meaningful bits when the NRRD header carries none.

            \(io)

            \(common)

            EXAMPLES
              \(tool) encode -i slice.nrrd -o slice.j2k --precision 12
              \(tool) encode -i slice.nrrd -o slice.jp2 --output-format jp2 --precision 12
              \(tool) encode -i rgb.nrrd -o rgb.j2k --mode lossy --quality 0.8 --wavelet 97 --mct ict
              \(tool) encode -i slice.nrrd -o slice.jph --output-format jph --precision 12
              cat slice.nrrd | \(tool) encode -i - --input-format nrrd -o - > slice.j2k
            """ + "\n"
        case "decode":
            return """
            USAGE: \(tool) decode -i IN.j2k -o IMAGE.nrrd [OPTIONS]

            Decode a JPEG 2000 Part 1 or HTJ2K Part 15 codestream or JP2/JPH/JPX container
            (unsigned or signed, 1..16 bits, 1..N components, 5/3 or 9/7, RCT or ICT, palette/cmap,
            any tiles, layers, ROI, code-block styles and progression orders) to the NRRD profile.

            \(io)

            \(common)

            EXAMPLES
              \(tool) decode -i slice.j2k -o slice.nrrd --overwrite
              \(tool) decode -i slice.jp2 -o slice.nrrd --overwrite
              \(tool) decode -i - -o - < slice.j2k > slice.nrrd
            """ + "\n"
        case "inspect":
            return """
            USAGE: \(tool) inspect -i IN.j2k [--json] [OPTIONS]

            Bounded structural inspection of a JPEG 2000 or HTJ2K codestream or JP2/JPH/JPX container:
            geometry, precision and tiles are read from the container and codestream headers without
            decoding samples. Output goes to stdout.

            \(io)

            \(common)

            EXAMPLES
              \(tool) inspect -i slice.j2k --json
              \(tool) inspect -i slice.jp2 --json
            """ + "\n"
        case "validate":
            return """
            USAGE: \(tool) validate -i IN.j2k [--json] [OPTIONS]

            Fully decode a JPEG 2000 or HTJ2K codestream or JP2/JPH/JPX container in memory and report
            success or the defined failure. No output file is written.

            \(io)

            \(common)

            EXAMPLES
              \(tool) validate -i slice.j2k
              \(tool) validate -i slice.jp2
            """ + "\n"
        default:
            return """
            USAGE: \(tool) transcode -i IN.j2k -o OUT.j2c [--input-format j2k|htj2k|jp2|jph|jpx] [--output-format j2k|htj2k|jp2|jph|jpx] [--container codestream|jp2|jph|jpx] [--levels N] [--code-block WxH] [OPTIONS]

            Losslessly transcode between JPEG 2000 Part 1 (j2k/jp2/jpx) and HTJ2K Part 15 (htj2k/jph/jpx)
            codestreams and containers in the wavelet coefficient domain without materialising an
            intermediate pixel image or writing temporary image files.

            CODEC OPTIONS
              --container FORMAT        codestream, jp2, jph or jpx.
              --levels N                Target decomposition levels 0..32; default preserves source levels
                                        (changing levels is rejected with exit 4 on the coefficient path).
              --code-block WxH          Target code-block size, powers of two 4..1024 with W*H <= 4096; default 64x64.

            \(io)

            \(common)

            EXAMPLES
              \(tool) transcode -i source.j2k --input-format j2k --output-format htj2k --mode lossless -o converted.j2c
              \(tool) transcode -i source.jp2 --input-format jp2 --output-format jph --mode lossless -o converted.jph
              \(tool) transcode -i - -o - < source.j2k > converted.j2c
            """ + "\n"
        }
    }
    return """
    \(tool) \(version) — JPEG 2000 and HTJ2K
    USAGE: \(tool) [OPTIONS] <command> [OPTIONS]

    COMMANDS
      encode                     NRRD image -> JPEG 2000 or HTJ2K codestream or JP2/JPH/JPX container.
      decode                     JPEG 2000 or HTJ2K codestream or JP2/JPH/JPX container -> NRRD image.
      inspect                    Report codestream or container geometry without decoding.
      validate                   Fully decode in memory and report the result.
      transcode                  Lossless JPEG 2000 <-> HTJ2K compressed-domain transcoding.
      capabilities [--json]      Report actual library support (scalar JPEG 2000 Part 1 and HTJ2K Part 15).
      help [command]             Show global or command-specific help.
      version                    Show the development version.

    Accelerated backends are unavailable (exit 4).
    Swift 6.2 minimum, Swift 6.4 qualified; Apple OS baseline 26.0. CLI hosts: macOS/Linux.

    \(common)

    EXAMPLES
      \(tool) encode -i slice.nrrd -o slice.j2k --precision 12
      \(tool) encode -i rgb.nrrd -o rgb.j2k --mode lossy --quality 0.8 --wavelet 97 --mct ict
      \(tool) decode -i slice.j2k -o slice.nrrd
      \(tool) transcode -i source.j2k --input-format j2k --output-format htj2k --mode lossless -o converted.j2c
      \(tool) inspect -i slice.j2k --json
      \(tool) capabilities --json -vv
    """ + "\n"
}

private func write(_ text: String, to handle: FileHandle) throws {
    try handle.write(contentsOf: Data(text.utf8))
}

// MARK: - NRRD interchange profile (CLI-04)

private struct NRRDImage {
    let width: Int
    let height: Int
    let components: Int
    let componentsFirst: Bool   // true when 3D layout is [C, W, H], false when [W, H, C] or 2D
    let storageBits: Int        // 8 or 16
    let signed: Bool
    let meaningfulBits: Int
    let bigEndian: Bool
    let samples: Data
}

private enum NRRD {
    static func parse(_ data: Data, defaultPrecision: Int?) throws -> NRRDImage {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, String(decoding: bytes[0..<4], as: UTF8.self) == "NRRD",
              bytes[4...6].allSatisfy({ $0 == 0x30 }) || String(decoding: bytes[4..<7], as: UTF8.self) == "000",
              (0x31...0x35).contains(bytes[7]) else {
            throw ExitFailure(status: 4, message: "unsupported format: input is not an NRRD file (magic NRRD0001..NRRD0005).")
        }
        // Header lines end at the first empty line.
        var position = 0
        var lines: [String] = []
        while position < bytes.count {
            var end = position
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            var line = String(decoding: bytes[position..<end], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            position = min(end + 1, bytes.count)
            if line.isEmpty { break }
            lines.append(line)
            guard lines.count <= 256 else { throw ExitFailure(status: 3, message: "malformed input: NRRD header exceeds 256 lines.") }
        }
        guard position <= bytes.count, lines.count >= 1 else { throw ExitFailure(status: 3, message: "malformed input: NRRD header has no terminating empty line.") }
        var fields: [String: String] = [:]
        var keyValues: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.hasPrefix("#") { continue }
            if let range = line.range(of: ":=") {
                keyValues[line[..<range.lowerBound].lowercased()] = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: ": ") {
                fields[line[..<range.lowerBound].lowercased()] = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                throw ExitFailure(status: 3, message: "malformed input: NRRD header line is neither 'field: value' nor 'key:=value'.")
            }
        }
        for forbidden in ["data file", "datafile", "line skip", "lineskip", "byte skip", "byteskip", "block size", "blocksize"]
        where fields[forbidden] != nil {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD '\(forbidden)' is outside the attached-raw profile.")
        }
        guard let type = fields["type"]?.lowercased() else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD header is missing type.")
        }
        let storageBits: Int
        let signed: Bool
        if ["uint16", "ushort", "unsigned short", "unsigned short int", "uint16_t"].contains(type) {
            storageBits = 16; signed = false
        } else if ["int16", "short", "short int", "signed short", "signed short int", "int16_t"].contains(type) {
            storageBits = 16; signed = true
        } else if ["uint8", "uchar", "unsigned char", "uint8_t"].contains(type) {
            storageBits = 8; signed = false
        } else if ["int8", "signed char", "int8_t"].contains(type) {
            storageBits = 8; signed = true
        } else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD type must be uint8, int8, uint16 or int16.")
        }
        guard let dimStr = fields["dimension"], dimStr == "2" || dimStr == "3" else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD dimension must be 2 or 3.")
        }
        guard let encoding = fields["encoding"]?.lowercased(), encoding == "raw" else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD encoding must be raw.")
        }
        let bigEndian: Bool
        if storageBits == 16 {
            guard let endian = fields["endian"]?.lowercased(), endian == "little" || endian == "big" else {
                throw ExitFailure(status: 3, message: "malformed input: NRRD endian must be little or big for 16-bit samples.")
            }
            bigEndian = (endian == "big")
        } else {
            bigEndian = (fields["endian"]?.lowercased() == "big")
        }

        let sizes = (fields["sizes"] ?? "").split(separator: " ").compactMap { Int($0) }
        let width: Int
        let height: Int
        let components: Int
        let componentsFirst: Bool

        if dimStr == "2" {
            guard sizes.count == 2, sizes[0] > 0, sizes[1] > 0 else {
                throw ExitFailure(status: 3, message: "malformed input: NRRD sizes must be two positive integers.")
            }
            width = sizes[0]
            height = sizes[1]
            components = 1
            componentsFirst = true
        } else {
            guard sizes.count == 3, sizes[0] > 0, sizes[1] > 0, sizes[2] > 0 else {
                throw ExitFailure(status: 3, message: "malformed input: 3-D NRRD sizes must be three positive integers.")
            }
            let kinds = (fields["kinds"] ?? "").lowercased().split(separator: " ").map(String.init)
            let compKinds: Set<String> = ["list", "vector", "rgb-color", "rgba-color", "3-color", "4-color", "point", "covariant-vector"]
            if kinds.count == 3 && compKinds.contains(kinds[2]) && !compKinds.contains(kinds[0]) {
                width = sizes[0]; height = sizes[1]; components = sizes[2]; componentsFirst = false
            } else if kinds.count == 3 && compKinds.contains(kinds[0]) {
                components = sizes[0]; width = sizes[1]; height = sizes[2]; componentsFirst = true
            } else if sizes[0] <= 16 && (sizes[2] > 16 || sizes[0] <= sizes[2]) {
                components = sizes[0]; width = sizes[1]; height = sizes[2]; componentsFirst = true
            } else {
                width = sizes[0]; height = sizes[1]; components = sizes[2]; componentsFirst = false
            }
        }

        var precision = defaultPrecision ?? storageBits
        if let declared = keyValues["swiftj2k.meaningfulbits"] {
            guard let value = Int(declared), (1...storageBits).contains(value) else {
                throw ExitFailure(status: 3, message: "malformed input: swiftj2k.meaningfulbits must be 1..\(storageBits).")
            }
            if let requested = defaultPrecision, requested != value {
                throw ExitFailure(status: 2, message: "invalid argument: --precision \(requested) contradicts the header key swiftj2k.meaningfulbits:=\(value).")
            }
            precision = value
        }
        guard (1...storageBits).contains(precision) else {
            throw ExitFailure(status: 2, message: "invalid argument: --precision \(precision) exceeds \(storageBits)-bit NRRD storage.")
        }

        let (wh, ov1) = width.multipliedReportingOverflow(by: height)
        let (totalSamples, ov2) = wh.multipliedReportingOverflow(by: components)
        let bytesPerSample = storageBits / 8
        let (expected, ov3) = totalSamples.multipliedReportingOverflow(by: bytesPerSample)
        guard !ov1 && !ov2 && !ov3, expected >= 0 else {
            throw ExitFailure(status: 5, message: "resource limit: NRRD size overflows.")
        }
        guard bytes.count - position == expected else {
            throw ExitFailure(status: 3, message: "malformed input: NRRD data holds \(bytes.count - position) bytes, expected \(expected).")
        }
        return NRRDImage(
            width: width, height: height, components: components,
            componentsFirst: componentsFirst, storageBits: storageBits,
            signed: signed, meaningfulBits: precision, bigEndian: bigEndian,
            samples: data.subdata(in: position..<position + expected)
        )
    }

    static func header(descriptor: ImageDescriptor) -> Data {
        let typeName: String
        if descriptor.storageBits == 8 {
            typeName = descriptor.sampleType == .signedInteger ? "int8" : "uint8"
        } else {
            typeName = descriptor.sampleType == .signedInteger ? "int16" : "uint16"
        }
        if descriptor.components.count == 1 {
            var lines = [
                "NRRD0004",
                "# SwiftJ2K interchange profile 1: 2-D greyscale, raw attached data (CLI.md)",
                "type: \(typeName)",
                "dimension: 2",
                "sizes: \(descriptor.width) \(descriptor.height)",
                "encoding: raw"
            ]
            if descriptor.storageBits == 16 {
                lines.append("endian: little")
            }
            lines.append("kinds: space space")
            lines.append("swiftj2k.meaningfulbits:=\(descriptor.meaningfulBits)")
            return Data((lines.joined(separator: "\n") + "\n\n").utf8)
        } else {
            let kind0 = descriptor.components.count == 3 ? "RGB-color" : (descriptor.components.count == 4 ? "RGBA-color" : "list")
            var lines = [
                "NRRD0004",
                "# SwiftJ2K multi-component NRRD interchange profile, raw attached data (CLI.md)",
                "type: \(typeName)",
                "dimension: 3",
                "sizes: \(descriptor.components.count) \(descriptor.width) \(descriptor.height)",
                "encoding: raw"
            ]
            if descriptor.storageBits == 16 {
                lines.append("endian: little")
            }
            lines.append("kinds: \(kind0) space space")
            lines.append("swiftj2k.meaningfulbits:=\(descriptor.meaningfulBits)")
            return Data((lines.joined(separator: "\n") + "\n\n").utf8)
        }
    }
}

// MARK: - Codec command execution

private struct CodecContext {
    let options: Options
    let diagnostic: (Int, String) throws -> Void
}

private func exitStatus(for error: Error) -> (Int32, String) {
    if error is CancellationError { return (130, "interrupted; no output was published.") }
    if let failure = error as? ExitFailure { return (failure.status, failure.message) }
    guard let codec = error as? CodecError else { return (7, "internal failure.") }
    switch codec.category {
    case .invalidArgument: return (2, "invalid argument: \(codec.message)")
    case .malformedInput: return (3, "malformed input: \(codec.message)")
    case .unsupportedFormat, .unsupportedFeature, .incompatibleImageLayout, .backendUnavailable:
        return (4, "unsupported: \(codec.message)")
    case .resourceLimitExceeded: return (5, "resource limit: \(codec.message)")
    case .ioFailure, .storageUnavailable: return (6, "storage failure: \(codec.message)")
    case .internalFailure: return (7, "internal failure: \(codec.message)")
    }
}

private func readInput(_ path: String) throws -> Data {
    if path == "-" {
        do { return try FileHandle.standardInput.readToEnd() ?? Data() }
        catch { throw ExitFailure(status: 6, message: "I/O failure: standard input could not be read.") }
    }
    do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
    catch { throw ExitFailure(status: 6, message: "I/O failure: the input could not be read.") }
}

/// Publishes final output: binary stdout, or an atomically replaced file.
private func publish(_ data: Data, to path: String, overwrite: Bool) throws {
    if path == "-" {
        do { try FileHandle.standardOutput.write(contentsOf: data) }
        catch { throw ExitFailure(status: 6, message: "output I/O failure: standard output closed; partial binary output cannot be rolled back.") }
        return
    }
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: path) && !overwrite {
        throw ExitFailure(status: 6, message: "output exists; pass --overwrite to replace it.")
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(tool)-\(getpid()).tmp")
    do {
        try data.write(to: temporary, options: [.withoutOverwriting])
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw ExitFailure(status: 6, message: "output I/O failure: the final output could not be written.")
    }
}

private func codestreamHasHT(_ data: Data, startIndex: Int, endIndex: Int) -> Bool {
    guard endIndex - startIndex >= 2,
          data[startIndex] == 0xFF, data[startIndex + 1] == 0x4F else {
        return false
    }
    var pos = startIndex + 2
    while pos + 2 <= endIndex {
        let marker = (UInt16(data[pos]) << 8) | UInt16(data[pos + 1])
        pos += 2
        if marker == 0xFF90 || marker == 0xFFD9 { break }
        if (0xFF30...0xFF3F).contains(marker) { continue }
        guard pos + 2 <= endIndex else { break }
        let segLen = Int((UInt16(data[pos]) << 8) | UInt16(data[pos + 1]))
        guard segLen >= 2, pos + segLen <= endIndex else { break }
        if marker == 0xFF51 && segLen >= 4 {
            let rsiz = (UInt16(data[pos + 2]) << 8) | UInt16(data[pos + 3])
            if (rsiz & 0x4000) != 0 { return true }
        } else if marker == 0xFF50 {
            return true
        } else if marker == 0xFF52 && segLen >= 12 {
            let cstyle = data[pos + 11]
            if (cstyle & 0x40) != 0 { return true }
        }
        pos += segLen
    }
    return false
}

private func detectContainerBrand(_ data: Data, declared: String?) throws -> String {
    let base = data.startIndex
    guard data.count >= 24 else {
        if let declared, ["jp2", "jph", "jpx"].contains(declared) { return declared }
        return "jp2"
    }
    let lbox = (UInt32(data[base + 12]) << 24) | (UInt32(data[base + 13]) << 16)
        | (UInt32(data[base + 14]) << 8) | UInt32(data[base + 15])
    let tbox = (UInt32(data[base + 16]) << 24) | (UInt32(data[base + 17]) << 16)
        | (UInt32(data[base + 18]) << 8) | UInt32(data[base + 19])
    guard tbox == 0x66747970 else {
        if let declared, ["jp2", "jph", "jpx"].contains(declared) { return declared }
        return "jp2"
    }
    let headerLen: Int
    let boxLen: Int
    if lbox == 0 {
        headerLen = 8
        boxLen = data.count - 12
    } else if lbox == 1 {
        guard data.count >= 28 else {
            if let declared, ["jp2", "jph", "jpx"].contains(declared) { return declared }
            return "jp2"
        }
        var xl: UInt64 = 0
        for i in 0..<8 { xl = (xl << 8) | UInt64(data[base + 20 + i]) }
        guard xl >= 16, xl <= UInt64(data.count - 12) else {
            if let declared, ["jp2", "jph", "jpx"].contains(declared) { return declared }
            return "jp2"
        }
        headerLen = 16
        boxLen = Int(xl)
    } else if lbox >= 8 && Int(lbox) <= data.count - 12 {
        headerLen = 8
        boxLen = Int(lbox)
    } else {
        if let declared, ["jp2", "jph", "jpx"].contains(declared) { return declared }
        return "jp2"
    }
    let payloadLen = boxLen - headerLen
    guard payloadLen >= 8, (payloadLen - 8) % 4 == 0 else {
        if let declared, ["jp2", "jph", "jpx"].contains(declared) { return declared }
        return "jp2"
    }
    let pStart = base + 12 + headerLen
    let brand = String(data[pStart..<(pStart + 4)].map { Character(UnicodeScalar($0)) })
    let compatCount = (payloadLen - 8) / 4
    var compat: [String] = []
    for i in 0..<compatCount {
        let off = pStart + 8 + i * 4
        compat.append(String(data[off..<(off + 4)].map { Character(UnicodeScalar($0)) }))
    }
    if brand == "jph " { return "jph" }
    if brand == "jpx " || brand == "jpxb" { return "jpx" }
    if brand == "jp2 " { return "jp2" }
    if compat.contains("jph ") { return "jph" }
    if compat.contains("jpx ") || compat.contains("jpxb") { return "jpx" }
    if compat.contains("jp2 ") { return "jp2" }
    throw ExitFailure(status: 4, message: "unsupported format: unsupported JP2 family brand '\(brand)'.")
}

private func detectFormat(_ data: Data, declared: String?) throws -> String {
    let isCodestream = data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x4F
    let isContainer = data.count >= 12 && data[data.startIndex..<(data.startIndex + 12)].elementsEqual([
        0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A
    ])
    let isNRRD = data.count >= 4 && data.prefix(4) == Data("NRRD".utf8)
    let detected: String?
    if isCodestream {
        detected = codestreamHasHT(data, startIndex: data.startIndex, endIndex: data.endIndex) ? "htj2k" : "j2k"
    } else if isContainer {
        detected = try detectContainerBrand(data, declared: declared)
    } else if isNRRD {
        detected = "nrrd"
    } else {
        detected = nil
    }
    if let declared {
        guard ["j2k", "htj2k", "jp2", "jph", "jpx", "nrrd"].contains(declared) else {
            throw UsageError(message: "--input-format must be j2k, htj2k, jp2, jph, jpx or nrrd.")
        }
        guard detected == declared else {
            throw ExitFailure(status: 4, message: "unsupported format: the input bytes are not \(declared) as declared.")
        }
        return declared
    }
    guard let detected else {
        throw ExitFailure(status: 4, message: "unsupported format: input is neither a JPEG 2000/HTJ2K codestream or container nor NRRD.")
    }
    return detected
}

private func limits(from options: Options, command: String) throws -> ResourceLimits {
    var workers = min(ProcessInfo.processInfo.activeProcessorCount, 8)
    var memory = 1024 * 1024 * 1024
    var metadata = 64 * 1024 * 1024
    var deadline = 120.0
    if let text = options.values["--threads"] {
        guard let value = Int(text), (1...8).contains(value) else { throw UsageError(message: "--threads must be 1..8.") }
        workers = value
    }
    if let text = options.values["--max-memory"] {
        guard let value = Int(text), value > 0 else { throw UsageError(message: "--max-memory must be a positive byte count.") }
        memory = value
    }
    if let text = options.values["--max-metadata"] {
        guard let value = Int(text), value > 0 else { throw UsageError(message: "--max-metadata must be a positive byte count.") }
        metadata = value
    }
    if let text = options.values["--timeout"] {
        guard let value = Double(text), value > 0, value.isFinite else { throw UsageError(message: "--timeout must be positive seconds.") }
        deadline = value
    }
    if let mode = options.values["--mode"] {
        guard ["lossless", "near-lossless", "lossy"].contains(mode) else {
            throw UsageError(message: "--mode must be lossless, near-lossless or lossy.")
        }
        if mode != "lossless" && command != "encode" {
            throw ExitFailure(status: 4, message: "unsupported: \(mode) mode applies to encode only.")
        }
    }
    if let backend = options.values["--backend"], backend != "scalar" {
        throw ExitFailure(status: 4, message: "unsupported: backend '\(backend)' is not available; only scalar exists.")
    }
    if let policy = options.values["--copy-policy"] {
        guard ["require-sharing", "allow-copy"].contains(policy) else { throw UsageError(message: "--copy-policy must be require-sharing or allow-copy.") }
    }
    if let meta = options.values["--metadata-policy"] {
        guard ["preserve", "discard-ancillary"].contains(meta) else { throw UsageError(message: "--metadata-policy must be preserve or discard-ancillary.") }
    }
    if options.values["--max-error"] != nil && command != "encode" {
        throw ExitFailure(status: 4, message: "unsupported: --max-error applies to encode only.")
    }
    return try ResourceLimits(
        maximumMetadataBytes: metadata,
        maximumWorkers: workers,
        deadlineSeconds: deadline,
        maximumMemoryBytes: memory
    )
}

private func fidelityString(_ fidelity: Fidelity) -> String {
    switch fidelity {
    case .exactSamples: return "exactSamples"
    case .boundedError(let b): return "boundedError(\(b))"
    case .lossy: return "lossy"
    case .originalBitstream: return "originalBitstream"
    }
}

private func report(_ fields: [String: Any], json: Bool, to handle: FileHandle) throws {
    guard json else { return }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    try handle.write(contentsOf: data + Data([10]))
}

private func containerHasHT(_ data: Data) -> Bool {
    guard data.count >= 12 else { return false }
    var pos = data.startIndex + 12
    while pos + 8 <= data.endIndex {
        let lbox = (UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16)
            | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3])
        let tbox = (UInt32(data[pos + 4]) << 24) | (UInt32(data[pos + 5]) << 16)
            | (UInt32(data[pos + 6]) << 8) | UInt32(data[pos + 7])
        let headerLen: Int
        let totalLen: Int
        if lbox == 0 {
            headerLen = 8
            totalLen = data.endIndex - pos
        } else if lbox == 1 {
            guard pos + 16 <= data.endIndex else { break }
            var xl: UInt64 = 0
            for i in 0..<8 { xl = (xl << 8) | UInt64(data[pos + 8 + i]) }
            guard xl >= 16, xl <= UInt64(data.endIndex - pos) else { break }
            headerLen = 16
            totalLen = Int(xl)
        } else if lbox >= 8, Int(lbox) <= data.endIndex - pos {
            headerLen = 8
            totalLen = Int(lbox)
        } else {
            break
        }
        if tbox == 0x6A703263 {
            return codestreamHasHT(data, startIndex: pos + headerLen, endIndex: pos + totalLen)
        }
        pos += totalLen
    }
    return false
}

private func parseContainerOption(_ raw: String?) throws -> CodecOptions.ContainerFormat? {
    guard let raw else { return nil }
    switch raw.lowercased() {
    case "codestream": return .codestream
    case "jp2": return .jp2
    case "jph": return .jph
    case "jpx": return .jpx
    default:
        throw UsageError(message: "--container must be codestream, jp2, jph or jpx.")
    }
}

private func parseEncodeConfiguration(
    options: Options,
    levels: Int?,
    blockWidth: Int,
    blockHeight: Int,
    blockCoding: CodecOptions.BlockCoding,
    containerFormat: CodecOptions.ContainerFormat
) throws -> EncoderConfiguration {
    let modeStr = options.values["--mode"] ?? "lossless"
    let mode: CompressionMode
    switch modeStr {
    case "lossless":
        if options.values["--max-error"] != nil {
            throw UsageError(message: "--max-error requires --mode near-lossless.")
        }
        mode = .lossless
    case "near-lossless":
        let boundStr = options.values["--max-error"] ?? "1"
        guard let bound = Int(boundStr), bound >= 1 else {
            throw UsageError(message: "--max-error must be a positive integer (>= 1).")
        }
        mode = .nearLossless(maximumAbsoluteError: bound)
    case "lossy":
        if options.values["--max-error"] != nil {
            throw UsageError(message: "--max-error cannot be combined with --mode lossy.")
        }
        mode = .lossy
    default:
        throw UsageError(message: "--mode must be lossless, near-lossless or lossy.")
    }

    var wavelet: CodecOptions.WaveletTransform = .automatic
    if let wText = options.values["--wavelet"]?.lowercased() {
        switch wText {
        case "auto", "automatic": wavelet = .automatic
        case "53", "reversible53": wavelet = .reversible53
        case "97", "irreversible97": wavelet = .irreversible97
        default: throw UsageError(message: "--wavelet must be auto, 53 or 97.")
        }
    }

    var colourTransform: CodecOptions.ColourTransform = .automatic
    if let mText = options.values["--mct"]?.lowercased() {
        switch mText {
        case "auto", "automatic": colourTransform = .automatic
        case "none": colourTransform = .none
        case "rct": colourTransform = .rct
        case "ict": colourTransform = .ict
        default: throw UsageError(message: "--mct must be auto, none, rct or ict.")
        }
    }

    var progressionOrder: CodecOptions.ProgressionOrder = .lrcp
    if let pText = options.values["--progression"]?.lowercased() {
        switch pText {
        case "lrcp": progressionOrder = .lrcp
        case "rlcp": progressionOrder = .rlcp
        case "rpcl": progressionOrder = .rpcl
        case "pcrl": progressionOrder = .pcrl
        case "cprl": progressionOrder = .cprl
        default: throw UsageError(message: "--progression must be lrcp, rlcp, rpcl, pcrl or cprl.")
        }
    }

    var quality: Double? = nil
    if let qText = options.values["--quality"] {
        guard let q = Double(qText), q.isFinite, (0.0...1.0).contains(q) else {
            throw UsageError(message: "--quality must be in 0.0..1.0.")
        }
        quality = q
    }

    var targetBpp: Double? = nil
    if let bText = options.values["--bpp"] {
        guard let b = Double(bText), b.isFinite, b > 0.0 else {
            throw UsageError(message: "--bpp must be a positive number.")
        }
        targetBpp = b
    }

    var layers = 1
    if let lText = options.values["--layers"] {
        guard let l = Int(lText), (1...255).contains(l) else {
            throw UsageError(message: "--layers must be 1..255.")
        }
        layers = l
    }

    var guardBits = 2
    if let gText = options.values["--guard-bits"] {
        guard let g = Int(gText), (1...7).contains(g) else {
            throw UsageError(message: "--guard-bits must be 1..7.")
        }
        guardBits = g
    }

    var qStyle: CodecOptions.QuantizationStyle = .automatic
    if let qsText = options.values["--qstyle"]?.lowercased() {
        switch qsText {
        case "auto", "automatic": qStyle = .automatic
        case "none": qStyle = .none
        case "derived", "scalarderived": qStyle = .scalarDerived
        case "expounded", "scalarexpounded": qStyle = .scalarExpounded
        default: throw UsageError(message: "--qstyle must be auto, none, derived or expounded.")
        }
    }

    var tileWidth: Int? = nil
    var tileHeight: Int? = nil
    if let tText = options.values["--tile-size"] {
        let parts = tText.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 1, parts[1] >= 1 else {
            throw UsageError(message: "--tile-size must be WxH with positive integers.")
        }
        tileWidth = parts[0]; tileHeight = parts[1]
    }

    var precinctSizes: [CodecOptions.PrecinctSize] = []
    if let prText = options.values["--precincts"] {
        for item in prText.split(separator: ",") {
            let parts = item.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else {
                throw UsageError(message: "--precincts must be WxH (or comma-separated WxH list).")
            }
            do {
                precinctSizes.append(try CodecOptions.PrecinctSize(width: parts[0], height: parts[1]))
            } catch let error as CodecError {
                throw UsageError(message: error.message)
            }
        }
    }

    var roi: CodecOptions.RegionOfInterest? = nil
    if let rText = options.values["--roi"] {
        let parts = rText.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 4 || parts.count == 5 else {
            throw UsageError(message: "--roi must be X,Y,W,H or X,Y,W,H,SHIFT.")
        }
        do {
            roi = try CodecOptions.RegionOfInterest(
                x: parts[0], y: parts[1], width: parts[2], height: parts[3],
                shift: parts.count == 5 ? parts[4] : nil
            )
        } catch let error as CodecError {
            throw UsageError(message: error.message)
        }
    }

    do {
        let codecOptions = try CodecOptions(
            decompositionLevels: levels,
            codeBlockWidth: blockWidth,
            codeBlockHeight: blockHeight,
            blockCoding: blockCoding,
            wavelet: wavelet,
            colourTransform: colourTransform,
            progressionOrder: progressionOrder,
            quality: quality,
            targetBitsPerPixel: targetBpp,
            qualityLayers: layers,
            quantizationStyle: qStyle,
            guardBits: guardBits,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            precinctSizes: precinctSizes,
            usesSOP: options.sop,
            usesEPH: options.eph,
            regionOfInterest: roi,
            containerFormat: containerFormat
        )
        return try EncoderConfiguration(mode: mode, codecOptions: codecOptions)
    } catch let error as CodecError {
        if error.category == .unsupportedFeature {
            throw ExitFailure(status: 4, message: "unsupported: \(error.message)")
        }
        throw UsageError(message: error.message)
    }
}

private func runCodecCommand(_ command: String, _ context: CodecContext) async throws -> Int32 {
    let options = context.options
    guard let inputPath = options.values["--input"] else { throw UsageError(message: "\(command) requires --input.") }
    let limits = try limits(from: options, command: command)
    // Every option value is validated before any input is opened (CLI-02).
    if let declaredInput = options.values["--input-format"],
       !["j2k", "htj2k", "jp2", "jph", "jpx", "nrrd"].contains(declaredInput) {
        throw UsageError(message: "--input-format must be j2k, htj2k, jp2, jph, jpx or nrrd.")
    }
    let explicitContainer = try parseContainerOption(options.values["--container"])
    var defaultPrecision: Int? = nil
    if let text = options.values["--precision"] {
        guard let value = Int(text), (1...16).contains(value) else { throw UsageError(message: "--precision must be 1..16.") }
        defaultPrecision = value
    }
    var levels: Int? = nil
    if let text = options.values["--levels"] {
        guard let value = Int(text), (0...32).contains(value) else { throw UsageError(message: "--levels must be 0..32.") }
        levels = value
    }
    var blockWidth = 64, blockHeight = 64
    if let text = options.values["--code-block"] {
        let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { throw UsageError(message: "--code-block must be WxH, for example 32x32.") }
        blockWidth = parts[0]; blockHeight = parts[1]
    }
    do {
        _ = try CodecOptions(decompositionLevels: levels, codeBlockWidth: blockWidth, codeBlockHeight: blockHeight)
    } catch let error as CodecError {
        throw UsageError(message: error.message)
    }
    let encodeOnlyFlags = [
        "--precision", "--quality", "--bpp", "--layers", "--wavelet", "--mct",
        "--progression", "--tile-size", "--precincts", "--roi", "--guard-bits", "--qstyle"
    ]
    if command != "encode" {
        for flag in encodeOnlyFlags where options.values[flag] != nil {
            throw UsageError(message: "\(flag) applies to encode only.")
        }
        if options.sop || options.eph {
            throw UsageError(message: "--sop and --eph apply to encode only.")
        }
    }
    if !["encode", "transcode"].contains(command),
       options.values["--levels"] != nil || options.values["--code-block"] != nil || options.values["--container"] != nil {
        throw UsageError(message: "--levels, --code-block and --container apply to encode and transcode only.")
    }
    for (option, allowed) in [("--output", ["encode", "decode", "transcode"]), ("--output-format", ["encode", "decode", "transcode"])]
    where options.values[option] != nil && !allowed.contains(command) {
        throw UsageError(message: "\(option) is not accepted by \(command).")
    }
    if ["encode", "decode", "transcode"].contains(command), options.values["--output"] == nil {
        throw UsageError(message: "\(command) requires --output.")
    }
    let copyPolicy: CopyPolicy = options.values["--copy-policy"] == "allow-copy" ? .allowCopy : .requireSharedStorage
    let metadataPolicy: MetadataPolicy = options.values["--metadata-policy"] == "discard-ancillary" ? .discardAncillary : .preserve
    let started = ContinuousClock.now
    try context.diagnostic(2, "reading input")
    let input = try readInput(inputPath)
    guard input.count <= limits.maximumCompressedBytes else {
        throw ExitFailure(status: 5, message: "resource limit: input exceeds the compressed-size admission limit.")
    }
    let format = try detectFormat(input, declared: options.values["--input-format"])
    try context.diagnostic(3, "input format \(format), \(input.count) bytes; limits: memory \(limits.maximumMemoryBytes) B, deadline \(limits.deadlineSeconds) s")

    let compressedFormats: Set<String> = ["j2k", "htj2k", "jp2", "jph", "jpx"]

    switch command {
    case "inspect":
        guard compressedFormats.contains(format) else {
            throw ExitFailure(status: 4, message: "unsupported format: inspect reads JPEG 2000 or HTJ2K codestreams and containers.")
        }
        let info = try Decoder().inspect(input, options: .init(resourceLimits: limits))
        let sampleTypeStr = info.descriptor.sampleType == .signedInteger ? "signedInteger" : "unsignedInteger"
        let compCount = info.descriptor.components.count
        let fields: [String: Any] = [
            "format": info.format, "width": info.descriptor.width, "height": info.descriptor.height,
            "meaningfulBits": info.descriptor.meaningfulBits, "storageBits": info.descriptor.storageBits,
            "sampleType": sampleTypeStr, "components": compCount, "frames": info.frameCount, "bytes": input.count
        ]
        if options.json {
            try report(fields, json: true, to: .standardOutput)
        } else {
            try write("format: \(info.format)\nwidth: \(info.descriptor.width)\nheight: \(info.descriptor.height)\nmeaningful bits: \(info.descriptor.meaningfulBits)\nstorage bits: \(info.descriptor.storageBits)\ncomponents: \(compCount)\nbytes: \(input.count)\n", to: .standardOutput)
        }
    case "validate":
        guard compressedFormats.contains(format) else {
            throw ExitFailure(status: 4, message: "unsupported format: validate reads JPEG 2000 or HTJ2K codestreams and containers.")
        }
        try context.diagnostic(2, "decoding in memory")
        let decoded = try await Decoder().decode(
            input,
            options: .init(resourceLimits: limits, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
        )
        let elapsed = ContinuousClock.now - started
        let fields: [String: Any] = [
            "valid": true, "width": decoded.image.descriptor.width, "height": decoded.image.descriptor.height,
            "meaningfulBits": decoded.image.descriptor.meaningfulBits,
            "components": decoded.image.descriptor.components.count,
            "backend": "scalar",
            "fidelity": fidelityString(decoded.report.fidelity),
            "bytes": input.count, "elapsedSeconds": elapsedSeconds(elapsed)
        ]
        if options.json { try report(fields, json: true, to: .standardOutput) }
        else { try write("valid: \(decoded.image.descriptor.width)x\(decoded.image.descriptor.height), \(decoded.image.descriptor.meaningfulBits) meaningful bits, \(input.count) bytes\n", to: .standardOutput) }
    case "decode":
        guard compressedFormats.contains(format) else {
            throw ExitFailure(status: 4, message: "unsupported format: decode reads JPEG 2000 or HTJ2K codestreams and containers.")
        }
        guard let outputPath = options.values["--output"] else { throw UsageError(message: "decode requires --output.") }
        if let declared = options.values["--output-format"], declared != "nrrd" {
            throw ExitFailure(status: 4, message: "unsupported format: decode writes nrrd.")
        }
        try context.diagnostic(2, "decoding")
        let decoded = try await Decoder().decode(
            input,
            options: .init(resourceLimits: limits, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
        )
        let descriptor = decoded.image.descriptor
        let compCount = descriptor.components.count
        let sampleBytes = descriptor.storageBits / 8
        var output = NRRD.header(descriptor: descriptor)
        output.reserveCapacity(output.count + descriptor.width * descriptor.height * compCount * sampleBytes)

        if compCount == 1 {
            try decoded.image.storage.withUnsafeBytes { bytes in
                let plane = descriptor.planes[0]
                for y in 0..<descriptor.height {
                    let row = plane.offset + y * plane.rowBytes
                    for x in 0..<descriptor.width {
                        let at = row + x * plane.pixelStride
                        if sampleBytes == 1 {
                            output.append(bytes[at])
                        } else if descriptor.byteOrder == .littleEndian {
                            output.append(bytes[at]); output.append(bytes[at + 1])
                        } else {
                            output.append(bytes[at + 1]); output.append(bytes[at])
                        }
                    }
                }
            }
        } else {
            // 3D NRRD [C, W, H] with little-endian samples:
            for y in 0..<descriptor.height {
                for x in 0..<descriptor.width {
                    for c in 0..<compCount {
                        let val = try decoded.image.sampleInt(component: c, x: x, y: y)
                        if sampleBytes == 1 {
                            let b = descriptor.sampleType == .signedInteger
                                ? UInt8(bitPattern: Int8(truncatingIfNeeded: val))
                                : UInt8(truncatingIfNeeded: val)
                            output.append(b)
                        } else {
                            let w = descriptor.sampleType == .signedInteger
                                ? UInt16(bitPattern: Int16(truncatingIfNeeded: val))
                                : UInt16(truncatingIfNeeded: val)
                            output.append(UInt8(truncatingIfNeeded: w))
                            output.append(UInt8(truncatingIfNeeded: w >> 8))
                        }
                    }
                }
            }
        }
        try context.diagnostic(2, "publishing output")
        try publish(output, to: outputPath, overwrite: options.overwrite)
        let elapsed = ContinuousClock.now - started
        try report(["command": "decode", "inputBytes": input.count, "outputBytes": output.count,
                    "width": descriptor.width, "height": descriptor.height,
                    "components": compCount, "meaningfulBits": descriptor.meaningfulBits,
                    "backend": "scalar", "fidelity": fidelityString(decoded.report.fidelity),
                    "copyEvents": decoded.report.copyEvents.count,
                    "pixelAllocations": decoded.report.pixelAllocationCount ?? -1,
                    "peakWorkspaceBytes": decoded.report.peakWorkspaceBytes ?? -1,
                    "discardedMetadataCount": decoded.report.discardedMetadataCount ?? 0,
                    "discardedMetadataBytes": decoded.report.discardedMetadataBytes ?? 0,
                    "discardedMetadataKinds": decoded.report.discardedMetadataKinds,
                    "elapsedSeconds": elapsedSeconds(elapsed)], json: options.json, to: .standardError)
    case "encode":
        guard format == "nrrd" else { throw ExitFailure(status: 4, message: "unsupported format: encode reads NRRD images.") }
        guard let outputPath = options.values["--output"] else { throw UsageError(message: "encode requires --output.") }
        let outputFormat = options.values["--output-format"] ?? "j2k"
        guard compressedFormats.contains(outputFormat) else {
            throw ExitFailure(status: 4, message: "unsupported format: encode writes j2k, htj2k, jp2, jph or jpx.")
        }
        let blockCoding: CodecOptions.BlockCoding
        let containerFormat: CodecOptions.ContainerFormat
        switch outputFormat {
        case "j2k":
            blockCoding = .part1
            containerFormat = explicitContainer ?? .codestream
        case "htj2k":
            blockCoding = .htj2k
            containerFormat = explicitContainer ?? .codestream
        case "jp2":
            if let explicitContainer, explicitContainer != .jp2 {
                throw UsageError(message: "--container \(explicitContainer.rawValue) conflicts with --output-format jp2.")
            }
            blockCoding = .part1
            containerFormat = .jp2
        case "jph":
            if let explicitContainer, explicitContainer != .jph {
                throw UsageError(message: "--container \(explicitContainer.rawValue) conflicts with --output-format jph.")
            }
            blockCoding = .htj2k
            containerFormat = .jph
        case "jpx":
            if let explicitContainer, explicitContainer != .jpx {
                throw UsageError(message: "--container \(explicitContainer.rawValue) conflicts with --output-format jpx.")
            }
            blockCoding = .part1
            containerFormat = .jpx
        default:
            throw ExitFailure(status: 4, message: "unsupported format: encode writes j2k, htj2k, jp2, jph or jpx.")
        }
        let encoderConfig = try parseEncodeConfiguration(
            options: options, levels: levels, blockWidth: blockWidth,
            blockHeight: blockHeight, blockCoding: blockCoding,
            containerFormat: containerFormat
        )
        let nrrd = try NRRD.parse(input, defaultPrecision: defaultPrecision)
        try context.diagnostic(3, "NRRD \(nrrd.width)x\(nrrd.height)x\(nrrd.components), \(nrrd.meaningfulBits) meaningful bits")

        let descriptor: ImageDescriptor
        if nrrd.components == 1 {
            if nrrd.storageBits == 16 && !nrrd.signed {
                descriptor = try ImageDescriptor.greyscale16(
                    width: nrrd.width, height: nrrd.height, meaningfulBits: nrrd.meaningfulBits, limits: limits
                )
            } else if nrrd.storageBits == 16 && nrrd.signed {
                descriptor = try ImageDescriptor.signedGreyscale16(
                    width: nrrd.width, height: nrrd.height, meaningfulBits: nrrd.meaningfulBits, limits: limits
                )
            } else {
                descriptor = try ImageDescriptor.greyscale8(
                    width: nrrd.width, height: nrrd.height, meaningfulBits: nrrd.meaningfulBits,
                    signed: nrrd.signed, limits: limits
                )
            }
        } else if nrrd.components == 3 {
            descriptor = try ImageDescriptor.rgbPlanar(
                width: nrrd.width, height: nrrd.height, storageBits: nrrd.storageBits,
                meaningfulBits: nrrd.meaningfulBits, signed: nrrd.signed, limits: limits
            )
        } else {
            descriptor = try ImageDescriptor.multiComponentPlanar(
                width: nrrd.width, height: nrrd.height, componentCount: nrrd.components,
                storageBits: nrrd.storageBits, meaningfulBits: nrrd.meaningfulBits,
                sampleType: nrrd.signed ? .signedInteger : .unsignedInteger, limits: limits
            )
        }

        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
        let minVal = nrrd.signed ? -(1 << (nrrd.meaningfulBits - 1)) : 0
        let maxVal = nrrd.signed ? ((1 << (nrrd.meaningfulBits - 1)) - 1) : ((1 << nrrd.meaningfulBits) - 1)
        let bytesPerSample = nrrd.storageBits / 8

        let image = try nrrd.samples.withUnsafeBytes { source -> Image in
            try destination.writeSamples { c, x, y in
                let sampleIndex: Int
                if nrrd.components == 1 {
                    sampleIndex = y * nrrd.width + x
                } else if nrrd.componentsFirst {
                    sampleIndex = (y * nrrd.width + x) * nrrd.components + c
                } else {
                    sampleIndex = (c * nrrd.height + y) * nrrd.width + x
                }
                let at = sampleIndex * bytesPerSample
                let value: Int
                if bytesPerSample == 1 {
                    let raw = source[at]
                    value = nrrd.signed ? Int(Int8(bitPattern: raw)) : Int(raw)
                } else {
                    let word = nrrd.bigEndian
                        ? (UInt16(source[at]) << 8 | UInt16(source[at + 1]))
                        : (UInt16(source[at]) | UInt16(source[at + 1]) << 8)
                    value = nrrd.signed ? Int(Int16(bitPattern: word)) : Int(word)
                }
                guard value >= minVal && value <= maxVal else {
                    throw CodecError(.invalidArgument, "a sample exceeds \(nrrd.meaningfulBits) meaningful bits; use --precision or fix the header key.")
                }
                return value
            }
        }

        try context.diagnostic(2, "encoding")
        let encoder = try Encoder(configuration: encoderConfig)
        let encoded = try await encoder.encode(
            image,
            options: .init(resourceLimits: limits, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
        )
        try context.diagnostic(2, "publishing output")
        try publish(encoded.data, to: outputPath, overwrite: options.overwrite)
        let elapsed = ContinuousClock.now - started
        let modeStr = options.values["--mode"] ?? "lossless"
        try report(["command": "encode", "inputBytes": input.count, "outputBytes": encoded.data.count,
                    "width": nrrd.width, "height": nrrd.height, "components": nrrd.components,
                    "meaningfulBits": nrrd.meaningfulBits,
                    "format": encoded.encoding.format, "mode": modeStr, "backend": "scalar",
                    "fidelity": fidelityString(encoded.report.fidelity),
                    "copyEvents": encoded.report.copyEvents.count, "peakWorkspaceBytes": encoded.report.peakWorkspaceBytes ?? -1,
                    "elapsedSeconds": elapsedSeconds(elapsed)], json: options.json, to: .standardError)
    case "transcode":
        guard compressedFormats.contains(format) else {
            throw ExitFailure(status: 4, message: "unsupported format: transcode reads JPEG 2000 or HTJ2K codestreams and containers.")
        }
        guard let outputPath = options.values["--output"] else { throw UsageError(message: "transcode requires --output.") }
        let inputIsHT: Bool
        switch format {
        case "htj2k", "jph": inputIsHT = true
        case "j2k", "jp2": inputIsHT = false
        default: inputIsHT = containerHasHT(input)
        }
        let target: TranscodeTarget
        let targetContainer: CodecOptions.ContainerFormat
        if let declared = options.values["--output-format"] {
            guard compressedFormats.contains(declared) else {
                throw ExitFailure(status: 4, message: "unsupported format: transcode writes j2k, htj2k, jp2, jph or jpx.")
            }
            switch declared {
            case "j2k":
                target = .jpeg2000
                targetContainer = explicitContainer ?? .codestream
            case "htj2k":
                target = .htj2k
                targetContainer = explicitContainer ?? .codestream
            case "jp2":
                if let explicitContainer, explicitContainer != .jp2 {
                    throw UsageError(message: "--container \(explicitContainer.rawValue) conflicts with --output-format jp2.")
                }
                target = .jpeg2000
                targetContainer = .jp2
            case "jph":
                if let explicitContainer, explicitContainer != .jph {
                    throw UsageError(message: "--container \(explicitContainer.rawValue) conflicts with --output-format jph.")
                }
                target = .htj2k
                targetContainer = .jph
            default: // "jpx"
                if let explicitContainer, explicitContainer != .jpx {
                    throw UsageError(message: "--container \(explicitContainer.rawValue) conflicts with --output-format jpx.")
                }
                target = inputIsHT ? .jpeg2000 : .htj2k
                targetContainer = .jpx
            }
        } else {
            target = inputIsHT ? .jpeg2000 : .htj2k
            if let explicitContainer {
                targetContainer = explicitContainer
            } else {
                switch format {
                case "jp2": targetContainer = .jph
                case "jph": targetContainer = .jp2
                case "jpx": targetContainer = .jpx
                default: targetContainer = .codestream
                }
            }
        }
        let targetIsHT = (target == .htj2k)
        guard targetIsHT != inputIsHT else {
            throw ExitFailure(status: 4, message: "unsupported format: input is already \(format); transcode requires JPEG 2000 <-> HTJ2K conversion.")
        }
        let transcodeOptions: CodecOptions
        do {
            transcodeOptions = try CodecOptions(
                decompositionLevels: levels,
                codeBlockWidth: blockWidth,
                codeBlockHeight: blockHeight,
                blockCoding: targetIsHT ? .htj2k : .part1,
                containerFormat: targetContainer
            )
        } catch let error as CodecError {
            if error.category == .unsupportedFeature {
                throw ExitFailure(status: 4, message: "unsupported: \(error.message)")
            }
            throw UsageError(message: error.message)
        }
        try context.diagnostic(2, "transcoding \(format) -> \(target.rawValue)")
        let transcoder = try Transcoder(configuration: TranscoderConfiguration(mode: .lossless, codecOptions: transcodeOptions))
        let transcoded = try await transcoder.transcode(
            input,
            to: target,
            options: .init(resourceLimits: limits, copyPolicy: copyPolicy, metadataPolicy: metadataPolicy)
        )
        try context.diagnostic(2, "publishing output")
        try publish(transcoded.data, to: outputPath, overwrite: options.overwrite)
        let elapsed = ContinuousClock.now - started
        let sourceFormatCanonical: String
        switch format {
        case "j2k": sourceFormatCanonical = "jpeg2000-codestream"
        case "htj2k": sourceFormatCanonical = "htj2k-codestream"
        default: sourceFormatCanonical = format
        }
        try report(["command": "transcode", "inputBytes": input.count, "outputBytes": transcoded.data.count,
                    "sourceFormat": sourceFormatCanonical,
                    "format": transcoded.encoding.format, "mode": "lossless", "backend": "scalar",
                    "fidelity": "exactSamples", "processingPath": "coefficients",
                    "copyEvents": transcoded.report.copyEvents.count,
                    "pixelAllocations": transcoded.report.pixelAllocationCount ?? -1,
                    "peakWorkspaceBytes": transcoded.report.peakWorkspaceBytes ?? -1,
                    "discardedMetadataCount": transcoded.report.discardedMetadataCount ?? 0,
                    "discardedMetadataBytes": transcoded.report.discardedMetadataBytes ?? 0,
                    "discardedMetadataKinds": transcoded.report.discardedMetadataKinds,
                    "elapsedSeconds": elapsedSeconds(elapsed)], json: options.json, to: .standardError)
    default:
        throw UsageError(message: "Unknown command.")
    }
    try context.diagnostic(4, "elapsed seconds: \(elapsedSeconds(ContinuousClock.now - started))")
    try context.diagnostic(5, "\(command) completed; output published; no intermediate image file used")
    return 0
}

private func elapsedSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - Entry point

private func run() async throws -> Int32 {
    let start = ContinuousClock.now
    let options: Options
    do { options = try parse(Array(CommandLine.arguments.dropFirst())) }
    catch let error as UsageError {
        try write("\(tool): \(error.message)\n", to: .standardError)
        return 2
    }
    if options.help || (options.command == nil && !options.version) {
        try write(help(options.command), to: .standardOutput); return 0
    }
    if options.version { try write("\(tool) \(version)\n", to: .standardOutput); return 0 }
    func diagnostic(_ level: Int, _ message: String) throws {
        if !options.quiet && options.verbosity >= level {
            try write("[\(level)] \(tool): \(message)\n", to: .standardError)
        }
    }
    try diagnostic(1, "development version \(version)")
    try diagnostic(2, "running \(options.command ?? "help")")
    if options.command == "capabilities" {
        let encoder = SwiftJ2K.Encoder.capabilities
        let decoder = SwiftJ2K.Decoder.capabilities
        let canTranscode = !SwiftJ2K.Transcoder.capabilities.isEmpty
        let formats = Array(Set(encoder.formats + decoder.formats)).sorted()
        if options.json {
            let payload: [String: Any] = ["tool": tool, "version": version, "minimumAppleOS": "26.0",
                "canEncode": encoder.canEncode, "canDecode": decoder.canDecode,
                "canInspect": decoder.canInspect, "canTranscode": canTranscode, "formats": formats]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        } else {
            try write("\(tool) \(version)\nencode: \(encoder.canEncode)\ndecode: \(decoder.canDecode)\ninspect: \(decoder.canInspect)\ntranscode: \(canTranscode)\nformats: \(formats.isEmpty ? "none" : formats.joined(separator: ", "))\n", to: .standardOutput)
        }
        try diagnostic(3, "advertised formats: \(formats.count); capability values read from the library")
        try diagnostic(4, "elapsed seconds: \(elapsedSeconds(ContinuousClock.now - start))")
        try diagnostic(5, "arguments validated; capability report emitted; no codec payload opened")
        return 0
    }
    do {
        return try await runCodecCommand(options.command!, CodecContext(options: options, diagnostic: diagnostic))
    } catch let error as UsageError {
        try write("\(tool): \(error.message)\n", to: .standardError)
        return 2
    } catch {
        let (status, message) = exitStatus(for: error)
        try write("\(tool): \(message)\n", to: .standardError)
        return status
    }
}

nonisolated func drive() -> Int32 {
    _ = signal(SIGPIPE, SIG_IGN)
    _ = signal(SIGINT, SIG_IGN)
    let work = Task.detached { () -> Int32 in
        do { return try await run() }
        catch {
            try? write("\(tool): output I/O failure.\n", to: .standardError)
            return 6
        }
    }
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { work.cancel() }
    interrupt.resume()
    let finished = DispatchSemaphore(value: 0)
    let status = Mutex<Int32>(7)
    Task.detached {
        let result = await work.value
        status.withLock { $0 = result }
        finished.signal()
    }
    finished.wait()
    interrupt.cancel()
    return status.withLock { $0 }
}

exit(drive())
