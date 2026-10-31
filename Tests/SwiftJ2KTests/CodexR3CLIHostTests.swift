// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("R3 JPIP CLI bind and verification addresses")
struct CodexR3CLIHostTests {
    @Test(arguments: [" 127.0.0.1 ", " \t\n ", "", " * ", " 0.0.0.0 "])
    func onceVerificationUsesTheAcceptedBindAddress(host: String) async throws {
        let resources = try #require(Bundle.module.resourceURL)
        let fixture = resources.appendingPathComponent("Fixtures/Lossless/g16_1x1_max.opj_n1.j2k")
        let result = try await CLITestProcess.run([
            "jpip", "server", "--single-file", fixture.path,
            "--host", host, "--port", "0", "--once", "--json"
        ])
        #expect(result.reason == .exit)
        #expect(result.status == 0, "\(result.stderrText)")
        let report = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(report["host"] as? String == (trimmed.isEmpty ? "127.0.0.1" : trimmed))
        #expect((report["port"] as? Int ?? 0) > 0)
        #expect(report["registeredTargets"] as? Int == 1)
    }

    @Test func invalidBindAddressFailsWithoutATrap() async throws {
        let resources = try #require(Bundle.module.resourceURL)
        let fixture = resources.appendingPathComponent("Fixtures/Lossless/g16_1x1_max.opj_n1.j2k")
        let result = try await CLITestProcess.run([
            "jpip", "server", "--single-file", fixture.path,
            "--host", "not-an-ip", "--port", "0", "--once", "--json"
        ])
        #expect(result.reason == .exit)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderrText.contains("Invalid IPv4 bind address"))
    }
}
