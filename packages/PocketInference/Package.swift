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
        .package(url: "https://github.com/google-ai-edge/LiteRT-LM", exact: "0.13.0")
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
