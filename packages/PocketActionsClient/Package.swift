// swift-tools-version:5.9
import PackageDescription

// Owner: claude-pocket-relay. Governed writeback + receipts + offline pending intents.
// Types are INTERIM and align to packages/PocketContracts (Atlas, v0.1) at freeze.
let package = Package(
    name: "PocketActionsClient",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PocketActionsClient", targets: ["PocketActionsClient"])
    ],
    targets: [
        .target(name: "PocketActionsClient"),
        .testTarget(name: "PocketActionsClientTests", dependencies: ["PocketActionsClient"])
    ]
)
