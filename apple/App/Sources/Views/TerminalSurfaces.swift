import DesignSystem
import SwiftUI

/// Grouped lists and forms on the terminal's background family instead of the system's black or
/// grey: the chrome follows the terminal (Ghostty `window-theme`), sheets and screens included.
struct TerminalGroupedBackground: ViewModifier {
    @Environment(\.terminalTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground.ignoresSafeArea())
    }
}

/// A grouped row's background on the terminal family (pair with `terminalGrouped()`).
struct RaisedRowBackground: View {
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        theme.raisedBackground
    }
}

extension View {
    /// A grouped list or form on the terminal's background (`groupedBackground`).
    func terminalGrouped() -> some View { modifier(TerminalGroupedBackground()) }

    /// Rows on `raisedBackground`; apply to each section of a `terminalGrouped()` list or form.
    func raisedRows() -> some View { listRowBackground(RaisedRowBackground()) }
}
