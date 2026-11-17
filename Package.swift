// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Murmur", targets: ["Murmur"])],
    dependencies: [
        // ASR (Parakeet on the Neural Engine) + speaker diarization/embeddings. TTS and the
        // NeMo text-normalisation runtime are left out to keep the app small.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        .target(
            name: "MurmurCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MurmurCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MurmurTests", dependencies: ["MurmurCore"], path: "Tests/MurmurTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
