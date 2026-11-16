import DesignSystem
import SwiftUI

/// Settings › Appearance › Panes › Inset Content Card: with Comfortable panes in a regular
/// window, the terminal sits as rounded cards inset from the window's edges and the sidebar,
/// with the sidebar's colour all around them, up under the title bar. Each pane is the card
/// (its own corners, the gaps between panes the same colour), so no square corner meets a
/// junction.
enum ContentCard {
    /// The card's distance from the window's edges and the sidebar.
    static let inset = DS.Space.s

    static func isShown(style: TerminalPreferences.PaneStyle, isOn: Bool, compact: Bool) -> Bool {
        isOn && style == .comfortable && !compact
    }
}

extension EnvironmentValues {
    /// The window draws its terminal area as an inset card (`ContentCard`).
    @Entry var showsContentCard = false
}
