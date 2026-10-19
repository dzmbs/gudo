import ActivityKit
import NotifyKit
import SwiftUI
import WidgetKit

/// The agent-run Live Activity: Lock Screen banner and Dynamic Island. Terminal-dark like the
/// app (the activity sits next to the terminal in the user's mind), hue only for state:
/// working amber, needs-you red, done green (the terminal palette, DESIGN.md).
@main
struct AgentActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentRunActivity()
    }
}

private enum Look {
    static let background = Color(red: 0x28 / 255, green: 0x2C / 255, blue: 0x34 / 255)
    static let foreground = Color(red: 0xC5 / 255, green: 0xC8 / 255, blue: 0xC6 / 255)
    static let working = Color(red: 0xF0 / 255, green: 0xC6 / 255, blue: 0x74 / 255)
    static let blocked = Color(red: 0xE8 / 255, green: 0x68 / 255, blue: 0x6C / 255)
    static let done = Color(red: 0xB5 / 255, green: 0xBD / 255, blue: 0x68 / 255)
    static let failed = Color(red: 0xCC / 255, green: 0x66 / 255, blue: 0x66 / 255)

    static func color(_ phase: AgentRunState.Phase) -> Color {
        switch phase {
        case .working: working
        case .blocked: blocked
        case .done: done
        case .failed: failed
        }
    }
}

struct AgentRunActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentRunAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Look.background)
                .activitySystemActionForegroundColor(Look.foreground)
                .widgetURL(context.attributes.openURL(scheme: Bundle.main.object(forInfoDictionaryKey: "BrandURLScheme") as? String ?? "unnamed"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.agent, systemImage: "sparkle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Look.foreground)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseBadge(phase: state.phase)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.headline)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(2)
                            .foregroundStyle(Look.foreground)
                        Text(context.attributes.hostName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: state.phase.systemImage)
                    .foregroundStyle(Look.color(state.phase))
            } compactTrailing: {
                if state.phase == .working {
                    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                        .foregroundStyle(Look.working)
                } else {
                    Text(state.phase.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Look.color(state.phase))
                }
            } minimal: {
                Image(systemName: state.phase.systemImage)
                    .foregroundStyle(Look.color(state.phase))
            }
            .keylineTint(Look.color(state.phase))
        }
    }
}

private struct PhaseBadge: View {
    let phase: AgentRunState.Phase

    var body: some View {
        Label(phase.title, systemImage: phase.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Look.color(phase))
    }
}

private struct LockScreenView: View {
    let attributes: AgentRunAttributes
    let state: AgentRunState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                Text(attributes.agent).fontWeight(.semibold)
                Text("· \(attributes.hostName)").foregroundStyle(.secondary)
                Spacer()
                PhaseBadge(phase: state.phase)
            }
            .font(.caption)
            Text(state.headline)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
            HStack {
                Text(attributes.task)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == .working {
                    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .foregroundStyle(Look.working)
                }
            }
            .font(.caption2)
        }
        .foregroundStyle(Look.foreground)
        .padding(14)
    }
}
