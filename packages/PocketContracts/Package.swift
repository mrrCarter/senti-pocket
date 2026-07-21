// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketContracts",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketContracts", targets: ["PocketContracts"])
    ],
    targets: [
        .target(name: "PocketContracts"),
        .testTarget(name: "PocketContractsTests", dependencies: ["PocketContracts"], resources: [.copy("../../Fixtures/canonical_checkpoint.json")])
    ]
)
