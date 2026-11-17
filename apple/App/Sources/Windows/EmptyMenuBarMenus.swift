#if os(macOS)
import AppKit

/// Takes menus with nothing in them out of the menu bar. A terminal has no rich text, so the
/// Format menu's items are replaced with none (`WorkspaceCommands`), and SwiftUI still adds the
/// menu itself, empty, whenever it makes the menu bar again.
@MainActor
enum EmptyMenuBarMenus {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { _ in
            // Once the bar is whole: a menu being made is empty for a moment.
            RunLoop.main.perform { MainActor.assumeIsolated { removeEmpty() } }
        }
    }

    private static func removeEmpty() {
        guard let bar = NSApp.mainMenu else { return }
        for item in bar.items.reversed() where item.submenu?.items.isEmpty == true {
            bar.removeItem(item)
        }
    }
}
#endif
