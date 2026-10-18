import DesignSystem
import SwiftUI

/// Links and paths found in the focused pane's scrollback (stub).
struct LinksSheet: View {
    let links: [DetectedLink]
    var onOpen: (DetectedLink) -> Void = { _ in }

    var body: some View { Text("Links") }
}
