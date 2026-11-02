import Foundation
import Observation
import Synchronization
import GudoCore

/// Host-key decisions the user has to make: trust a new host's key
/// (TOFU), or, after a key change, replace the record. The SSH core asks on a blocking thread
/// and waits; the UI shows `pending` and calls `answer`.
@MainActor
@Observable
public final class HostKeyPrompts {
    public struct Prompt: Identifiable, Sendable {
        public let id = UUID()
        public let host: String
        public let algorithm: String
        public let fingerprint: String
        /// Set when the host presented a different key than the one on record.
        public let expected: [String]?

        public var isChange: Bool { expected != nil }
    }

    /// The question on screen, if any (one at a time; others wait behind it).
    public private(set) var pending: Prompt?
    /// Trust first-contact keys without asking (UI tests). Changed keys are still refused.
    public var trustNewHostsAutomatically = false

    @ObservationIgnored private var queue: [(Prompt, (Bool) -> Void)] = []

    public init() {}

    public func answer(_ trust: Bool) {
        guard !queue.isEmpty else { return }
        let (_, reply) = queue.removeFirst()
        pending = queue.first?.0
        reply(trust)
    }

    func ask(_ prompt: Prompt, reply: @escaping (Bool) -> Void) {
        if trustNewHostsAutomatically, !prompt.isChange { return reply(true) }
        queue.append((prompt, reply))
        if pending == nil { pending = prompt }
    }

    /// The delegate to hand to `HostKeyPolicy.ask`.
    public nonisolated func delegate() -> any HostKeyDelegate {
        PromptDelegate(prompts: self)
    }
}

/// Bridges the core's blocking host-key callbacks to `HostKeyPrompts`.
nonisolated private final class PromptDelegate: HostKeyDelegate {
    private let prompts: HostKeyPrompts
    /// No answer within this long counts as "don't trust".
    private static let timeout = DispatchTimeInterval.seconds(300)

    init(prompts: HostKeyPrompts) {
        self.prompts = prompts
    }

    func trustNewHost(key: HostKeyInfo) -> Bool {
        ask(HostKeyPrompts.Prompt(host: key.host, algorithm: key.algorithm, fingerprint: key.fingerprint, expected: nil))
    }

    func trustChangedHost(key: HostKeyInfo, expected: [String]) -> Bool {
        ask(HostKeyPrompts.Prompt(host: key.host, algorithm: key.algorithm, fingerprint: key.fingerprint, expected: expected))
    }

    private func ask(_ prompt: HostKeyPrompts.Prompt) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let answer = Mutex(false)
        let prompts = prompts
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                prompts.ask(prompt) { trust in
                    answer.withLock { $0 = trust }
                    semaphore.signal()
                }
            }
        }
        guard semaphore.wait(timeout: .now() + Self.timeout) == .success else { return false }
        return answer.withLock { $0 }
    }
}

/// known_hosts persisted in the secret store (changes are saved as they happen).
nonisolated public enum KnownHosts {
    static let key = "known_hosts"

    public static func load(from secrets: any SecretStore) -> KnownHostsStore {
        let text = (try? secrets.string(for: key)) ?? ""
        return KnownHostsStore(text: text, listener: Saver(secrets: secrets))
    }

    private final class Saver: KnownHostsListener {
        let secrets: any SecretStore
        init(secrets: any SecretStore) { self.secrets = secrets }
        func changed(text: String) { try? secrets.set(text, for: KnownHosts.key) }
    }
}
