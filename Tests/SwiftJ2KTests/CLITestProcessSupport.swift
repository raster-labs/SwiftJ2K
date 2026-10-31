// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import Synchronization
import Testing
@testable import SwiftJ2K

private final class CLITestBundleAnchor: NSObject {}

struct CLITestProcessResult: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
    let stdout: Data
    let stderr: Data
    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

enum CLITestProcess {
    /// The wrapper may supply the exact product from its validated scratch build.
    /// Otherwise only ancestors of the running test executable/bundle are searched;
    /// source-relative .build directories and in-suite builds are never used.
    static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        anchors: [URL]? = nil
    ) throws -> URL {
        func validated(_ url: URL) -> URL? {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
            return resolved
        }
        if let supplied = environment["SWIFTJ2K_TEST_CLI_PATH"] {
            guard supplied.hasPrefix("/"), let binary = validated(URL(fileURLWithPath: supplied)) else {
                throw CodecError(.internalFailure,
                    "SWIFTJ2K_TEST_CLI_PATH must identify an existing absolute executable path; prebuild swiftj2k-cli with the test build's configuration and scratch path.")
            }
            return binary
        }
        let activeAnchors = anchors ?? [
            URL(fileURLWithPath: CommandLine.arguments[0]),
            Bundle(for: CLITestBundleAnchor.self).bundleURL,
            Bundle.main.bundleURL
        ]
        for anchor in activeAnchors {
            var directory = anchor.standardizedFileURL.resolvingSymlinksInPath()
            // SwiftPM on Darwin: debug/Foo.xctest/Contents/MacOS/Foo;
            // Linux: debug/Foo.xctest. Xcode products use Debug or Release.
            for _ in 0..<7 {
                if ["debug", "release"].contains(directory.lastPathComponent.lowercased()),
                   let binary = validated(directory.appendingPathComponent("swiftj2k-cli")) {
                    return binary
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        throw CodecError(.internalFailure,
            "No swiftj2k-cli exists beside the active test build. Prebuild the product with the same configuration and scratch path, or supply its validated absolute path in SWIFTJ2K_TEST_CLI_PATH. Tests never build the CLI.")
    }

    static func run(
        _ arguments: [String], stdinData: Data? = nil, executable: URL? = nil
    ) async throws -> CLITestProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            // Process waiting and pipe I/O must not occupy a cooperative executor
            // or a global Dispatch worker. Each invocation owns its dedicated
            // blocking thread; completion follows child exit and all pipe joins.
            Thread.detachNewThread {
                do {
                    let result = try runBlocking(arguments, stdinData: stdinData, executable: executable)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Independent oracles discard output; keep their process lifetime and
    /// blocking wait on a dedicated thread without allocating pipe buffers.
    static func runDiscardingOutput(
        _ arguments: [String], executable: URL
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        _ arguments: [String], stdinData: Data?, executable: URL?
    ) throws -> CLITestProcessResult {
        let process = Process()
        process.executableURL = try executable ?? locateBinary()
        process.arguments = arguments
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        let stdinPipe = stdinData == nil ? nil : Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe { process.standardInput = stdinPipe }
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe?.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
        }
        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()

        let stdout = Mutex(Data()), stderr = Mutex(Data())
        let inputError = Mutex<(any Error)?>(nil)
        let ioWorkers = DispatchGroup()
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        ioWorkers.enter()
        Thread.detachNewThread {
            defer { ioWorkers.leave() }
            let bytes = outHandle.readDataToEndOfFile()
            stdout.withLock { $0 = bytes }
        }
        ioWorkers.enter()
        Thread.detachNewThread {
            defer { ioWorkers.leave() }
            let bytes = errHandle.readDataToEndOfFile()
            stderr.withLock { $0 = bytes }
        }
        if let stdinPipe, let stdinData {
            let inHandle = stdinPipe.fileHandleForWriting
            ioWorkers.enter()
            Thread.detachNewThread {
                defer {
                    try? inHandle.close()
                    ioWorkers.leave()
                }
                do { try inHandle.write(contentsOf: stdinData) }
                catch { inputError.withLock { $0 = error } }
            }
        }
        process.waitUntilExit()
        ioWorkers.wait()
        if let error = inputError.withLock({ $0 }) { throw error }
        return CLITestProcessResult(
            status: process.terminationStatus, reason: process.terminationReason,
            stdout: stdout.withLock { $0 }, stderr: stderr.withLock { $0 })
    }
}

@Suite("CLI subprocess harness")
struct CLITestProcessSupportTests {
    @Test("CLI resolution uses the active scratch build and rejects an invalid explicit path")
    func activeBuildResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("custom-scratch/any-target-triple/release")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let binary = products.appendingPathComponent("swiftj2k-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let expected = binary.resolvingSymlinksInPath()
        for anchor in [products.appendingPathComponent("Tests.xctest"),
                       products.appendingPathComponent("Tests.xctest/Contents/MacOS/Tests")] {
            #expect(try CLITestProcess.locateBinary(environment: [:], anchors: [anchor]) == expected)
        }
        #expect(try CLITestProcess.locateBinary(
            environment: ["SWIFTJ2K_TEST_CLI_PATH": binary.path], anchors: []) == expected)
        do {
            _ = try CLITestProcess.locateBinary(
                environment: ["SWIFTJ2K_TEST_CLI_PATH": root.appendingPathComponent("missing").path],
                anchors: [products.appendingPathComponent("Tests.xctest")])
            Issue.record("An invalid explicit CLI path must fail without falling back")
        } catch let error as CodecError {
            #expect(error.category == .internalFailure)
            #expect(error.message.contains("prebuild"))
        }
    }

    @Test("Concurrent stdout/stderr drains and stdin join before subprocess completion")
    func pipeCapacityDoesNotDeadlock() async throws {
        // Fill stderr before stdout: sequential stdout-then-stderr draining would
        // stall while the child waits for stderr space and stdout remains open.
        let line = String(repeating: "x", count: 63) + "\n"
        let script = "i=0; while [ $i -lt 4096 ]; do printf '%s\\n' '\(String(repeating: "x", count: 63))' >&2; i=$((i+1)); done; cat"
        let input = Data(repeating: 0xA5, count: 262_144)
        let result = try await CLITestProcess.run(["-c", script], stdinData: input,
                                                 executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(result.status == 0)
        #expect(result.reason == .exit)
        #expect(result.stdout == input)
        #expect(result.stderr == Data(String(repeating: line, count: 4096).utf8))
    }
}
