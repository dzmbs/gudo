import SwiftUI

/// Shortcut glyphs for palette rows and menus: adjacent symbols, no separators.
public struct ShortcutLabel: View {
    let symbols: [String]

    public init(_ symbols: [String]) {
        self.symbols = symbols
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).frame(minWidth: 13)
            }
        }
        // The row's own font; `.secondary` is relative to the row's colour (the selection's
        // text on the palette's selected row).
        .foregroundStyle(DS.Palette.textSecondary)
        .monospacedDigit()
        .accessibilityLabel(symbols.joined())
    }
}

public struct KeyCap: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(DS.Font.keyCap)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .fill(DS.Palette.raised)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }
}
