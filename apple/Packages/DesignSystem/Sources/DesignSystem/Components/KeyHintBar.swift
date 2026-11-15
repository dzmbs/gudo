import SwiftUI
#if canImport(GameController)
import GameController
#endif

/// One key hint: its key caps and what they do ("↑ ↓ Move", "↩ Open", "esc Close").
nonisolated public struct KeyHint: Identifiable, Hashable, Sendable {
    public var keys: [String]
    public var label: String

    public var id: String { keys.joined() + label }

    public init(_ keys: [String], _ label: String) {
        self.keys = keys
        self.label = label
    }

    public static let move = KeyHint(["↑", "↓"], "Move")
    public static let close = KeyHint(["esc"], "Close")
    public static let nextField = KeyHint(["⇥"], "Next Field")

    /// ↩ and what it does on the highlighted row ("Open", "Run", "Switch").
    public static func choose(_ label: String) -> KeyHint { KeyHint(["↩"], label) }

    /// What a key cap says to VoiceOver.
    static func spoken(_ key: String) -> String {
        switch key {
        case "↑": "Up Arrow"
        case "↓": "Down Arrow"
        case "↩": "Return"
        case "esc": "Escape"
        case "⇥": "Tab"
        case "⌘": "Command"
        case "⇧": "Shift"
        case "⌃": "Control"
        case "⌥": "Option"
        default: key
        }
    }
}

/// The foot of a list popover (the palette, the switchers): key caps for moving, choosing and
/// closing, then the context's own actions, closing always last at the trailing edge. Shown only
/// where a keyboard is: always on the Mac, with a hardware keyboard on iPad and iPhone.
public struct KeyHintBar: View {
    let hints: [KeyHint]
    let trailing: [KeyHint]

    /// `hints` from the leading edge; `trailing` (by default esc Close) at the trailing edge.
    public init(_ hints: [KeyHint], trailing: [KeyHint] = [.close]) {
        self.hints = hints
        self.trailing = trailing
    }

    public var body: some View {
        if Self.hasKeyboard {
            VStack(spacing: 0) {
                Hairline()
                HStack(spacing: DS.Space.m) {
                    ForEach(hints) { KeyHintLabel(hint: $0) }
                    Spacer(minLength: DS.Space.s)
                    ForEach(trailing) { KeyHintLabel(hint: $0) }
                }
                .padding(.horizontal, DS.Space.m)
                .frame(height: Self.height)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("key-hints")
        }
    }

    /// One dense row: a key cap and a caption with room above and below.
    static let height: CGFloat = 30

    @MainActor static var hasKeyboard: Bool {
        #if os(macOS)
        true
        #elseif canImport(GameController)
        GCKeyboard.coalesced != nil
        #else
        false
        #endif
    }
}

private struct KeyHintLabel: View {
    let hint: KeyHint

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xxs) {
                ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
            }
            Text(hint.label)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hint.keys.map(KeyHint.spoken).joined(separator: " ")): \(hint.label)")
    }
}
