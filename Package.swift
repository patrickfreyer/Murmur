// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Undersay",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Undersay", targets: ["Undersay"])],
    dependencies: [
        // ASR (Parakeet on the Neural Engine) + speaker diarization/embeddings. TTS and the
        // NeMo text-normalisation runtime are left out to keep the app small.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        .target(
            name: "UndersayCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/UndersayCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Undersay",
            dependencies: ["UndersayCore"],
            path: "Sources/Undersay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "UndersayTests", dependencies: ["UndersayCore"], path: "Tests/UndersayTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
