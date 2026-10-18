import SwiftUI

/// Shortcut glyphs shown right-aligned in palette rows and menus (Ghostty `ShortcutSymbolsView`):
/// adjacent symbols, no separators, secondary.
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
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityLabel(symbols.joined())
    }
}

/// A single key cap (Ghostty SurfaceView.swift `KeyCap`): 12 pt rounded medium, radius 4,
/// control background, 0.5 pt primary 15 % stroke and a half-point drop shadow.
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
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}
