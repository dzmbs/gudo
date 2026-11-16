import SwiftUI

// Liquid Glass usage rules:
// 1. Glass is for the navigation layer that floats over content: toolbars, the sidebar, the tab
//    capsule, floating panels (palette, search, toasts), the key bar. Never on content itself:
//    the terminal grid, list rows, diff lines and file content stay opaque.
// 2. Never stack glass on glass; group neighbours in a `GlassEffectContainer` so they blend.
// 3. Tint glass only to carry state (the selected tab, a prominent primary action), never for
//    decoration.

public extension View {
    /// A floating panel over content: a glass `Surface.card`, or with `elevated` a
    /// `Surface.panel` for what sits above everything (the palette).
    func floatingPanel(cornerRadius: CGFloat = DS.Radius.panel, elevated: Bool = false) -> some View {
        surface(elevated ? .panel : .card, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A floating glass capsule (toasts, notices, hint pills): a `Surface.card`.
    func floatingCapsule(interactive: Bool = false) -> some View {
        surface(.card, in: Capsule(), interactive: interactive)
    }

    /// The theme's surface as glass behind the content, opaque under Reduce Transparency: the
    /// one fill every glass surface uses (through `Surface`).
    func themedGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        modifier(ThemedGlassFill(shape: shape, interactive: interactive))
    }
}

/// What a glass surface shows: Liquid Glass tinted with the chrome's surface, or under Reduce
/// Transparency that surface opaque, as the system's own bars are. The surface is the paper itself
/// on light chrome (a raised grey there reads as a flat grey card), the raised surface on dark.
nonisolated public enum GlassSurface: Equatable, Sendable {
    case glass(tint: ThemeColor, opacity: Double)
    case opaque(ThemeColor)

    /// How much of the surface tints dark glass: enough to carry the theme's hue, little enough
    /// that the glass still reads as glass. Light chrome needs more of its paper: text under
    /// clear glass reads through it.
    static let tintOpacity = (light: 0.88, dark: 0.55)

    public static func choose(for chrome: ChromePalette, reduceTransparency: Bool) -> GlassSurface {
        let light = chrome.scheme == .light
        let surface = light ? chrome.base : chrome.raised
        guard !reduceTransparency else { return .opaque(surface) }
        return .glass(tint: surface, opacity: light ? tintOpacity.light : tintOpacity.dark)
    }
}

private struct ThemedGlassFill<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch GlassSurface.choose(for: chrome, reduceTransparency: reduceTransparency) {
        case .glass(let tint, let opacity):
            let glass = Glass.regular.tint(tint.color.opacity(opacity))
            content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        case .opaque(let surface):
            content.background(surface.color, in: shape)
        }
    }
}

/// The one primary action on a screen, in the theme's prominent colour (its accent deepened
/// until the label reads on it at 4.5:1). On touch it is prominent glass. On the Mac it is drawn
/// solid: the system's glass buttons turn grey in a window that is not key, and the label then
/// fades into them, so an approval card over another app would read as disabled.
public struct PrimaryGlassButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        Button(configuration)
            .buttonStyle(PrimaryFillButtonStyle())
        #else
        Button(configuration)
            .buttonStyle(.glassProminent)
            .tint(DS.Palette.prominent)
            // Its own label colour: content under `chromeContent()` carries the theme's ink.
            .foregroundStyle(DS.Palette.onProminent)
        #endif
    }
}

#if os(macOS)
/// The Mac's primary button: the prominent fill at the system button's height for its control
/// size, lit and pressed from `ControlState`. Disabled, it drops to a push button's bezel with
/// the stepped-down ink.
struct PrimaryFillButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let metrics = PrimaryButtonMetrics(controlSize)
        let shape = RoundedRectangle.rounded(DS.Radius.field)
        configuration.label
            .font(metrics.font)
            .lineLimit(1)
            .foregroundStyle(isEnabled ? DS.Palette.onProminent : DS.Palette.text.disabled)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(minHeight: metrics.height)
            .background {
                if isEnabled {
                    shape.fill(DS.Palette.prominent)
                        .overlay {
                            ControlFillShape(
                                state: ControlState(isHovered: isHovered, isPressed: configuration.isPressed), shape: shape)
                                .animation(DS.Motion.micro, value: isHovered)
                        }
                } else {
                    ControlFillShape(state: ControlState(isSelected: true, isEnabled: false), shape: shape)
                }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.micro, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

/// The system push button's height, padding and label size for each control size.
nonisolated struct PrimaryButtonMetrics: Equatable {
    var height: CGFloat
    var horizontalPadding: CGFloat
    var font: Font

    init(_ controlSize: ControlSize) {
        switch controlSize {
        case .mini: (height, horizontalPadding, font) = (16, DS.Space.row, .caption)
        case .small: (height, horizontalPadding, font) = (20, DS.Space.s, .subheadline)
        case .large: (height, horizontalPadding, font) = (30, DS.Space.m, .body)
        case .extraLarge: (height, horizontalPadding, font) = (36, DS.Space.l, .title3)
        default: (height, horizontalPadding, font) = (24, DS.Space.gap10, .body)
        }
    }
}
#endif

public extension PrimitiveButtonStyle where Self == PrimaryGlassButtonStyle {
    static var primaryGlass: PrimaryGlassButtonStyle { PrimaryGlassButtonStyle() }
}

/// A plain, chrome-quiet button for bars: icon only, secondary until hovered or pressed.
public struct BarButtonStyle: ButtonStyle {
    /// The area a finger can hit, around the drawn button; nil for the button itself.
    var hitArea: CGFloat?
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(hitArea: CGFloat? = nil) {
        self.hitArea = hitArea
    }

    public func makeBody(configuration: Configuration) -> some View {
        let state = ControlState(isHovered: isHovered, isPressed: configuration.isPressed, isEnabled: isEnabled)
        let isLit = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(isEnabled ? (isLit ? DS.Palette.text : DS.Palette.textSecondary) : DS.Palette.textSecondary.disabled)
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 2)
            .background(
                ControlFillShape(state: state, shape: .rounded(DS.Radius.field))
                    .animation(DS.Motion.micro, value: isLit))
            .frame(minWidth: hitArea, minHeight: hitArea)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }
}

public extension ButtonStyle where Self == BarButtonStyle {
    static var bar: BarButtonStyle { BarButtonStyle() }
    /// A bar button a finger hits in the full touch target, drawn at the bar's size.
    static var touchBar: BarButtonStyle { BarButtonStyle(hitArea: DS.Size.touchTarget) }
}

/// A full-width list row with hover and pressed fills, for rows that are buttons.
public struct RowButtonStyle: ButtonStyle {
    var isSelected: Bool
    var cornerRadius = DS.Radius.control
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(isSelected: Bool = false, cornerRadius: CGFloat = DS.Radius.control) {
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        let state = ControlState(
            isHovered: isHovered, isPressed: configuration.isPressed, isSelected: isSelected, isEnabled: isEnabled, tint: .accent)
        configuration.label
            .contentShape(.rect)
            .background(
                ControlFillShape(state: state, shape: .rounded(cornerRadius))
                    .animation(DS.Motion.micro, value: isHovered))
            .onHover { isHovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }
}

public extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
    static func row(selected: Bool) -> RowButtonStyle { RowButtonStyle(isSelected: selected) }
    static func paletteRow(selected: Bool) -> RowButtonStyle {
        RowButtonStyle(isSelected: selected, cornerRadius: DS.Radius.control)
    }
}

/// A sidebar row as the platform draws a selected one, in the theme's accent: the solid accent
/// with its own label while the window (or the iPad's scene) is active, the soft accent tint once
/// it is not (where the system would turn grey).
public struct SidebarRowButtonStyle: ButtonStyle {
    var isSelected: Bool
    @State private var isHovered = false

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(configuration: configuration, isSelected: isSelected, isHovered: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct SidebarRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let selection = chrome.rowSelection(on: chrome.sidebar, emphasized: appearsActive)
        let state = ControlState(isHovered: isHovered, isPressed: configuration.isPressed, tint: .accent)
        configuration.label
            .foregroundStyle(isSelected ? AnyShapeStyle(selection.text.color) : AnyShapeStyle(DS.Palette.text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                // Selected, the platform's own sidebar selection in the accent; otherwise the
                // control states.
                if isSelected {
                    RoundedRectangle.rounded(DS.Radius.control).fill(selection.fill.color)
                } else {
                    ControlFillShape(state: state, shape: .rounded(DS.Radius.control))
                }
            }
    }
}

public extension ButtonStyle where Self == SidebarRowButtonStyle {
    static func sidebarRow(selected: Bool) -> SidebarRowButtonStyle { SidebarRowButtonStyle(isSelected: selected) }
}

public extension View {
    /// A toolbar toggle that is on (Find while the search bar is open): lit with the terminal's
    /// ink behind the glyph, never the accent.
    func lit(_ isOn: Bool) -> some View {
        modifier(LitModifier(isOn: isOn))
    }
}

private struct LitModifier: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .background {
                ControlFillShape(state: ControlState(isSelected: isOn), shape: Capsule())
                    .padding(-DS.Space.xs)
            }
            .animation(DS.Motion.micro, value: isOn)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A text or icon button inside a row, a banner or a card: no chrome of its own, the label in the
/// theme's secondary ink (or the accent for the row's main verb), a soft fill under the pointer or
/// a finger. Glass stays on bars and floating surfaces: a glass capsule inside a list row reads as
/// a sticker.
public struct QuietButtonStyle: ButtonStyle {
    var prominent: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(foreground(configuration.isPressed))
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .frame(minHeight: 28)
            .background(
                ControlFillShape(
                    state: ControlState(isHovered: isHovered, isPressed: configuration.isPressed, isEnabled: isEnabled),
                    shape: .rounded(DS.Radius.field)))
            .contentShape(.rounded(DS.Radius.field))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.micro, value: configuration.isPressed)
            .onHover { isHovered = $0 }
            #if os(iOS)
            .contentShape(.hoverEffect, .rounded(DS.Radius.field))
            .hoverEffect(.highlight)
            #endif
    }

    private func foreground(_ pressed: Bool) -> AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(prominent ? DS.Palette.accent.disabled : DS.Palette.textSecondary.disabled) }
        if prominent { return AnyShapeStyle(DS.Palette.accent) }
        return AnyShapeStyle(isHovered || pressed ? DS.Palette.text : DS.Palette.textSecondary)
    }
}

/// An action in a settings form (Forget Saved Passwords, Delete All Replays): on the Mac a push
/// button filled from the theme's ink, on touch a row's tinted label. A destructive one reads in
/// the theme's red; disabled, the label drops to the tertiary ink (≥ 3:1), never a faded tint.
public struct FormActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .foregroundStyle(foreground(configuration.role))
            .padding(.horizontal, DS.Space.gap10)
            .padding(.vertical, 3)
            // A push button's bezel is its selected fill, deeper while pressed.
            .background(
                ControlFillShape(
                    state: ControlState(isPressed: configuration.isPressed, isSelected: true, isEnabled: isEnabled),
                    shape: .rounded(DS.Radius.field)))
            .contentShape(.rounded(DS.Radius.field))
        #else
        configuration.label
            .foregroundStyle(foreground(configuration.role))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
        #endif
    }

    private func foreground(_ role: ButtonRole?) -> AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(DS.Palette.textTertiary) }
        if role == .destructive { return AnyShapeStyle(DS.Palette.error) }
        #if os(macOS)
        return AnyShapeStyle(DS.Palette.text)
        #else
        return AnyShapeStyle(DS.Palette.accent)
        #endif
    }
}

public extension ButtonStyle where Self == FormActionButtonStyle {
    static var formAction: FormActionButtonStyle { FormActionButtonStyle() }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    /// A secondary verb in a row (Reply, Open, Revoke).
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    /// The row's own main verb when it is not a decision (a banner's Undo).
    static var quietProminent: QuietButtonStyle { QuietButtonStyle(prominent: true) }
}
