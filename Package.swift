// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ping",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "PingKit", targets: ["PingKit"]),
        .executable(name: "ping", targets: ["ping"]),
    ],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "PingKit",
            dependencies: [.product(name: "IrohLib", package: "iroh-ffi")]
        ),
        .executableTarget(
            name: "ping",
            dependencies: ["PingKit"]
        ),
    ]
)
