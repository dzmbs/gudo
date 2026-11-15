import SwiftUI

public extension DS {
    /// The chrome type scale. Chrome is SF Pro through text styles so Dynamic Type works on iOS;
    /// literals (paths, commands, hosts) use SF Mono; only the terminal grid uses JetBrains Mono.
    /// macOS text styles resolve to the AppKit sizes (body 13, callout 12, caption 10).
    nonisolated enum Font {
        /// Sheet and screen titles that are not navigation titles.
        public static let title = SwiftUI.Font.title3.weight(.semibold)
        public static let rowTitle = SwiftUI.Font.body
        public static let rowTitleEmphasis = SwiftUI.Font.body.weight(.medium)
        public static let rowSubtitle = SwiftUI.Font.subheadline
        public static let prose = rowTitle
        public static let proseTitle = SwiftUI.Font.title2.weight(.semibold)
        public static let proseHeading = SwiftUI.Font.headline
        public static let proseSecondary = SwiftUI.Font.callout
        public static let proseSecondaryEmphasis = proseSecondary.weight(.semibold)
        public static let caption = SwiftUI.Font.caption
        public static let captionDetail = SwiftUI.Font.caption2
        #if os(macOS)
        public static let tabTitle = SwiftUI.Font.callout
        #else
        public static let tabTitle = SwiftUI.Font.subheadline
        #endif
        /// Sentence case, never uppercase.
        public static let section = SwiftUI.Font.subheadline.weight(.semibold)
        /// Monospaced digits so columns do not jitter.
        public static let meta = SwiftUI.Font.caption.monospacedDigit()
        /// Pills and badges: counts and ages, so monospaced digits.
        public static let badge = SwiftUI.Font.caption2.weight(.medium).monospacedDigit()
        /// Paths, commands, host names, diff and file content.
        public static let literal = SwiftUI.Font.system(.callout, design: .monospaced)
        public static let literalSmall = SwiftUI.Font.system(.caption, design: .monospaced)
        public static let paletteQuery = SwiftUI.Font.title3.weight(.light)
        public static let keyCap = SwiftUI.Font.system(size: 12, weight: .medium, design: .rounded)
        /// A row's third line (an agent's summary): quieter than its subtitle.
        public static let rowDetail = SwiftUI.Font.footnote
        public static let sectionSmall = SwiftUI.Font.footnote.weight(.semibold)
        public static let button = SwiftUI.Font.subheadline.weight(.medium)
        public static let banner = SwiftUI.Font.subheadline.weight(.medium)
        /// Plain glyphs at the trailing edge of menu rows, never key caps.
        public static let menuShortcut = SwiftUI.Font.subheadline.monospacedDigit()
        /// The cols × rows readout and the exit bar.
        public static let overlay = SwiftUI.Font.system(.callout).monospacedDigit()

        /// The sidebar's text at one of its three sizes (`sidebar-text-size`).
        public static func sidebar(_ size: SidebarSize) -> Sidebar { Sidebar(size: size) }
    }
}

public extension DS.Font {
    /// The sidebar's sizes. On the Mac they are the system sidebar's own point sizes (small,
    /// medium and large in System Settings › Appearance); on touch, text styles a step apart so
    /// Dynamic Type still applies.
    nonisolated enum SidebarSize: Int, CaseIterable, Sendable {
        case small = 1, medium, large

        /// What `sidebar-text-size` asks for, `system` meaning the Mac's sidebar size
        /// (`NSTableViewDefaultSizeMode`: 1, 2, 3; 0 when unset) or medium on touch.
        public init(_ preference: TerminalPreferences.SidebarTextSize, systemMode: Int) {
            switch preference {
            case .small: self = .small
            case .medium: self = .medium
            case .large: self = .large
            case .system: self = SidebarSize(rawValue: systemMode) ?? .medium
            }
        }
    }

    nonisolated struct Sidebar: Equatable, Sendable {
        public let size: SidebarSize

        #if os(macOS)
        private var points: (title: CGFloat, subtitle: CGFloat, icon: CGFloat) {
            switch size {
            case .small: (11, 10, 15)
            case .medium: (13, 11, 17)
            case .large: (15, 13, 20)
            }
        }

        public var title: SwiftUI.Font { .system(size: points.title) }
        public var subtitle: SwiftUI.Font { .system(size: points.subtitle) }
        public var section: SwiftUI.Font { .system(size: points.subtitle, weight: .semibold) }
        public var project: SwiftUI.Font { .system(size: points.title, weight: .semibold) }
        public var number: SwiftUI.Font { .system(size: points.subtitle).monospacedDigit() }
        /// The program glyph's slot leading each tab row.
        public var icon: CGFloat { points.icon }
        #else
        private var styles: (title: SwiftUI.Font.TextStyle, subtitle: SwiftUI.Font.TextStyle, project: SwiftUI.Font.TextStyle, icon: CGFloat) {
            switch size {
            case .small: (.subheadline, .footnote, .subheadline, 20)
            case .medium: (.body, .subheadline, .headline, 24)
            case .large: (.title3, .body, .title3, 28)
            }
        }

        public var title: SwiftUI.Font { .system(styles.title) }
        public var subtitle: SwiftUI.Font { .system(styles.subtitle) }
        public var section: SwiftUI.Font { .system(styles.subtitle).weight(.semibold) }
        public var project: SwiftUI.Font { .system(styles.project).weight(.semibold) }
        public var number: SwiftUI.Font { .system(styles.subtitle).monospacedDigit() }
        public var icon: CGFloat { styles.icon }
        #endif

        /// A project's folder mark, in proportion to the row's glyph.
        public var projectMark: CGFloat { (icon * 0.6).rounded() }

        /// How much wider the sidebar column grows (or narrows) for its text.
        public var widthExtra: Double {
            switch size {
            case .small: -24
            case .medium: 0
            case .large: 36
            }
        }
    }
}
