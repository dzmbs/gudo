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
        public static let row: CGFloat = 6
        /// A leading slot to its title in dense rows, and a toast's vertical padding.
        public static let gap10: CGFloat = 10
        /// A capsule's or badge's horizontal padding (h 7 / v 3, the Ghostty palette badge).
        public static let badgeH: CGFloat = 7
        public static let badgeV: CGFloat = 3
    }
}

// MARK: - Opacity

public extension DS {
    /// The three greys come from `.secondary` / `.tertiary` / `.quaternary`; these are the only
    nonisolated enum Opacity {
        /// Leading glyphs in rows and empty states: present, never louder than the text.
        public static let mutedGlyph: Double = 0.6
        /// Inactive tabs and secondary chrome dimmed by opacity, so their colours survive.
        public static let inactive: Double = 0.7
        public static let inactiveHover: Double = 0.85
    }
}

// MARK: - Radii

public extension DS {
    nonisolated enum Radius {
        /// Key caps, badges, the resize overlay (Ghostty `SurfaceResizeOverlay`: 4).
        public static let chip: CGFloat = 4
        /// Command palette rows: concentric with the panel's corners at an 8 pt inset.
        public static let paletteRow: CGFloat = 8
        /// Text fields inside overlays (Ghostty search field: 6).
        public static let field: CGFloat = 6
        /// Buttons and hover fills inside bars (Ghostty `SearchButtonStyle`: 6, rows: 8).
        public static let control: CGFloat = 8
        public static let pane: CGFloat = 10
        /// Floating panels: command palette, search bar, toasts' container (Ghostty palette 10, grown
        /// for glass, which reads smaller than an opaque edge).
        public static let panel: CGFloat = 16
        /// The selected tab's pill in the tab strip (Ghostty/AppKit native tabs: 7).
        public static let tabPill: CGFloat = 7
        /// The scrollback search bar's glass (Ghostty's search overlay, grown for glass).
        public static let searchPanel: CGFloat = 14
        /// Ghostty's secure-input badge.
        public static let secureBadge: CGFloat = 12
        /// Glass cards over the terminal: secret prompts, knocks, control requests.
        public static let card: CGFloat = 20
        /// The reconnect card and the control-request card (the tallest glass on the grid).
        public static let largeCard: CGFloat = 22
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
        public static let tabStrip: CGFloat = 34
        /// Presence avatar diameter.
        public static let avatar: CGFloat = 22
        /// Command palette width (Spotlight, Raycast): room for a title and its context on one
        /// line, wider for touch.
        #if os(macOS)
        public static let paletteWidth: CGFloat = 580
        #else
        public static let paletteWidth: CGFloat = 640
        #endif
        /// A hairline: one physical pixel (separators, the tab strip's rule).
        public static func hairline(scale: CGFloat) -> CGFloat { 1 / max(scale, 1) }
        public static let keyBarPhone: CGFloat = 44
        public static let keyBarPad: CGFloat = 52
        public static let keyBarHardware: CGFloat = 36
        /// A swipe action's width (Mail: 74).
        public static let swipeAction: CGFloat = 74
        public static let statusDot: CGFloat = 8
        /// The host switcher's width: a host name, its state and ⌃⌘9 on one line.
        public static let switcherWidth: CGFloat = 320
    }
}

// MARK: - Motion

public extension DS {
    /// Durations and curves. Every animation is interruptible (springs or short ease-outs) and runs
    /// at the display's refresh rate; nothing loops except the working spinner.
    nonisolated enum Motion {
        /// Selection changes, row insertions, tab switches.
        public static let snappy = Animation.snappy(duration: 0.25)
        public static let quick = Animation.easeInOut(duration: 0.15)
        /// Hover fills.
        public static let hover = Animation.easeInOut(duration: 0.1)
        /// Overlays appearing and disappearing (Ghostty search bar corner snap: easeOut 0.2).
        public static let overlay = Animation.easeOut(duration: 0.2)
        #if os(macOS)
        public static let palette: Animation? = nil
        #else
        public static let palette: Animation? = .easeOut(duration: 0.15)
        #endif
        /// Badges and indicators changing state (Ghostty KeyStateIndicator: response 0.3, damping 0.8).
        public static let indicator = Animation.spring(response: 0.3, dampingFraction: 0.8)
        /// Bell border (Ghostty BellBorderOverlay: easeInOut 0.3).
        public static let bell = Animation.easeInOut(duration: 0.3)
        /// Sheets and panels sliding in.
        public static let panel = Animation.smooth(duration: panelDuration)
        public static let panelDuration = 0.35
        /// The sidebar showing and hiding: AppKit's split view collapse (ease in-out, 0.25 s).
        /// A curve that ends on time, so the terminals' one reflow follows straight after.
        public static let sidebar = Animation.easeInOut(duration: sidebarDuration)
        public static let sidebarDuration = 0.25
        /// The layout moving to a new fold (a book's pages parting, the deck rising): ends on time
        /// so the terminals reflow once, straight after.
        public static let fold = Animation.smooth(duration: foldDuration)
        public static let foldDuration = 0.4
        /// How long the cols × rows overlay stays after the last resize (Ghostty
        /// `resize-overlay-duration` default 750 ms).
        public static let resizeOverlayDuration = Duration.milliseconds(750)
        /// Toasts stay this long (long enough to read eight words).
        public static let toastDuration = Duration.milliseconds(2400)
        public static let feedbackDelay = Duration.milliseconds(200)

        // to wobble, quick enough to feel attached to the finger.

        /// Panes splitting, closing, zooming, a dragged pane's neighbours making room and its
        /// drop settling: quick and decisive, with no overshoot. Each terminal shows its last
        /// frame on the way and draws at its new size once there (`splitSettle`, when a spring
        /// this stiff is within a point).
        public static let split = Animation.spring(duration: splitDuration, bounce: 0)
        public static let splitDuration = 0.3
        public static let splitSettle = 0.42
        /// Banners dropping in and lifting out.
        public static let banner = Animation.spring(response: 0.42, dampingFraction: 0.82)
        /// Menus, popovers and the highlight moving between their rows.
        public static let menu = Animation.spring(response: 0.3, dampingFraction: 0.86)
        /// A row settling open or shut after a swipe.
        public static let swipe = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// Rows making room for a dragged one, and a dropped row settling (Finder, Safari's
        /// sidebar): springy, interruptible, no visible overshoot.
        public static let reorder = Animation.spring(response: 0.3, dampingFraction: 0.84)
        /// A collapsed group opening under a drag that rests on it (spring-loaded folders).
        public static let springOpenDelay = Duration.milliseconds(600)
        /// A control's pressed state.
        public static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
        /// A pane lifting out of its tab into a floating window, docking back, going to the
        /// tray and coming back: one spring for the window and the panes making room, a breath
        /// of bounce on the card only it shows. Grids hold for `liftDuration`, then reflow once.
        public static let lift = Animation.spring(duration: 0.42, bounce: 0.12)
        public static let liftDuration = 0.5
        /// A floating window let go: carried by its flick, coming to rest on the line it snaps to.
        public static let settle = Animation.spring(response: 0.34, dampingFraction: 0.86)
        /// Errors stay longer than confirmations: they are read, not glanced at.
        public static let bannerErrorDuration = Duration.seconds(4)
    }
}

// MARK: - Shadows

public extension DS {
    /// heavier shadow to read at all.
    nonisolated enum Shadow: Sendable {
        /// Banners, hint capsules, the agent cards: lifted a little off whatever is under them.
        case float
        /// The palette and the host switcher: the top of the stack.
        case panel

        public func opacity(dark: Bool) -> Double {
            switch self {
            case .float: dark ? 0.35 : 0.12
            case .panel: dark ? 0.45 : 0.16
            }
        }

        public var radius: CGFloat { self == .float ? 16 : 28 }
        public var y: CGFloat { self == .float ? 6 : 12 }
    }
}

public extension View {
    /// One of the two shadows, weighted for the chrome's scheme.
    func shadow(_ shadow: DS.Shadow) -> some View {
        modifier(ShadowModifier(shadow: shadow))
    }
}

private struct ShadowModifier: ViewModifier {
    let shadow: DS.Shadow
    @Environment(\.chrome) private var chrome

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(shadow.opacity(dark: chrome.scheme == .dark)), radius: shadow.radius, y: shadow.y)
    }
}

// MARK: - Reduce Motion

public extension View {
    /// Slides in from `edge` with a fade; under Reduce Motion, only the fade.
    func movingTransition(_ edge: Edge) -> some View {
        modifier(MotionAwareTransition(moving: .move(edge: edge)))
    }

    /// Grows from `scale` with a fade; under Reduce Motion, only the fade.
    func scalingTransition(_ scale: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(MotionAwareTransition(moving: .scale(scale: scale, anchor: anchor)))
    }
}

private struct MotionAwareTransition: ViewModifier {
    let moving: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : moving.combined(with: .opacity))
    }
}
