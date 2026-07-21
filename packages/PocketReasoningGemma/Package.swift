// swift-tools-version:5.9
import PackageDescription

// PocketReasoningGemma — bridges echo's PocketInference (LiteRT-LM / Gemma E4B, on-device) into the ReasoningProvider
// abstraction, so Gemma is ACTUALLY USED for offline reasoning over the verified checkpoint. Isolated in its own
// package so the LiteRT-LM dependency only loads for builds that opt into on-device Gemma (the app injects it as the
// offline provider once the Gemma model artifact is prepared).
let package = Package(
    name: "PocketReasoningGemma",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketReasoningGemma", targets: ["PocketReasoningGemma"])
    ],
    dependencies: [
        .package(path: "../PocketReasoning"),
        .package(path: "../PocketInference"),
        .package(path: "../PocketCall"),
        .package(path: "../PocketContracts")
    ],
    targets: [
        .target(name: "PocketReasoningGemma", dependencies: [
            .product(name: "PocketReasoning", package: "PocketReasoning"),
            .product(name: "PocketInference", package: "PocketInference"),
            .product(name: "PocketCall", package: "PocketCall"),
            .product(name: "PocketContracts", package: "PocketContracts")
        ])
        // NOTE: no .testTarget yet. A sourceless test target breaks `swift build` with "overlapping sources"
        // (SwiftPM defaults its path onto the main target). A real one needs Tests/PocketReasoningGemmaTests/
        // sources AND a buildable PocketInference (LiteRTLM currently ships unsafe build flags -> blocked).
        // Re-add WITH real sources once LiteRTLM is unblocked.
    ]
)
