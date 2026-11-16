#if os(iOS)
import DesignSystem
import SwiftUI

/// Inline code reads as a literal: SF Mono, a step under the prose around it, on the raised fill.
nonisolated enum ChatInlineCode {
    static func styled(_ text: AttributedString, background: Color) -> AttributedString {
        let code = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        guard !code.isEmpty else { return text }
        var styled = text
        for range in code {
            styled[range].font = DS.Font.literal
            styled[range].backgroundColor = background
        }
        return styled
    }
}
#endif
