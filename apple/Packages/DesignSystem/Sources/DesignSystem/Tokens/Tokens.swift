import SwiftUI

/// The design system's namespace. Every number a screen uses comes from here; see docs/DESIGN.md
/// for where each value was taken from.
public enum DS {}

// MARK: - Spacing

public extension DS {
    /// A 4 pt grid with a 2 pt half step for hairline-tight chrome (Ghostty's overlays pad 5 and 8;
    nonisolated enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }
}

// MARK: - Radii

public extension DS {
    nonisolated enum Radius {
        /// Key caps, the resize overlay (Ghostty SurfaceView.swift `SurfaceResizeOverlay`: 4).
        public static let chip: CGFloat = 4
        /// Text fields inside overlays (Ghostty search field: 6).
        public static let field: CGFloat = 6
        /// Buttons and hover fills inside bars (Ghostty `SearchButtonStyle`: 6, rows: 8).
        public static let control: CGFloat = 8
        public static let pane: CGFloat = 10
        /// Floating panels: command palette, search bar, toasts' container (Ghostty palette 10, grown
        /// for glass, which reads smaller than an opaque edge).
        public static let panel: CGFloat = 16
        public static let tabSelection: CGFloat = 16.5
    }
}

// MARK: - Sizes

public extension DS {
    nonisolated enum Size {
        /// Visible split divider (Ghostty SplitView.swift `splitterVisibleSize`).
        public static let dividerVisible: CGFloat = 1
        /// Extra invisible hit area around it with a pointer (Ghostty `splitterInvisibleSize`)...
        public static let dividerHitPointer: CGFloat = 6
        /// ...and with a finger (44 pt is the HIG minimum; 20 keeps neighbouring cells tappable).
        public static let dividerHitTouch: CGFloat = 20
        /// Status glyph slot in dense rows.
        public static let statusGlyph: CGFloat = 12
        /// Horizontal tab strip height (macOS 26 titlebar tabs are 28 inside a 36 bar).
        public static let tabBar: CGFloat = 36
        public static let tab: CGFloat = 28
        /// Presence avatar diameter.
        public static let avatar: CGFloat = 22
        /// Command palette width (Ghostty CommandPalette.swift `.frame(maxWidth: 500)`).
        public static let paletteWidth: CGFloat = 560
        public static let keyBarPhone: CGFloat = 44
        public static let keyBarPad: CGFloat = 52
        public static let keyBarHardware: CGFloat = 36
    }
}

// MARK: - Motion

public extension DS {
    /// Durations and curves. Every animation is interruptible (springs or short ease-outs) and runs
    /// at the display's refresh rate; nothing loops except the working spinner.
    nonisolated enum Motion {
        /// Selection changes, row insertions, tab switches.
        public static let snappy = Animation.snappy(duration: 0.25)
        /// Overlays appearing and disappearing (Ghostty search bar corner snap: easeOut 0.2).
        public static let overlay = Animation.easeOut(duration: 0.2)
        /// Badges and indicators changing state (Ghostty KeyStateIndicator: response 0.3, damping 0.8).
        public static let indicator = Animation.spring(response: 0.3, dampingFraction: 0.8)
        /// Bell border (Ghostty BellBorderOverlay: easeInOut 0.3).
        public static let bell = Animation.easeInOut(duration: 0.3)
        /// Sheets and panels sliding in.
        public static let panel = Animation.smooth(duration: 0.35)
        /// How long the cols × rows overlay stays after the last resize (Ghostty
        /// `resize-overlay-duration` default 750 ms).
        public static let resizeOverlayDuration = Duration.milliseconds(750)
        /// Toasts stay this long (long enough to read eight words).
        public static let toastDuration = Duration.milliseconds(2400)
        public static let feedbackDelay = Duration.milliseconds(200)
    }
}
