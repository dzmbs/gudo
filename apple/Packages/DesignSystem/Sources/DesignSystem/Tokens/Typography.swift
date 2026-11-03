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
        #if os(macOS)
        public static let tabTitle = SwiftUI.Font.callout
        #else
        public static let tabTitle = SwiftUI.Font.subheadline
        #endif
        /// Sentence case, never uppercase.
        public static let section = SwiftUI.Font.subheadline.weight(.semibold)
        /// Monospaced digits so columns do not jitter.
        public static let meta = SwiftUI.Font.caption.monospacedDigit()
        public static let badge = SwiftUI.Font.caption2.weight(.medium)
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
    }
}
