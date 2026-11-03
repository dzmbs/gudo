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
/// placeholder alert. On success the title, subtitle (place and host), body, category, thread (per pane) and
/// interruption level come from the decrypted payload, and `userInfo["push"]` holds the
/// decrypted JSON (with the daemon's signature) for the action handler. On any failure the
/// placeholder stays.
///
/// Everything else in a push's `userInfo` came from the relay and is dropped, success or not:
/// the action handler must only ever see a payload this device opened and verified.
public enum PushContent {
    public static let sealedKey = "s"
    public static let payloadKey = "push"
    /// The daemon's signature over the payload JSON, base64.
    public static let signatureKey = "push-sig"

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
        else { return placeholder(content) }
        apply(note, opened: opened, to: mutable)
        return mutable
    }

    /// The relay's placeholder with only its `aps` kept: what to show when the payload cannot
    /// be opened (or the extension runs out of time).
    public static func placeholder(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        mutable.userInfo = trusted(content.userInfo)
        return mutable
    }

    static func trusted(_ userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        userInfo["aps"].map { ["aps": $0] } ?? [:]
    }

    public static func apply(
        _ note: PushNotification,
        opened: Opened,
        to content: UNMutableNotificationContent
    ) {
        content.title = note.title
        content.subtitle = [note.place, note.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = note.body
        // The category comes from the signed payload, not from the relay.
        content.categoryIdentifier = note.kind.categoryIdentifier
        content.threadIdentifier = "\(note.daemon).pane.\(note.pane)"
        switch note.kind {
        case .approval, .blocked:
            content.interruptionLevel = .timeSensitive
        case .done, .failed, .command:
            content.interruptionLevel = .active
        }
        var userInfo = trusted(content.userInfo)
        userInfo[payloadKey] = String(decoding: opened.json, as: UTF8.self)
        userInfo[signatureKey] = opened.signature.base64EncodedString()
        content.userInfo = userInfo
    }

    /// The decrypted notification stored by ``decrypt(_:deviceKey:isPairedDaemon:)``, for the
    /// action handler (`userNotificationCenter(_:didReceive:)`). Its daemon signature is checked
    /// again: a push without `mutable-content` skips the extension and arrives with whatever
    /// `userInfo` the relay chose.
    public static func payload(from userInfo: [AnyHashable: Any]) -> PushNotification? {
        guard let json = userInfo[payloadKey] as? String,
            let signature = (userInfo[signatureKey] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        return try? Opened(signature: signature, json: Data(json.utf8)).notification()
    }
}
