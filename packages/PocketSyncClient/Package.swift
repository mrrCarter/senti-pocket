// swift-tools-version:5.9
import PackageDescription

// Owner: claude-pocket-relay. Narrow interface package — checkpoint bundle pull + sync to phone.
// Types here are INTERIM and align to packages/PocketContracts (Atlas, v0.1) at freeze.
let package = Package(
    name: "PocketSyncClient",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PocketSyncClient", targets: ["PocketSyncClient"])
    ],
    targets: [
        .target(name: "PocketSyncClient"),
        .testTarget(name: "PocketSyncClientTests", dependencies: ["PocketSyncClient"])
    ]
)
