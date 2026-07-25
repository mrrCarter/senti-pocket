// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketUI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "PocketUI", targets: ["PocketUI"])
    ],
    dependencies: [
        .package(path: "../PocketContracts"),
        .package(path: "../PocketCall")
    ],
    targets: [
        .target(
            name: "PocketUI",
            dependencies: [
                .product(name: "PocketContracts", package: "PocketContracts"),
                .product(name: "PocketCall", package: "PocketCall")
            ]
        ),
        .testTarget(
            name: "PocketUIUnitTests",
            dependencies: ["PocketUI", "PocketContracts", "PocketCall"]
        )
    ]
)
