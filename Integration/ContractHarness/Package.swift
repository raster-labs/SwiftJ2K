// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ContractHarness",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "SwiftJ2K", path: "../.."), .package(path: "../../../SwiftJLS"),
        .package(path: "../../../SwiftJXL"), .package(path: "../../../SwiftJLI")
    ],
    targets: [.executableTarget(name: "ContractHarness", dependencies: [
        .product(name: "SwiftJ2K", package: "SwiftJ2K"),
        .product(name: "SwiftJLS", package: "SwiftJLS"),
        .product(name: "SwiftJXL", package: "SwiftJXL"),
        .product(name: "SwiftJLI", package: "SwiftJLI")
    ])],
    swiftLanguageModes: [.v6]
)
