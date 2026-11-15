import Foundation
import Testing

/// Reads the app's and the packages' sources and fails on chrome styled outside the design
/// system: raw or system colours, literal opacities on colours, literal corner radii and corners
/// that are not continuous. A line may opt out with `// style-exempt: <reason>` on it or on the
/// line above; whole files only through `exemptFiles`, each with its reason.
struct StyleLintTests {
    struct Rule: Sendable {
        let name: String
        let pattern: String
        /// Where the rule does not apply: the token files that define the values.
        let allowedIn: [String]
    }

    static let tokenFiles = [
        "DesignSystem/Sources/DesignSystem/Tokens/", "DesignSystem/Sources/DesignSystem/Theme/",
        "DesignSystem/Sources/DesignSystem/Terminal/TerminalTheme.swift",
    ]

    static let rules = [
        Rule(
            name: "raw colour",
            pattern: #"Color\((\.sRGB,\s*)?red:|Color\(hex:|UIColor\(red:|NSColor\((srgb|calibrated|device)?[Rr]ed:|(?<![\w.])(Color|UIColor|NSColor)?\.(white|black)\b(?!\w)"#,
            allowedIn: tokenFiles),
        Rule(
            name: "system colour",
            pattern: #"(?<![\w.])(Color|UIColor|NSColor)?\.(red|green|blue|orange|yellow|purple|pink|gray|mint|teal|cyan|indigo|brown|systemRed|systemGreen|systemBlue|systemOrange|systemYellow|systemGray)\b(?!\w|:)|Color\.accentColor|\(\.accentColor\)"#,
            allowedIn: tokenFiles),
        Rule(name: "literal opacity on a colour", pattern: #"[A-Za-z_\]]\.opacity\([^()]*\d*\.\d+[^()]*\)"#, allowedIn: tokenFiles),
        Rule(name: "half-point line (use hairlineBorder or Hairline: one physical pixel)", pattern: #"lineWidth:\s*0?\.5\b"#, allowedIn: []),
        Rule(name: "literal corner radius", pattern: #"cornerRadius:\s*-?\d|\.rounded\(\s*\d|cornerRadius\s*=\s*\d"#, allowedIn: ["DesignSystem/Sources/DesignSystem/Tokens/Tokens.swift"]),
    ]

    /// Files that draw content rather than chrome.
    static let exemptFiles: [String: String] = [
        "TerminalKit/": "the terminal renderer draws the grid in the theme's own colours",
        "GudoCore/": "generated FFI bindings",
    ]

    static let roundedShape = #"RoundedRectangle\(|\.rect\(cornerRadius|UnevenRoundedRectangle\("#
    static let fontWeight = #"weight:\s*\.black"#

    static var appleDirectory: URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { directory.deleteLastPathComponent() }
        return directory
    }

    static func sourceFiles() -> [(path: String, lines: [String])] {
        let apple = appleDirectory
        var roots = [apple.appendingPathComponent("App/Sources")]
        let packages = apple.appendingPathComponent("Packages")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: packages.path) {
            roots += names.sorted().map { packages.appendingPathComponent($0).appendingPathComponent("Sources") }
        }
        var files: [(String, [String])] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.path.replacingOccurrences(of: apple.path + "/", with: "")
                guard !exemptFiles.keys.contains(where: { path.contains($0) }),
                      let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files.append((path, contents.components(separatedBy: "\n")))
            }
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// The code on a line, without its trailing comment.
    static func code(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return "" }
        guard let range = line.range(of: " //") else { return line }
        return String(line[..<range.lowerBound])
    }

    static func isExempt(_ lines: [String], _ index: Int) -> Bool {
        lines[index].contains("style-exempt:") || (index > 0 && lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("// style-exempt:"))
    }

    static func violations() throws -> [String] {
        let compiled = try rules.map { ($0, try NSRegularExpression(pattern: $0.pattern)) }
        let shape = try NSRegularExpression(pattern: roundedShape)
        let weight = try NSRegularExpression(pattern: fontWeight)
        var found: [String] = []
        for (path, lines) in sourceFiles() {
            for (index, line) in lines.enumerated() {
                let code = weight.stringByReplacingMatches(in: code(line), range: NSRange(code(line).startIndex..., in: code(line)), withTemplate: "")
                guard !code.isEmpty, !isExempt(lines, index) else { continue }
                for (rule, regex) in compiled where !rule.allowedIn.contains(where: { path.contains($0) }) {
                    if regex.matches(code) { found.append("\(path):\(index + 1): \(rule.name): \(line.trimmingCharacters(in: .whitespaces))") }
                }
                for match in shape.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                    guard let start = Range(match.range, in: code)?.lowerBound else { continue }
                    let statement = ([String(code[start...])] + lines.dropFirst(index + 1).prefix(4)).joined(separator: "\n")
                    if !closingStatement(statement).contains(".continuous") {
                        found.append("\(path):\(index + 1): corner not continuous: \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        return found
    }

    /// The text up to the parenthesis that closes the first one opened.
    static func closingStatement(_ text: String) -> Substring {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return text[...index] }
            default: break
            }
        }
        return Substring(text)
    }

    @Test func chromeStylesComeFromTheDesignSystem() throws {
        let violations = try Self.violations()
        #expect(violations.isEmpty, "\(violations.count) violations:\n\(violations.joined(separator: "\n"))")
    }

    @Test func theLintCatchesWhatItIsFor() throws {
        let compiled = try Self.rules.map { try NSRegularExpression(pattern: $0.pattern) }
        let samples = [
            ".fill(Color.white.opacity(0.16))", "Color(red: 1, green: 0, blue: 0)", ".tint(.red)",
            ".fill(DS.Palette.accent.opacity(0.25))", "RoundedRectangle(cornerRadius: 6, style: .continuous)",
        ]
        for sample in samples {
            #expect(compiled.contains { $0.matches(sample) }, "\(sample)")
        }
        let clean = [".opacity(isShown ? 1 : 0)", "DS.Palette.text", ".font(.system(size: 8))", "RoundedRectangle.rounded(DS.Radius.control)"]
        for sample in clean {
            #expect(!compiled.contains { $0.matches(sample) }, "\(sample)")
        }
        #expect(!Self.closingStatement("RoundedRectangle(cornerRadius: DS.Radius.chip)").contains(".continuous"))
    }
}

private extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
