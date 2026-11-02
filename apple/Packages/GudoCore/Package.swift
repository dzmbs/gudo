// swift-tools-version: 6.2
import PackageDescription

// The Rust core (crates/apple-ffi) for the app. `cargo xtask build-xcframework` builds
// GudoCore.xcframework and Sources/GudoCore/GudoCore.swift (both gitignored);
// `--macos-only` is enough for `swift test`. See docs/APPLE-FFI.md.
let package = Package(
    name: "GudoCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "GudoCore", targets: ["GudoCore"]),
    ],
    targets: [
        // Static library + C header (module GudoCoreFFI). Exports only the UniFFI API;
        // its libghostty-vt and Rust std are private to it.
        .binaryTarget(name: "GudoCoreFFI", path: "GudoCore.xcframework"),
        .target(
            name: "GudoCore",
            dependencies: ["GudoCoreFFI"],
            linkerSettings: [
                // iroh/netdev (network paths and interfaces, DNS), ring/rustls (system roots).
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(name: "GudoCoreTests", dependencies: ["GudoCore"]),
    ]
)
