import CoreGraphics
import TerminalCore

/// How a terminal looks: everything a theme or the design layer may change. Defaults are Ghostty's
/// (`src/config/Config.zig`), with the bundled JetBrains Mono Nerd Font.
public struct TerminalAppearance: Sendable, Equatable {
    /// Font family; nil uses the bundled JetBrains Mono (Nerd Font build).
    public var fontFamily: String?
    /// `font-size` in points (Ghostty's macOS default).
    public var fontSize: CGFloat = 13
    public var background = RGB(r: 0x28, g: 0x2C, b: 0x34)
    public var foreground = RGB(r: 0xFF, g: 0xFF, b: 0xFF)
    /// 256 colors; nil keeps Ghostty's default palette.
    public var palette: [RGB]?
    /// `cursor-color`; nil uses the foreground.
    public var cursorColor: RGB?
    /// `cursor-style` / `cursor-style-blink`: the shape DECSCUSR 0 resets to.
    public var cursorStyle = CursorShape.block
    public var cursorBlink = true
    /// Ghostty blinks the cursor every 600 ms.
    public var cursorBlinkInterval: Double = 0.6
    /// `selection-background` / `selection-foreground`; nil inverts the cell's colors (Ghostty's
    /// default).
    public var selectionBackground: RGB?
    public var selectionForeground: RGB?
    /// `search-background` / `search-foreground`: every match of a scrollback search.
    public var searchBackground = RGB(r: 0xFF, g: 0xE0, b: 0x82)
    public var searchForeground = RGB(r: 0, g: 0, b: 0)
    /// `search-selected-background` / `search-selected-foreground`: the match next/previous is on.
    public var searchSelectedBackground = RGB(r: 0xF2, g: 0xA5, b: 0x7E)
    public var searchSelectedForeground = RGB(r: 0, g: 0, b: 0)
    /// `faint-opacity`.
    public var faintOpacity: Double = 0.5
    /// `window-padding-x/y` in points.
    public var padding: CGFloat = 2
    /// `window-padding-balance`: center the grid in the leftover space (Ghostty's default: false).
    public var paddingBalance = false
    /// `unfocused-split-opacity`: how much of an unfocused split shows through the dimming. The
    /// host applies it; the renderer only carries the value.
    public var unfocusedSplitOpacity: Double = 0.7

    public init() {}

    /// The VT-side part of the appearance.
    public var terminalConfiguration: Terminal.Configuration {
        var c = Terminal.Configuration()
        c.background = background
        c.foreground = foreground
        c.palette = palette
        c.cursorColor = cursorColor
        c.cursorStyle = cursorStyle
        c.cursorBlink = cursorBlink
        return c
    }
}
