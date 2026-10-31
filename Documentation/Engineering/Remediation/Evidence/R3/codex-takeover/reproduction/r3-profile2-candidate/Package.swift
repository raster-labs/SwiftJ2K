// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "R3Profile2", platforms: [.macOS(.v26)],
    products: [.executable(name: "r3-profile2", targets: ["Profile"])],
    dependencies: [.package(path: "/Users/raster/Documents/Codex/2026-10-31/swiftj2k-r3-codex-takeover/work/candidate-snapshot-03")],
    targets: [.executableTarget(name: "Profile", dependencies: [
        .product(name: "SwiftJ2K", package: "candidate-snapshot-03"),
        .product(name: "SwiftJ2K3D", package: "candidate-snapshot-03")
    ])], swiftLanguageModes: [.v6])
