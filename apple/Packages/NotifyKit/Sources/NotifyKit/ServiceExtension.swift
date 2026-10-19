import CryptoKit
import Foundation
import PushCrypto
import Security
import UserNotifications

/// The Notification Service Extension's work, testable without the extension: open the sealed
/// payload with the device's X25519 key, check the daemon is a paired host and its signature,
/// then set title, subtitle, body, thread and category from the payload (never the relay's).
/// On any failure the relay's placeholder text stays.
public struct ServiceExtensionCore: Sendable {
    /// The device's sealing key (shared Keychain group; `nil` without the push entitlement).
    public var deviceKey: @Sendable () -> Curve25519.KeyAgreement.PrivateKey?
    /// Daemon ids (hex) of paired hosts (shared app group; empty without it).
    public var pairedDaemons: @Sendable () -> Set<String>

    public init(
        deviceKey: @escaping @Sendable () -> Curve25519.KeyAgreement.PrivateKey?,
        pairedDaemons: @escaping @Sendable () -> Set<String>
    ) {
        self.deviceKey = deviceKey
        self.pairedDaemons = pairedDaemons
    }

    /// The extension's store: the Keychain access group and app group named in its Info.plist
    /// (`PushKeychainGroup`, `PushAppGroup`), both set only when the build has the push
    /// entitlement.
    public static func shared(bundle: Bundle = .main) -> ServiceExtensionCore {
        let store = SharedPushStore(bundle: bundle)
        return ServiceExtensionCore(deviceKey: { store.sealKey() }, pairedDaemons: { store.pairedDaemons() })
    }

    public func process(_ content: UNNotificationContent) -> UNNotificationContent {
        let paired = pairedDaemons()
        return PushContent.decrypt(content, deviceKey: deviceKey()) { paired.contains($0.lowercased()) }
    }
}

/// What the app shares with its extensions when it has the push entitlement: the device's
/// sealing secret (Keychain, access group, `AfterFirstUnlock` so a locked phone can decrypt)
/// and the paired daemons (app group defaults). Without the entitlement both reads return
/// nothing and pushes keep the relay's placeholder.
public struct SharedPushStore: Sendable {
    public let keychainGroup: String?
    public let appGroup: String?
    static let service = "push-seal-key"
    static let pairedKey = "paired-daemons"

    public init(keychainGroup: String?, appGroup: String?) {
        self.keychainGroup = keychainGroup.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        self.appGroup = appGroup.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    public init(bundle: Bundle) {
        self.init(
            keychainGroup: bundle.object(forInfoDictionaryKey: "PushKeychainGroup") as? String,
            appGroup: bundle.object(forInfoDictionaryKey: "PushAppGroup") as? String)
    }

    /// Whether this build can share anything with the extension.
    public var isAvailable: Bool { keychainGroup != nil && appGroup != nil }

    private var defaults: UserDefaults? { appGroup.flatMap(UserDefaults.init(suiteName:)) }

    public func pairedDaemons() -> Set<String> {
        Set((defaults?.stringArray(forKey: Self.pairedKey) ?? []).map { $0.lowercased() })
    }

    public func setPairedDaemons(_ ids: Set<String>) {
        defaults?.set(ids.sorted(), forKey: Self.pairedKey)
    }

    private func query() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "device",
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let keychainGroup { query[kSecAttrAccessGroup as String] = keychainGroup }
        return query
    }

    public func sealKey() -> Curve25519.KeyAgreement.PrivateKey? {
        guard keychainGroup != nil else { return nil }
        var item = query()
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// Stores the sealing secret for the extension (the app, after `generatePushSealKey`).
    @discardableResult
    public func setSealKey(_ secret: Data) -> Bool {
        guard keychainGroup != nil else { return false }
        SecItemDelete(query() as CFDictionary)
        var item = query()
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
