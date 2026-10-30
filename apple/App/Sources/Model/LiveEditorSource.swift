import Foundation
import HostKit
import Observation
import os
import PaneLayout
import UnnamedCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "editor")

/// VS Code for one folder on one host: an editor pane's (`pinned`, docs/APP-ARCHITECTURE.md
/// §20), or the window's focused pane's folder when nothing is pinned (tests).
///
/// - Default: `openEditor` (`code serve-web` on the host, VSCodium where Microsoft's CLI cannot
///   run) over a local forward; one session per host and folder, reused when reopened. Never a
///   sign-in.
/// - Opt-in: the VS Code Remote Tunnel through vscode.dev (`openTunnel`). The host signs in with
///   the user's own GitHub or Microsoft account by device code, which the user completes in their
///   own browser.
///
/// Nothing of Microsoft's is installed or started on a host before the user accepted Microsoft's
/// licence terms for it in the first-use sheet (`EditorLicence`, per host).
@MainActor
@Observable
final class LiveEditorSource: EditorSource {
    @ObservationIgnored weak var window: WindowModel?
    @ObservationIgnored let app: AppModel
    private(set) var phase = EditorPhase.idle
    private(set) var mode = EditorMode.server
    private(set) var folder = "~"
    private(set) var hostName = ""
    private(set) var tunnelDesktopURI: URL?
    var pendingURL: URL?

    /// Tests: where acceptances are kept.
    @ObservationIgnored var licence = EditorLicence()
    /// Tests: where the source acts, instead of the window's host.
    @ObservationIgnored var contextOverride: (() -> HostContext?)?
    /// The editor pane's host and folder: the source always opens exactly that folder there.
    @ObservationIgnored let pinned: EditorMember?

    /// Open sessions by "host|folder".
    @ObservationIgnored private var sessions: [String: (hub: DaemonWorkspace, session: EditorSession)] = [:]
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// When the last open started, for the timing log.
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    /// What waits for the licence sheet's answer.
    @ObservationIgnored private var pending: Pending?
    /// Hosts the user chose the tunnel for (this run): reopening goes through it again.
    @ObservationIgnored private var tunnelHosts: [String: EditorTunnelAccount] = [:]
    @ObservationIgnored private var tunnel: TunnelLink?
    @ObservationIgnored private var serverLost: ((String) -> Void)?
    /// Bumped with each server opened: only the latest one's host is watched.
    @ObservationIgnored private var watching = 0

    private enum Pending {
        case server(HostContext, folder: String, key: String)
        case tunnel(EditorTunnelAccount)
    }

    /// The tunnel being followed: its host's push hub and the observer there.
    private struct TunnelLink {
        let hostId: String
        let hub: DaemonWorkspace
        let observer: UUID
        var opened = false
    }

    init(app: AppModel, pinned: EditorMember? = nil) {
        self.app = app
        self.pinned = pinned
        if let pinned {
            folder = pinned.folder
            hostName = app.hosts.record(pinned.hostId)?.name ?? pinned.hostId
        }
        EditorLicence.resetForTestsIfAsked()
    }

    private var context: HostContext? {
        if let contextOverride { return contextOverride() }
        if let pinned { return HostContext.host(pinned.hostId, app: app) }
        return HostContext.resolve(app: app, window: window)
    }

    /// The host the source waits for while it connects (a restored editor's, or the window's).
    private var isHostConnecting: Bool {
        if let pinned { return app.hosts.connection(pinned.hostId) is DaemonConnection }
        return window?.workspace?.host is DaemonConnection
    }

    var unavailableReason: String? { context == nil ? HostContext.noHost : nil }

    func open() async {
        // One open at a time: the screen's own open and a file open race on presentation.
        if let opening {
            await opening.value
            return
        }
        let task = Task { await performOpen() }
        opening = task
        await task.value
        opening = nil
    }

    /// Waits for the window's host and its folder; nil (and `.failed`) when there is none.
    private func resolveTarget() async -> (HostContext, String)? {
        // The host may still be connecting (a restored editor at launch): wait for it, saying
        // so, rather than fail.
        if context == nil, isHostConnecting {
            phase = .checking
            if pinned == nil { hostName = window?.hostName ?? "" }
            for _ in 0..<(pinned == nil ? 150 : 600) where context == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if let pinned, let context {
            hostName = context.name
            folder = pinned.folder
            return (context, pinned.folder)
        }
        // Just after connecting the panes may not have said where they are yet.
        for _ in 0..<20 where context != nil && context?.directory == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let context else {
            phase = .failed(HostContext.noHost)
            return nil
        }
        hostName = context.name
        let directory = context.directory ?? "~"
        // The repository root when the pane is inside one (VS Code shows the project), else the directory.
        var target = directory
        if let status = try? await context.api().gitStatus(path: directory) { target = status.root }
        folder = target
        return (context, target)
    }

    private func performOpen() async {
        guard let (context, target) = await resolveTarget() else { return }
        if let account = tunnelHosts[context.hostId] {
            await startTunnel(context: context, account: account)
            return
        }
        mode = .server
        let key = "\(context.hostId)|\(target)"
        current = key
        if let existing = sessions[key], let url = URL(string: existing.session.url) {
            phase = .loading(url)
            return
        }
        guard licence.isAccepted(host: context.hostId) else {
            pending = .server(context, folder: target, key: key)
            phase = .needsLicence
            return
        }
        await start(context: context, folder: target, key: key)
    }

    func acceptLicence() async {
        guard let pending else { return }
        self.pending = nil
        switch pending {
        case .server(let context, let folder, let key):
            licence.accept(host: context.hostId)
            log.info("VS Code licence accepted by the user for host=\(context.hostId, privacy: .public)")
            await start(context: context, folder: folder, key: key)
        case .tunnel(let account):
            guard let context else {
                phase = .failed(HostContext.noHost)
                return
            }
            licence.accept(host: context.hostId)
            log.info("VS Code licence accepted by the user for host=\(context.hostId, privacy: .public)")
            await startTunnel(context: context, account: account)
        }
    }

    /// The licence was accepted for this host meanwhile (in another editor pane): go on
    /// without asking again.
    func resumeIfAccepted() async {
        guard phase == .needsLicence, let pending else { return }
        let host: String? = switch pending {
        case .server(let context, _, _): context.hostId
        case .tunnel: context?.hostId
        }
        guard let host, licence.isAccepted(host: host) else { return }
        await acceptLicence()
    }

    func declineLicence() {
        pending = nil
        phase = .idle
        current = nil
    }

    private func start(context: HostContext, folder: String, key: String) async {
        startedAt = .now
        phase = .checking
        do {
            let api = try context.api()
            if let status = try? await api.editorStatus(),
               let vscode = status.available.first(where: { $0.kind == .vsCode }) {
                phase = vscode.installed ? .starting : .installing
            } else {
                phase = .starting
            }
            // The user accepted Microsoft's terms for this host in the first-use sheet.
            let session = try await api.openEditor(folder: folder, acceptVscodeLicense: licence.isAccepted(host: context.hostId))
            sessions[key] = (context.hub, session)
            watchRestart(context.daemon)
            let elapsed = startedAt.map { (ContinuousClock.now - $0) / .milliseconds(1) } ?? 0
            log.info("editor ready host=\(context.hostId, privacy: .public) kind=\(String(describing: session.instance.kind), privacy: .public) installed=\(session.installedCli) in \(elapsed, format: .fixed(precision: 0)) ms")
            guard current == key else { return }
            if let url = URL(string: session.url) {
                phase = .loading(url)
            } else {
                phase = .failed("The editor answered with an address this device cannot open.")
            }
        } catch {
            guard current == key else { return }
            phase = .failed(ScreenError.describe(error))
        }
    }

    // MARK: Remote Tunnel (opt-in)

    func openTunnel(account: EditorTunnelAccount) async {
        guard let (context, _) = await resolveTarget() else { return }
        await startTunnel(context: context, account: account)
    }

    private func startTunnel(context: HostContext, account: EditorTunnelAccount) async {
        mode = .tunnel
        current = "tunnel|\(context.hostId)"
        tunnelHosts[context.hostId] = account
        guard licence.isAccepted(host: context.hostId) else {
            pending = .tunnel(account)
            phase = .needsLicence
            return
        }
        guard let api = (try? context.hub.client()) as? any DaemonTunnelAPI else {
            phase = .failed("This host's helper cannot run a VS Code tunnel.")
            return
        }
        startedAt = .now
        phase = .connectingTunnel
        follow(context.hub, host: context.hostId)
        do {
            var status = try await api.vscodeTunnelStatus()
            if status.cli == nil {
                // The user accepted the VS Code licence for this host: the host fetches the CLI from Microsoft.
                status = try await api.vscodeCliInstall(acceptLicense: true)
            }
            if case .running = status.state {} else {
                status = try await api.vscodeTunnelStart(start: VsCodeTunnelStart(
                    acceptServerLicense: true, provider: account == .github ? .gitHub : .microsoft, name: nil))
            }
            apply(status)
        } catch {
            phase = .failed(ScreenError.describe(error))
        }
    }

    /// Follows the host's tunnel pushes (device code, running, failed).
    private func follow(_ hub: DaemonWorkspace, host: String) {
        if let tunnel, tunnel.hostId == host {
            self.tunnel?.opened = false
            return
        }
        stopFollowing()
        let observer = hub.observeTunnel { [weak self] status in self?.apply(status) }
        tunnel = TunnelLink(hostId: host, hub: hub, observer: observer)
    }

    private func stopFollowing() {
        if let tunnel { tunnel.hub.removeObserver(tunnel.observer) }
        tunnel = nil
    }

    private func apply(_ status: VsCodeTunnelStatus) {
        guard mode == .tunnel, tunnel != nil else { return }
        switch status.state {
        case .stopped, .starting:
            if phase.url == nil { phase = .connectingTunnel }
        case .needsLogin(let login):
            // A late answer must not bring the code back once the tunnel runs.
            guard tunnel?.opened == false, let url = URL(string: login.verificationUrl) else { return }
            phase = .signingIn(EditorDeviceCode(
                account: login.provider == .gitHub ? .github : .microsoft, verificationURL: url, code: login.userCode))
        case .running:
            guard tunnel?.opened == false else { return }
            tunnel?.opened = true
            Task { await openThroughTunnel(path: nil, line: nil, column: nil) }
        case .failed(let message, let retrying):
            if retrying {
                if phase.url == nil { phase = .connectingTunnel }
            } else {
                phase = .failed(message)
            }
        }
    }

    /// Asks the daemon for the vscode.dev URL of the folder (or a file at a line) and shows it.
    private func openThroughTunnel(path: String?, line: Int?, column: Int?) async {
        guard let tunnel, let api = (try? tunnel.hub.client()) as? any DaemonTunnelAPI else { return }
        do {
            let opened = try await api.vscodeTunnelOpen(open: VsCodeTunnelOpen(
                folder: folder == "~" ? nil : folder, path: path ?? folder,
                line: line.map { UInt32($0) }, column: column.map { UInt32($0) }))
            tunnelDesktopURI = URL(string: opened.desktopUri)
            guard let url = TunnelWeb.url(opened.webUrl) else {
                phase = .failed("The tunnel answered with an address this device cannot open.")
                return
            }
            if path != nil, phase.url != nil {
                if !opened.inWindow { pendingURL = url }
            } else {
                phase = .loading(url)
            }
            log.info("tunnel editor open host=\(tunnel.hostId, privacy: .public) in_window=\(opened.inWindow)")
        } catch {
            phase = .failed(ScreenError.describe(error))
        }
    }

    // MARK: Workbench

    func didLoad() {
        if case .loading(let url) = phase {
            phase = .ready(url)
            if let startedAt {
                log.info("editor workbench loaded \((ContinuousClock.now - startedAt) / .milliseconds(1), format: .fixed(precision: 0)) ms after open")
                self.startedAt = nil
            }
        }
    }

    func open(path: String, line: Int?, column: Int?) async {
        if mode == .tunnel, tunnel != nil, phase.url != nil {
            await openThroughTunnel(path: path, line: line, column: column)
            return
        }
        if current == nil || sessions[current ?? ""] == nil { await open() }
        if mode == .tunnel {
            if phase.url != nil { await openThroughTunnel(path: path, line: line, column: column) }
            return
        }
        guard let key = current, let (hub, session) = sessions[key], let api = try? hub.client() else { return }
        do {
            if let next = try await api.editorOpenInSession(
                session: session, path: path, line: line.map { UInt32($0) }, column: column.map { UInt32($0) }),
                let url = URL(string: next) {
                pendingURL = url
            }
        } catch {
            log.error("editor open \(path, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    func onServerLost(_ handler: @escaping (String) -> Void) {
        serverLost = handler
    }

    /// The host's helper restarting takes its editor servers with it: the workbench would
    /// retry the old one for hours.
    private func watchRestart(_ daemon: DaemonConnection) {
        watching += 1
        follow(daemon, epoch: daemon.epoch, watch: watching)
    }

    private func follow(_ daemon: DaemonConnection, epoch: UInt64?, watch: Int) {
        withObservationTracking {
            _ = daemon.epoch
        } onChange: { [weak self, weak daemon] in
            Task { @MainActor [weak self, weak daemon] in
                guard let self, let daemon, self.watching == watch, self.mode == .server else { return }
                if let now = daemon.epoch, let epoch, now != epoch {
                    self.serverLost?("the host's helper restarted")
                } else {
                    self.follow(daemon, epoch: epoch ?? daemon.epoch, watch: watch)
                }
            }
        }
    }

    func reopen() async {
        guard mode == .server, let key = current else { return }
        sessions[key] = nil
        await open()
    }

    func close(stopServer: Bool) async {
        defer {
            phase = .idle
            current = nil
            pending = nil
        }
        if mode == .tunnel {
            let link = tunnel
            stopFollowing()
            tunnelDesktopURI = nil
            mode = .server
            guard stopServer, let link else { return }
            // Stopping ends the tunnel on the host; the next open is the default editor again.
            tunnelHosts[link.hostId] = nil
            if let api = (try? link.hub.client()) as? any DaemonTunnelAPI { _ = try? await api.vscodeTunnelStop() }
            return
        }
        guard stopServer, let key = current, let (hub, session) = sessions.removeValue(forKey: key),
              let api = try? hub.client()
        else { return }
        try? await api.closeEditor(session: session, stopServer: true)
    }
}
