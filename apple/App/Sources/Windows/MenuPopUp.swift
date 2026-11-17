#if os(macOS)
import AppKit

extension NSMenu {
    /// Pops the menu up at `point` in `view` while the view is in a window; whether it did.
    /// AppKit raises for a view in none, and the raise unwinds through whatever was handling the
    /// click, which can leave SwiftUI's own click handling stuck.
    @discardableResult
    func popUpIfShown(at point: NSPoint, in view: NSView) -> Bool {
        guard view.window != nil else { return false }
        return popUp(positioning: nil, at: point, in: view)
    }
}

/// A right click in the title bar opens the menu of what was clicked: a tab chip's, the sidebar
/// toggle's, the people's. AppKit hands every right click in a toolbar to the toolbar's own menu,
/// which with nothing to customize is one blank item, and never asks the view under the pointer.
@MainActor
enum TitleBarContextMenus {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            show(for: event) ? nil : event
        }
    }

    private static func show(for event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView, let frameView = content.superview,
              let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)),
              !hit.isDescendant(of: content)
        else { return false }
        var view: NSView? = hit
        while let current = view, current !== frameView {
            if let menu = current.menu(for: event), menu.items.contains(where: { !$0.title.isEmpty }) {
                NSMenu.popUpContextMenu(menu, with: event, for: current)
                return true
            }
            view = current.superview
        }
        return false
    }
}
#endif
