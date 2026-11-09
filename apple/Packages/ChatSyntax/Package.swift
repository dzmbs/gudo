// swift-tools-version: 6.0
import PackageDescription

let grammars: [(String, String, Package.Dependency)] = [
    ("TreeSitterRust", "tree-sitter-rust", .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2")),
    ("TreeSitterSwift", "tree-sitter-swift", .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "82bb3a533e0801fd2bbaa11dc49676e10bf41948")),
    ("TreeSitterJavaScript", "tree-sitter-javascript", .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1")),
    ("TreeSitterTypeScript", "tree-sitter-typescript", .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2")),
    ("TreeSitterPython", "tree-sitter-python", .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6")),
    ("TreeSitterGo", "tree-sitter-go", .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0")),
    ("TreeSitterBash", "tree-sitter-bash", .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1")),
    ("TreeSitterJSON", "tree-sitter-json", .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8")),
    ("TreeSitterYAML", "tree-sitter-yaml", .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0")),
    ("TreeSitterTOML", "tree-sitter-toml", .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", revision: "64b56832c2cffe41758f28e05c756a3a98d16f41")),
    ("TreeSitterMarkdown", "tree-sitter-markdown", .package(url: "https://github.com/MDeiml/tree-sitter-markdown", exact: "0.5.4")),
    ("TreeSitterC", "tree-sitter-c", .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2")),
    ("TreeSitterCPP", "tree-sitter-cpp", .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4")),
    ("TreeSitterHTML", "tree-sitter-html", .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2")),
    ("TreeSitterCSS", "tree-sitter-css", .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2")),
    ("TreeSitterDiff", "tree-sitter-diff", .package(url: "https://github.com/the-mikedavis/tree-sitter-diff", exact: "0.2.0")),
]

let package = Package(
    name: "ChatSyntax",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "ChatSyntax", targets: ["ChatSyntax"])],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
    ] + grammars.map(\.2),
    targets: [
        .target(name: "ChatSyntax", dependencies: [
            .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            .product(name: "TreeSitter", package: "tree-sitter")
        ] + grammars.map { .product(name: $0.0, package: $0.1) }),
        .testTarget(name: "ChatSyntaxTests", dependencies: ["ChatSyntax"]),
    ]
)
