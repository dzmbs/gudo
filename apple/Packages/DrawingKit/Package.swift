// swift-tools-version: 6.2
import PackageDescription

// (Excalidraw scene px ↔ cells ↔ view points), PencilKit strokes → Excalidraw `freedraw`
// elements, and the row tracker that pins anchored rows in the app's own terminal.
let package = Package(
    name: "DrawingKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DrawingKit", targets: ["DrawingKit"]),
    ],
    dependencies: [
        .package(path: "../TerminalKit"),
    ],
    targets: [
        .target(name: "DrawingKit", dependencies: [.product(name: "TerminalCore", package: "TerminalKit")]),
        .testTarget(name: "DrawingKitTests", dependencies: ["DrawingKit"]),
    ]
)
