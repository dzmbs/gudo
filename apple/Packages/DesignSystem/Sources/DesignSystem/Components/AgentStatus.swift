import SwiftUI

/// What a program in a pane reports about itself (OSC 7501 states): the one state vocabulary
/// every screen uses.
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

    /// The most urgent of several states (a tab's panes, a project's tabs): blocked, then failed,
    /// working, done, no contact, idle.
    public static func mostUrgent(_ states: some Sequence<AgentState>) -> AgentState? {
        states.min { $0.urgency < $1.urgency }
    }

    /// How a program tile carries the state: quiet states as a dot on its corner, the ones that
    /// need you as a `StatePill` beside the title. Nothing for a host out of contact.
    public enum StatusMark: Sendable { case dot, pill }

    public var statusMark: StatusMark? {
        switch self {
        case .idle, .working, .done: .dot
        case .blocked, .error: .pill
        case .unknown: nil
        }
    }

    /// The pill's words.
    public var pillTitle: String {
        switch self {
        case .blocked: "Needs you"
        case .error: "Failed"
        default: title
        }
    }

    /// A tab whose agent turns blocked while it is out of sight gets one attention beat; a tab
    /// in view, or a failure, does not.
    public static func callsForAttention(from previous: AgentState?, to state: AgentState?, isVisible: Bool) -> Bool {
        state == .blocked && previous != .blocked && !isVisible
    }

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

    public var color: ChromeStyle {
        switch self {
        case .idle, .unknown: DS.Palette.textSecondary
        case .working: DS.Palette.working
        case .blocked: DS.Palette.blocked
        case .done: DS.Palette.done
        case .error: DS.Palette.error
        }
    }

    /// SF Symbol for the static states (working draws a spinner instead); menus show it too.
    public var symbol: String {
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

/// The small status glyph. Shape carries the meaning as well as colour.
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
        .animation(DS.Motion.micro, value: state)
        .accessibilityElement()
        .accessibilityLabel(state.title)
    }
}

/// A 3/4 arc that turns once per second; a still arc under Reduce Motion so it still says
/// "working". The turn is a Core Animation on the arc's layer: a sidebar of working agents costs
/// the main thread nothing per frame, and it stops off screen.
public struct Spinner: View {
    private let color: @Sendable (EnvironmentValues) -> Color.Resolved
    var lineWidth: CGFloat
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: ChromeStyle = DS.Palette.textSecondary, lineWidth: CGFloat = 1.5) {
        self.color = { color.resolve(in: $0) }
        self.lineWidth = lineWidth
    }

    public init(color: Color, lineWidth: CGFloat = 1.5) {
        self.color = { color.resolve(in: $0) }
        self.lineWidth = lineWidth
    }

    public var body: some View {
        SpinnerLayer(color: color(environment).cgColor, lineWidth: lineWidth, turning: !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// A status chip: glyph, state name and optional detail ("Working · 4m").
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
                Text(detail).fontWeight(.regular)
            }
        }
        .font(DS.Font.badge.monospacedDigit())
        .foregroundStyle(state.color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(DS.Palette.container(state.color), in: .rounded(DS.Radius.chip))
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
                .foregroundStyle(urgent ? DS.Palette.on(DS.Palette.blocked) : DS.Palette.textSecondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(urgent ? AnyShapeStyle(DS.Palette.blocked) : AnyShapeStyle(DS.Palette.selectedFill), in: .capsule)
                .contentTransition(.numericText())
                .animation(DS.Motion.micro, value: count)
                .accessibilityLabel("\(count)")
        }
    }
}
