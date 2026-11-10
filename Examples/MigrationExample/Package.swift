// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
// Executable companion of MIGRATION.md. Depends on the repository by path; an
// application uses the URL form shown in the guide instead.
import PackageDescription

let package = Package(
    name: "MigrationExample",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "MigrationExample", dependencies: [.product(name: "SwiftJ2K", package: "SwiftJ2K")])],
    swiftLanguageModes: [.v6]
)
