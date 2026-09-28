// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CallMenu", platforms: [.macOS("14.2")],
    products: [
        .library(name: "CallAudio", targets: ["CallAudio"]),
        .executable(name: "CallMenu", targets: ["CallMenu"]),
        .executable(name: "CallMCP", targets: ["CallMCP"])
    ],
    targets: [
        .executableTarget(name: "CallMenu", dependencies: ["CallAudio", "CallPreferences", "CallVoice", "CallControl", "CallAutomation", "CallHistory", "CallTranscription"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallAutomation", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallAutomationTests", dependencies: ["CallAutomation"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallControl", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CallMCP", dependencies: ["CallControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallControlTests", dependencies: ["CallControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallVoice", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallVoiceTests", dependencies: ["CallVoice"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LiveVoiceCheck", dependencies: ["CallVoice"], path: "Tests/LiveVoiceCheck", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallPreferences", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallHistory", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallTranscription", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallTranscriptionTests", dependencies: ["CallTranscription"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallHistoryTests", dependencies: ["CallHistory"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallPreferencesTests", dependencies: ["CallPreferences"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CallAudioDSP", publicHeadersPath: "include"),
        .target(name: "CallAudio", dependencies: ["CallAudioDSP"], exclude: ["Architecture.md"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CallAudioTests", dependencies: ["CallAudio", "CallAudioDSP"], swiftSettings: [.swiftLanguageMode(.v5)])
    ])
