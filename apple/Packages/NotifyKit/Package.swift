// swift-tools-version: 6.2
import PackageDescription

// Notifications without the core: categories and actions, per-kind preferences, local
// notifications from the attention feed, the Notification Service Extension's work (PushCrypto)
// and the action handler, behind small protocols so they are unit-tested here and shared by the
// app and the extension (which must stay small and cannot link the Rust core). docs/PUSH.md.
let package = Package(
    name: "NotifyKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "NotifyKit", targets: ["NotifyKit"]),
    ],
    dependencies: [
        .package(path: "../PushCrypto"),
    ],
    targets: [
        .target(
            name: "NotifyKit",
            dependencies: [.product(name: "PushCrypto", package: "PushCrypto")]
        ),
        .testTarget(
            name: "NotifyKitTests",
            dependencies: ["NotifyKit", .product(name: "PushCrypto", package: "PushCrypto")]
        ),
    ]
)
