// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Aspen",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .watchOS(.v26),
        .tvOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "Aspen", targets: ["Aspen"]),
        .executable(name: "party", targets: ["party"]),
        .executable(name: "identity", targets: ["identity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Aspen",
            dependencies: [
                .product(name: "IrohLib", package: "iroh-ffi"),
            ]
        ),
        .executableTarget(
            name: "party",
            dependencies: [
                "Aspen",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/Party"
        ),
        .executableTarget(
            name: "identity",
            dependencies: [
                "Aspen",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/Identity"
        ),
        .testTarget(
            name: "AspenTests",
            dependencies: ["Aspen"]
        ),
    ]
)
