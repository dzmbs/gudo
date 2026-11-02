// swift-tools-version: 6.2
import PackageDescription

// Tokens, Liquid Glass components and Ghostty-derived overlays shared by every screen of the app.
// Nothing here knows about panes, hosts or the daemon: screens pass plain values in.
let package = Package(
    name: "DesignSystem",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(
            name: "DesignSystem",
            resources: [
                .copy("Resources/ghostty-themes.json"),
                // Official program logos, switched on one by one in `ProgramCatalog.logos`.
                .process("Resources/ProgramLogos.xcassets"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
