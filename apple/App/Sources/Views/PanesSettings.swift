import DesignSystem
import SwiftUI

/// Settings › Appearance › Panes: how panes sit together and how the active one stands out,
/// each choice a small live drawing of two panes in the user's own theme.
struct PanesSettingsSection: View {
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact
    @AppStorage(TerminalPreferences.Key.paneActiveBorder) private var activeBorder = TerminalPreferences.Default.paneActiveBorder
    @AppStorage(TerminalPreferences.Key.paneInactiveFade) private var inactiveFade = TerminalPreferences.Default.paneInactiveFade

    var body: some View {
        Section {
            PreviewChoices(selection: $paneStyle, choices: TerminalPreferences.PaneStyle.allCases, title: \.title) { style in
                PanePairPreview(style: style, fade: inactiveFade, activeBorder: activeBorder)
            }
            .accessibilityLabel("Pane Style")
            .accessibilityIdentifier("settings-pane-style")
            .settingAnchor("pane-style")
            PreviewChoices(selection: $inactiveFade, choices: TerminalPreferences.InactivePaneFade.allCases, title: \.title) { fade in
                PanePairPreview(style: paneStyle, fade: fade, activeBorder: activeBorder)
            }
            .accessibilityLabel("Inactive Panes")
            .accessibilityIdentifier("settings-pane-fade")
            .settingAnchor("pane-inactive-fade")
            Toggle(isOn: $activeBorder.animation(DS.Motion.micro)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ring Around the Active Pane")
                    Text("A thin line in the accent colour")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .accessibilityIdentifier("settings-pane-active-border")
            .settingAnchor("pane-active-border")
        } header: {
            Text("Panes")
        }
    }
}

/// A row of preview cards, one per choice, the chosen one ringed in the accent with a ✓ by its
/// name.
private struct PreviewChoices<Choice: Hashable & Identifiable, Preview: View>: View {
    @Binding var selection: Choice
    let choices: [Choice]
    let title: KeyPath<Choice, String>
    @ViewBuilder let preview: (Choice) -> Preview

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            ForEach(choices) { choice in
                let isSelected = choice == selection
                Button {
                    withAnimation(DS.Motion.micro) { selection = choice }
                } label: {
                    VStack(spacing: DS.Space.row) {
                        preview(choice)
                            .frame(height: 64)
                            .padding(DS.Space.xs)
                            .background(DS.Palette.raised, in: .rounded(DS.Radius.control))
                            .overlay {
                                RoundedRectangle.rounded(DS.Radius.control)
                                    .strokeBorder(isSelected ? DS.Palette.accent : DS.Palette.border, lineWidth: isSelected ? 2 : 1)
                            }
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(DS.Palette.accent)
                                .opacity(isSelected ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(choice[keyPath: title])
                                .font(DS.Font.caption)
                                .foregroundStyle(isSelected ? DS.Palette.text : DS.Palette.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice[keyPath: title])
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .contain)
    }
}

/// Two panes side by side in the theme: the left one active (its header full strength), the
/// right one as an inactive pane looks with `fade`.
struct PanePairPreview: View {
    let style: TerminalPreferences.PaneStyle
    let fade: TerminalPreferences.InactivePaneFade
    let activeBorder: Bool
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        let comfortable = style == .comfortable
        HStack(spacing: comfortable ? DS.Space.xs : 0) {
            MiniPane(isActive: true, fade: fade, activeBorder: activeBorder, rounded: comfortable, unfocusedOpacity: unfocusedOpacity)
            if !comfortable {
                Rectangle().fill(theme.splitDivider).frame(width: 1)
            }
            MiniPane(isActive: false, fade: fade, activeBorder: activeBorder, rounded: comfortable, unfocusedOpacity: unfocusedOpacity)
        }
        .padding(comfortable ? DS.Space.xs : 0)
        .background(comfortable ? theme.splitDivider : theme.background, in: .rounded(DS.Radius.chip))
        .clipShape(.rounded(DS.Radius.chip))
        .accessibilityHidden(true)
    }
}

private struct MiniPane: View {
    let isActive: Bool
    let fade: TerminalPreferences.InactivePaneFade
    let activeBorder: Bool
    let rounded: Bool
    let unfocusedOpacity: Double
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 3) {
                line(color: theme.ansi(2), width: 0.35)
                line(color: theme.foreground, width: 0.8)
                line(color: theme.foreground, width: 0.55)
                line(color: theme.ansi(4), width: 0.4)
            }
            .padding(DS.Space.row)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay { if !isActive && fade.dimsContent { dim } }
        }
        .background(theme.background)
        .overlay { if activeBorder { ActivePaneRing(isActive: isActive, cornerRadius: rounded ? DS.Radius.chip : 0) } }
        .clipShape(.rounded(rounded ? DS.Radius.chip : 0))
    }

    private var header: some View {
        HStack(spacing: DS.Space.xxs) {
            Capsule().fill(theme.foreground.opacity(isActive ? DS.Opacity.inactiveHover : DS.Opacity.mutedGlyph)).frame(width: 18, height: 3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.row)
        .frame(height: 10)
        .overlay { if !isActive && fade.dimsHeader { dim } }
    }

    private var dim: some View {
        UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background)
    }

    private func line(color: Color, width: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(color).frame(width: geometry.size.width * width, height: 2)
        }
        .frame(height: 2)
    }
}
