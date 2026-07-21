// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketBriefing",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketBriefing", targets: ["PocketBriefing"])
    ],
    dependencies: [
        .package(path: "../PocketContracts")
    ],
    targets: [
        .target(name: "PocketBriefing", dependencies: [.product(name: "PocketContracts", package: "PocketContracts")]),
        .testTarget(name: "PocketBriefingTests", dependencies: [
            "PocketBriefing",
            .product(name: "PocketContracts", package: "PocketContracts")
        ])
    ]
)
