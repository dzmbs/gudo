#if os(iOS)
import ChatSyntax
import DesignSystem
import Foundation
import SwiftUI

/// Parsing stays on RowBuilder. This small, bounded cache only projects immutable ranges into
/// theme colours, so a theme/contrast change never reparses code or changes row geometry.
@MainActor enum ChatCodeStyler {
    private struct Key: Hashable {
        let text: String
        let tokens: [CodeToken]
        let theme: TerminalTheme
        let increasedContrast: Bool
    }
    private static let cache = BoundedLRU<Key, AttributedString>(capacity: 64, byteLimit: 512 * 1_024, unitLimit: 64)
    private(set) static var projectionCount = 0
    static var cacheBytes: Int { cache.cost.bytes }

    static func text(_ code: ChatCodeSnippet, theme: TerminalTheme, increasedContrast: Bool) -> AttributedString {
        let key = Key(text: code.preview, tokens: code.highlights, theme: theme, increasedContrast: increasedContrast)
        if let cached = cache.value(for: key) { return cached }
        var text = AttributedString(code.preview)
        text.foregroundColor = theme.foreground
        var slots: [Int: Color] = [:]
        for token in code.highlights {
            guard let sourceRange = Range(token.range, in: code.preview),
                  let lower = AttributedString.Index(sourceRange.lowerBound, within: text),
                  let upper = AttributedString.Index(sourceRange.upperBound, within: text) else { continue }
            let slot = token.role.ansiSlot
            let color = slots[slot] ?? theme.syntaxANSI(slot, increasedContrast: increasedContrast).color
            slots[slot] = color
            text[lower..<upper].foregroundColor = color
        }
        projectionCount += 1
        cache.insert(text, for: key, cost: LRUCost(bytes: code.preview.utf8.count * 8 + code.highlights.count * 256 + 1_024, units: 1))
        return text
    }
}
#endif
