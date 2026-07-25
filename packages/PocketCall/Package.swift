// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketCall",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketCall", targets: ["PocketCall"])
    ],
    dependencies: [
        .package(path: "../PocketContracts")
    ],
    targets: [
        .target(name: "PocketCall", dependencies: [.product(name: "PocketContracts", package: "PocketContracts")]),
        .testTarget(name: "PocketCallTests", dependencies: [
            "PocketCall",
            .product(name: "PocketContracts", package: "PocketContracts")
        ])
    ]
)
