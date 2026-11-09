import SwiftUI

/// What a hand-drawn control is showing. Rest draws nothing behind it; hover, press and
/// selection lay the theme's ink under it at `ChromePalette.fillLevels`.
nonisolated public struct ControlState: Equatable, Sendable {
    public var isHovered: Bool
    public var isPressed: Bool
    public var isSelected: Bool
    public var isEnabled: Bool

    public init(isHovered: Bool = false, isPressed: Bool = false, isSelected: Bool = false, isEnabled: Bool = true) {
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }

    /// The ink's strength behind the control. A disabled control neither lights under the
    /// pointer nor answers a press; it keeps its selection.
    public var fillLevel: Double {
        let levels = ChromePalette.fillLevels
        guard isEnabled else { return isSelected ? levels.selected : 0 }
        if isPressed { return levels.pressed }
        if isSelected { return levels.selected }
        if isHovered { return levels.hover }
        return 0
    }
}

nonisolated public extension ChromeStyle {
    /// This ink on a disabled control: one step quieter and never fainter than the tertiary
    /// text, so the label still reads. A coloured label (the accent, a state) turns grey.
    var disabled: ChromeStyle {
        switch token {
        case .text, .accent, .done, .error, .attention, .working, .info: DS.Palette.textSecondary
        case .textSecondary, .textTertiary, .textQuaternary: DS.Palette.textTertiary
        default: self
        }
    }
}

public extension View {
    /// The fill behind a hand-drawn control in `state`, easing in and out with `DS.Motion.hover`.
    func controlFill(_ state: ControlState, in shape: some Shape = RoundedRectangle(cornerRadius: DS.Radius.control)) -> some View {
        background {
            shape
                .fill(DS.Palette.ink.opacity(state.fillLevel))
                .animation(DS.Motion.hover, value: state.fillLevel)
        }
    }
}
