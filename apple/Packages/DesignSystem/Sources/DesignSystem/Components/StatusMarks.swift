import SwiftUI

/// A state that needs you, as a compact pill: "Needs you", "Failed". The words carry it without
/// colour; nothing for the quiet states, which are a dot on the program's tile.
public struct StatePill: View {
    let state: AgentState

    public init(_ state: AgentState) {
        self.state = state
    }

    public var body: some View {
        if state.statusMark == .pill {
            Text(state.pillTitle)
                .font(DS.Font.badge)
                .foregroundStyle(state.color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, DS.Space.badgeH)
                .padding(.vertical, DS.Space.badgeV)
                .background(DS.Palette.container(state.color), in: .rounded(DS.Radius.chip))
                .accessibilityElement()
                .accessibilityLabel(state.title)
        }
    }
}

/// A quiet state as a dot: idle a ring, working and done filled in their colours. With
/// Differentiate Without Colour done carries a check, so each reads by its shape alone.
public struct StateDot: View {
    let state: AgentState
    let diameter: CGFloat
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor

    public init(_ state: AgentState, diameter: CGFloat = DS.Size.statusDot) {
        self.state = state
        self.diameter = diameter
    }

    public var body: some View {
        Group {
            switch state {
            case .idle:
                Circle().strokeBorder(DS.Palette.textSecondary, lineWidth: Self.ringWidth(diameter))
            case .done where differentiatesWithoutColor:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .foregroundStyle(DS.Palette.done)
            default:
                Circle().fill(state.color)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(state.title)
    }

    /// An idle ring stays a ring at every size: a little under a quarter of the dot, a point at least.
    static func ringWidth(_ diameter: CGFloat) -> CGFloat { max(1, (diameter / 4.5).rounded()) }
}

public extension View {
    /// A quiet state as a dot cut into the bottom trailing corner of a square mark `tileSize`
    /// wide: a gap around it so it reads on any row, selected or not. Pill states and nil draw
    /// nothing here.
    func stateDot(_ state: AgentState?, tileSize: CGFloat) -> some View {
        modifier(StateDotCorner(state: state?.statusMark == .dot ? state : nil, tileSize: tileSize))
    }

    /// One attention beat when the agent here turns blocked while its tab is out of sight;
    /// nothing under Reduce Motion, and never focus.
    func attentionWhenBlocked(_ state: AgentState?, isVisible: Bool) -> some View {
        modifier(BlockedAttention(state: state, isVisible: isVisible))
    }
}

private struct StateDotCorner: ViewModifier {
    let state: AgentState?
    let tileSize: CGFloat
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor

    func body(content: Content) -> some View {
        let dot = tileSize * (differentiatesWithoutColor ? 0.5 : 0.42)
        let gap = tileSize * 0.1
        let centre = CGPoint(x: tileSize - dot / 2 + tileSize * 0.12, y: tileSize - dot / 2 + tileSize * 0.12)
        content
            .mask {
                Rectangle()
                    .overlay {
                        if state != nil {
                            Circle()
                                .frame(width: dot + gap * 2, height: dot + gap * 2)
                                .position(centre)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .topLeading) {
                if let state {
                    StateDot(state, diameter: dot)
                        .position(centre)
                        .motionTransition(.pill())
                }
            }
            .animation(DS.Motion.micro, value: state)
    }
}

private struct BlockedAttention: ViewModifier {
    let state: AgentState?
    let isVisible: Bool
    @State private var beats = 0

    func body(content: Content) -> some View {
        content
            .attentionCue(trigger: beats)
            .onChange(of: state) { previous, current in
                if AgentState.callsForAttention(from: previous, to: current, isVisible: isVisible) { beats += 1 }
            }
    }
}
