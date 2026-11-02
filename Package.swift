// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

// The manifest floor stays at the 6.2 minimum that SUITE_POLICY.md PLAT-01
// fixes, so a 6.2 or 6.3 consumer can still resolve this package. That is a
// resolution floor, not a ceiling: the sources build unchanged under the 6.4
// toolchain, and CI is expected to exercise both.
let package = Package(
    name: "SwiftJ2K",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .visionOS(.v26), .watchOS(.v26)],
    products: [.library(name: "SwiftJ2K", targets: ["SwiftJ2K"]),
               .library(name: "SwiftJ2K3D", targets: ["SwiftJ2K3D"]),
               .library(name: "SwiftJ2KJPIP", targets: ["SwiftJ2KJPIP"]),
               .executable(name: "swiftj2k-cli", targets: ["swiftj2k-cli"])],
    targets: [
        .target(name: "CZlibShim", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "SwiftJ2K"),
        .target(name: "SwiftJ2K3D", dependencies: ["SwiftJ2K"]),
        .target(name: "SwiftJ2KJPIP", dependencies: ["SwiftJ2K", "SwiftJ2K3D"]),
        .target(name: "SwiftJ2KCLI", dependencies: ["SwiftJ2K", "SwiftJ2K3D", "SwiftJ2KJPIP", "CZlibShim"]),
        .executableTarget(name: "swiftj2k-cli", dependencies: ["SwiftJ2KCLI"], path: "Sources/SwiftJ2KCLIMain"),
        .testTarget(
            name: "SwiftJ2KTests",
            dependencies: [
                "SwiftJ2K",
                "SwiftJ2KCLI",
                .target(name: "swiftj2k-cli", condition: .when(platforms: [.macOS, .linux]))
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SwiftJ2K3DTests", dependencies: ["SwiftJ2K3D", "SwiftJ2K"]),
        .testTarget(name: "SwiftJ2KJPIPTests", dependencies: ["SwiftJ2KJPIP", "SwiftJ2K3D", "SwiftJ2K"])
    ],
    swiftLanguageModes: [.v6]
)
