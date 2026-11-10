// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
// Development-only mutation fuzz harness (TESTING.md TEST-05). Depends on the
// repository by path and is never part of the shipped dependency graph.
import PackageDescription

let package = Package(
    name: "FuzzHarness",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "FuzzHarness", dependencies: [.product(name: "SwiftJ2K", package: "SwiftJ2K")])],
    swiftLanguageModes: [.v6]
)
