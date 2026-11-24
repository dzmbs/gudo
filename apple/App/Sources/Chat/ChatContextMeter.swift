import DesignSystem
import SwiftUI

/// How full the agent's context is, as a small percentage in the composer's row, so it reads as
/// a number and never as progress. Tapping it says how much, in words.
struct ChatContextMeter: View {
    let usage: ChatContextUsage
    @State private var showsDetails = false

    static let attentionFraction = 0.75
    static let errorFraction = 0.9

    private var tint: ChromeStyle {
        usage.fraction >= Self.errorFraction ? DS.Palette.error
            : usage.fraction >= Self.attentionFraction ? DS.Palette.attention : DS.Palette.textTertiary
    }

    var body: some View {
        Button { showsDetails.toggle() } label: {
            Text(verbatim: "\(usage.percent)%")
                .font(DS.Font.caption).monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(usage.percent)))
                .padding(.horizontal, DS.Space.xs)
                .frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                .contentShape(.rect)
                .animation(DS.Motion.standard, value: usage.percent)
        }
        .buttonStyle(.plain)
        .help("Context \(usage.percent)% full, \(usage.amount) tokens")
        .accessibilityLabel("Context")
        .accessibilityValue("\(usage.percent) percent used, \(usage.amount) tokens")
        .accessibilityIdentifier("chat-context-meter")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details.chromePopover().presentationCompactAdaptation(.popover) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Context \(usage.percent)% full").font(ChatFont.proseEmphasis)
            Text(verbatim: usage.amount + " tokens").font(ChatFont.subtitle).foregroundStyle(DS.Palette.textSecondary)
            if let output = usage.lastOutput {
                Text(verbatim: "Last turn wrote " + ChatContextUsage.compact(output) + " tokens")
                    .font(ChatFont.subtitle).foregroundStyle(DS.Palette.textSecondary)
            }
            if usage.source == .lastTurn {
                Text("As of the last finished turn.").font(ChatFont.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .foregroundStyle(DS.Palette.text)
        .padding(DS.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-context-details")
    }
}
