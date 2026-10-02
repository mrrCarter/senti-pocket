// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketSyncClient",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketSyncClient", targets: ["PocketSyncClient"])
    ],
    dependencies: [
        .package(path: "../PocketContracts")
    ],
    targets: [
        .target(
            name: "PocketSyncClient",
            dependencies: [.product(name: "PocketContracts", package: "PocketContracts")]
        ),
        .testTarget(
            name: "PocketSyncClientTests",
            dependencies: [
                "PocketSyncClient",
                .product(name: "PocketContracts", package: "PocketContracts")
            ]
        )
    ]
)
