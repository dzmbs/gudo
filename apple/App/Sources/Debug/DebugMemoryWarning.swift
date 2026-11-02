#if DEBUG && os(iOS)
import UIKit

/// Sends the app a real memory warning from outside, for lifecycle stress runs:
/// `xcrun simctl spawn <device> notifyutil -p dev.unnamed.debug.memorywarning` (the Simulator's
/// menu item has no command-line equivalent).
enum DebugMemoryWarning {
    static func install() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                // UIKit's own path: system caches are purged and the notification is posted.
                UIApplication.shared.perform(NSSelectorFromString("_performMemoryWarning"))
            }
        }, "dev.unnamed.debug.memorywarning" as CFString, nil, .deliverImmediately)
    }
}
#endif
