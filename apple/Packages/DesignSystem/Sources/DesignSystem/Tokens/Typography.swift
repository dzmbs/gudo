import SwiftUI

public extension DS {
    /// The chrome type scale. Chrome is SF Pro through text styles so Dynamic Type works on iOS;
    /// literals (paths, commands, hosts) use SF Mono; only the terminal grid uses JetBrains Mono.
    /// macOS text styles resolve to the AppKit sizes (body 13, callout 12, caption 10).
    nonisolated enum Font {
        /// Sheet and screen titles that are not navigation titles.
        public static let title = SwiftUI.Font.title3.weight(.semibold)
        /// List row primary line.
        public static let rowTitle = SwiftUI.Font.body
        /// Emphasised row title (selected tab, unread item).
        public static let rowTitleEmphasis = SwiftUI.Font.body.weight(.medium)
        /// List row secondary line.
        public static let rowSubtitle = SwiftUI.Font.subheadline
        /// on touch (15 / 13). Weight never changes with selection; the fill shows it.
        #if os(macOS)
        public static let sidebarTitle = SwiftUI.Font.body
        public static let sidebarSubtitle = SwiftUI.Font.caption
        #else
        public static let sidebarTitle = SwiftUI.Font.subheadline
        public static let sidebarSubtitle = SwiftUI.Font.footnote
        #endif
        /// Tab strip titles: the Mac's callout (12), one step under the sidebar on touch (15).
        #if os(macOS)
        public static let tabTitle = SwiftUI.Font.callout
        #else
        public static let tabTitle = SwiftUI.Font.subheadline
        #endif
        /// Section headers in sidebars and lists (sentence case, never uppercase).
        public static let section = SwiftUI.Font.subheadline.weight(.semibold)
        /// Metadata: ages, counts, shortcuts. Monospaced digits so columns do not jitter.
        public static let meta = SwiftUI.Font.caption.monospacedDigit()
        /// Badges and pills (Ghostty palette badge: caption2 medium).
        public static let badge = SwiftUI.Font.caption2.weight(.medium)
        /// Paths, commands, host names, diff and file content.
        public static let literal = SwiftUI.Font.system(.callout, design: .monospaced)
        public static let literalSmall = SwiftUI.Font.system(.caption, design: .monospaced)
        /// The command palette query (Ghostty CommandPalette.swift: 20 pt light).
        public static let paletteQuery = SwiftUI.Font.title3.weight(.light)
        /// Key caps (Ghostty SurfaceView.swift `KeyCap`: 12 pt medium rounded).
        public static let keyCap = SwiftUI.Font.system(size: 12, weight: .medium, design: .rounded)
        /// Terminal overlays drawn over the grid: the cols × rows readout and the exit bar.
        public static let overlay = SwiftUI.Font.system(.callout).monospacedDigit()
    }
}
