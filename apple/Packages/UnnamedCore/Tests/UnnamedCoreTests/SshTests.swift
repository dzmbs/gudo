import Foundation
import Synchronization
import Testing
import UnnamedCore

/// The VM from scripts/ssh-test-vm.sh (`source target/ssh-test/env`).
private let sshEnv = ProcessInfo.processInfo.environment
private let sshHost = sshEnv["UN_SSH_TEST_HOST"].flatMap { $0.isEmpty ? nil : $0 }

/// Trusts every new host and records what it was asked.
final class TrustingDelegate: HostKeyDelegate {
    let asked = Mutex<[HostKeyInfo]>([])

    func trustNewHost(key: HostKeyInfo) -> Bool {
        asked.withLock { $0.append(key) }
        return true
    }

    func trustChangedHost(key: HostKeyInfo, expected: [String]) -> Bool { false }
}

/// Collects bootstrap progress.
final class Steps: BootstrapListener {
    let steps = Mutex<[BootstrapStep]>([])
    func onStep(step: BootstrapStep) { steps.withLock { $0.append(step) } }
}

/// The daemon builds to install: the app's bundle format (`cargo xtask build-hostd-linux`,
/// gzipped) if built, else the test VM's raw build.
private func hostdBinaries(keys: URL) -> HostdBinaries {
    func pick(_ arch: String) -> HostdBinary? {
        let candidates = [
            repoRoot.appending(path: "apple/build/hostd/unnamed-hostd-\(arch)-linux.gz"),
            sshEnv["UN_SSH_TEST_HOSTD"].map(URL.init(fileURLWithPath:)),
            keys.appending(path: "bin/unnamed-hostd-\(arch)-linux"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            .map { .file(path: $0.path) }
    }
    return HostdBinaries(linuxAarch64: pick("aarch64"), linuxX8664: pick("x86_64"))
}

@Suite(.serialized, .enabled(if: sshHost != nil, "set UN_SSH_TEST_HOST (scripts/ssh-test-vm.sh)"))
struct SshTests {
    /// Key auth → plain-SSH pane echo → bootstrap the daemon → pair by its ticket → echo.
    @Test func keyAuthPaneBootstrapPair() async throws {
        let host = try #require(sshHost)
        let user = sshEnv["UN_SSH_TEST_USER"] ?? "untest"
        let keys = URL(fileURLWithPath: try #require(sshEnv["UN_SSH_TEST_KEYS"]))
        let pem = try Data(contentsOf: keys.appending(path: "id_ed25519"))

        let saved = SavedHosts()
        let knownHosts = KnownHostsStore(text: "", listener: saved)
        let delegate = TrustingDelegate()
        let states = SshStateStream()
        let session = try SshSession.start(
            target: SshTarget(jumps: [], host: SshHostSpec(host: host, port: 22, user: user, hostKeyAlias: nil)),
            auth: [.keyData(pem: pem, passphrase: nil)],
            knownHosts: knownHosts,
            hostKeys: .ask(delegate: delegate),
            options: SshOptions(),
            listener: states
        )
        try await session.connected()
        #expect(delegate.asked.withLock { $0.count } == 1)
        #expect(saved.text.withLock { $0 }?.contains("ssh-ed25519") == true)
        if case .connected = session.state() {} else { Issue.record("state \(session.state())") }

        let uname = try await session.exec(command: "uname -s")
        #expect(String(decoding: uname.stdout, as: UTF8.self).hasPrefix("Linux"))
        #expect(uname.exitStatus == 0)

        // Plain-SSH pane: same events as a daemon pane.
        let paneEvents = Recorder()
        let pane = session.openPane(
            options: SshPaneOptions(paneId: 1 << 40, size: PaneSize(cols: 80, rows: 24)),
            listener: paneEvents
        )
        try await paneEvents.wait("ssh pane connected") { all in
            all.first { if case .connected = $0 { true } else { false } }
        }
        pane.sendInput(data: Data("echo ssh-$((6*7))\r".utf8))
        try await paneEvents.wait("ssh echo") { _ in
            paneEvents.output(of: pane.paneId()).contains("ssh-42") ? true : nil
        }
        pane.close()
        try await paneEvents.wait("pane closed") { all in
            all.first { if case .paneClosed = $0 { true } else { false } }
        }

        // Bootstrap the daemon over the same session, then pair with its ticket.
        let steps = Steps()
        let report = try await session.bootstrap(
            binaries: hostdBinaries(keys: keys), ticketMinutes: 5, waitSecs: 30, listener: steps
        )
        #expect(report.platform == .linuxAarch64 || report.platform == .linuxX8664)
        #expect(report.ticket.hasPrefix("unnamed://pair/"))
        #expect(steps.steps.withLock { $0.first } == .probing)
        print("bootstrap: \(report.action), \(report.service), steps \(steps.steps.withLock { $0 })")

        let events = Recorder()
        let client = try DaemonClient.connect(
            ticket: report.ticket,
            config: ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: true),
            listener: events
        )
        let daemonPane = try await attachFirstPane(client, events)
        client.sendInput(paneId: daemonPane, data: Data("echo paired-$((8*8))\r".utf8))
        try await events.wait("daemon echo over the bootstrap ticket") { _ in
            client.paneText(paneId: daemonPane).flatMap { $0.contains("paired-64") ? true : nil }
        }
        session.close()
    }

    /// A changed host key reaches the delegate; refusing it is a typed mismatch error.
    @Test func changedHostKeyIsAskedAndRefused() async throws {
        let host = try #require(sshHost)
        let user = sshEnv["UN_SSH_TEST_USER"] ?? "untest"
        let keys = URL(fileURLWithPath: try #require(sshEnv["UN_SSH_TEST_KEYS"]))
        let pem = try Data(contentsOf: keys.appending(path: "id_ed25519"))
        // Record a different (random) key for the host.
        let bogus = try inspectPrivateKey(pem: generateEd25519Key(comment: "").privateKey).publicKey
        let knownHosts = KnownHostsStore(text: "\(host) \(bogus)\n", listener: nil)
        let session = try SshSession.start(
            target: SshTarget(jumps: [], host: SshHostSpec(host: host, port: 22, user: user, hostKeyAlias: nil)),
            auth: [.keyData(pem: pem, passphrase: nil)],
            knownHosts: knownHosts,
            hostKeys: .ask(delegate: TrustingDelegate()),
            options: SshOptions(),
            listener: nil
        )
        do {
            try await session.connected()
            Issue.record("connected despite a changed host key")
        } catch let SshError.HostKeyMismatch(_, expected, actual) {
            #expect(expected.count == 1)
            #expect(actual.hasPrefix("SHA256:"))
        }
        session.close()
    }
}
