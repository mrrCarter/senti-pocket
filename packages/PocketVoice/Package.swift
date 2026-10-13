// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PocketVoice",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketVoice", targets: ["PocketVoice"])
    ],
    dependencies: [
        .package(path: "../PocketContracts"),
        .package(
            url: "https://github.com/cloudflare/realtimekit-ios-core.git",
            exact: "3.1.0"
        )
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        ),
        .target(
            name: "PocketVoice",
            dependencies: [
                "whisper",
                "PocketContracts",
                .product(
                    name: "RealtimeKit",
                    package: "realtimekit-ios-core",
                    condition: .when(platforms: [.iOS])
                )
            ]
        ),
        .testTarget(
            name: "PocketVoiceTests",
            dependencies: ["PocketVoice", "PocketContracts"]
        )
    ]
)
