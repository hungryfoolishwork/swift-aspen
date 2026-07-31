// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ping",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ping",
            dependencies: [.product(name: "IrohLib", package: "iroh-ffi")]
        )
    ]
)
