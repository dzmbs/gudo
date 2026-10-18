// swift-tools-version: 6.2
import PackageDescription

// The Rust core (crates/apple-ffi) for the app. `cargo xtask build-xcframework` builds
// UnnamedCore.xcframework and Sources/UnnamedCore/UnnamedCore.swift (both gitignored);
// `--macos-only` is enough for `swift test`. See docs/APPLE-FFI.md.
let package = Package(
    name: "UnnamedCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "UnnamedCore", targets: ["UnnamedCore"]),
    ],
    targets: [
        // Static library + C header (module UnnamedCoreFFI). Exports only the UniFFI API;
        // its libghostty-vt and Rust std are private to it.
        .binaryTarget(name: "UnnamedCoreFFI", path: "UnnamedCore.xcframework"),
        .target(
            name: "UnnamedCore",
            dependencies: ["UnnamedCoreFFI"],
            linkerSettings: [
                // iroh/netdev (network paths and interfaces, DNS), ring/rustls (system roots).
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(name: "UnnamedCoreTests", dependencies: ["UnnamedCore"]),
    ]
)
