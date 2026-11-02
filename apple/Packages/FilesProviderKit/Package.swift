// swift-tools-version: 6.2
import PackageDescription

// The Files app's view of each paired host (iOS File Provider, docs/APP-ARCHITECTURE.md §22):
// item identity, the items, and the operations over the daemon's file RPCs, plus what the app
// shares with the extension. The extension target (apple/FilesProvider) is thin glue over it.
let package = Package(
    name: "FilesProviderKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "FilesProviderKit", targets: ["FilesProviderKit"]),
    ],
    dependencies: [
        .package(path: "../HostKit"),
        .package(path: "../GudoCore"),
    ],
    targets: [
        .target(
            name: "FilesProviderKit",
            dependencies: [
                .product(name: "HostKit", package: "HostKit"),
                .product(name: "GudoCore", package: "GudoCore"),
            ]
        ),
        .testTarget(name: "FilesProviderKitTests", dependencies: ["FilesProviderKit"]),
    ]
)
