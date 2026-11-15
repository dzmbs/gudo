import SwiftUI

/// The design system's namespace. Every number a screen uses comes from here; see docs/DESIGN.md.
public enum DS {}

// MARK: - Spacing

public extension DS {
    /// A 4 pt grid with a 2 pt half step for hairline-tight chrome.
    nonisolated enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
        /// Glyph to label, and a dense row's vertical padding.
        public static let row: CGFloat = 6
        /// A leading slot to its title in dense rows, and a toast's vertical padding.
        public static let gap10: CGFloat = 10
        /// A capsule's or badge's padding.
        public static let badgeH: CGFloat = 7
        public static let badgeV: CGFloat = 3
    }
}

// MARK: - Opacity

public extension DS {
    /// The three greys come from `.secondary` / `.tertiary` / `.quaternary`; these are the only
    /// other opacities.
    nonisolated enum Opacity {
        public static let mutedGlyph: Double = 0.6
        /// Dimmed by opacity rather than a grey, so their colours survive.
        public static let inactive: Double = 0.7
        public static let inactiveHover: Double = 0.85
        /// An unfocused pane in a window that is not active shows at its own opacity times this.
        public static let recededPane: Double = 0.85
    }
}

// MARK: - Radii

public extension DS {
    /// Six radii, each a step on from the last, every one drawn with continuous corners
    /// (`.rounded(_:)`). A shape inset in another takes the outer radius less the inset.
    nonisolated enum Radius {
        /// Status chips, key caps, the resize overlay.
        public static let chip: CGFloat = 4
        /// Fields, bar buttons, quiet buttons, the selected tab.
        public static let field: CGFloat = 6
        /// Rows, row highlights, palette rows (concentric with the panel at an 8 pt inset), code blocks.
        public static let control: CGFloat = 8
        /// Comfortable panes, the search bar, the secure-input badge, cards in the sidebar.
        public static let pane: CGFloat = 12
        /// Floating glass panels (the palette); glass reads smaller than an opaque edge.
        public static let panel: CGFloat = 16
        /// Glass cards over the terminal: secret prompts, knocks, reconnect and control requests.
        public static let card: CGFloat = 20
    }
}

// MARK: - Sizes

public extension DS {
    nonisolated enum Size {
        /// A split divider's drawn line: one physical pixel (`hairline(scale:)`); its hit area
        /// is wider.
        /// Extra invisible hit area around a divider with a pointer...
        public static let dividerHitPointer: CGFloat = 6
        /// ...and with a finger (44 pt is the HIG minimum; 20 keeps neighbouring cells tappable).
        public static let dividerHitTouch: CGFloat = 20
        public static let statusGlyph: CGFloat = 12
        public static let touchTarget: CGFloat = 44
        public static let proseQuoteRule: CGFloat = 3
        public static let proseTableColumn: CGFloat = 80
        public static let proseTableLineHeight: CGFloat = 24
        public static let proseOutputLineHeight: CGFloat = 16
        public static let proseDiffLineHeight: CGFloat = 20
        /// macOS 26 titlebar tabs are 28 inside a 36 bar.
        public static let tabBar: CGFloat = 36
        public static let tab: CGFloat = 28
        public static let tabStrip: CGFloat = 34
        /// A strip chip's share of the strip stays between these; more tabs scroll.
        public static let tabMinWidth: CGFloat = 160
        public static let tabMaxWidth: CGFloat = 240
        public static let avatar: CGFloat = 22
        /// Room for a title and its context on one line, wider for touch.
        #if os(macOS)
        public static let paletteWidth: CGFloat = 580
        #else
        public static let paletteWidth: CGFloat = 640
        #endif
        /// One physical pixel: every chrome line and split divider.
        public static func hairline(scale: CGFloat) -> CGFloat { 1 / max(scale, 1) }
        public static let keyBarPhone: CGFloat = 44
        public static let keyBarPad: CGFloat = 52
        public static let keyBarHardware: CGFloat = 36
        public static let swipeAction: CGFloat = 74
        public static let statusDot: CGFloat = 8
        /// A host name, its state and ⌃⌘9 on one line.
        public static let switcherWidth: CGFloat = 320
    }
}

// MARK: - Motion

public extension DS {
    /// One vocabulary for every animation: critically damped springs (no overshoot, never
    /// reversing) that keep their velocity when interrupted, by role. Chrome moves only by
    /// opacity, scale and offset (`MotionTransition`). See docs/DESIGN.md, Motion.
    nonisolated enum Motion {
        nonisolated public enum Role: CaseIterable, Sendable {
            /// Hover, press, pills, badges, status glyphs, lit toggles.
            case micro
            /// Rows, selection, toasts, menus, popovers, panels, the palette, swipes.
            case standard
            /// Splits, zoom, float and dock, the sidebar, a fold changing posture.
            case structural

            public var spring: Spring {
                switch self {
                case .micro: Spring(duration: 0.12, bounce: 0)
                case .standard: Spring(duration: 0.22, bounce: 0)
                case .structural: Spring(duration: 0.3, bounce: 0)
                }
            }

            public var animation: Animation { .spring(spring) }

            /// When it is within 1 % of where it is going, which is when it reads as still.
            public var budget: Double {
                switch self {
                case .micro: 0.15
                case .standard: 0.25
                case .structural: 0.34
                }
            }
        }

        public static let micro = Role.micro.animation
        public static let standard = Role.standard.animation
        public static let structural = Role.structural.animation

        /// A structural move is within a point of a full-window move: each terminal shows its
        /// last frame on the way and draws at its new size from here.
        public static let structuralSettle = 0.42
        /// Something that lands where a structural move is heading shows as the move arrives.
        public static let arrivalDelay = 0.16

        /// None on the Mac, where the palette is a panel that appears at once; `standard` on touch.
        #if os(macOS)
        public static let palette: Animation? = nil
        #else
        public static let palette: Animation? = standard
        #endif

        /// The only loops: the working spinner, the working shimmer and the secure-input badge.
        nonisolated public enum Loop {
            public static let spinnerPeriod = 1.0
            public static let shimmerPeriod = 3.0
            public static let secureInput = Animation.linear(duration: 2)
        }

        /// How long the cols × rows overlay stays after the last resize.
        public static let resizeOverlayDuration = Duration.milliseconds(750)
        /// Long enough to read eight words.
        public static let toastDuration = Duration.milliseconds(2400)
        /// Errors stay longer than confirmations: they are read, not glanced at.
        public static let bannerErrorDuration = Duration.seconds(4)
        /// Do not show progress for anything faster than this.
        public static let feedbackDelay = Duration.milliseconds(200)
        /// A collapsed group opening under a drag that rests on it.
        public static let springOpenDelay = Duration.milliseconds(600)
    }
}

// MARK: - Shadows

public extension DS {
    /// Dark chrome needs a heavier shadow to read at all.
    nonisolated enum Shadow: Sendable {
        /// Banners, hint capsules, the agent cards.
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
    func shadow(_ shadow: DS.Shadow) -> some View {
        modifier(ShadowModifier(shadow: shadow, isVisible: true))
    }

    /// The shadow only while `isVisible`, fading with whatever animates the change.
    func shadow(_ shadow: DS.Shadow, visible isVisible: Bool) -> some View {
        modifier(ShadowModifier(shadow: shadow, isVisible: isVisible))
    }
}

private struct ShadowModifier: ViewModifier {
    let shadow: DS.Shadow
    let isVisible: Bool
    @Environment(\.chrome) private var chrome

    func body(content: Content) -> some View {
        let opacity = isVisible ? shadow.opacity(dark: chrome.scheme == .dark) : 0
        content.shadow(color: .black.opacity(opacity), radius: isVisible ? shadow.radius : 0, y: isVisible ? shadow.y : 0)
    }
}
