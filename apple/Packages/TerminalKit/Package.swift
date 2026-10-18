// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "TerminalRenderer", targets: ["TerminalRenderer"]),
        .library(name: "LocalPTY", targets: ["LocalPTY"]),
        .executable(name: "TerminalDemo", targets: ["TerminalDemo"]),
        .executable(name: "TerminalBench", targets: ["TerminalBench"]),
    ],
    targets: [
        // Built by apple/scripts/build-libghostty-vt.sh (macOS universal, iOS, iOS simulator slices).
        .binaryTarget(name: "GhosttyVt", path: "../../build/ghostty-vt/lib/ghostty-vt.xcframework"),
        .target(name: "TerminalCore", dependencies: ["GhosttyVt"]),
        .target(
            name: "TerminalRenderer",
            dependencies: ["TerminalCore"],
            resources: [.copy("Resources/Fonts"), .copy("Resources/Shaders")]
        ),
        .target(name: "CPTYSpawn"),
        .target(name: "LocalPTY", dependencies: ["CPTYSpawn"]),
        .executableTarget(name: "TerminalDemo", dependencies: ["TerminalRenderer", "LocalPTY"]),
        .executableTarget(name: "TerminalBench", dependencies: ["TerminalRenderer", "LocalPTY"]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        .testTarget(name: "LocalPTYTests", dependencies: ["LocalPTY"]),
        .testTarget(name: "TerminalRendererTests", dependencies: ["TerminalRenderer"]),
    ]
)
