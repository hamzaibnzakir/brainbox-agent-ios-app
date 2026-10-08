// swift-tools-version:5.9
import PackageDescription

// BrainboxCore holds everything that is not UI: models, the provider
// protocols, the Brainbox wire protocol, transports, mock providers,
// persistence and pure text utilities (markdown, syntax, diff).
//
// It deliberately builds on Linux as well as Apple platforms so the
// core test-suite can run on cheap Linux CI runners. Apple-only APIs
// (Keychain) are guarded with `#if canImport(...)`.
let package = Package(
    name: "BrainboxCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BrainboxCore", targets: ["BrainboxCore"])
    ],
    targets: [
        .target(
            name: "BrainboxCore",
            path: "Sources/BrainboxCore"
        ),
        .testTarget(
            name: "BrainboxCoreTests",
            dependencies: ["BrainboxCore"],
            path: "Tests/BrainboxCoreTests"
        )
    ]
)
