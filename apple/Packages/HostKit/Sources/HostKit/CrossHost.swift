import Foundation
import Observation
import os
import GudoCore

// Agents reaching other hosts (docs/security/proposals/cross-host-agents.md): this device relays
// an agent's call from one host to another it is paired with as owner, once the owner turned
// the pair on and said yes. The rules live in the core (`CrossHostRelay`); this keeps the
// owner's switches, follows the hosts and shows the requests.

/// The relay half of `GudoCore.CrossHostRelay`, so the session can be tested with a fake.
nonisolated public protocol CrossHostRelayAPI: AnyObject, Sendable {
    func addOwnerHost(id: String, name: String, client: DaemonClient)
    func addGuestHost(id: String, name: String)
    func addSshHost(id: String, name: String)
    func addUnreachedHost(id: String, name: String)
    func removeHost(id: String)
    func setPair(from: String, to: String, enabled: Bool)
    func endAllows(from: String, to: String)
    func answer(from: String, requestId: UInt64, choice: CrossHostChoice)
}

extension CrossHostRelay: CrossHostRelayAPI {}

/// What the relay said, in order.
nonisolated public enum CrossHostUpdate: Sendable {
    case card(CrossHostCard)
    case closed(from: String, requestId: UInt64)
    case standing([StandingAllow])
}

nonisolated final class CrossHostRelayListener: CrossHostListener {
    private let handler: @Sendable (CrossHostUpdate) -> Void

    init(_ handler: @escaping @Sendable (CrossHostUpdate) -> Void) {
        self.handler = handler
    }

    func onCard(card: CrossHostCard) { handler(.card(card)) }
    func onCardClosed(from: String, requestId: UInt64) { handler(.closed(from: from, requestId: requestId)) }
    func onStanding(allows: [StandingAllow]) { handler(.standing(allows)) }
}

/// "Agents on `from` may reach `to`": one direction of one pair of hosts.
nonisolated public struct HostPair: Hashable, Codable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// A request on screen: an agent on one host asking to act on another.
nonisolated public struct CrossHostRequestInfo: Identifiable, Hashable, Sendable {
    public var id: String { "\(from)/\(requestId)" }
    public var from: String
    public var requestId: UInt64
    /// `Claude`.
    public var agent: String
    public var fromName: String
    public var to: String
    public var toName: String
    /// Exactly what it would do there, from its arguments: `run $ npm test`.
    public var action: String
    public var isRead: Bool
    /// A guest drives the asking pane.
    public var guestDriving: String?
    public var expires: Date

    public init(
        from: String, requestId: UInt64, agent: String, fromName: String, to: String, toName: String,
        action: String, isRead: Bool = false, guestDriving: String? = nil, expires: Date = .distantFuture
    ) {
        self.from = from
        self.requestId = requestId
        self.agent = agent
        self.fromName = fromName
        self.to = to
        self.toName = toName
        self.action = action
        self.isRead = isRead
        self.guestDriving = guestDriving
        self.expires = expires
    }

    init(_ card: CrossHostCard) {
        self.init(
            from: card.from, requestId: card.requestId, agent: card.agent, fromName: card.fromName, to: card.to,
            toName: card.toName, action: card.action, isRead: card.verb == .read, guestDriving: card.guestDriving,
            expires: Date(timeIntervalSince1970: Double(card.expiresAtMs) / 1000))
    }

    /// "Claude on mac wants to reach ops".
    public var headline: String { "\(agent) on \(fromName) wants to reach \(toName)" }

    /// What the card says under the headline: the exact action, and what a yes lets through.
    public var detail: String {
        let reads = isRead ? " What it reads there goes to the agent and its model provider." : ""
        let guest = guestDriving.map { " Asked while \($0) is driving the agent." } ?? ""
        return "It wants to \(action) on \(toName).\(reads)\(guest)"
    }
}

/// An agent's standing yes on another host.
nonisolated public struct StandingAllowInfo: Identifiable, Hashable, Sendable {
    public var id: String { "\(from)/\(paneId)/\(to)" }
    public var from: String
    public var fromName: String
    public var to: String
    public var toName: String
    public var paneId: UInt64
    public var agent: String
    /// Everything; else reads after an "Allow once".
    public var all: Bool

    public init(from: String, fromName: String, to: String, toName: String, paneId: UInt64, agent: String, all: Bool) {
        self.from = from
        self.fromName = fromName
        self.to = to
        self.toName = toName
        self.paneId = paneId
        self.agent = agent
        self.all = all
    }

    init(_ allow: StandingAllow) {
        self.init(from: allow.from, fromName: allow.fromName, to: allow.to, toName: allow.toName,
                  paneId: allow.paneId, agent: allow.agent, all: allow.all)
    }

    /// "Claude on mac may do anything on ops until its pane closes".
    public var summary: String {
        let what = all ? "may do anything" : "may read"
        return "\(agent) on \(fromName) \(what) on \(toName) until its pane closes"
    }
}

/// How the device reaches one of its hosts, for the relay.
public enum CrossHostLink: Equatable {
    case owner(DaemonClient)
    case unreached
    case guest
    case ssh

    public static func == (left: Self, right: Self) -> Bool {
        switch (left, right) {
        case (.owner(let one), .owner(let other)): one === other
        case (.unreached, .unreached), (.guest, .guest), (.ssh, .ssh): true
        default: false
        }
    }
}

public struct CrossHostMember: Equatable {
    public var id: String
    public var name: String
    public var link: CrossHostLink

    public init(id: String, name: String, link: CrossHostLink) {
        self.id = id
        self.name = name
        self.link = link
    }
}

/// The owner's switches, the requests waiting for them and the standing yeses.
@MainActor
@Observable
public final class CrossHostSession {
    /// Requests waiting for an answer, oldest first.
    public private(set) var requests: [CrossHostRequestInfo] = []
    public private(set) var allows: [StandingAllowInfo] = []
    /// The pairs turned on. Off by default; each direction on its own.
    public private(set) var pairs: Set<HostPair>

    @ObservationIgnored private var relay: (any CrossHostRelayAPI)?
    @ObservationIgnored private var members: [String: CrossHostMember] = [:]
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    public static let pairsKey = "crossHost.pairs"
    private static let log = Logger(subsystem: Log.subsystem, category: "cross-host")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.data(forKey: Self.pairsKey)).flatMap { try? JSONDecoder().decode([HostPair].self, from: $0) }
        pairs = Set(saved ?? [])
    }

    /// Starts relaying through `make`'s relay (the core's by default).
    public func start(_ make: (CrossHostListener) -> any CrossHostRelayAPI = { CrossHostRelay(listener: $0) }) {
        guard relay == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: CrossHostUpdate.self)
        let relay = make(CrossHostRelayListener { continuation.yield($0) })
        self.relay = relay
        for pair in pairs { relay.setPair(from: pair.from, to: pair.to, enabled: true) }
        pump = Task { [weak self] in
            for await update in stream {
                self?.apply(update)
            }
        }
    }

    /// The hosts as they are now: added, replaced when their connection changed, removed.
    public func sync(_ hosts: [CrossHostMember]) {
        guard let relay else { return }
        let ids = Set(hosts.map(\.id))
        for id in members.keys where !ids.contains(id) {
            relay.removeHost(id: id)
            members[id] = nil
        }
        for host in hosts where members[host.id] != host {
            switch host.link {
            case .owner(let client): relay.addOwnerHost(id: host.id, name: host.name, client: client)
            case .unreached: relay.addUnreachedHost(id: host.id, name: host.name)
            case .guest: relay.addGuestHost(id: host.id, name: host.name)
            case .ssh: relay.addSshHost(id: host.id, name: host.name)
            }
            members[host.id] = host
        }
        let known = pairs.filter { ids.contains($0.from) && ids.contains($0.to) }
        if known != pairs, !members.isEmpty { save(known) }
    }

    public func isEnabled(from: String, to: String) -> Bool {
        pairs.contains(HostPair(from: from, to: to))
    }

    /// Turns a pair on or off. Off ends every standing yes for it at once.
    public func setEnabled(_ enabled: Bool, from: String, to: String) {
        var changed = pairs
        if enabled { changed.insert(HostPair(from: from, to: to)) } else { changed.remove(HostPair(from: from, to: to)) }
        guard changed != pairs else { return }
        save(changed)
        relay?.setPair(from: from, to: to, enabled: enabled)
        Self.log.info("agents on \(from, privacy: .public) \(enabled ? "may" : "may no longer", privacy: .public) reach \(to, privacy: .public)")
    }

    /// Ends the standing yeses agents on `from` hold for `to`; the pair stays on and asks again.
    public func endAllows(from: String, to: String) {
        relay?.endAllows(from: from, to: to)
    }

    public func allows(from: String, to: String) -> [StandingAllowInfo] {
        allows.filter { $0.from == from && $0.to == to }
    }

    public func answer(_ request: CrossHostRequestInfo, _ choice: CrossHostChoice) {
        requests.removeAll { $0.id == request.id }
        relay?.answer(from: request.from, requestId: request.requestId, choice: choice)
    }

    /// Applies one update (public so previews and tests can drive the session without a relay).
    public func apply(_ update: CrossHostUpdate) {
        switch update {
        case .card(let card):
            let request = CrossHostRequestInfo(card)
            requests.removeAll { $0.id == request.id }
            requests.append(request)
        case .closed(let from, let requestId):
            requests.removeAll { $0.from == from && $0.requestId == requestId }
        case .standing(let list):
            allows = list.map(StandingAllowInfo.init)
        }
    }

    private func save(_ changed: Set<HostPair>) {
        pairs = changed
        let sorted = changed.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        defaults.set(try? JSONEncoder().encode(sorted), forKey: Self.pairsKey)
    }
}

extension CrossHostSession {
    /// The relay's view of `hosts`: owner hosts with their live connection (or unreached), guests
    /// and plain SSH hosts by name. Opens a connection to each host in a pair that is on, so
    /// requests reach the device and calls reach their host while the app runs.
    public func follow(_ hosts: HostsModel) {
        let members = withObservationTracking {
            for pair in pairs {
                for id in [pair.from, pair.to] where hosts.connection(id) == nil && hosts.record(id) != nil {
                    _ = try? hosts.open(id)
                }
            }
            return hosts.records.map { record in
                CrossHostMember(id: record.id, name: record.name, link: Self.link(record, hosts.connection(record.id)))
            }
        } onChange: { [weak self, weak hosts] in
            Task { @MainActor in
                guard let self, let hosts else { return }
                self.follow(hosts)
            }
        }
        sync(members)
    }

    static func link(_ record: HostRecord, _ connection: (any HostConnection)?) -> CrossHostLink {
        switch record.kind {
        case .ssh: return .ssh
        case .daemon where record.isGuest: return .guest
        case .daemon:
            guard let daemon = connection as? DaemonConnection, daemon.status.isLive,
                  let client = daemon.client as? DaemonClient
            else { return .unreached }
            return .owner(client)
        }
    }
}
