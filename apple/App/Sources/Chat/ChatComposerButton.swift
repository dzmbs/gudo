#if os(iOS)
import DesignSystem
import SwiftUI

/// The composer's buttons. Send is the screen's one primary action, a disc in the prominent
/// accent; Stop is the same disc in the ink; Add and Dictate stay quiet glyphs. All of them keep a
/// 44 pt target, so swapping one for another never moves the row.
struct ChatComposerButtonStyle: ButtonStyle {
    enum Weight { case glyph, primary, stop }

    let weight: Weight
    @Environment(\.isEnabled) private var isEnabled

    init(action: ChatComposer.PrimaryAction) {
        switch action {
        case .send, .queue: weight = .primary
        case .stop: weight = .stop
        }
    }

    init(_ weight: Weight) { self.weight = weight }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.rowTitleEmphasis)
            .imageScale(weight == .glyph ? .medium : .small)
            .foregroundStyle(glyph)
            .frame(width: DS.Size.proseSendDisc, height: DS.Size.proseSendDisc)
            .background { if let disc { Circle().fill(disc) } }
            .frame(width: DS.Size.touchTarget, height: DS.Size.touchTarget)
            .contentShape(.circle)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? DS.Opacity.inactiveHover : 1)
            .animation(DS.Motion.micro, value: configuration.isPressed)
            .animation(DS.Motion.micro, value: isEnabled)
            .hoverEffect(.highlight)
    }

    private var disc: ChromeStyle? {
        switch weight {
        case .primary: isEnabled ? DS.Palette.prominent : DS.Palette.selectedFill
        case .stop: isEnabled ? DS.Palette.text : DS.Palette.selectedFill
        case .glyph: nil
        }
    }

    private var glyph: ChromeStyle {
        guard isEnabled else { return DS.Palette.textTertiary }
        switch weight {
        case .primary: return DS.Palette.onProminent
        case .stop: return DS.Palette.on(DS.Palette.text)
        case .glyph: return DS.Palette.textSecondary
        }
    }
}
#endif
