// swift-tools-version: 5.9
import PackageDescription

// PHASE-A STUB (pocket-forge, demo build): LiteRT-LM ships unsafe build flags that SwiftPM refuses to
// resolve for an app product, so the remote dep + its product are stripped and the sole file that imports
// LiteRTLM (LiteRTLMInferenceEngine.swift) is excluded. Nothing in the app/packages references that engine
// (only a README example did), so the deterministic Phase-A inference path is unaffected. This is a
// throwaway demo-build worktree; the canonical stub decision lives on the integration branch.
let package = Package(
    name: "PocketInference",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketInference", targets: ["PocketInference"])
    ],
    dependencies: [
        .package(path: "../PocketContracts"),
        .package(path: "../PocketCall")
    ],
    targets: [
        .target(
            name: "PocketInference",
            dependencies: [
                "PocketContracts",
                "PocketCall"
            ],
            exclude: ["LiteRTLMInferenceEngine.swift"]
        ),
        .testTarget(
            name: "PocketInferenceTests",
            dependencies: ["PocketInference", "PocketContracts", "PocketCall"]
        )
    ]
)
