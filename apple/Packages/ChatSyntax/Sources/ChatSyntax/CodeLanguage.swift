import Foundation

public enum CodeLanguage: String, CaseIterable, Sendable {
    case rust, swift, javascript, typescript, tsx, python, go, bash, json, yaml, toml, markdown, c, cpp, html, css, diff

    public init?(fence: String?) {
        guard let fence, fence.utf8.count <= 128,
              let name = fence.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return nil }
        switch name {
        case "rs": self = .rust
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts": self = .typescript
        case "py", "python3": self = .python
        case "golang": self = .go
        case "sh", "shell", "zsh": self = .bash
        case "jsonc": self = .json
        case "yml": self = .yaml
        case "md", "mdown": self = .markdown
        case "h": self = .c
        case "c++", "cxx", "cc", "hpp": self = .cpp
        case "htm", "xml": self = .html
        case "patch": self = .diff
        default:
            guard let language = Self(rawValue: name) else { return nil }
            self = language
        }
    }
}

public struct CodeToken: Hashable, Sendable {
    public enum Role: Int, Hashable, Sendable {
        case keyword, type, function, string, constant, comment, property, added, removed, heading

        public var ansiSlot: Int {
            switch self {
            case .keyword, .heading: 5
            case .type: 3
            case .function: 4
            case .string, .added: 2
            case .constant, .property: 6
            case .comment: 8
            case .removed: 1
            }
        }

        init?(capture: [String]) {
            guard let first = capture.first else { return nil }
            switch first {
            case "keyword", "conditional", "repeat", "exception", "include", "preproc", "operator": self = .keyword
            case "type", "constructor", "namespace", "module": self = .type
            case "function", "method": self = .function
            case "string", "character", "escape": self = .string
            case "number", "float", "boolean", "constant": self = .constant
            case "comment": self = .comment
            case "property", "attribute", "tag": self = .property
            default:
                if capture.contains(where: { ["addition", "added", "plus", "inserted"].contains($0) }) { self = .added }
                else if capture.contains(where: { ["deletion", "removed", "minus", "deleted"].contains($0) }) { self = .removed }
                else if capture.contains(where: { ["title", "heading"].contains($0) }) { self = .heading }
                else if capture.contains("raw") || capture.contains("literal") { self = .string }
                else { return nil }
            }
        }
    }

    public let range: NSRange
    public let role: Role
}
