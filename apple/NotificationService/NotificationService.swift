import NotifyKit
import UserNotifications

/// The relay's push carries a sealed, daemon-signed payload and a placeholder alert. Open it with
/// the device's sealing key (shared Keychain group), check the daemon is a paired host, and show
/// the real title, host, body, category (Approve / Deny / Open) and thread. Any failure keeps the
/// placeholder.
///
/// Builds without the push entitlement have no shared Keychain group: the key is nil and the
/// placeholder stays (such builds never register for pushes anyway).
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var originalContent: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        originalContent = request.content
        contentHandler(ServiceExtensionCore.shared().process(request.content))
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver only the relay's placeholder, without anything else it sent.
        if let contentHandler, let originalContent { contentHandler(ServiceExtensionCore.placeholder(originalContent)) }
    }
}
