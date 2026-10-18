import Foundation
import Synchronization
import Testing
import UnnamedCore

/// Saves known_hosts text the way the app would (Keychain), here in memory.
final class SavedHosts: KnownHostsListener {
    let text = Mutex<String?>(nil)
    func changed(text: String) { self.text.withLock { $0 = text } }
}

@Suite struct OfflineTests {
    @Test func keysRoundTrip() throws {
        let key = try generateEd25519Key(comment: "ipad")
        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(key.publicKey.hasSuffix(" ipad"))
        #expect(!privateKeyIsEncrypted(pem: key.privateKey))
        let info = try inspectPrivateKey(pem: key.privateKey)
        #expect(info.fingerprint == key.fingerprint)
        #expect(info.algorithm == "ssh-ed25519")
        #expect(throws: SshError.self) { try inspectPrivateKey(pem: Data("nope".utf8)) }
        #expect(generateDeviceKey().count == 32)
    }

    @Test func sshConfigAndDestinations() throws {
        let config = try SshConfigFile.parse(
            text: """
            Host box db *.corp
              HostName 10.0.0.5
              User me
              ProxyJump admin@bastion:2222
            Host bastion
              IdentityFile ~/.ssh/bastion
            """,
            home: "/home/me"
        )
        #expect(config.hostAliases() == ["box", "db", "bastion"])
        let target = try config.target(destination: "box", defaultUser: "nobody")
        #expect(target.host == SshHostSpec(host: "10.0.0.5", port: 22, user: "me", hostKeyAlias: nil))
        #expect(target.jumps == [SshHostSpec(host: "bastion", port: 2222, user: "admin", hostKeyAlias: nil)])
        #expect(config.resolve(alias: "bastion").identityFiles == ["/home/me/.ssh/bastion"])
        #expect(config.resolve(alias: "box").proxyJump == ["admin@bastion:2222"])

        let destination = try parseSshDestination(text: "me@[::1]:2200")
        #expect(destination == SshDestination(user: "me", host: "::1", port: 2200))
        #expect(throws: SshError.self) { try parseSshDestination(text: "@host") }
    }

    @Test func knownHostsPersistThroughTheListener() throws {
        let saved = SavedHosts()
        let store = KnownHostsStore(text: "", listener: saved)
        let key = try inspectPrivateKey(pem: generateEd25519Key(comment: "host").privateKey).publicKey
        #expect(try store.check(host: "box", port: 22, publicKey: key) == .unknown)
        try store.add(host: "box", port: 2222, publicKey: key)
        #expect(try store.check(host: "box", port: 2222, publicKey: key) == .trusted)
        #expect(saved.text.withLock { $0 } == store.toText())
        #expect(try store.remove(host: "box", port: 2222) == 1)
        #expect(saved.text.withLock { $0 } == "")
    }

    @Test func badTicketsAreTypedErrors() {
        #expect(throws: ClientError.self) {
            try DaemonClient.connect(
                ticket: "not a ticket",
                config: ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: true),
                listener: Discard()
            )
        }
    }

    /// FFI cost of one `PaneBytes` event: Rust event → UniFFI enum → buffer → Swift enum
    /// with `Data`, through the callback interface.
    @Test func paneBytesCrossingCost() {
        for size in [64, 4096, 65536] {
            let count: UInt32 = size >= 65536 ? 20_000 : 100_000
            let discard = benchPanaBytesSample(Discard(), count: count, size: size)
            let touch = Touch()
            let touched = benchPanaBytesSample(touch, count: count, size: size)
            #expect(touch.bytes == Int(count) * size)
            print(
                "PaneBytes \(size) B: \(discard) ns/event across FFI (no-op listener),"
                    + " \(touched) ns/event reading the payload"
            )
        }
    }
}

/// Nanoseconds per event spent crossing the boundary (FFI path minus the Rust-only path).
private func benchPanaBytesSample(_ listener: ClientEventListener, count: UInt32, size: Int) -> Double {
    let result = benchPaneBytes(listener: listener, count: count, size: UInt32(size))
    return (Double(result.ffiNs) - Double(result.rustNs)) / Double(result.events)
}

@Suite(.serialized) struct DaemonTests {
    /// Connect by ticket to a locally spawned daemon, attach, type, see the echo.
    @Test func connectAttachEcho() async throws {
        let daemon = try LocalDaemon()
        let ticket = try await daemon.ticket()
        let events = Recorder()
        let client = try DaemonClient.connect(
            ticket: ticket,
            config: ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: true),
            listener: events
        )
        let pane = try await attachFirstPane(client, events)

        client.sendInput(paneId: pane, data: Data("echo ffi-$((6*7))\r".utf8))
        try await events.wait("echo") { _ in
            client.paneText(paneId: pane).flatMap { $0.contains("ffi-42") ? true : nil }
        }

        // The same through semantic input: a paste, then Enter as a key event (GhosttyKey
        // ENTER is 58 in the pinned libghostty-vt's key table).
        client.sendPaste(paneId: pane, text: "echo paste-$((7*7))")
        client.sendKey(paneId: pane, key: KeyEvent(key: 58, mods: 0, action: .press))
        try await events.wait("paste echo") { _ in
            client.paneText(paneId: pane).flatMap { $0.contains("paste-49") ? true : nil }
        }

        // Layout ops and RPCs answer with their ids.
        let opId = client.op(op: .split(paneId: pane, axis: .horizontal, launch: .shell(cwd: nil)))
        let outcome = try await events.wait("split result") { all in
            all.lazy.compactMap {
                if case let .opResult(id, outcome) = $0, id == opId { outcome } else { nil }
            }.first
        }
        guard case .paneCreated = outcome else { throw TestError("split: \(outcome)") }
        let searchId = client.search(
            paneId: pane, query: SearchQuery(pattern: "ffi-42", mode: .plain, case: .sensitive),
            cursor: 0, limit: 10
        )
        let page = try await events.wait("search result") { all in
            all.lazy.compactMap {
                if case let .searchResult(id, _, page, _) = $0, id == searchId { page } else { nil }
            }.first
        }
        #expect(page.total >= 1)
        #expect(client.stats().connections == 1)
    }

    /// Bytes and snapshots arrive without a Rust-side mirror too (the app feeds its own VT).
    @Test func eventsWithoutMirror() async throws {
        let daemon = try LocalDaemon()
        let events = Recorder()
        let client = try DaemonClient.connect(
            ticket: try await daemon.ticket(),
            config: ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: false),
            listener: events
        )
        let pane = try await attachFirstPane(client, events)
        client.sendInput(paneId: pane, data: Data("echo raw-$((5*5))\r".utf8))
        try await events.wait("raw echo") { _ in events.output(of: pane).contains("raw-25") ? true : nil }
        #expect(client.paneText(paneId: pane) == nil)
        let snapshot = events.all.contains { if case .paneSnapshot = $0 { true } else { false } }
        #expect(snapshot)
    }
}
