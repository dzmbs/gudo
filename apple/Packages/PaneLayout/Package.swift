// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaneLayout",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PaneLayout", targets: ["PaneLayout"]),
    ],
    targets: [
        .target(name: "PaneLayout"),
        .testTarget(name: "PaneLayoutTests", dependencies: ["PaneLayout"]),
    ]
)
