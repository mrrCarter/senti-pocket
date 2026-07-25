// swift-tools-version:5.9
import PackageDescription

// PocketDialVoice — the AUDIO half of the DIALS voice loop (Forge). LiveDialVoice: PocketCall.DialVoice wires
// on-device TTS (AVSpeech) + on-device Whisper STT (PocketVoice) + an injected DialReasoner (PocketReasoning)
// into the orchestrator's speak/listen seam. This is the package that RE-INTRODUCES on-device Whisper STT to
// the app closure — per apps/SentiPocketApp/project.yml's 2026-07-20 note ("re-add WITH a real import when
// on-device Whisper STT actually ships (needs PrivacyInfo)"). App-target wiring is Atlas's (project.yml owner).
let package = Package(
    name: "PocketDialVoice",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PocketDialVoice", targets: ["PocketDialVoice"])
    ],
    dependencies: [
        .package(path: "../PocketContracts"),
        .package(path: "../PocketCall"),
        .package(path: "../PocketReasoning"),
        .package(path: "../PocketVoice")
    ],
    targets: [
        .target(
            name: "PocketDialVoice",
            dependencies: [
                .product(name: "PocketContracts", package: "PocketContracts"),
                .product(name: "PocketCall", package: "PocketCall"),
                .product(name: "PocketReasoning", package: "PocketReasoning"),
                .product(name: "PocketVoice", package: "PocketVoice")
            ]
        ),
        .testTarget(
            name: "PocketDialVoiceTests",
            dependencies: [
                "PocketDialVoice",
                .product(name: "PocketContracts", package: "PocketContracts"),
                .product(name: "PocketCall", package: "PocketCall"),
                .product(name: "PocketReasoning", package: "PocketReasoning"),
                .product(name: "PocketVoice", package: "PocketVoice")
            ]
        )
    ]
)
