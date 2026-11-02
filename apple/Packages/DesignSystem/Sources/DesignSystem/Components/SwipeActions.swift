import SwiftUI

/// One action behind a row: its word, symbol and system tint (red ends something, orange stops or
/// puts away, blue goes somewhere; never grey, which reads as disabled).
public struct SwipeAction: Identifiable, Hashable, Sendable {
    public var id: String
    /// The one short word under the symbol.
    public var title: String
    /// What VoiceOver says (the menu title).
    public var label: String
    public var systemImage: String
    public var tint: Color

    public init(id: String, title: String, label: String? = nil, systemImage: String, tint: Color) {
        self.id = id
        self.title = title
        self.label = label ?? title
        self.systemImage = systemImage
        self.tint = tint
    }
}

/// The actions a swipe reveals beside a hand-drawn row, drawn as the system's own `List` swipe
/// actions are since iOS 26: a tinted circle per action with its symbol in white, the word under
/// it when the row is tall enough, the circles growing in with the reveal. Armed (a full swipe),
/// the outermost stretches into a capsule across the whole reveal. `actions` run from the row's
/// edge outwards.
public struct SwipeActionTray: View {
    let actions: [SwipeAction]
    let edge: HorizontalEdge
    let revealed: CGFloat
    let rowHeight: CGFloat
    let armed: Bool
    let perform: (SwipeAction) -> Void

    public init(
        _ actions: [SwipeAction], edge: HorizontalEdge, revealed: CGFloat, rowHeight: CGFloat, armed: Bool,
        perform: @escaping (SwipeAction) -> Void
    ) {
        self.actions = actions
        self.edge = edge
        self.revealed = revealed
        self.rowHeight = rowHeight
        self.armed = armed
        self.perform = perform
    }

    /// Tall rows show the word under the circle, as `List` does.
    static func showsTitle(rowHeight: CGFloat) -> Bool { rowHeight >= 68 }

    /// The circle: as tall as the row allows, never under a comfortable touch or over the
    /// system's 48.
    public static func diameter(rowHeight: CGFloat) -> CGFloat {
        let room = showsTitle(rowHeight: rowHeight) ? rowHeight - 26 : rowHeight - 4
        return min(48, max(28, room))
    }

    public static func width(for count: Int, rowHeight: CGFloat) -> CGFloat {
        CGFloat(count) * (diameter(rowHeight: rowHeight) + DS.Space.s) + DS.Space.s
    }

    public var body: some View {
        let diameter = Self.diameter(rowHeight: rowHeight)
        let fullWidth = Self.width(for: actions.count, rowHeight: rowHeight)
        let progress = min(1, revealed / max(1, fullWidth))
        let shown = armed ? Array(actions.suffix(1)) : actions
        // Laid out left to right: on the trailing edge the outermost is rightmost.
        let ordered = edge == .trailing ? shown : shown.reversed()
        HStack(spacing: DS.Space.s) {
            ForEach(ordered) { action in
                Button {
                    perform(action)
                } label: {
                    VStack(spacing: DS.Space.xs) {
                        Capsule()
                            .fill(action.tint)
                            .frame(width: armed ? max(diameter, revealed - DS.Space.s * 2) : diameter, height: diameter)
                            .overlay {
                                Image(systemName: action.systemImage)
                                    .font(.system(size: diameter * 0.4, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        if Self.showsTitle(rowHeight: rowHeight) {
                            Text(action.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(DS.Palette.text)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .scaleEffect(armed ? 1 : 0.6 + 0.4 * progress)
                    .opacity(armed ? 1 : min(1, progress * 1.6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.label)
                .accessibilityIdentifier(action.id)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(width: max(0, revealed), alignment: edge == .trailing ? .trailing : .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .animation(DS.Motion.swipe, value: armed)
    }
}
