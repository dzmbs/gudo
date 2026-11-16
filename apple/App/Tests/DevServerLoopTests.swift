import Foundation
import GudoCore
import HostKit
import Network
import Synchronization
import XCTest
@testable import App

/// This Mac's helper shares this device's loopback: a request to one of its ports reaches
/// whatever listens there, never the app's own router and back into the host's forward.
@MainActor
final class DevServerLoopTests: XCTestCase {
    /// The sign-in sheet's watch probes the host's callback port through the host's forward. With
    /// the program gone, that is one connection to an empty port, not a chain of them.
    func testAProbeOfThisMacsSignInPortMakesOneHop() async throws {
        let port: UInt16 = 48_340
        let hostId = "this-mac-loop"
        let thisMac = try await ThisMacClient.start(serving: port)
        defer { thisMac.stop() }
        let routing = DevServerRouting()
        routing.isThisDevice = { $0 == hostId }

        _ = try? await routing.claimSignIn(port: port, hostId: hostId, client: { thisMac }, onRequest: { _ in })
        let forwardPort = try thisMac.forward(localPort: 0, target: .tcp(port: port))
        _ = await HostPortProbe.answers(localPort: forwardPort)
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(thisMac.hops, 1, "the probe reached the host's port once and nothing forwarded it back")
        await routing.forgetHost(hostId)
    }
}

/// A daemon client for This Mac whose forward is real: each connection to it opens one to
/// `127.0.0.1:<port>` here, as the helper does.
nonisolated final class ThisMacClient: FakeWorkspaceClient, @unchecked Sendable {
    private let listener: NWListener
    private let target: UInt16
    private let queue = DispatchQueue(label: "this-mac-forward")
    private let accepted = Mutex(0)
    private(set) var forwardPort: UInt16 = 0

    var hops: Int { accepted.withLock { $0 } }

    private init(listener: NWListener, target: UInt16) {
        self.listener = listener
        self.target = target
        super.init()
    }

    static func start(serving target: UInt16) async throws -> ThisMacClient {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let client = ThisMacClient(listener: try NWListener(using: parameters), target: target)
        client.listener.newConnectionHandler = { [client] connection in client.relay(connection) }
        client.forwardPort = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            client.listener.stateUpdateHandler = { [listener = client.listener] state in
                let result: Result<UInt16, any Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let result, resumed.withLock({ wasResumed in defer { wasResumed = true }; return !wasResumed }) else { return }
                continuation.resume(with: result)
            }
            client.listener.start(queue: client.queue)
        }
        return client
    }

    func stop() { listener.cancel() }

    override func forward(localPort: UInt16, target: ForwardTarget) throws -> UInt16 {
        state.withLock { $0.forwards.append(ForwardInfo(localPort: forwardPort, target: target)) }
        return forwardPort
    }

    private func relay(_ client: NWConnection) {
        accepted.withLock { $0 += 1 }
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Self.copy(from: client, to: upstream)
                Self.copy(from: upstream, to: client)
            case .failed, .waiting:
                upstream.cancel()
                client.cancel()
            default: break
            }
        }
        client.start(queue: queue)
        upstream.start(queue: queue)
    }

    private static func copy(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { _ in copy(from: source, to: sink) })
            } else if isComplete || error != nil {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            } else {
                copy(from: source, to: sink)
            }
        }
    }
}
