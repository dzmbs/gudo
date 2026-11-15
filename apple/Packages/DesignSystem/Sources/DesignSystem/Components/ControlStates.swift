import SwiftUI

/// What a hand-drawn control is showing. Rest draws nothing behind it; hover, press and
/// selection lay the theme's ink under it at `ChromePalette.fillLevels`, or with the accent
/// variant the accent for a press (`accentDim`) and a selection (`selection`). Every button
/// style and hand-drawn control takes its fill from here.
nonisolated public struct ControlState: Equatable, Sendable {
    public enum Tint: Equatable, Sendable {
        case neutral, accent
    }

    public var isHovered: Bool
    public var isPressed: Bool
    public var isSelected: Bool
    public var isEnabled: Bool
    public var tint: Tint

    public init(isHovered: Bool = false, isPressed: Bool = false, isSelected: Bool = false, isEnabled: Bool = true, tint: Tint = .neutral) {
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.tint = tint
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

    /// The fill behind the control, nil at rest.
    public var fill: ChromeStyle? {
        switch tint {
        case .neutral:
            switch fillLevel {
            case ChromePalette.fillLevels.pressed: DS.Palette.pressedFill
            case ChromePalette.fillLevels.selected: DS.Palette.selectedFill
            case ChromePalette.fillLevels.hover: DS.Palette.hoverFill
            default: nil
            }
        case .accent:
            if isSelected { DS.Palette.selection }
            else if !isEnabled { nil }
            else if isPressed { DS.Palette.accentDim }
            else if isHovered { DS.Palette.hoverFill }
            else { nil }
        }
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
    /// The fill behind a hand-drawn control in `state`, easing in and out with `DS.Motion.micro`.
    func controlFill(_ state: ControlState, in shape: some Shape = RoundedRectangle.rounded(DS.Radius.control)) -> some View {
        background {
            ControlFillShape(state: state, shape: shape)
                .animation(DS.Motion.micro, value: state)
        }
    }
}

/// `state`'s fill in `shape`, clear at rest so the change to and from rest can fade.
public struct ControlFillShape<S: Shape>: View {
    let state: ControlState
    let shape: S

    public init(state: ControlState, shape: S) {
        self.state = state
        self.shape = shape
    }

    public var body: some View {
        shape
            .fill(state.fill ?? DS.Palette.hoverFill)
            .opacity(state.fill == nil ? 0 : 1)
    }
}
