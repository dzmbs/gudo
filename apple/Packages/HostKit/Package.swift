// swift-tools-version: 6.2
import PackageDescription

// The app's data and control layer (docs/APP-ARCHITECTURE.md): hosts, pairing, daemon and
// plain-SSH connections, the layout store and pane backends over GudoCore, connection
// lifecycle, secrets. No views: the UI binds to its @Observable models.
let package = Package(
    name: "HostKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HostKit", targets: ["HostKit"]),
    ],
    dependencies: [
        .package(path: "../PaneLayout"),
        .package(path: "../TerminalKit"),
        .package(path: "../GudoCore"),
    ],
    targets: [
        .target(
            name: "HostKit",
            dependencies: [
                .product(name: "PaneLayout", package: "PaneLayout"),
                // Echo-prediction types (`PredictionUpdate`, `EchoHint`) only.
                .product(name: "TerminalCore", package: "TerminalKit"),
                .product(name: "GudoCore", package: "GudoCore"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "HostKitTests",
            dependencies: ["HostKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
