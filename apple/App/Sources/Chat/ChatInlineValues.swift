import Foundation
import Markdown

/// Reuse the block parser's simplest inline nodes instead of invoking a second Markdown parser.
/// Unsupported/nested constructs retain Foundation's complete inline interpretation.
nonisolated enum ChatInlineValues {
    static func flat(_ markup: (any Markup)?, source: String) -> AttributedString? {
        guard let markup, markup is Paragraph, !source.isEmpty,
              source.first?.isWhitespace == false, source.last?.isWhitespace == false,
              // Swift Markdown smart punctuation differs from Foundation's literal inline mode.
              !source.contains("--"), !source.contains("..."),
              !source.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 || $0 == 34 || $0 == 39 }) else { return nil }
        var result = AttributedString()
        for child in markup.children {
            var attributes = AttributeContainer()
            let value: String
            if let text = child as? Markdown.Text { value = text.string }
            else if let code = child as? InlineCode {
                value = code.code
                attributes.inlinePresentationIntent = .code
            } else if let strong = child as? Strong, let text = onlyText(strong) {
                value = text
                attributes.inlinePresentationIntent = .stronglyEmphasized
            } else if let emphasis = child as? Emphasis, let text = onlyText(emphasis) {
                value = text
                attributes.inlinePresentationIntent = .emphasized
            } else if let link = child as? Markdown.Link, link.title == nil, isInlineLink(link, in: markup, source: source),
                      let text = onlyText(link), let destination = link.destination, let url = URL(string: destination) {
                value = text
                switch url.scheme?.lowercased() {
                case "https", "http", "mailto": attributes.link = url
                default: break
                }
            } else { return nil }
            // Foundation's bare URL/email autolinks are broader than Swift Markdown's AST.
            // Code spans are literal; other candidates keep Foundation's own interpretation.
            if !(child is InlineCode), hasAutolinkCandidate(value) { return nil }
            result.append(AttributedString(value, attributes: attributes))
        }
        return result
    }

    private static func hasAutolinkCandidate(_ value: String) -> Bool {
        // Any slash is a conservative candidate; avoiding substring searches keeps the common
        // prose-only path cheap without trying to reproduce Foundation's URL grammar.
        if value.utf8.contains(where: { $0 == 64 || $0 == 47 }) { return true }
        guard value.utf8.contains(46), value.utf8.contains(119) || value.utf8.contains(87) else { return false }
        return value.range(of: "www.", options: .caseInsensitive) != nil
    }

    private static func isInlineLink(_ link: Markdown.Link, in markup: any Markup, source: String) -> Bool {
        // Reference destinations depend on other source blocks and cannot use the source-only
        // inline cache. Keep their existing Foundation path, along with autolinks/unknown ranges.
        guard let root = markup.range, let range = link.range,
              range.lowerBound.line == root.lowerBound.line, range.upperBound.line == root.lowerBound.line else { return false }
        let lower = range.lowerBound.column - root.lowerBound.column
        let upper = range.upperBound.column - root.lowerBound.column
        let bytes = source.utf8
        guard lower >= 0, lower < upper, upper <= bytes.count else { return false }
        return bytes[bytes.index(bytes.startIndex, offsetBy: lower)] == 91
            && bytes[bytes.index(bytes.startIndex, offsetBy: upper - 1)] == 41
    }

    private static func onlyText(_ markup: any Markup) -> String? {
        guard markup.childCount == 1, let text = markup.child(at: 0) as? Markdown.Text else { return nil }
        return text.string
    }
}
