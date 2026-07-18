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
        .testTarget(
            name: "PocketContractsTests",
            dependencies: ["PocketContracts"],
            // P1.5: the signed pocket.bundle.v1 KAV is a bundled test RESOURCE (loaded via Bundle.module),
            // so the test verifies the committed signature/pubkey/canonical instead of duplicating literals.
            resources: [.copy("Fixtures/bundle_kav.json")]
        )
    ]
)
