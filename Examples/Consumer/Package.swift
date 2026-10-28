// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "SwiftJ2K", package: "SwiftJ2K"),
                .product(name: "SwiftJ2K3D", package: "SwiftJ2K"),
                .product(name: "SwiftJ2KJPIP", package: "SwiftJ2K")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
