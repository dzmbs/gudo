import Foundation
import os
import UnnamedCore

// Push plumbing (docs/PUSH.md): the device's sealing key, relay registration per daemon, and
// the lock-screen answer on a one-shot connection. Registration only runs when the app has an
// APNs token, which needs the push entitlement (a paid team); without it nothing here is
// called and local notifications cover a backgrounded app.

/// The push half of `DaemonClient`.
nonisolated public protocol PushClientAPI: AnyObject, Sendable {
    func pushRegister(registration: PushRegistration) async throws -> PushStatus
    func pushUnregister() async throws -> PushStatus
    func pushStatus() async throws -> PushStatus
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
    public func registerPush(
        hostId: String, apnsToken: Data, environment: ApnsEnvironment, prefs: PushPrefs,
        relayURL: URL = URL(string: defaultPushRelayUrl())!, session: URLSession = .shared
    ) async throws -> PushStatus {
        guard let record = record(hostId), let daemonId = record.daemonId, !record.isGuest,
              let connection = connection(hostId) as? DaemonConnection, let client = connection.push
        else { throw PushRegistrationError.notConnected }
        var request = URLRequest(url: relayURL.appending(path: "v1/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(pushRelayRegisterBody(apnsToken: apnsToken, environment: environment, daemonId: daemonId, kind: .alert).utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cap = object["cap"] as? String
        else {
            throw PushRegistrationError.relay(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let key = try pushSealKey()
        let status = try await client.pushRegister(registration: PushRegistration(
            cap: cap, sealKey: key.publicKey, relayUrl: relayURL.absoluteString, prefs: prefs, activityCap: nil))
        Self.pushLog.info("push registered host=\(hostId, privacy: .public) devices=\(status.devices)")
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
            ticket: ticket, config: ClientConfig(secretKey: key, relay: .default, mirrorVt: false),
            options: ConnectOptions(relayCaDer: []), token: token,
            decision: approve ? .approve : .deny, timeoutMs: UInt64(timeout / .milliseconds(1)))
    }
}
