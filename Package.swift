// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesCustom",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HermesCustom", targets: ["HermesCustom"])
    ],
    dependencies: [
        .package(path: "../HermesShared")
    ],
    targets: [
        .executableTarget(
            name: "HermesCustom",
            dependencies: [.product(name: "HermesShared", package: "HermesShared")],
            path: "Sources"
        ),
        .testTarget(
            name: "HermesCustomTests",
            dependencies: ["HermesCustom"],
            path: "Tests"
        )
    ],
    // Match the shipping build (project.yml SWIFT_VERSION 5.0). Swift 6 strict-concurrency
    // migration is tracked separately on the roadmap.
    swiftLanguageModes: [.v5]
)
