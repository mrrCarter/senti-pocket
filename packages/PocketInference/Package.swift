// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PocketInference",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketInference", targets: ["PocketInference"])
    ],
    dependencies: [
        .package(path: "../PocketContracts"),
        .package(path: "../PocketCall"),
        // LiteRT-LM v0.15.0. The upstream release is mutable, so bind the reviewed source commit.
        .package(
            url: "https://github.com/google-ai-edge/LiteRT-LM",
            revision: "2117fc4314670e00047bc8469783f02a68c33f0c"
        )
    ],
    targets: [
        .target(
            name: "PocketInference",
            dependencies: [
                "PocketContracts",
                "PocketCall",
                .product(name: "LiteRTLM", package: "LiteRT-LM")
            ]
        ),
        .testTarget(
            name: "PocketInferenceTests",
            dependencies: ["PocketInference", "PocketContracts", "PocketCall"]
        )
    ]
)
