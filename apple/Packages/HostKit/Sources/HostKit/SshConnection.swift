import Foundation
import Observation
import os
import PaneLayout
import Synchronization
import TerminalCore
import GudoCore

/// A plain-SSH host (no daemon): one self-healing `SshSession` shared by every pane (one
/// channel each), and a local split layout. Also the connection the "Install helper"
/// bootstrap runs over.
@MainActor
@Observable
public final class SshConnection: HostConnection {
    public let hostId: String
    public private(set) var status: ConnectionStatus = .idle
    public let layout: LocalLayoutStore
    public var layoutStore: any LayoutStore { layout }
    public var isReady: Bool { true }
    /// The SSH session (nil before `connect`).
    @ObservationIgnored public private(set) var session: SshSession?

    @ObservationIgnored private var pump: Task<Void, Never>?
    private static let log = Logger(subsystem: Log.subsystem, category: "ssh")

    public init(hostId: String, layout: LocalLayoutStore = LocalLayoutStore()) {
        self.hostId = hostId
        self.layout = layout
    }

    /// Starts the session. Connection problems arrive as `status`; this throws only for a key
    /// that cannot be decoded.
    public func connect(
        target: SshTarget, auth: [SshAuth], jumpAuth: [[SshAuth]] = [], knownHosts: KnownHostsStore,
        hostKeys: HostKeyPolicy, options: SshOptions = defaultSshOptions()
    ) throws {
        let states = SshStateStream()
        status = .connecting(.dialing)
        let started = ContinuousClock.now
        session = try SshSession.start(
            target: target, auth: auth, knownHosts: knownHosts, hostKeys: hostKeys, options: options,
            listener: states, jumpAuth: jumpAuth)
        pump = Task { [weak self] in
            var logged = false
            for await state in states.states {
                guard let self else { return }
                if case .connected = state, !logged {
                    logged = true
                    Self.log.info("ssh connected host=\(self.hostId, privacy: .public) after \((ContinuousClock.now - started) / .milliseconds(1), format: .fixed(precision: 1)) ms")
                }
                apply(state)
            }
        }
    }

    /// Waits until the session is authenticated (or needs the user).
    public func connected() async throws {
        guard let session else { throw HostError.notConnected }
        try await session.connected()
        apply(session.state())
    }

    public func makeBackend(for pane: PaneId) throws -> any PaneBackend {
        guard let session else { throw HostError.notConnected }
        return SshPaneBackend(pane: pane, session: session)
    }

    public func retry() {
        session?.reconnectNow()
    }

    public func foreground() {
        session?.setForeground(foreground: true)
    }

    public func background() {
        // SSH cannot be suspended (no serialized state); keep it up while iOS allows and let
        // the session go offline after its background budget (docs/SSH.md §2).
        session?.setForeground(foreground: false)
    }

    public func networkChanged() {
        session?.networkChanged()
    }

    public func close() {
        pump?.cancel()
        session?.close()
        session = nil
        status = .idle
    }

    /// Round trip of the last keepalive.
    public var keepaliveRoundTrip: Duration? {
        session?.rtt().map { .milliseconds(Int64($0 * 1000)) }
    }

    func apply(_ state: SshConnectionState) {
        switch state {
        case .connecting:
            status = .connecting(.dialing)
        case .connected:
            status = .connected(rtt: keepaliveRoundTrip)
        case .reconnecting(let attempt, _, let reason):
            status = .reconnecting(attempt: attempt, reason: reason)
        case .offline(let reason):
            status = .offline(reason: reason)
        case .needsAttention(let error):
            status = .needsAttention(reason: SshErrorText.describe(error))
        case .closed:
            status = .idle
        }
    }
}

/// A plain-SSH pane: a PTY channel on the host's shared session, with the same events as a
/// daemon pane (docs/SSH.md §4). After a drop the session redials and the pane opens a new
/// shell (or re-attaches tmux), marked in the stream.
///
/// It predicts echo like a daemon pane, but nothing here can read the remote termios or ack
/// inputs: `StreamEchoInference` allows prediction only once keystrokes were seen echoed.
nonisolated public final class SshPaneBackend: PaneBackend, PredictionFeed {
    public let pane: PaneId
    private let session: SshSession
    private let channel = Mutex<SshPane?>(nil)
    private let size = Mutex(PaneSize(cols: 80, rows: 24, widthPx: 0, heightPx: 0))
    private let tmuxSession: String?
    private let echo = StreamEchoInference()
    private let prediction = Mutex<(@Sendable (PredictionUpdate) -> Void)?>(nil)
    /// Judges keystrokes whose echo never came while nothing else happens.
    private let echoTimer = Mutex<DispatchSourceTimer?>(nil)

    init(pane: PaneId, session: SshSession, tmuxSession: String? = nil) {
        self.pane = pane
        self.session = session
        self.tmuxSession = tmuxSession
    }

    public func start(events: @escaping @Sendable (PaneEvent) -> Void) {
        let listener = ClosureListener { [weak self] event in
            switch event {
            case .paneBytes(_, _, let data):
                events(.output(data))
                self?.predict(self?.echo.output(data) ?? [])
            case .paneResized(_, _, let size): events(.resized(size))
            case .connected: events(.connection(.live))
            case .disconnected(let reason), .refused(let reason): events(.connection(.stale(reason: reason)))
            case .paneClosed: events(.exited)
            default: break
            }
        }
        events(.connection(.stale(reason: "Connecting…")))
        let options = SshPaneOptions(
            paneId: pane.rawValue, size: size.withLock { $0 }, term: "xterm-256color", env: [
                EnvVar(name: "COLORTERM", value: "truecolor"),
            ], command: nil, tmuxSession: tmuxSession)
        let opened = session.openPane(options: options, listener: listener)
        channel.withLock { $0 = opened }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, let channel = channel.withLock({ $0 }) else { return }
        channel.sendInput(data: Data(bytes))
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        let newSize = PaneSize(
            cols: cols, rows: rows,
            widthPx: UInt16(clamping: UInt32(cols) * cellWidth),
            heightPx: UInt16(clamping: UInt32(rows) * cellHeight))
        size.withLock { $0 = newSize }
        channel.withLock { $0 }?.resize(size: newSize)
    }

    public func terminate() {
        echoTimer.withLock { timer in
            timer?.cancel()
            timer = nil
        }
        prediction.withLock { $0 = nil }
        channel.withLock { channel in
            channel?.close()
            channel = nil
        }
    }

    // MARK: Echo prediction

    public func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
        prediction.withLock { $0 = onUpdate }
        onUpdate(.hint(echo.hint))
    }

    public func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64) {
        predict(echo.input(Array(bytes)))
        write(bytes)
        armEchoCheck()
    }

    /// Checks for keystrokes whose echo never came every 250 ms while some wait, and not at
    /// all otherwise: an idle SSH pane costs no wakeups.
    private func armEchoCheck() {
        guard prediction.withLock({ $0 }) != nil else { return }
        echoTimer.withLock { timer in
            guard timer == nil else { return }
            let check = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            check.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
            check.setEventHandler { [weak self] in
                guard let self else { return }
                predict(echo.tick())
                // Under the lock `armEchoCheck` takes, so a keystroke sent meanwhile either
                // keeps this timer or arms a new one.
                echoTimer.withLock { armed in
                    guard !echo.isWaiting else { return }
                    armed?.cancel()
                    armed = nil
                }
            }
            check.resume()
            timer = check
        }
    }

    private func predict(_ updates: [PredictionUpdate]) {
        guard !updates.isEmpty, let onUpdate = prediction.withLock({ $0 }) else { return }
        for update in updates { onUpdate(update) }
    }
}

/// Human text for SSH errors (status rows, alerts).
nonisolated public enum SshErrorText {
    public static func describe(_ error: Error) -> String {
        guard let error = error as? SshError else { return error.localizedDescription }
        switch error {
        case .Io(let message): return message
        case .Protocol(let message): return "Protocol error: \(message)"
        case .Timeout(let message): return "Timed out: \(message)"
        case .Disconnected(let message): return "Disconnected: \(message)"
        case .AuthFailed(let user, let host, let tried, let allowed):
            return "Authentication failed for \(user)@\(host) (tried \(tried); server allows \(allowed))"
        case .HostKeyMismatch(let host, let expected, let actual):
            return "HOST KEY CHANGED for \(host): expected \(expected.joined(separator: " or ")), got \(actual)"
        case .HostKeyRejected(let host, let fingerprint):
            return "Host key for \(host) (\(fingerprint)) was not trusted"
        case .Key(let message): return "Key problem: \(message)"
        case .KeyEncrypted: return "The key needs its passphrase"
        case .Signer(let message): return "Signing failed: \(message)"
        case .Config(let message): return "ssh config: \(message)"
        case .Remote(let status, let stderr): return "Remote command failed (\(status)): \(stderr)"
        case .ChecksumMismatch(let path, let expected, let actual):
            return "Checksum mismatch for \(path): expected \(expected), got \(actual)"
        case .Bootstrap(let message): return "Install failed: \(message)"
        case .Closed: return "Closed"
        }
    }
}
