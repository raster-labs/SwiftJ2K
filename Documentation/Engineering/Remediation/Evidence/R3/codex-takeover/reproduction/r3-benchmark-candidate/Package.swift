// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "R3Benchmark", platforms: [.macOS(.v26)], products: [.executable(name: "r3-benchmark", targets: ["Benchmark"])], dependencies: [.package(path: "/Users/raster/Documents/Codex/2026-10-31/swiftj2k-r3-codex-takeover/work/diagnostic-source-05")], targets: [.executableTarget(name: "Benchmark", dependencies: [.product(name: "SwiftJ2K", package: "diagnostic-source-05"), .product(name: "SwiftJ2K3D", package: "diagnostic-source-05")])], swiftLanguageModes: [.v6])
