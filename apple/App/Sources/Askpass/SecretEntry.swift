import Foundation
import HostKit
import Observation
import GudoCore

/// The app's saved-password vault ("Remember in Keychain"), shared by every window.
@MainActor
enum AskpassVaultStore {
    static var shared: any AskpassVault = {
        if LaunchOptions.mock || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return MemoryAskpassVault()
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "app"
        return AskpassVaults.appDefault(bundleId: AppData.isIsolated ? bundleId + ".test" : bundleId)
    }()

    /// Whether this build can remember passwords, probed once.
    static var isAvailable: Bool {
        if let cached = availability { return cached }
        let available = shared.isAvailable
        availability = available
        return available
    }

    private static var availability: Bool?

    /// Keys whose saved password was just sent: if the same question comes back as a retry,
    /// the saved password is wrong and is forgotten.
    static var recentlyUsed: [AskpassVaultKey: ContinuousClock.Instant] = [:]
}

/// One secure prompt being answered: an askpass request (`SecretPrompt`) or a password prompt
/// the terminal shows itself (`DetectedPrompt`). Holds the typed secret only until it is sent.
@MainActor
@Observable
final class SecretEntry {
    enum Target {
        case askpass(SecretPrompt)
        case detected(DetectedPrompt)
    }

    let target: Target
    let copy: AskpassCopy
    let key: AskpassVaultKey
    /// What the user typed; cleared as soon as it is sent.
    var secret = ""
    /// Save the answer in the Keychain (opt-in, per host and prompt).
    var remember = false
    private(set) var isSending = false
    /// Why the last attempt failed, to show under the field.
    private(set) var failure: String?
    /// A saved password exists for this host and prompt.
    private(set) var hasSaved: Bool
    /// The saved password was just forgotten because it did not work.
    private(set) var forgotSaved = false

    @ObservationIgnored private let session: AskpassSession
    @ObservationIgnored private let vault: any AskpassVault
    @ObservationIgnored private let vaultAvailable: Bool

    init(target: Target, hostId: String, session: AskpassSession, vault: any AskpassVault, vaultAvailable: Bool) {
        self.target = target
        self.session = session
        self.vault = vault
        self.vaultAvailable = vaultAvailable
        switch target {
        case .askpass(let prompt): copy = AskpassCopy(prompt: prompt)
        case .detected(let detected): copy = AskpassCopy(detected: detected)
        }
        key = AskpassVaultKey(host: hostId, kind: copy.kind, prompt: copy.fieldLabel)
        // No one-tap saved password while a guest drives: their command may be what asks.
        hasSaved = vaultAvailable && !copy.echo && copy.guestNotice == nil && vault.contains(key)
        if case .askpass(let prompt) = target, prompt.retry, hasSaved,
           let used = AskpassVaultStore.recentlyUsed[key], used.duration(to: .now) < .seconds(60) {
            // The saved password went out and the same question came straight back.
            try? vault.remove(key)
            AskpassVaultStore.recentlyUsed[key] = nil
            hasSaved = false
            forgotSaved = true
        }
    }

    /// Whether "Remember in Keychain" is offered.
    var canRemember: Bool { vaultAvailable && !copy.echo }

    /// The prompt says the last answer was wrong.
    var isRetry: Bool {
        if case .askpass(let prompt) = target { return prompt.retry }
        return false
    }

    var canSend: Bool { !isSending && (copy.echo || !secret.isEmpty) }

    /// Sends what was typed. Returns true when the card can close.
    func send() async -> Bool {
        guard canSend else { return false }
        let value = secret
        secret = ""
        let ok = await deliver(value)
        if ok, remember, canRemember {
            do {
                try vault.save(value, for: key)
            } catch {
                // The answer went through; only remembering failed. Say so, but let it close.
                failure = "Couldn't save to the Keychain: \(error.localizedDescription)"
            }
        }
        return ok
    }

    /// Sends the saved password after Face ID / Touch ID. Returns true when the card can close.
    func sendSaved() async -> Bool {
        do {
            let value = try await vault.read(key, reason: "Use the saved password for \(copy.kind)")
            let ok = await deliver(value)
            if ok { AskpassVaultStore.recentlyUsed[key] = .now }
            return ok
        } catch AskpassVaultError.cancelled {
            return false
        } catch AskpassVaultError.notFound {
            hasSaved = false
            return false
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    /// Declines (askpass) or just closes (detected prompt; the terminal keeps asking).
    func cancel() async {
        secret = ""
        if case .askpass(let prompt) = target { await session.cancel(prompt) }
    }

    private func deliver(_ value: String) async -> Bool {
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            switch target {
            case .askpass(let prompt): try await session.answer(prompt, secret: value)
            case .detected(let detected): try await session.typeSecret(value, into: detected.paneId)
            }
            return true
        } catch AskpassError.Gone {
            // Someone else answered, or the program gave up: nothing left to do here.
            return true
        } catch {
            failure = askpassMessage(error)
            return false
        }
    }
}
