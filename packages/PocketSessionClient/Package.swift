// swift-tools-version:5.9
import PackageDescription

// PocketSessionClient — Relay-owned client-side auth + session-READ transport for Senti Pocket.
// Implements the ratified Pocket Auth + Session-Fetch security contract (docs/auth-fetch-contract.md @ a0a9114c).
// Standalone until Atlas's step-2 shell consumes it. Depends on the merged wire DTOs in PocketContracts.
let package = Package(
    name: "PocketSessionClient",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketSessionClient", targets: ["PocketSessionClient"])
    ],
    dependencies: [
        .package(path: "../PocketContracts")
    ],
    targets: [
        .target(
            name: "PocketSessionClient",
            dependencies: [.product(name: "PocketContracts", package: "PocketContracts")]
        ),
        .testTarget(
            name: "PocketSessionClientTests",
            dependencies: ["PocketSessionClient"]
        )
    ]
)
