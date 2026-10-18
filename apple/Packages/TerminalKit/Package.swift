// swift-tools-version: 6.2
import Foundation
import PackageDescription

// libghostty-vt is prebuilt by apple/scripts/build-libghostty-vt.sh into apple/build/ghostty-vt.
// Once Xcode is available this becomes a `.binaryTarget` over zig's ghostty-vt.xcframework (macOS +
// iOS + iOS simulator slices) and the unsafe -L flag goes away.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let ghosttyLibDir = packageDir.appending(path: "../../build/ghostty-vt/lib").standardized.path

let package = Package(
    name: "TerminalKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "TerminalRenderer", targets: ["TerminalRenderer"]),
        .executable(name: "TerminalDemo", targets: ["TerminalDemo"]),
        .executable(name: "TerminalBench", targets: ["TerminalBench"]),
    ],
    targets: [
        .target(
            name: "CGhosttyVt",
            linkerSettings: [
                .unsafeFlags(["-L", ghosttyLibDir]),
                .linkedLibrary("ghostty-vt"),
            ]
        ),
        .target(name: "TerminalCore", dependencies: ["CGhosttyVt"]),
        .target(
            name: "TerminalRenderer",
            dependencies: ["TerminalCore"],
            resources: [.copy("Resources/Fonts"), .copy("Resources/Shaders")]
        ),
        .target(name: "LocalPTY"),
        .executableTarget(name: "TerminalDemo", dependencies: ["TerminalRenderer", "LocalPTY"]),
        .executableTarget(name: "TerminalBench", dependencies: ["TerminalRenderer", "LocalPTY"]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        .testTarget(name: "TerminalRendererTests", dependencies: ["TerminalRenderer"]),
    ]
)
