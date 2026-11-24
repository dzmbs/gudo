import DesignSystem
import SwiftUI

/// How full the agent's context is, as a small ring in the composer's row. Tapping it says how
/// much, in words.
struct ChatContextMeter: View {
    let usage: ChatContextUsage
    @State private var showsDetails = false

    private var ring: ChromeStyle {
        usage.fraction >= 0.9 ? DS.Palette.error : usage.fraction >= 0.75 ? DS.Palette.attention : DS.Palette.textSecondary
    }

    var body: some View {
        Button { showsDetails.toggle() } label: {
            ZStack {
                Circle().stroke(DS.Palette.hairline, lineWidth: 2.5)
                Circle().trim(from: 0, to: usage.fraction)
                    .stroke(ring, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: DS.Space.l, height: DS.Space.l)
            .frame(width: DS.Size.touchTarget, height: DS.Size.touchTarget)
            .contentShape(.rect)
            .animation(DS.Motion.standard, value: usage.fraction)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context")
        .accessibilityValue("\(usage.percent) percent used, \(usage.amount) tokens")
        .accessibilityIdentifier("chat-context-meter")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details.chromePopover().presentationCompactAdaptation(.popover) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Context \(usage.percent)% full").font(DS.Font.rowTitleEmphasis)
            Text(verbatim: usage.amount + " tokens").font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.textSecondary)
            if let output = usage.lastOutput {
                Text(verbatim: "Last turn wrote " + ChatContextUsage.compact(output) + " tokens")
                    .font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.textSecondary)
            }
            Text("As of the last finished turn.").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
        .foregroundStyle(DS.Palette.text)
        .padding(DS.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-context-details")
    }
}
