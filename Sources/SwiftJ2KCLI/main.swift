// SPDX-License-Identifier: Apache-2.0
//
// swiftj2k-cli: the standalone executable of the SwiftJ2K library (CLI_CONTRACT
// CLI-01..CLI-04, CLI-06..CLI-09). Milestone 4 wired encode, decode, inspect
// and validate over the NRRD interchange profile; Milestone 6 adds Part 15
// HTJ2K and native compressed-domain J2K <-> HTJ2K transcode. Library errors
// map to exit statuses here and nowhere else; the library never terminates the
// process.
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
private let valueOptions: Set<String> = ["--input", "-i", "--output", "-o", "--input-format", "--output-format",
    "--mode", "--max-error", "--backend", "--copy-policy", "--threads", "--max-memory", "--timeout",
    "--levels", "--code-block", "--precision"]

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
    var values: [String: String] = [:]
    var codecOptions: Bool { !values.isEmpty || overwrite }
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
            let canonical = arg == "-i" ? "--input" : (arg == "-o" ? "--output" : arg)
            let value = try consumeValue()
            guard options.values[canonical] == nil else { throw UsageError(message: "\(canonical) was given twice.") }
            options.values[canonical] = value
        } else if !positionalOnly && arg == "--overwrite" { options.overwrite = true }
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
      --input-format FORMAT     j2k, htj2k or nrrd; checked against the bytes.
      --output-format FORMAT    j2k, htj2k or nrrd; the default follows the command.
      --overwrite               Replace an existing output file. Output is written to a sibling
                                temporary file and renamed into place; nothing partial remains.
      --json                    Structured report on stderr (encode/decode/transcode) or stdout (inspect/validate).

    LIMITS AND POLICIES
      --mode lossless           The only mode; near-lossless and lossy are unsupported (exit 4).
      --backend NAME            scalar (default); accelerated backends are unavailable (exit 4).
      --copy-policy POLICY      require-sharing (default) or allow-copy; neither copies here.
      --threads N               Worker limit (1..8; the scalar path uses one).
      --max-memory BYTES        Admission budget for input, output and workspace.
      --timeout SECONDS         Operation deadline (exit 5 when exceeded).

    NRRD PROFILE (CLI.md)
      Attached header, 2-D, type uint16, encoding raw, explicit endian, no detached data.
      A key 'swiftj2k.meaningfulbits:=N' carries 1..16 meaningful bits; on encode
      --precision N supplies it when the header has none (default 16).
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
            USAGE: \(tool) encode -i IMAGE.nrrd -o OUT.j2k [--output-format j2k|htj2k] [--levels N] [--code-block WxH] [--precision N] [OPTIONS]

            Losslessly encode one unsigned greyscale NRRD image (1..16 meaningful bits in 16-bit
            samples) to a raw JPEG 2000 Part 1 (j2k) or HTJ2K Part 15 (htj2k) codestream:
            reversible 5/3 wavelet, one tile, one layer, default code-block style.

            CODEC OPTIONS
              --levels N                Decomposition levels 0..32; default min(5, floor(log2(min(w, h)))).
              --code-block WxH          Code-block size, powers of two 4..1024 with W*H <= 4096; default 64x64.
              --precision N             Meaningful bits when the NRRD header carries none; default 16.

            \(io)

            \(common)

            EXAMPLES
              \(tool) encode -i slice.nrrd -o slice.j2k --precision 12
              \(tool) encode -i slice.nrrd -o slice.j2c --output-format htj2k --precision 12
              cat slice.nrrd | \(tool) encode -i - --input-format nrrd -o - > slice.j2k
            """ + "\n"
        case "decode":
            return """
            USAGE: \(tool) decode -i IN.j2k -o IMAGE.nrrd [OPTIONS]

            Decode a raw JPEG 2000 Part 1 or HTJ2K Part 15 codestream (unsigned greyscale,
            1..16 bits, reversible 5/3, any tiles, layers, code-block styles and progression
            orders) to the NRRD profile.

            \(io)

            \(common)

            EXAMPLES
              \(tool) decode -i slice.j2k -o slice.nrrd --overwrite
              \(tool) decode -i - -o - < slice.j2k > slice.nrrd
            """ + "\n"
        case "inspect":
            return """
            USAGE: \(tool) inspect -i IN.j2k [--json] [OPTIONS]

            Bounded structural inspection of a JPEG 2000 or HTJ2K codestream: geometry, precision
            and tiles are read from the main and tile-part headers without decoding samples.
            Output goes to stdout.

            \(io)

            \(common)

            EXAMPLES
              \(tool) inspect -i slice.j2k --json
            """ + "\n"
        case "validate":
            return """
            USAGE: \(tool) validate -i IN.j2k [--json] [OPTIONS]

            Fully decode a JPEG 2000 or HTJ2K codestream in memory and report success or the
            defined failure. No output file is written.

            \(io)

            \(common)

            EXAMPLES
              \(tool) validate -i slice.j2k
            """ + "\n"
        default:
            return """
            USAGE: \(tool) transcode -i IN.j2k -o OUT.j2c [--input-format j2k|htj2k] [--output-format j2k|htj2k] [--levels N] [--code-block WxH] [OPTIONS]

            Losslessly transcode between raw JPEG 2000 Part 1 (j2k) and HTJ2K Part 15 (htj2k)
            codestreams in the wavelet coefficient domain without materialising an intermediate
            pixel image or writing temporary image files.

            CODEC OPTIONS
              --levels N                Target decomposition levels 0..32; default preserves source levels
                                        (changing levels is rejected with exit 4 on the coefficient path).
              --code-block WxH          Target code-block size, powers of two 4..1024 with W*H <= 4096; default 64x64.

            \(io)

            \(common)

            EXAMPLES
              \(tool) transcode -i source.j2k --input-format j2k --output-format htj2k --mode lossless -o converted.j2c
              \(tool) transcode -i converted.j2c --input-format htj2k --output-format j2k --mode lossless -o restored.j2k
              \(tool) transcode -i - -o - < source.j2k > converted.j2c
            """ + "\n"
        }
    }
    return """
    \(tool) \(version) — JPEG 2000 and HTJ2K
    USAGE: \(tool) [OPTIONS] <command> [OPTIONS]

    COMMANDS
      encode                     NRRD greyscale image -> lossless JPEG 2000 or HTJ2K codestream.
      decode                     JPEG 2000 or HTJ2K codestream -> NRRD greyscale image.
      inspect                    Report codestream geometry without decoding.
      validate                   Fully decode in memory and report the result.
      transcode                  Lossless JPEG 2000 <-> HTJ2K compressed-domain transcoding.
      capabilities [--json]      Report actual library support (scalar lossless JPEG 2000 and HTJ2K).
      help [command]             Show global or command-specific help.
      version                    Show the development version.

    Accelerated backends and lossy/near-lossless modes are unavailable (exit 4).
    Swift 6.2 minimum, Swift 6.4 qualified; Apple OS baseline 26.0. CLI hosts: macOS/Linux.

    \(common)

    EXAMPLES
      \(tool) encode -i slice.nrrd -o slice.j2k --precision 12
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
    let meaningfulBits: Int
    let bigEndian: Bool
    let samples: Data          // raw 16-bit samples in the file's byte order
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
        guard let type = fields["type"]?.lowercased(),
              ["uint16", "ushort", "unsigned short", "unsigned short int", "uint16_t"].contains(type) else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD type must be uint16 for this profile.")
        }
        guard fields["dimension"] == "2" else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD dimension must be 2.")
        }
        guard let encoding = fields["encoding"]?.lowercased(), encoding == "raw" else {
            throw ExitFailure(status: 4, message: "unsupported format: NRRD encoding must be raw.")
        }
        guard let endian = fields["endian"]?.lowercased(), endian == "little" || endian == "big" else {
            throw ExitFailure(status: 3, message: "malformed input: NRRD endian must be little or big for 16-bit samples.")
        }
        let sizes = (fields["sizes"] ?? "").split(separator: " ").compactMap { Int($0) }
        guard sizes.count == 2, sizes[0] > 0, sizes[1] > 0 else {
            throw ExitFailure(status: 3, message: "malformed input: NRRD sizes must be two positive integers.")
        }
        var precision = defaultPrecision ?? 16
        if let declared = keyValues["swiftj2k.meaningfulbits"] {
            guard let value = Int(declared), (1...16).contains(value) else {
                throw ExitFailure(status: 3, message: "malformed input: swiftj2k.meaningfulbits must be 1..16.")
            }
            if let requested = defaultPrecision, requested != value {
                throw ExitFailure(status: 2, message: "invalid argument: --precision \(requested) contradicts the header key swiftj2k.meaningfulbits:=\(value).")
            }
            precision = value
        }
        let (count, overflow) = sizes[0].multipliedReportingOverflow(by: sizes[1])
        guard !overflow, count <= Int.max / 2 else { throw ExitFailure(status: 5, message: "resource limit: NRRD size overflows.") }
        let expected = count * 2
        guard bytes.count - position == expected else {
            throw ExitFailure(status: 3, message: "malformed input: NRRD data holds \(bytes.count - position) bytes, expected \(expected).")
        }
        return NRRDImage(width: sizes[0], height: sizes[1], meaningfulBits: precision, bigEndian: endian == "big",
                         samples: data.subdata(in: position..<position + expected))
    }

    static func header(width: Int, height: Int, meaningfulBits: Int) -> Data {
        Data("""
        NRRD0004
        # SwiftJ2K interchange profile 1: 2-D unsigned 16-bit greyscale, raw attached data (CLI.md)
        type: uint16
        dimension: 2
        sizes: \(width) \(height)
        encoding: raw
        endian: little
        kinds: space space
        swiftj2k.meaningfulbits:=\(meaningfulBits)

        """.utf8) + Data([0x0A])   // the multi-line literal ends without the blank terminator line
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
        // POSIX rename(2) is atomic and replaces an existing destination on
        // both Darwin and Linux; FileManager.replaceItemAt is not portable.
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw ExitFailure(status: 6, message: "output I/O failure: the final output could not be written.")
    }
}

private func detectFormat(_ data: Data, declared: String?) throws -> String {
    let isCodestream = data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x4F
    let isNRRD = data.count >= 4 && data.prefix(4) == Data("NRRD".utf8)
    let detected: String?
    if isCodestream {
        if data.count >= 8 && data[data.startIndex + 2] == 0xFF && data[data.startIndex + 3] == 0x51 {
            let rsiz = (UInt16(data[data.startIndex + 6]) << 8) | UInt16(data[data.startIndex + 7])
            detected = (rsiz & 0x4000) != 0 ? "htj2k" : "j2k"
        } else {
            detected = "j2k"
        }
    } else if isNRRD {
        detected = "nrrd"
    } else {
        detected = nil
    }
    if let declared {
        guard ["j2k", "htj2k", "nrrd"].contains(declared) else {
            throw UsageError(message: "--input-format must be j2k, htj2k or nrrd.")
        }
        guard detected == declared else {
            throw ExitFailure(status: 4, message: "unsupported format: the input bytes are not \(declared) as declared.")
        }
        return declared
    }
    guard let detected else {
        throw ExitFailure(status: 4, message: "unsupported format: input is neither a JPEG 2000/HTJ2K codestream nor NRRD.")
    }
    return detected
}

private func limits(from options: Options) throws -> ResourceLimits {
    var workers = min(ProcessInfo.processInfo.activeProcessorCount, 8)
    var memory = 1024 * 1024 * 1024
    var deadline = 120.0
    if let text = options.values["--threads"] {
        guard let value = Int(text), (1...8).contains(value) else { throw UsageError(message: "--threads must be 1..8.") }
        workers = value
    }
    if let text = options.values["--max-memory"] {
        guard let value = Int(text), value > 0 else { throw UsageError(message: "--max-memory must be a positive byte count.") }
        memory = value
    }
    if let text = options.values["--timeout"] {
        guard let value = Double(text), value > 0, value.isFinite else { throw UsageError(message: "--timeout must be positive seconds.") }
        deadline = value
    }
    if let mode = options.values["--mode"], mode != "lossless" {
        guard ["near-lossless", "lossy"].contains(mode) else { throw UsageError(message: "--mode must be lossless, near-lossless or lossy.") }
        throw ExitFailure(status: 4, message: "unsupported: only lossless mode is implemented.")
    }
    if let backend = options.values["--backend"], backend != "scalar" {
        throw ExitFailure(status: 4, message: "unsupported: backend '\(backend)' is not available; only scalar exists.")
    }
    if let policy = options.values["--copy-policy"] {
        guard ["require-sharing", "allow-copy"].contains(policy) else { throw UsageError(message: "--copy-policy must be require-sharing or allow-copy.") }
    }
    if options.values["--max-error"] != nil {
        throw ExitFailure(status: 4, message: "unsupported: --max-error applies to near-lossless modes, which are not implemented.")
    }
    return try ResourceLimits(maximumWorkers: workers, deadlineSeconds: deadline, maximumMemoryBytes: memory)
}

private func report(_ fields: [String: Any], json: Bool, to handle: FileHandle) throws {
    guard json else { return }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    try handle.write(contentsOf: data + Data([10]))
}

private func runCodecCommand(_ command: String, _ context: CodecContext) async throws -> Int32 {
    let options = context.options
    guard let inputPath = options.values["--input"] else { throw UsageError(message: "\(command) requires --input.") }
    let limits = try limits(from: options)
    // Every option value is validated before any input is opened (CLI-02).
    if let declaredInput = options.values["--input-format"], !["j2k", "htj2k", "nrrd"].contains(declaredInput) {
        throw UsageError(message: "--input-format must be j2k, htj2k or nrrd.")
    }
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
    let codecOptions: CodecOptions
    do { codecOptions = try CodecOptions(decompositionLevels: levels, codeBlockWidth: blockWidth, codeBlockHeight: blockHeight) }
    catch let error as CodecError { throw UsageError(message: error.message) }
    if command != "encode", options.values["--precision"] != nil {
        throw UsageError(message: "--precision applies to encode only.")
    }
    if !["encode", "transcode"].contains(command), options.values["--levels"] != nil || options.values["--code-block"] != nil {
        throw UsageError(message: "--levels and --code-block apply to encode and transcode only.")
    }
    for (option, allowed) in [("--output", ["encode", "decode", "transcode"]), ("--output-format", ["encode", "decode", "transcode"])]
    where options.values[option] != nil && !allowed.contains(command) {
        throw UsageError(message: "\(option) is not accepted by \(command).")
    }
    if ["encode", "decode", "transcode"].contains(command), options.values["--output"] == nil {
        throw UsageError(message: "\(command) requires --output.")
    }
    let copyPolicy: CopyPolicy = options.values["--copy-policy"] == "allow-copy" ? .allowCopy : .requireSharedStorage
    let started = ContinuousClock.now
    try context.diagnostic(2, "reading input")
    let input = try readInput(inputPath)
    guard input.count <= limits.maximumCompressedBytes else {
        throw ExitFailure(status: 5, message: "resource limit: input exceeds the compressed-size admission limit.")
    }
    let format = try detectFormat(input, declared: options.values["--input-format"])
    try context.diagnostic(3, "input format \(format), \(input.count) bytes; limits: memory \(limits.maximumMemoryBytes) B, deadline \(limits.deadlineSeconds) s")

    switch command {
    case "inspect":
        guard format == "j2k" || format == "htj2k" else {
            throw ExitFailure(status: 4, message: "unsupported format: inspect reads JPEG 2000 or HTJ2K codestreams.")
        }
        let info = try Decoder().inspect(input, options: .init(resourceLimits: limits))
        let fields: [String: Any] = ["format": info.format, "width": info.descriptor.width, "height": info.descriptor.height,
                                     "meaningfulBits": info.descriptor.meaningfulBits, "storageBits": info.descriptor.storageBits,
                                     "sampleType": "unsignedInteger", "components": 1, "frames": info.frameCount, "bytes": input.count]
        if options.json {
            try report(fields, json: true, to: .standardOutput)
        } else {
            try write("format: \(info.format)\nwidth: \(info.descriptor.width)\nheight: \(info.descriptor.height)\nmeaningful bits: \(info.descriptor.meaningfulBits)\nstorage bits: \(info.descriptor.storageBits)\ncomponents: 1\nbytes: \(input.count)\n", to: .standardOutput)
        }
    case "validate":
        guard format == "j2k" || format == "htj2k" else {
            throw ExitFailure(status: 4, message: "unsupported format: validate reads JPEG 2000 or HTJ2K codestreams.")
        }
        try context.diagnostic(2, "decoding in memory")
        let decoded = try await Decoder().decode(input, options: .init(resourceLimits: limits, copyPolicy: copyPolicy))
        let elapsed = ContinuousClock.now - started
        let fields: [String: Any] = ["valid": true, "width": decoded.image.descriptor.width, "height": decoded.image.descriptor.height,
                                     "meaningfulBits": decoded.image.descriptor.meaningfulBits, "backend": "scalar",
                                     "fidelity": "exactSamples", "bytes": input.count, "elapsedSeconds": elapsedSeconds(elapsed)]
        if options.json { try report(fields, json: true, to: .standardOutput) }
        else { try write("valid: \(decoded.image.descriptor.width)x\(decoded.image.descriptor.height), \(decoded.image.descriptor.meaningfulBits) meaningful bits, \(input.count) bytes\n", to: .standardOutput) }
    case "decode":
        guard format == "j2k" || format == "htj2k" else {
            throw ExitFailure(status: 4, message: "unsupported format: decode reads JPEG 2000 or HTJ2K codestreams.")
        }
        guard let outputPath = options.values["--output"] else { throw UsageError(message: "decode requires --output.") }
        if let declared = options.values["--output-format"], declared != "nrrd" {
            throw ExitFailure(status: 4, message: "unsupported format: decode writes nrrd.")
        }
        try context.diagnostic(2, "decoding")
        let decoded = try await Decoder().decode(input, options: .init(resourceLimits: limits, copyPolicy: copyPolicy))
        let descriptor = decoded.image.descriptor
        var output = NRRD.header(width: descriptor.width, height: descriptor.height, meaningfulBits: descriptor.meaningfulBits)
        output.reserveCapacity(output.count + descriptor.width * descriptor.height * 2)
        // Serialise samples row by row in little-endian order (a pipe carries bytes, not storage).
        try decoded.image.storage.withUnsafeBytes { bytes in
            let plane = descriptor.planes[0]
            for y in 0..<descriptor.height {
                let row = plane.offset + y * plane.rowBytes
                for x in 0..<descriptor.width {
                    let at = row + x * plane.pixelStride
                    if descriptor.byteOrder == .littleEndian { output.append(bytes[at]); output.append(bytes[at + 1]) }
                    else { output.append(bytes[at + 1]); output.append(bytes[at]) }
                }
            }
        }
        try context.diagnostic(2, "publishing output")
        try publish(output, to: outputPath, overwrite: options.overwrite)
        let elapsed = ContinuousClock.now - started
        try report(["command": "decode", "inputBytes": input.count, "outputBytes": output.count,
                    "width": descriptor.width, "height": descriptor.height, "meaningfulBits": descriptor.meaningfulBits,
                    "backend": "scalar", "fidelity": "exactSamples", "copyEvents": decoded.report.copyEvents.count,
                    "pixelAllocations": decoded.report.pixelAllocationCount ?? -1,
                    "peakWorkspaceBytes": decoded.report.peakWorkspaceBytes ?? -1,
                    "elapsedSeconds": elapsedSeconds(elapsed)], json: options.json, to: .standardError)
    case "encode":
        guard format == "nrrd" else { throw ExitFailure(status: 4, message: "unsupported format: encode reads NRRD images.") }
        guard let outputPath = options.values["--output"] else { throw UsageError(message: "encode requires --output.") }
        let outputFormat = options.values["--output-format"] ?? "j2k"
        guard ["j2k", "htj2k"].contains(outputFormat) else {
            throw ExitFailure(status: 4, message: "unsupported format: encode writes j2k or htj2k.")
        }
        let nrrd = try NRRD.parse(input, defaultPrecision: defaultPrecision)
        try context.diagnostic(3, "NRRD \(nrrd.width)x\(nrrd.height), \(nrrd.meaningfulBits) meaningful bits, \(nrrd.bigEndian ? "big" : "little") endian")
        let descriptor = try ImageDescriptor.greyscale16(width: nrrd.width, height: nrrd.height,
                                                         meaningfulBits: nrrd.meaningfulBits, limits: limits)
        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
        let maximum = UInt16((1 << nrrd.meaningfulBits) - 1)
        let image = try nrrd.samples.withUnsafeBytes { source -> Image in
            try destination.writeUInt16 { x, y in
                let at = (y * nrrd.width + x) * 2
                let value = nrrd.bigEndian ? UInt16(source[at]) << 8 | UInt16(source[at + 1]) : UInt16(source[at]) | UInt16(source[at + 1]) << 8
                guard value <= maximum else {
                    throw CodecError(.invalidArgument, "a sample exceeds \(nrrd.meaningfulBits) meaningful bits; use --precision or fix the header key.")
                }
                return value
            }
        }
        try context.diagnostic(2, "encoding")
        let blockCoding: CodecOptions.BlockCoding = (outputFormat == "htj2k") ? .htj2k : .part1
        let encodeOptions = try CodecOptions(decompositionLevels: levels, codeBlockWidth: blockWidth,
                                             codeBlockHeight: blockHeight, blockCoding: blockCoding)
        let encoder = try Encoder(configuration: EncoderConfiguration(mode: .lossless, codecOptions: encodeOptions))
        let encoded = try await encoder.encode(image, options: .init(resourceLimits: limits, copyPolicy: copyPolicy))
        try context.diagnostic(2, "publishing output")
        try publish(encoded.data, to: outputPath, overwrite: options.overwrite)
        let elapsed = ContinuousClock.now - started
        try report(["command": "encode", "inputBytes": input.count, "outputBytes": encoded.data.count,
                    "width": nrrd.width, "height": nrrd.height, "meaningfulBits": nrrd.meaningfulBits,
                    "format": encoded.encoding.format, "mode": "lossless", "backend": "scalar", "fidelity": "exactSamples",
                    "copyEvents": encoded.report.copyEvents.count, "peakWorkspaceBytes": encoded.report.peakWorkspaceBytes ?? -1,
                    "elapsedSeconds": elapsedSeconds(elapsed)], json: options.json, to: .standardError)
    case "transcode":
        guard format == "j2k" || format == "htj2k" else {
            throw ExitFailure(status: 4, message: "unsupported format: transcode reads JPEG 2000 or HTJ2K codestreams.")
        }
        guard let outputPath = options.values["--output"] else { throw UsageError(message: "transcode requires --output.") }
        let targetFormat: String
        if let declared = options.values["--output-format"] {
            guard ["j2k", "htj2k"].contains(declared) else {
                throw ExitFailure(status: 4, message: "unsupported format: transcode writes j2k or htj2k.")
            }
            targetFormat = declared
        } else {
            targetFormat = (format == "j2k") ? "htj2k" : "j2k"
        }
        guard targetFormat != format else {
            throw ExitFailure(status: 4, message: "unsupported format: input is already \(format); transcode requires j2k -> htj2k or htj2k -> j2k.")
        }
        let target: TranscodeTarget = (targetFormat == "htj2k") ? .htj2k : .jpeg2000
        try context.diagnostic(2, "transcoding \(format) -> \(targetFormat)")
        let transcoder = try Transcoder(configuration: TranscoderConfiguration(mode: .lossless, codecOptions: codecOptions))
        let transcoded = try await transcoder.transcode(input, to: target, options: .init(resourceLimits: limits, copyPolicy: copyPolicy))
        try context.diagnostic(2, "publishing output")
        try publish(transcoded.data, to: outputPath, overwrite: options.overwrite)
        let elapsed = ContinuousClock.now - started
        try report(["command": "transcode", "inputBytes": input.count, "outputBytes": transcoded.data.count,
                    "sourceFormat": format == "htj2k" ? "htj2k-codestream" : "jpeg2000-codestream",
                    "format": transcoded.encoding.format, "mode": "lossless", "backend": "scalar",
                    "fidelity": "exactSamples", "processingPath": "coefficients",
                    "copyEvents": transcoded.report.copyEvents.count,
                    "pixelAllocations": transcoded.report.pixelAllocationCount ?? -1,
                    "peakWorkspaceBytes": transcoded.report.peakWorkspaceBytes ?? -1,
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

// CLI process boundary only: a closed pipe is reported as exit 6, never SIGPIPE success,
// and SIGINT cancels the in-flight operation cooperatively (exit 130). Top-level code is
// main-actor isolated, so the process is driven from a nonisolated function: the work
// runs on a detached task and the interrupt handler on a global queue, neither touching
// main-actor state, while the main thread waits on a semaphore.
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
