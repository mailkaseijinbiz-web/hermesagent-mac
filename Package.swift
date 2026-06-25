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
    targets: [
        .executableTarget(
            name: "HermesCustom",
            path: "Sources"
        )
    ]
)
