// swift-tools-version:5.9
import PackageDescription

// HermesKit: the phone's direct line to Hermes over SSH, the same way Hermes
// Desktop connects. SSH (SwiftNIO SSH) starts or reuses `hermes serve` on the
// server and tunnels its HTTP + WebSocket API; everything above that speaks
// Hermes' own JSON-RPC gateway (the backend Desktop and the TUI use).
//
// Builds and tests on Linux too, so the whole engine is exercised in CI
// against a real sshd and a real `hermes serve`.
let package = Package(
    name: "HermesKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HermesKit", targets: ["HermesKit"])],
    dependencies: [
        .package(path: "../BrainboxCore"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "HermesKit",
            dependencies: [
                "BrainboxCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
    ]
)
