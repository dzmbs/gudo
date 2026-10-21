import Foundation
import HostKit
import PaneLayout

/// What a new window opens on (docs/APP-ARCHITECTURE.md "Windows"): New Window (⌘N) carries
/// the current window's hosts and tab, Open in New Window a host or a tab. The window then goes
/// its own way: its own selection, its own terminals.
struct WindowRequest: Codable, Hashable {
    /// Hosts to open in the new window, in sidebar order.
    var hosts: [String] = []
    /// The tab to show (its host opens too).
    var tab: TabRef?
    /// The pane to focus in that tab.
    var pane: UInt64?
    /// Every request is its own window (`openWindow(value:)` brings a window with an equal value
    /// forward instead of opening one).
    var id = UUID()

    /// A new window like `window`: the same hosts, on the same tab.
    @MainActor
    static func like(_ window: WindowModel) -> WindowRequest {
        // Mixed tabs belong to their window: the new one opens on the focused pane's host tab.
        let mixed = window.currentTab?.hostId == HostGroups.mixedId
        let tab = mixed ? window.workspace?.session.activeTabId.map { TabRef(hostId: window.currentGroupId, tab: $0) } : window.currentTab
        return WindowRequest(hosts: window.groups.openHosts, tab: tab)
    }
}

/// The Handoff and drag-out activity of a window (`NSUserActivity`): which host, tab and pane it
/// shows. Another device continues it on the same host if it has that host (matched by the
/// daemon's id or the SSH address, never by this device's host ids); this device (a tab dragged
/// out into a new window) uses the host id.
struct HandoffPayload: Codable, Equatable {
    enum Kind: String, Codable {
        case daemon, ssh, local
    }

    var kind: Kind
    /// The host's id on the device that made the activity (nil for this device's own shell).
    var hostId: String?
    var hostName: String
    /// A paired daemon's endpoint id (hex): the same on every device paired with it.
    var daemonId: String?
    /// `user@host[:port]` for SSH hosts.
    var ssh: String?
    var tab: UInt64?
    var pane: UInt64?
    /// The installation that made it (a drag within this device vs Handoff from another).
    var origin: String
    /// Where it was made ("This iPad"), for messages.
    var device: String

    static let activityType = (Bundle.main.bundleIdentifier ?? "dev.unnamed.app") + ".terminal"
    static let userInfoKey = "payload"

    /// This installation's id (activities it made itself are drags between its own windows).
    static var installation: String {
        let key = "window.installationId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    /// The payload for what a window shows, nil when it shows nothing continuable.
    @MainActor
    static func current(in window: WindowModel) -> HandoffPayload? {
        guard window.destination == .terminal, let workspace = window.workspace,
              let tab = workspace.session.activeTab else { return nil }
        let pane = tab.focused.rawValue
        guard let hostId = workspace.hostId else {
            return HandoffPayload(
                kind: .local, hostId: nil, hostName: WindowModel.deviceName, tab: tab.id.rawValue, pane: pane,
                origin: installation, device: WindowModel.deviceName)
        }
        let record = window.app.hosts.record(hostId)
        return HandoffPayload(
            kind: record?.kind == .ssh ? .ssh : .daemon, hostId: hostId, hostName: record?.name ?? hostId,
            daemonId: record?.daemonId, ssh: record?.ssh?.display, tab: tab.id.rawValue, pane: pane,
            origin: installation, device: WindowModel.deviceName)
    }

    /// Whether another device can continue it: this device's own shell lives here only.
    var isContinuable: Bool { kind != .local }

    var title: String { hostName }

    // MARK: Activity

    func userInfo() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.userInfoKey: data]
    }

    init(
        kind: Kind, hostId: String?, hostName: String, daemonId: String? = nil, ssh: String? = nil,
        tab: UInt64?, pane: UInt64?, origin: String, device: String
    ) {
        self.kind = kind
        self.hostId = hostId
        self.hostName = hostName
        self.daemonId = daemonId
        self.ssh = ssh
        self.tab = tab
        self.pane = pane
        self.origin = origin
        self.device = device
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let data = userInfo?[Self.userInfoKey] as? Data,
              let payload = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = payload
    }

    // MARK: Continuing

    enum Resolution: Equatable {
        /// Open this host (its id here) on the tab and pane.
        case host(id: String, tab: TabId?, pane: PaneId?)
        /// This device's own shell tab (a tab dragged out within this device).
        case local(tab: TabId?, pane: PaneId?)
        /// The host is not paired (or saved) here: say so and offer to add it.
        case notPaired
        /// Another device's own shell: nothing here can show it.
        case elsewhere
    }

    /// Where to continue: by host id on the device that made it, else the saved host with the
    /// same daemon or SSH address.
    func resolve(records: [HostRecord], installation: String = HandoffPayload.installation) -> Resolution {
        let tab = tab.map(TabId.init)
        let pane = pane.map(PaneId.init)
        let sameDevice = origin == installation
        if kind == .local { return sameDevice ? .local(tab: tab, pane: pane) : .elsewhere }
        if sameDevice, let hostId, records.contains(where: { $0.id == hostId }) {
            return .host(id: hostId, tab: tab, pane: pane)
        }
        if let daemonId, let match = records.first(where: { $0.daemonId == daemonId && !$0.isGuest }) ?? records.first(where: { $0.daemonId == daemonId }) {
            return .host(id: match.id, tab: tab, pane: pane)
        }
        if let ssh, let match = records.first(where: { $0.ssh?.display == ssh }) {
            // A plain-SSH tab's ids belong to that device's own session: show the host.
            return .host(id: match.id, tab: kind == .ssh ? nil : tab, pane: kind == .ssh ? nil : pane)
        }
        return .notPaired
    }
}

/// The window's layout by width, never by device (DESIGN.md "Size classes"): compact is the
/// iPhone layout (one pane, the tab switcher, the tab bar), regular the sidebar with splits. The
/// same bucket applies on an iPhone, a foldable's inner screen, an iPad in Split View or Slide
/// Over, a Stage Manager window and the Mac.
enum WidthBucket: String, Equatable, Sendable {
    case compact
    case regular

    /// The boundary in points: an iPhone in portrait, Slide Over, a third or half of an 11" iPad
    /// and narrow Stage Manager windows are compact; iPhones in landscape, a foldable's inner
    /// screen (≈ 7.6–8"), iPad mini and larger halves are regular.
    static let boundary: Double = 600
    /// A window being resized across the boundary switches only once it is this far past it,
    /// so a drag that hovers at the edge never flips the layout back and forth.
    static let hysteresis: Double = 12

    /// The bucket for `width`, given the window's current one.
    static func of(width: Double, current: WidthBucket?) -> WidthBucket {
        switch current {
        case .compact?: width >= boundary + hysteresis ? .regular : .compact
        case .regular?: width < boundary - hysteresis ? .compact : .regular
        case nil: width >= boundary ? .regular : .compact
        }
    }
}
