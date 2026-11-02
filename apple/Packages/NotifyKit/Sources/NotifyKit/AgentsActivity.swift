import CryptoKit
import Foundation
import PushCrypto

/// The agents Live Activity driven by the daemons' pushes: one activity for all agents of all
/// hosts. Each daemon pushes its own row, sealed to this device, as the
/// activity's content state; the widget opens it (`AgentsActivityReader`), keeps the other
/// hosts' latest rows in the shared app group, and shows the sum.
///
/// The content state stays sealed on the wire (APNs and the relay see ciphertext; a Live
/// Activity push never passes through the Notification Service Extension).
public struct AgentsActivityState: Codable, Hashable, Sendable {
    /// `push::ActivityState`, sealed (unpadded base64url).
    public var s: String
    public var v: Int

    public init(s: String, v: Int = 1) {
        self.s = s
        self.v = v
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// The ActivityKit attributes the relay names in a push-to-start (`attributes-type`
/// `AgentsActivityAttributes`, `attributes {"v": 1}`): nothing static but the version, so any
/// host may start it and every host updates it.
public struct AgentsActivityAttributes: ActivityAttributes {
    public typealias ContentState = AgentsActivityState
    public var v: Int

    public init(v: Int = 1) {
        self.v = v
    }
}
#endif

public struct AgentsBoard: Equatable, Sendable {
    public struct Host: Codable, Equatable, Sendable {
        /// The daemon's key, hex.
        public var daemon: String
        public var host: String
        public var running: UInt32
        public var blocked: UInt32
        public var done: UInt32
        public var headline: String
        /// Unix ms.
        public var at: UInt64

        public init(_ state: SealedActivityState) {
            daemon = state.daemon.lowercased()
            host = state.host
            running = state.running
            blocked = state.blocked
            done = state.done
            headline = state.headline
            at = state.at
        }

        public var isActive: Bool { running + blocked > 0 }

        public var board: AgentsBoard { AgentsBoard(rows: [self]) }
    }

    /// Hosts that have something to show, the most urgent first (needs you, working, done).
    public var hosts: [Host]

    public var running: UInt32 { hosts.reduce(0) { $0 + $1.running } }
    public var blocked: UInt32 { hosts.reduce(0) { $0 + $1.blocked } }
    public var done: UInt32 { hosts.reduce(0) { $0 + $1.done } }

    public var phase: AgentRunState.Phase {
        if blocked > 0 { return .blocked }
        if running > 0 { return .working }
        return .done
    }

    /// The most urgent host's.
    public var headline: String { hosts.first?.headline ?? "" }

    /// "1 needs you · 2 working · 3 done".
    public var summary: String {
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) needs you") }
        if running > 0 { parts.append("\(running) working") }
        if done > 0 { parts.append("\(done) done") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }

    init(rows: [Host]) {
        hosts = rows.filter { $0.isActive || $0.done > 0 }.sorted { lhs, rhs in
            if (lhs.blocked > 0) != (rhs.blocked > 0) { return lhs.blocked > 0 }
            if (lhs.running > 0) != (rhs.running > 0) { return lhs.running > 0 }
            return lhs.at > rhs.at
        }
    }
}

public struct AgentsActivityReader: Sendable {
    /// The device's sealing key (shared Keychain group; `nil` without the push entitlement).
    public var deviceKey: @Sendable () -> Curve25519.KeyAgreement.PrivateKey?
    /// Hex daemon ids.
    public var pairedDaemons: @Sendable () -> Set<String>
    /// Stored in the shared app group.
    public var loadRows: @Sendable () -> [AgentsBoard.Host]
    public var saveRows: @Sendable ([AgentsBoard.Host]) -> Void

    /// Another host's row is dropped once it is this old (its daemon stopped updating: gone
    /// offline, or its activity ended).
    public static let rowLifetime: TimeInterval = 20 * 60

    public init(
        deviceKey: @escaping @Sendable () -> Curve25519.KeyAgreement.PrivateKey?,
        pairedDaemons: @escaping @Sendable () -> Set<String>,
        loadRows: @escaping @Sendable () -> [AgentsBoard.Host],
        saveRows: @escaping @Sendable ([AgentsBoard.Host]) -> Void
    ) {
        self.deviceKey = deviceKey
        self.pairedDaemons = pairedDaemons
        self.loadRows = loadRows
        self.saveRows = saveRows
    }

    public static func shared(bundle: Bundle = .main) -> AgentsActivityReader {
        let store = SharedPushStore(bundle: bundle)
        return AgentsActivityReader(
            deviceKey: { store.sealKey() }, pairedDaemons: { store.pairedDaemons() },
            loadRows: { store.activityRows() }, saveRows: { store.setActivityRows($0) })
    }

    /// Nil when `state` doesn't open, isn't signed by a paired host, or has another format.
    public func board(for state: AgentsActivityState, now: Date = .now) -> AgentsBoard? {
        guard state.v == 1, let key = deviceKey(),
              let opened = try? PushCrypto.open(state.s, deviceKey: key),
              let row = try? opened.activity(),
              pairedDaemons().contains(row.daemon.lowercased())
        else { return nil }
        let fresh = AgentsBoard.Host(row)
        let cutoff = UInt64(max(0, now.timeIntervalSince1970 - Self.rowLifetime) * 1000)
        var rows = loadRows().filter { $0.daemon != fresh.daemon && $0.at >= cutoff }
        // An older push arriving late never replaces a newer row of the same host.
        if let kept = loadRows().first(where: { $0.daemon == fresh.daemon }), kept.at > fresh.at {
            rows.append(kept)
        } else {
            rows.append(fresh)
        }
        saveRows(rows)
        return AgentsBoard(rows: rows)
    }
}

extension SharedPushStore {
    static let activityRowsKey = "activity-rows"

    private var groupDefaults: UserDefaults? { appGroup.flatMap(UserDefaults.init(suiteName:)) }

    public func activityRows() -> [AgentsBoard.Host] {
        guard let data = groupDefaults?.data(forKey: Self.activityRowsKey) else { return [] }
        return (try? JSONDecoder().decode([AgentsBoard.Host].self, from: data)) ?? []
    }

    public func setActivityRows(_ rows: [AgentsBoard.Host]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        groupDefaults?.set(data, forKey: Self.activityRowsKey)
    }
}
