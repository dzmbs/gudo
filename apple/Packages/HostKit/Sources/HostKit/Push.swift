import Foundation
import os
import GudoCore

// Push plumbing (docs/PUSH.md): the device's sealing key, relay registration per daemon, and
// the lock-screen answer on a one-shot connection. Registration only runs when the app has an
// APNs token, which needs the push entitlement (a paid team); without it nothing here is
// called and local notifications cover a backgrounded app.

/// The push half of `DaemonClient`.
nonisolated public protocol PushClientAPI: AnyObject, Sendable {
    func pushRegister(registration: PushRegistration) async throws -> PushStatus
    func pushUnregister() async throws -> PushStatus
    func pushStatus() async throws -> PushStatus
    /// The running agents Live Activity's capability (nil: it ended).
    func pushActivity(cap: String?) async throws -> PushStatus
    /// The daemon sends the agents Live Activity.
    func offersLiveActivity() -> Bool
    /// Which agents this device wants pushed (after registering).
    func pushAgents(rules: [PushAgentRule]) async throws -> PushStatus
    /// The daemon takes per-agent rules.
    func offersPushAgents() -> Bool
}

extension DaemonClient: PushClientAPI {}

public enum PushRegistrationError: Error, LocalizedError {
    case relay(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .relay(let reason): "The push relay refused the registration: \(reason)"
        case .notConnected: "The host is not connected."
        }
    }
}

extension DaemonConnection {
    /// The connection's push requests (nil for fakes without them).
    public var push: (any PushClientAPI)? { pushClient }
}

extension HostsModel {
    static let pushLog = Logger(subsystem: Log.subsystem, category: "push")

    /// The device's X25519 sealing key: generated once, kept with the other secrets. The app
    /// copies the secret into the Keychain group its Notification Service Extension reads.
    public func pushSealKey() throws -> PushSealKey {
        if let secret = try secrets.data(for: "push-seal-key"), secret.count == 32 {
            return PushSealKey(secret: secret, publicKey: try pushSealPublicKey(secret: secret))
        }
        let fresh = generatePushSealKey()
        try secrets.set(fresh.secret, for: "push-seal-key")
        return fresh
    }

    /// Daemon ids of paired (owner) hosts, for the extension's "is this a host I paired?" check.
    public var pairedDaemonIds: Set<String> {
        Set(records.filter { $0.kind == .daemon && !$0.isGuest }.compactMap { $0.daemonId?.lowercased() })
    }

    /// Registers this device's APNs token with the relay for one connected daemon, then the
    /// capability and sealing key with the daemon. Re-run on every launch and token change.
    /// `activityStartToken` (ActivityKit push-to-start) lets the daemon start the agents Live
    /// Activity; it is sent only to daemons that offer Live Activities. `agentRules` go to
    /// daemons that take them (older ones push every agent as `prefs` say).
    public func registerPush(
        hostId: String, apnsToken: Data, environment: ApnsEnvironment, prefs: PushPrefs,
        agentRules: [PushAgentRule] = [], activityStartToken: Data? = nil,
        relayURL: URL = URL(string: defaultPushRelayUrl())!, session: URLSession = .shared
    ) async throws -> PushStatus {
        guard let record = record(hostId), let daemonId = record.daemonId, !record.isGuest,
              let connection = connection(hostId) as? DaemonConnection, let client = connection.push
        else { throw PushRegistrationError.notConnected }
        let relay = PushRelay(url: relayURL, session: session)
        let cap = try await cachedCapability(relay, token: apnsToken, environment: environment, daemonId: daemonId, kind: .alert)
        var activityCap: String?
        if let activityStartToken, client.offersLiveActivity() {
            activityCap = try await cachedCapability(relay, token: activityStartToken, environment: environment, daemonId: daemonId, kind: .activity)
        }
        let key = try pushSealKey()
        var status = try await client.pushRegister(registration: PushRegistration(
            cap: cap, sealKey: key.publicKey, relayUrl: relayURL.absoluteString, prefs: prefs, activityCap: activityCap))
        if client.offersPushAgents() {
            status = try await client.pushAgents(rules: agentRules)
        }
        Self.pushLog.info("push registered host=\(hostId, privacy: .public) devices=\(status.devices) activity=\(activityCap != nil)")
        return status
    }

    private func cachedCapability(
        _ relay: PushRelay, token: Data, environment: ApnsEnvironment, daemonId: String, kind: PushCapKind
    ) async throws -> String {
        let key = "\(relay.url.absoluteString)|\(daemonId)|\(token.base64EncodedString())|\(environment)|\(kind)"
        if let cap = pushCapabilities[key] { return cap }
        let cap = try await relay.capability(token: token, environment: environment, daemonId: daemonId, kind: kind)
        pushCapabilities[key] = cap
        return cap
    }

    /// Hands one connected daemon the running agents Live Activity's push token (through a
    /// relay capability bound to it), or `nil` once the activity ended: the daemon then sends
    /// its updates there. No-op (nil) for daemons without Live Activities.
    @discardableResult
    public func registerActivityToken(
        hostId: String, token: Data?, environment: ApnsEnvironment,
        relayURL: URL = URL(string: defaultPushRelayUrl())!, session: URLSession = .shared
    ) async throws -> PushStatus? {
        guard let record = record(hostId), let daemonId = record.daemonId, !record.isGuest,
              let connection = connection(hostId) as? DaemonConnection, let client = connection.push
        else { throw PushRegistrationError.notConnected }
        guard client.offersLiveActivity() else { return nil }
        var cap: String?
        if let token {
            cap = try await PushRelay(url: relayURL, session: session)
                .capability(token: token, environment: environment, daemonId: daemonId, kind: .activity)
        }
        let status = try await client.pushActivity(cap: cap)
        Self.pushLog.info("live activity token host=\(hostId, privacy: .public) running=\(cap != nil)")
        return status
    }

    /// Answers a push's approval on a one-shot connection signed with this device's key
    /// (the lock-screen Approve / Deny). `daemonId` picks the paired host and its ticket.
    public func sendPushDecision(daemonId: String, token: Data, approve: Bool, timeout: Duration = .seconds(8)) async throws -> Decided {
        guard let record = records.first(where: { $0.daemonId?.lowercased() == daemonId.lowercased() && !$0.isGuest }),
              let ticket = try secrets.string(for: record.ticketKey)
        else { throw HostError.missingSecret("pairing for this host") }
        let key = try DeviceIdentity.load(from: secrets)
        return try await sendPushAction(
            ticket: ticket, config: clientConfig(key, mirrorVt: false),
            options: relaySettings.connectOptions(askpass: false), token: token,
            decision: approve ? .approve : .deny, timeoutMs: UInt64(timeout / .milliseconds(1)))
    }
}

/// `POST <relay>/v1/register`: trades an APNs or ActivityKit token for a capability bound to
/// one daemon.
public struct PushRelay: Sendable {
    public var url: URL
    public var session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func capability(token: Data, environment: ApnsEnvironment, daemonId: String, kind: PushCapKind) async throws -> String {
        var request = URLRequest(url: url.appending(path: "v1/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(pushRelayRegisterBody(apnsToken: token, environment: environment, daemonId: daemonId, kind: kind).utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cap = object["cap"] as? String
        else {
            throw PushRegistrationError.relay(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return cap
    }
}
