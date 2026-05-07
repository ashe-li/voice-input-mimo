// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInputMimo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceInputMimo",
            path: "Sources/VoiceInputMimo"
        )
    ]
)
