import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterDiff
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

extension CodeLanguage {
    var parserLanguage: Language {
        let pointer: OpaquePointer
        switch self {
        case .rust: pointer = tree_sitter_rust()
        case .swift: pointer = tree_sitter_swift()
        case .javascript: pointer = tree_sitter_javascript()
        case .typescript: pointer = tree_sitter_typescript()
        case .tsx: pointer = tree_sitter_tsx()
        case .python: pointer = tree_sitter_python()
        case .go: pointer = tree_sitter_go()
        case .bash: pointer = tree_sitter_bash()
        case .json: pointer = tree_sitter_json()
        case .yaml: pointer = tree_sitter_yaml()
        case .toml: pointer = tree_sitter_toml()
        case .markdown: pointer = tree_sitter_markdown()
        case .c: pointer = tree_sitter_c()
        case .cpp: pointer = tree_sitter_cpp()
        case .html: pointer = tree_sitter_html()
        case .css: pointer = tree_sitter_css()
        case .diff: pointer = tree_sitter_diff()
        }
        return Language(pointer)
    }

    private var bundleName: String {
        let name: String
        switch self {
        case .rust: name = "Rust"
        case .swift: name = "Swift"
        case .javascript: name = "JavaScript"
        case .typescript: name = "TypeScript"
        case .tsx: return "TreeSitterTypeScript_TreeSitterTSX"
        case .python: name = "Python"
        case .go: name = "Go"
        case .bash: name = "Bash"
        case .json: name = "JSON"
        case .yaml: name = "YAML"
        case .toml: name = "TOML"
        case .markdown: name = "Markdown"
        case .c: name = "C"
        case .cpp: name = "CPP"
        case .html: name = "HTML"
        case .css: name = "CSS"
        case .diff: name = "Diff"
        }
        return "TreeSitter\(name)_TreeSitter\(name)"
    }

    func highlightQuery() throws -> Query {
        try SharedQueries.instance.query(for: self)
    }

    func compileHighlightQuery() throws -> Query {
        // These grammars extend their base language's queries. Compile the combined source
        // against the derived grammar, never execute a base grammar's numeric node IDs.
        let parents: [CodeLanguage]
        switch self {
        case .typescript, .tsx: parents = [.javascript]
        case .cpp: parents = [.c]
        default: parents = []
        }
        var data = Data()
        for language in parents + [self] {
            data.append(try language.queryData())
            data.append(10)
        }
        return try Query(language: parserLanguage, data: data)
    }

    private func queryData() throws -> Data {
        // SPM command-line tests, Xcode-hosted tests and app bundles have different resource
        // containers. Only look beside their known bundles, never in user/project files.
        let bundles = [Bundle.main] + Bundle.allBundles.filter { $0.bundleURL.pathExtension == "xctest" }
        for container in bundles.flatMap({ [$0.resourceURL, $0.bundleURL, $0.bundleURL.deletingLastPathComponent()] }).compactMap({ $0 }) {
            let url = container.appendingPathComponent(bundleName + ".bundle", isDirectory: true)
            if let bundle = Bundle(url: url),
               let resource = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries") {
                return try Data(contentsOf: resource)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
