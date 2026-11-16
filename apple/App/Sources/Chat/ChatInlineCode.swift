#if os(iOS)
import DesignSystem
import SwiftUI

/// Inline code reads as a literal: SF Mono, a step under the prose around it, on the raised fill.
/// Code stays on one line where it fits: a short span never breaks, a long one only at its spaces.
nonisolated enum ChatInlineCode {
    private static let wordJoiner: Character = "\u{2060}"
    private static let noBreakSpace: Character = "\u{00A0}"
    /// Fits a line of the narrowest phone column at the largest standard text size.
    private static let unbrokenLength = 24

    static func styled(_ text: AttributedString, background: Color) -> AttributedString {
        guard text.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { return text }
        var styled = AttributedString()
        for run in text.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else {
                styled.append(text[run.range])
                continue
            }
            let characters = text[run.range].characters
            let keepsWhole = characters.count <= unbrokenLength
            var code = AttributedString(joiningWords(of: characters, keepsWhole: keepsWhole), attributes: run.attributes)
            code.font = DS.Font.literal
            code.backgroundColor = background
            styled.append(code)
        }
        return styled
    }

    /// Hyphens, slashes and the like are line-break opportunities in prose; inside a word of
    /// code a break there splits one token across two lines.
    private static func joiningWords(of characters: some Sequence<Character>, keepsWhole: Bool) -> String {
        var joined = ""
        var previous: Character?
        for character in characters {
            if let previous, !previous.isWhitespace, !character.isWhitespace { joined.append(wordJoiner) }
            joined.append(keepsWhole && character == " " ? noBreakSpace : character)
            previous = character
        }
        return joined
    }
}
#endif
