import PaneLayout
import SwiftUI

/// Starts a tab's Chat while the pointer rests on the tab, so it opens on rows already on their way.
struct ChatHoverPrewarm: ViewModifier {
    /// A pointer passing over tabs on its way elsewhere starts nothing.
    static let intent: Duration = .milliseconds(80)

    let hovered: Bool
    let tab: Tab
    let workspace: Workspace?

    func body(content: Content) -> some View {
        content.task(id: hovered) {
            guard hovered, let workspace else { return }
            try? await Task.sleep(for: Self.intent)
            guard !Task.isCancelled else { return }
            workspace.prewarmChat(of: tab)
        }
    }
}
