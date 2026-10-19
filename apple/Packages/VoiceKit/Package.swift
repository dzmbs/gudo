// swift-tools-version: 6.2
import PackageDescription

// Push-to-talk dictation for the terminal and agent prompts (docs/APP-ARCHITECTURE.md §13):
// Apple's on-device speech (SpeechAnalyzer/SpeechTranscriber, else SFSpeechRecognizer on device),
// the transcript and commit logic, and the hold-to-talk shortcut. No views and no terminal types:
// the app supplies a `DictationTarget` per pane.
let package = Package(
    name: "VoiceKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
    ],
    targets: [
        .target(
            name: "VoiceKit",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "VoiceKitTests",
            dependencies: ["VoiceKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
