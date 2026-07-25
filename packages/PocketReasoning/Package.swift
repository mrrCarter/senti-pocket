// swift-tools-version:5.9
import PackageDescription

// PocketReasoning — the app-shell reasoning seam (Atlas). The ReasoningProvider abstraction + the two providers
// (Gateway = online .liveReasoned; Cached = offline .cachedSample fallback) that finish the reasoning seam whose
// gateway wire Relay shipped + Warden gated (/answer bf79a6fa, /brief 4b1feaa). Depends only on PocketContracts.
let package = Package(
    name: "PocketReasoning",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketReasoning", targets: ["PocketReasoning"])
    ],
    dependencies: [
        .package(path: "../PocketContracts")
    ],
    targets: [
        .target(name: "PocketReasoning", dependencies: [.product(name: "PocketContracts", package: "PocketContracts")]),
        .testTarget(name: "PocketReasoningTests", dependencies: [
            "PocketReasoning",
            .product(name: "PocketContracts", package: "PocketContracts")
        ])
    ]
)
