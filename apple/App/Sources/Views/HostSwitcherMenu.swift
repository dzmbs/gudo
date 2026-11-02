import DesignSystem
import HostKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The window's host in the toolbar; the symbol gives way to the link's glyph while the link is
/// not healthy. A click or tap opens the host switcher.
struct HostToolbarButton: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    /// A command chosen in the popover, run once it has closed: a sheet presented while a
    /// popover is still dismissing is dropped.
    @State private var afterClose: (() -> Void)?

    var body: some View {
        @Bindable var model = model
        Button {
            model.isHostSwitcherShown.toggle()
        } label: {
            // A plain stack, not a Label: iPad toolbars reduce a Label to its icon.
            HostSwitcherLabel(model.hostName) {
                ConnectionGlyph(model.connection, healthy: Image(systemName: WindowModel.symbol(forHost: model.currentGroupId, kind: nil)))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $model.isHostSwitcherShown, arrowEdge: .top) {
            HostSwitcher(
                hosts: model.switcherHosts,
                commands: commands,
                onSelect: { model.selectHost(id: $0.id) },
                onCreate: { destination in
                    afterClose = { model.addHost(mode: .ssh, destination: destination) }
                    model.isHostSwitcherShown = false
                },
                focusesFilter: InboxView.hasKeyboard,
                onDismiss: { model.isHostSwitcherShown = false })
                .presentationCompactAdaptation(.popover)
                .environment(\.chrome, chrome)
        }
        .onChange(of: model.isHostSwitcherShown) { _, shown in
            guard !shown, let next = afterClose else { return }
            afterClose = nil
            Task { @MainActor in next() }
        }
        .help(model.connection.isQuiet ? "\(model.hostName) · Switch Host" : "\(model.hostName) · \(model.connection.title)")
        .accessibilityLabel("\(model.hostName), \(model.connection.title)")
        .accessibilityHint("Switch host")
        .accessibilityIdentifier("hosts-button")
    }

    @Environment(\.chrome) private var chrome

    private var commands: [HostSwitcherCommand] {
        let rawCommands: [HostSwitcherCommand] = [
            HostSwitcherCommand(id: "new-tab", title: "New Tab", systemImage: "plus", shortcut: ["⌘", "T"]) {
                model.newTab()
            },
            HostSwitcherCommand(id: "new-agent", title: "New Agent…", systemImage: "sparkle", shortcut: ["⇧", "⌘", "N"]) {
                model.newAgent(onGroup: model.currentGroupId)
            },
            HostSwitcherCommand(id: "connect-ssh", group: 1, title: "Connect via SSH…", systemImage: "terminal") {
                model.addHost(mode: .ssh)
            },
            HostSwitcherCommand(id: "pair-ticket", group: 1, title: "Pair with a Ticket…", systemImage: "ticket") {
                model.addHost(mode: .ticket)
            },
            HostSwitcherCommand(id: "join", group: 1, title: "Join a Session…", systemImage: "person.2") {
                model.sheet = .join
            },
            HostSwitcherCommand(id: "all-hosts", group: 2, title: "All Hosts", systemImage: "server.rack", shortcut: ["⇧", "⌘", "H"]) {
                withAnimation(DS.Motion.snappy) { model.destination = .hosts }
            },
        ]
        return rawCommands.map { command in
            HostSwitcherCommand(id: command.id, group: command.group, title: command.title, systemImage: command.systemImage, shortcut: command.shortcut) {
                afterClose = command.perform
                model.isHostSwitcherShown = false
            }
        }
    }
}

extension WindowModel {
    /// Every host the switcher lists, in its ⌃⌘ order: this device first (where it has a shell or
    /// tabs), then the saved hosts as the Hosts screen orders them.
    var switcherHosts: [HostSwitcherHost] {
        var summaries = hosts.hosts
        let localId = HostGroups.localId
        if !summaries.contains(where: { $0.id == localId }), groups.group(localId) != nil {
            summaries.insert(HostSummary(
                id: localId, name: Self.deviceName, address: "", kind: .local, connection: .connected,
                sessionCount: 0, agentCounts: [:], lastSeen: .now, isPinned: true), at: 0)
        }
        let current = currentGroupId
        return summaries.enumerated().map { index, host in
            let isCurrent = host.id == current
            let state = isCurrent ? connection : host.connection
            return HostSwitcherHost(
                id: host.id, name: host.kind == .local ? Self.deviceName : host.name,
                systemImage: Self.symbol(forHost: host.id, kind: host.kind),
                detail: Self.switcherDetail(state, needsYou: host.needsYouCount),
                address: host.kind == .local ? nil : host.address,
                link: Self.link(state), needsYou: host.needsYouCount > 0, isCurrent: isCurrent,
                shortcut: index < 9 ? index + 1 : nil)
        }
    }

    /// ⌃⌘1…⌃⌘9 and the switcher's rows.
    func selectHost(number: Int) {
        let hosts = switcherHosts
        guard hosts.indices.contains(number - 1) else { return }
        selectHost(id: hosts[number - 1].id)
    }

    func selectHost(id: String) {
        isHostSwitcherShown = false
        hosts.connect(id)
        if LaunchOptions.mock || id == HostGroups.localId {
            destination = .terminal
            if id == HostGroups.localId { show(.local) }
        }
    }

    /// The device's own symbol for this device, a server for the rest.
    static func symbol(forHost id: String, kind: HostKind?) -> String {
        if id == HostGroups.localId || kind == .local {
            #if os(macOS)
            return "laptopcomputer"
            #else
            return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            #endif
        }
        return kind == .ssh ? "terminal" : "server.rack"
    }

    private static func link(_ state: ConnectionState) -> HostSwitcherHost.Link {
        switch state {
        case .connected, .slow: .live
        case .connecting, .reconnecting: .connecting
        case .offline, .needsAttention, .unreachable: .down
        case .paused, .disconnected: .closed
        }
    }

    /// Only news: a link that is not fine, or agents waiting.
    private static func switcherDetail(_ state: ConnectionState, needsYou: Int) -> String? {
        switch state {
        case .connected, .paused, .disconnected:
            needsYou > 0 ? "\(needsYou) need\(needsYou == 1 ? "s" : "") you" : nil
        default:
            state.title
        }
    }
}
