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
#endif
