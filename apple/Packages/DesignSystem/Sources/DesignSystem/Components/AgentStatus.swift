import SwiftUI

/// agent vocabulary): the one state vocabulary every screen uses.
nonisolated public enum AgentState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle, working, blocked, done, error
    /// Contact with the host is lost; the last known state is stale.
    case unknown

    /// Sort order for "needs you first" lists.
    public var urgency: Int {
        switch self {
        case .blocked: 0
        case .error: 1
        case .working: 2
        case .done: 3
        case .unknown: 4
        case .idle: 5
        }
    }

    public var needsYou: Bool { self == .blocked || self == .error }

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Needs You"
        case .done: "Done"
        case .error: "Failed"
        case .unknown: "No Contact"
        }
    }

    /// The state's colour, from the theme (`ChromePalette`): resolved where it is drawn.
    public var color: ChromeStyle {
        switch self {
        case .idle, .unknown: DS.Palette.textSecondary
        case .working: DS.Palette.working
        case .blocked: DS.Palette.blocked
        case .done: DS.Palette.done
        case .error: DS.Palette.error
        }
    }

    /// SF Symbol for the static states (working draws a spinner instead).
    var symbol: String {
        switch self {
        case .idle: "circle"
        case .working: "circle.dotted"
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .unknown: "circle.dashed"
        }
    }
}

/// well as color: spinner, exclamation, check, cross, ring, dashed ring.
public struct StatusIndicator: View {
    let state: AgentState
    var size: CGFloat

    public init(_ state: AgentState, size: CGFloat = DS.Size.statusGlyph) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Group {
            if state == .working {
                Spinner(color: state.color, lineWidth: max(1.5, size / 7))
                    .padding(size * 0.08)
            } else {
                Image(systemName: state.symbol)
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(state.color)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.indicator, value: state)
        .accessibilityElement()
        .accessibilityLabel(state.title)
    }
}

/// A 3/4 arc that turns once per second; a still arc under Reduce Motion so it still says
public struct Spinner: View {
    var color: AnyShapeStyle
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: some ShapeStyle = HierarchicalShapeStyle.secondary, lineWidth: CGFloat = 1.5) {
        self.color = AnyShapeStyle(color)
        self.lineWidth = lineWidth
    }

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
    }
}

public struct StatusPill: View {
    let state: AgentState
    let detail: String?

    public init(_ state: AgentState, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: 4) {
            StatusIndicator(state, size: 10)
            Text(state.title)
            if let detail {
                Text(detail).foregroundStyle(state.color.opacity(0.75))
            }
        }
        .font(DS.Font.badge.monospacedDigit())
        .foregroundStyle(state.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(state.color.opacity(0.10), in: .rect(cornerRadius: DS.Radius.chip))
        .accessibilityElement(children: .combine)
    }
}

/// A count badge (unread / needs-you). Red only when something needs the user.
public struct CountBadge: View {
    let count: Int
    let urgent: Bool

    public init(_ count: Int, urgent: Bool = true) {
        self.count = count
        self.urgent = urgent
    }

    public var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                // The window's base colour on the amber: dark text on a dark theme's light amber,
                // light on a light theme's deep one.
                .foregroundStyle(urgent ? AnyShapeStyle(DS.Palette.base) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(urgent ? AnyShapeStyle(DS.Palette.blocked) : AnyShapeStyle(DS.Palette.selectedFill), in: .capsule)
                .contentTransition(.numericText())
                .animation(DS.Motion.indicator, value: count)
                .accessibilityLabel("\(count)")
        }
    }
}
