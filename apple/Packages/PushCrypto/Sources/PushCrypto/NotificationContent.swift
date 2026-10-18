import CryptoKit
import Foundation
import UserNotifications

/// What a Notification Service Extension does with a relay push, in one call:
///
/// ```swift
/// override func didReceive(_ request: UNNotificationRequest,
///                          withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
///     let content = PushContent.decrypt(request.content,
///                                       deviceKey: try? Keychain.pushKey(),
///                                       isPairedDaemon: Hosts.isPaired)
///     handler(content)
/// }
/// ```
///
/// The relay sends `{"aps": {..., "mutable-content": 1}, "s": <sealed>, "v": 1}` with a
/// placeholder alert. On success the title, subtitle (host), body, category, thread and
/// interruption level come from the decrypted payload, and `userInfo["push"]` holds the
/// decrypted JSON for the action handler. On any failure the placeholder stays.
public enum PushContent {
    /// `userInfo` key of the sealed payload.
    public static let sealedKey = "s"
    /// `userInfo` key the decrypted payload JSON is stored under.
    public static let payloadKey = "push"

    public static func decrypt(
        _ content: UNNotificationContent,
        deviceKey: Curve25519.KeyAgreement.PrivateKey?,
        isPairedDaemon: (String) -> Bool
    ) -> UNNotificationContent {
        guard let deviceKey,
            let sealed = content.userInfo[sealedKey] as? String,
            let opened = try? PushCrypto.open(sealed, deviceKey: deviceKey),
            let note = try? opened.notification(),
            isPairedDaemon(note.daemon),
            let mutable = content.mutableCopy() as? UNMutableNotificationContent
        else { return content }
        apply(note, json: opened.json, to: mutable)
        return mutable
    }

    /// Fills `content` from a decrypted notification.
    public static func apply(
        _ note: PushNotification,
        json: Data,
        to content: UNMutableNotificationContent
    ) {
        content.title = note.title
        content.subtitle = note.host
        content.body = note.body
        // The category comes from the signed payload, not from the relay.
        content.categoryIdentifier = note.kind.categoryIdentifier
        content.threadIdentifier = note.daemon
        switch note.kind {
        case .approval, .blocked:
            content.interruptionLevel = .timeSensitive
        case .done, .failed, .command:
            content.interruptionLevel = .active
        }
        var info = content.userInfo
        info.removeValue(forKey: sealedKey)
        info[payloadKey] = String(decoding: json, as: UTF8.self)
        content.userInfo = info
    }

    /// The decrypted notification stored by ``decrypt(_:deviceKey:isPairedDaemon:)``, for the
    /// action handler (`userNotificationCenter(_:didReceive:)`).
    public static func payload(from userInfo: [AnyHashable: Any]) -> PushNotification? {
        guard let json = userInfo[payloadKey] as? String else { return nil }
        return try? JSONDecoder().decode(PushNotification.self, from: Data(json.utf8))
    }
}
