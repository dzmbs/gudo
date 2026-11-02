import Foundation
@testable import HostKit
import Synchronization
import Testing
import GudoCore

/// What the fake daemon was asked (push calls) and whether it offers Live Activities.
nonisolated private enum PushLog {
    static let registrations = Mutex<[PushRegistration]>([])
    static let activityCaps = Mutex<[String?]>([])
    static let offers = Atomic<Bool>(true)
}

extension FakeClient: PushClientAPI {
    private static var status: PushStatus {
        PushStatus(enabled: true, relayUrl: "http://relay", registered: nil, devices: 1, lastError: nil)
    }

    func pushRegister(registration: PushRegistration) async throws -> PushStatus {
        PushLog.registrations.withLock { $0.append(registration) }
        return Self.status
    }

    func pushUnregister() async throws -> PushStatus { Self.status }
    func pushStatus() async throws -> PushStatus { Self.status }

    func pushActivity(cap: String?) async throws -> PushStatus {
        PushLog.activityCaps.withLock { $0.append(cap) }
        return Self.status
    }

    func offersLiveActivity() -> Bool { PushLog.offers.load(ordering: .relaxed) }
}

/// A push relay answering `/v1/register` with a capability naming the kind and token.
nonisolated private final class RelayStub: URLProtocol {
    static let bodies = Mutex<[[String: String]]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                if bytesRead <= 0 { break }
                body.append(buffer, count: bytesRead)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
        Self.bodies.withLock { $0.append(json) }
        let cap = "cap-\(json["kind"] ?? "?")-\(json["token"]?.prefix(4) ?? "")"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["cap": cap, "expires": 1]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayStub.self]
        return URLSession(configuration: config)
    }
}

/// Push registration with the relay and the daemon (docs/PUSH.md §2, §6): the alert
/// capability, the Live Activity push-to-start capability for daemons that offer it, and the
/// running activity's token handed over and withdrawn.
@MainActor
@Suite(.serialized) struct PushRegistrationTests {
    private func model() throws -> HostsModel {
        PushLog.registrations.withLock { $0.removeAll() }
        PushLog.activityCaps.withLock { $0.removeAll() }
        RelayStub.bodies.withLock { $0.removeAll() }
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        model.upsert(HostRecord(id: "d", name: "studio", kind: .daemon, daemonId: String(repeating: "ab", count: 32)))
        let connection = DaemonConnection(hostId: "d", ticket: "t") { _, listener in FakeClient(listener: listener) }
        try connection.connect()
        model.connections["d"] = connection
        return model
    }

    private let relay = URL(string: "http://relay.test")!

    @Test func registersAlertAndPushToStartCapabilities() async throws {
        let model = try model()
        PushLog.offers.store(true, ordering: .relaxed)
        _ = try await model.registerPush(
            hostId: "d", apnsToken: Data([0xAA, 0xBB, 0, 1, 2, 3, 4, 5]), environment: .sandbox, prefs: PushPrefs(approvals: true, blocked: true, done: true, failed: true, commands: true),
            activityStartToken: Data([0xCC, 0xDD, 0, 1, 2, 3, 4, 5]), relayURL: relay, session: RelayStub.session)
        let registration = try #require(PushLog.registrations.withLock { $0.last })
        #expect(registration.cap == "cap-alert-aabb")
        #expect(registration.activityCap == "cap-activity-ccdd")
        #expect(registration.sealKey.count == 32)
        let bodies = RelayStub.bodies.withLock { $0 }
        #expect(bodies.map { $0["daemon"] } == [String(repeating: "ab", count: 32), String(repeating: "ab", count: 32)])
        #expect(bodies.allSatisfy { $0["env"] == "sandbox" })

        // A daemon without Live Activities gets no activity capability (and no relay call).
        PushLog.offers.store(false, ordering: .relaxed)
        _ = try await model.registerPush(
            hostId: "d", apnsToken: Data([0xAA, 0xBB, 0, 1, 2, 3, 4, 5]), environment: .sandbox, prefs: PushPrefs(approvals: true, blocked: true, done: true, failed: true, commands: true),
            activityStartToken: Data([0xCC, 0xDD, 0, 1, 2, 3, 4, 5]), relayURL: relay, session: RelayStub.session)
        #expect(PushLog.registrations.withLock { $0.last?.activityCap } == nil)
        #expect(RelayStub.bodies.withLock { $0.count } == 3)
    }

    @Test func handsOverAndWithdrawsTheRunningActivity() async throws {
        let model = try model()
        PushLog.offers.store(true, ordering: .relaxed)
        let started = try await model.registerActivityToken(
            hostId: "d", token: Data([0xEE, 0xFF, 0, 1, 2, 3, 4, 5]), environment: .production, relayURL: relay, session: RelayStub.session)
        #expect(started != nil)
        #expect(RelayStub.bodies.withLock { $0.last?["kind"] } == "activity")
        #expect(RelayStub.bodies.withLock { $0.last?["env"] } == "production")
        _ = try await model.registerActivityToken(hostId: "d", token: nil, environment: .production, relayURL: relay, session: RelayStub.session)
        #expect(PushLog.activityCaps.withLock { $0 } == ["cap-activity-eeff", nil])

        PushLog.offers.store(false, ordering: .relaxed)
        let skipped = try await model.registerActivityToken(
            hostId: "d", token: Data([1, 2, 3, 4, 5, 6, 7, 8]), environment: .production, relayURL: relay, session: RelayStub.session)
        #expect(skipped == nil)
        #expect(PushLog.activityCaps.withLock { $0.count } == 2)
        await #expect(throws: PushRegistrationError.self) {
            try await model.registerActivityToken(hostId: "missing", token: nil, environment: .production)
        }
    }
}
