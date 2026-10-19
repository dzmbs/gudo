import DesignSystem
import Foundation
import Observation

/// What the detail column (or the iPhone tab) shows.
enum Destination: Hashable {
    case terminal
    case inbox
    case hosts
}

/// Modal surfaces. One at a time, like the system's own sheets.
enum SheetRoute: String, Identifiable {
    case pairing, launchAgent, invite, links, diff, files, browser, editor, settings
    var id: String { rawValue }
}

/// One window's UI state and the data sources behind its screens. App-wide data (hosts,
/// connections, workspaces) lives in `AppModel`; this holds what the window shows and adapts
/// those models to the screens' protocols (`ScreenModels.swift`). With `-mock` the screens read
/// `MockData.swift` instead, for screenshots.
@MainActor
@Observable
final class WindowModel {
    var destination = Destination.terminal
    var sheet: SheetRoute?
    var isPaletteShown = false
    var isSearchShown = false
    var searchNeedle = "" {
        didSet { if searchNeedle != oldValue { updateSearchCount() } }
    }
    /// Matches of `searchNeedle` in the focused pane's whole scrollback (daemon panes).
    var searchTotal: Int?
    @ObservationIgnored var searchCountTask: Task<Void, Never>?
    /// The Add Host sheet's starting mode and destination (quick connect pre-fills SSH).
    var pairingMode = PairingSheet.Mode.ssh
    var pairingDestination = ""
    /// The workspace on screen (set by `WindowRoot` when the target changes).
    var workspace: Workspace? {
        didSet {
            if workspace !== oldValue { followConnection() }
            if workspace != nil { ActiveWindow.workspace = workspace }
            workspace?.onNewTabUnavailable = { [weak self] in self?.addHost() }
        }
    }
    /// The design fixtures' stand-in connection state (`-screen reconnect`).
    var connectionOverride: ConnectionState?
    /// The window's host link in the design system's words; `.connected` for the local workspace.
    private(set) var liveConnection = ConnectionState.connected

    let app: AppModel
    let hosts: any HostDirectory
    let agents: any AgentFeed
    let paneStatus: any PaneStatusSource
    let files: any FileSource
    let diffs: any DiffSource
    let editor: any EditorSource
    let ports: any PortSource
    let links: any LinkSource
    /// The page the in-app browser opens (a forwarded port, a link).
    var browserURL: URL?
    /// The editor is presented (full screen on iPhone and iPad).
    var isEditorShown = false
    let toasts = ToastCenter()

    /// Opens a target in this window (`WindowRoot` sets it).
    @ObservationIgnored var show: (WorkspaceTarget) -> Void = { _ in }
    @ObservationIgnored private var downSince: Date?

    init(app: AppModel) {
        self.app = app
        defer { ActiveWindow.register(self) }
        if LaunchOptions.mock {
            hosts = MockHostDirectory()
            agents = MockAgentFeed()
            paneStatus = MockPaneStatus()
            files = MockFileSource()
            diffs = MockDiffSource()
            editor = MockEditorSource()
            ports = MockPortSource()
            links = MockLinkSource()
            return
        }
        let live = LiveHostDirectory(app: app)
        hosts = live
        let feed = LiveAgentFeed(hosts: app.hosts)
        agents = feed
        let status = LivePaneStatus()
        paneStatus = status
        let files = LiveFileSource(app: app)
        let diffs = LiveDiffSource(app: app)
        let editor = LiveEditorSource(app: app)
        let ports = LivePortSource(app: app)
        let links = LiveLinkSource(app: app)
        self.files = files
        self.diffs = diffs
        self.editor = editor
        self.ports = ports
        self.links = links
        live.window = self
        status.window = self
        feed.window = self
        files.window = self
        diffs.window = self
        editor.window = self
        ports.window = self
        links.window = self
    }

    var connection: ConnectionState { connectionOverride ?? liveConnection }

    var needsYouCount: Int { agents.items.filter(\.state.needsYou).count }

    /// The window's host as the chrome names it: the host's name, or this device.
    var hostName: String {
        if LaunchOptions.mock { return connectionOverride == nil ? Self.deviceName : "studio" }
        guard let id = workspace?.hostId else { return Self.deviceName }
        return app.hosts.record(id)?.name ?? id
    }

    /// Whether the window shows a remote host.
    var isRemote: Bool { workspace?.isRemote ?? false }

    static var deviceName: String {
        #if os(macOS)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }

    // MARK: Actions

    /// Add Host, optionally straight into SSH with a destination typed elsewhere.
    func addHost(mode: PairingSheet.Mode = .ssh, destination: String = "") {
        pairingMode = mode
        pairingDestination = destination
        sheet = .pairing
    }

    /// Retry from the reconnect card and banners.
    func retryConnection() {
        if connectionOverride != nil { connectionOverride = nil; return }
        workspace?.host?.retry()
    }

    /// Leaves the host: the window goes back to this device's shell; the host stays saved.
    func disconnect() {
        if connectionOverride != nil { connectionOverride = nil; return }
        guard let id = workspace?.hostId else { return }
        app.hosts.disconnect(id)
        show(.local)
    }

    func report(_ error: any Error, _ prefix: String) {
        toasts.show(Toast("\(prefix): \(SshErrorText.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
    }

    // MARK: Connection state

    /// Mirrors the window's host status into `liveConnection`, remembering when it went down so
    /// the reconnect card can say how long ago output last arrived.
    private func followConnection() {
        let status = workspace?.host?.status
        if status?.isLive ?? true {
            downSince = nil
        } else if downSince == nil {
            downSince = .now
        }
        // No host: this device's own shell is "connected"; an iPhone or iPad without one is not.
        let next = status.map { ConnectionState($0, since: downSince ?? .now) } ?? (LaunchOptions.hasLocalShell ? .connected : .disconnected)
        if next != liveConnection { liveConnection = next }
        guard let host = workspace?.host else { return }
        withObservationTracking {
            _ = host.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followConnection() }
        }
    }
}

extension ConnectionState {
    init(_ status: ConnectionStatus, since: Date) {
        switch status {
        case .connected:
            self = .connected
        case .idle, .connecting, .suspended:
            self = .connecting
        case .reconnecting(let attempt, _):
            self = .reconnecting(attempt: Int(max(attempt, 1)), since: since)
        case .offline(let reason):
            self = .unreachable(reason: reason, hint: "Sessions resume when the network is back.")
        case .needsAttention(let reason):
            self = .unreachable(reason: reason, hint: nil)
        }
    }
}

/// Launch arguments for design review and screenshots:
/// `-mock` fills the screens with sample hosts, agents and statuses; `-screen <name>` opens
/// straight to one screen.
enum LaunchOptions {
    static let mock = ProcessInfo.processInfo.arguments.contains("-mock")
    static let screen: String? = UserDefaults.standard.string(forKey: "screen")
    /// Whether this device offers a local shell: always on the Mac; on iPhone and iPad only the
    /// echo stand-in, so only for UI tests (`-localEcho YES`), `-mock` and design fixtures. A real
    /// iOS install starts on the welcome and Hosts screens, never in a fake shell.
    static var hasLocalShell: Bool {
        #if os(macOS)
        true
        #else
        mock || screen != nil || UserDefaults.standard.bool(forKey: "localEcho")
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
