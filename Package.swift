// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-aspen",
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
        .executable(name: "pool", targets: ["pool"]),
        .executable(name: "identity", targets: ["identity"]),
        .executable(name: "identitychain", targets: ["identitychain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hungryfoolishwork/iroh-ffi.git", branch: "swift-xcframework-coexist"),
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
            name: "pool",
            dependencies: [
                "Aspen",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/Pool"
        ),
        .executableTarget(
            name: "identity",
            dependencies: [
                "Aspen",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/Identity"
        ),
        .executableTarget(
            name: "identitychain",
            dependencies: [
                "Aspen",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/IdentityChain"
        ),
        .testTarget(
            name: "AspenTests",
            dependencies: ["Aspen"]
        ),
    ]
)
