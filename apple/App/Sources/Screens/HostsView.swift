import DesignSystem
import HostKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The Hosts screen bound to the window: the real hosts (`LiveHostDirectory`), or the mock
/// directory with `-mock`.
struct HostsScreen: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        HostsView(
            directory: model.hosts, live: LaunchOptions.mock ? nil : model.app.hosts,
            onAdd: { model.addHost() },
            onOpen: { _ in model.destination = .terminal })
    }
}

/// Daemon and SSH hosts, "Needs you" first, then active, pinned and the rest, under a
/// quick-connect field that takes `user@host`.
struct HostsView: View {
    let directory: any HostDirectory
    /// The real hosts model, for ssh_config import (nil with mock data).
    var live: HostsModel?
    var onAdd: () -> Void = {}
    var onOpen: (HostSummary) -> Void = { _ in }

    @Environment(WindowModel.self) private var model
    @Environment(\.chrome) private var chrome
    @State private var destination = ""
    @State private var renaming: HostSummary?
    @State private var newName = ""
    @State private var importingFile = false
    @State private var editing: HostRecord?
    @FocusState private var isQuickConnectFocused: Bool

    var body: some View {
        let hosts = directory.hosts
        Group {
            if hosts.isEmpty {
                EmptyState("No Hosts", systemImage: "server.rack", message: PairingHint.message) {
                    #if os(iOS)
                    Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") { model.addHost(mode: .scan) }
                        .buttonStyle(.primaryGlass)
                        .accessibilityIdentifier("hosts-scan")
                    Button("Add Host", action: onAdd)
                        .buttonStyle(.glass)
                    #else
                    Button("Add Host", action: onAdd)
                        .buttonStyle(.primaryGlass)
                    #endif
                }
            } else {
                list(hosts)
            }
        }
        .chromeContent()
        .navigationTitle("Hosts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let live {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Import", systemImage: "square.and.arrow.down") {
                        #if os(macOS)
                        Button("Read ~/.ssh/config", systemImage: "doc.text") { run { try live.loadUserSSHConfig() } }
                        #endif
                        Button("Choose ssh_config File…", systemImage: "folder") { importingFile = true }
                        Button("Paste ssh_config", systemImage: "doc.on.clipboard") { run { try live.loadSSHConfig(pasteboardText()) } }
                    }
                    .menuIndicator(.hidden)
                    .help("Import hosts from an ssh_config")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Host", systemImage: "plus", action: onAdd)
                    .help("Add Host")
                    .accessibilityIdentifier("hosts-add")
            }
        }
        .alert("Rename Host", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { directory.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data, .plainText, .item]) { result in
            guard let live, case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            run { try live.loadSSHConfig(String(contentsOf: url, encoding: .utf8)) }
        }
        .sheet(isPresented: Binding(get: { !(live?.sshConfigAliases.isEmpty ?? true) }, set: { if !$0 { live?.clearSSHConfigAliases() } })) {
            if let live { SSHConfigImportSheet(hosts: live) }
        }
        .sheet(item: $editing) { record in
            if let live { EditSSHHostSheet(hosts: live, record: record) }
        }
    }

    private func list(_ hosts: [HostSummary]) -> some View {
        let groups = HostGroups(hosts)
        return List {
            quickConnect
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.l, bottom: DS.Space.s, trailing: DS.Space.l))
            Section {
            } footer: {
                if directory.isOffline {
                    Label("No network. Hosts reconnect when it's back.", systemImage: "wifi.slash")
                        .foregroundStyle(DS.Palette.error)
                        .accessibilityIdentifier("offline-banner")
                }
            }
            section("Needs you", groups.needsYou)
            section("Active", groups.active)
            section("Pinned", groups.pinned)
            section("Other", groups.other)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DS.Palette.base)
        .animation(DS.Motion.snappy, value: hosts)
    }

    @ViewBuilder
    private func section(_ title: String, _ hosts: [HostSummary]) -> some View {
        if !hosts.isEmpty {
            Section {
                ForEach(hosts) { host in
                    Button { open(host) } label: {
                        HostRow(host: host, emphasizeNeedsYou: title == "Needs you")
                    }
                    .buttonStyle(.plain)
                    .listRowActions(
                        RowActions(.host(isLocal: host.isLocal, isOpen: host.connection != .disconnected, isPinned: host.isPinned)),
                        name: host.name
                    ) { action in
                        perform(action, on: host)
                    } menu: {
                        menu(host)
                    }
                    .accessibilityIdentifier("host-\(host.name)")
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(chrome.hairline)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in HostRow.textColumn }
                }
            } header: {
                SectionTitle(title, count: hosts.count, small: true)
                    .padding(.top, DS.Space.s)
            }
        }
    }

    @ViewBuilder
    private func menu(_ host: HostSummary) -> some View {
        Button("Connect", systemImage: "bolt.horizontal") { open(host) }
        if !host.isLocal {
            if !host.connection.isLive {
                Button("Retry Now", systemImage: "arrow.clockwise") { directory.retry(host.id) }
            }
            if host.canInstallHelper, host.progress == nil {
                Button("Install Helper", systemImage: "bolt.horizontal.circle") { installHelper(host) }
            }
            if let helper = host.helper, helper.canUpdate, host.progress == nil {
                Button("Update Helper", systemImage: "arrow.down.circle") { updateHelper(host) }
            }
            if let record = live?.record(host.id), record.kind == .ssh, record.ssh != nil {
                Button("Edit…", systemImage: "slider.horizontal.3") { editing = record }
                    .accessibilityIdentifier("host-edit")
            }
            Button("Rename…", systemImage: "pencil") {
                newName = host.name
                renaming = host
            }
        }
        if live != nil, PairDeviceTarget.owns(host.id) {
            Button("Pair a Device…", systemImage: "qrcode") { model.pairDevice(hostId: host.id) }
            Button("Devices…", systemImage: "laptopcomputer.and.iphone") { SettingsLink.shared.open(.hostDevices(host.id)) }
        }
        if host.isTailscale, TailscaleApp.isInstalled {
            Button("Open Tailscale", systemImage: "arrow.up.forward.app", action: TailscaleApp.open)
        }
        Button("Copy Address", systemImage: "doc.on.doc") { copy(host.address) }
    }

    private func perform(_ action: RowAction, on host: HostSummary) {
        switch action {
        case .pin, .unpin: withAnimation(DS.Motion.snappy) { directory.togglePin(host.id) }
        case .disconnect: directory.disconnect(host.id)
        case .removeHost: withAnimation(DS.Motion.snappy) { directory.forget(host.id) }
        default: break
        }
    }

    private var quickConnect: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "terminal")
                .font(.subheadline)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 16)
            TextField("Connect", text: $destination, prompt: Text("Connect to user@host or an ssh alias").font(.body))
                .font(DS.Font.literal)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .submitLabel(.go)
                .focused($isQuickConnectFocused)
                .onSubmit(connectTyped)
                .accessibilityIdentifier("hosts-quick-connect")
            if !destination.isEmpty {
                Button("Connect", systemImage: "return", action: connectTyped)
                    .help("Connect (↩)")
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
            }
        }
        .padding(.horizontal, DS.Space.gap10)
        .frame(height: Self.fieldHeight)
        .fieldSurface(isFocused: isQuickConnectFocused)
        .contentShape(.rect)
        .onTapGesture { isQuickConnectFocused = true }
        #if os(iOS)
        .frame(minHeight: 44)
        #endif
    }

    #if os(macOS)
    static let fieldHeight: CGFloat = 28
    #else
    static let fieldHeight: CGFloat = 36
    #endif

    private func connectTyped() {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        directory.quickConnect(trimmed)
        destination = ""
    }

    private func open(_ host: HostSummary) {
        directory.connect(host.id)
        onOpen(host)
    }

    private func installHelper(_ host: HostSummary) {
        Task {
            do {
                try await directory.installHelper(host.id)
                model.toasts.show(Toast("\(host.name) now runs the helper", systemImage: "checkmark.circle.fill", style: .success))
            } catch {
                model.report(error, "Couldn't install the helper")
            }
        }
    }

    private func updateHelper(_ host: HostSummary) {
        Task {
            do {
                try await directory.updateHelper(host.id)
                model.toasts.show(Toast("\(host.name) runs the new helper", systemImage: "checkmark.circle.fill", style: .success))
            } catch {
                model.report(error, "Couldn't update the helper")
            }
        }
    }

    private func run(_ importConfig: () throws -> Void) {
        do { try importConfig() } catch { model.report(error, "Couldn't read the ssh_config") }
    }

    private func pasteboardText() -> String {
        #if canImport(UIKit)
        UIPasteboard.general.string ?? ""
        #else
        NSPasteboard.general.string(forType: .string) ?? ""
        #endif
    }
}

/// Splits hosts into the four sections; each host appears once, in its most urgent section.
private struct HostGroups {
    var needsYou: [HostSummary] = []
    var active: [HostSummary] = []
    var pinned: [HostSummary] = []
    var other: [HostSummary] = []

    init(_ hosts: [HostSummary]) {
        for host in hosts {
            if host.needsYouCount > 0 {
                needsYou.append(host)
            } else if host.progress != nil || (host.sessionCount > 0 && host.connection.isDialledOrLive) {
                active.append(host)
            } else if host.isPinned {
                pinned.append(host)
            } else {
                other.append(host)
            }
        }
    }
}

private extension ConnectionState {
    var isDialledOrLive: Bool {
        switch self {
        case .connected, .slow, .connecting, .reconnecting, .offline, .paused: true
        case .needsAttention, .unreachable, .disconnected: false
        }
    }
}

/// One host: kind glyph, name and status line, address in SF Mono, then the most useful detail
/// for its state (why it needs you, the install in progress, the last output line, or why it is
/// unreachable).
private struct HostRow: View {
    let host: HostSummary
    let emphasizeNeedsYou: Bool
    @Environment(WindowModel.self) private var model

    #if os(macOS)
    static let glyphSlot: CGFloat = 16
    #else
    static let glyphSlot: CGFloat = 18
    #endif
    static let textColumn: CGFloat = glyphSlot + DS.Space.m

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Image(systemName: glyph)
                .foregroundStyle(.primary)
                .opacity(DS.Opacity.mutedGlyph)
                .frame(width: Self.glyphSlot)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.row) {
                    Text(host.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    ConnectionGlyph(host.connection)
                        .font(.caption)
                    if host.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    if host.isTailscale {
                        TailscaleTag()
                    }
                    Spacer(minLength: DS.Space.s)
                    trailing
                }
                Text(host.address)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                if let sharing = host.sharing {
                    Button { model.sheet = .sharing } label: {
                        Label(sharing, systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote)
                            .foregroundStyle(DS.Palette.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .help("Manage Sharing")
                    .accessibilityIdentifier("sharing-\(host.name)")
                }
                if host.needsTailscale {
                    TailscaleHint(compact: true)
                }
            }
        }
        .padding(.vertical, DS.Space.row)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var glyph: String {
        switch host.kind {
        case .daemon: "server.rack"
        case .ssh: "terminal"
        case .local:
            #if os(macOS)
            "laptopcomputer"
            #else
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            #endif
        }
    }

    @ViewBuilder private var trailing: some View {
        if emphasizeNeedsYou {
            CountBadge(host.needsYouCount)
        } else {
            HStack(spacing: DS.Space.s) {
                ForEach(summaryStates, id: \.self) { state in
                    HStack(spacing: 3) {
                        StatusIndicator(state, size: 11)
                        Text("\(host.agentCounts[state] ?? 0)")
                    }
                }
                if host.sessionCount > 0 {
                    Text(host.sessionCount == 1 ? "1 tab" : "\(host.sessionCount) tabs")
                }
            }
            .font(DS.Font.meta)
            .foregroundStyle(DS.Palette.textSecondary)
            .fixedSize()
        }
    }

    /// Agent states worth a glyph in the row, most urgent first.
    private var summaryStates: [AgentState] {
        host.agentCounts
            .filter { $0.value > 0 && $0.key != .idle }
            .map(\.key)
            .sorted { $0.urgency < $1.urgency }
    }

    @ViewBuilder private var detail: some View {
        if let progress = host.progress {
            Text(progress)
                .font(.footnote)
                .foregroundStyle(DS.Palette.working)
                .monospacedDigit()
                .lineLimit(1)
        } else if emphasizeNeedsYou, let needsYou = host.needsYou {
            Text(needsYou)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
        } else {
            switch host.connection {
            case .reconnecting(let attempt, _):
                Text("\(Text("Reconnecting").foregroundStyle(DS.Palette.attention)) · attempt \(attempt)")
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.textSecondary)
            case .connecting, .offline:
                Text(host.connection.title)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.textSecondary)
            case .unreachable(let reason, let hint):
                let explanation = [reason, hint].compactMap(\.self).joined(separator: " ")
                Text("\(Text("Can't reach").foregroundStyle(DS.Palette.error)) · \(explanation)")
                    .foregroundStyle(DS.Palette.textSecondary)
                    .font(.footnote)
                    .lineLimit(2)
            case .needsAttention(let reason, _):
                Text("\(Text("Can't connect").foregroundStyle(DS.Palette.error)) · \(reason)")
                    .foregroundStyle(DS.Palette.textSecondary)
                    .font(.footnote)
                    .lineLimit(2)
            case .disconnected:
                Text(host.statusLine ?? lastUsed)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.textTertiary)
            case .connected, .slow, .paused:
                if let helper = host.helper, helper.canUpdate {
                    Label(helper.message, systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("helper-update-\(host.name)")
                } else if let line = host.lastLine {
                    Text(line)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                } else if let status = host.statusLine {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var lastUsed: String {
        guard host.lastSeen > .distantPast else { return "Not connected" }
        return "Last used \(host.lastSeen.formatted(.relative(presentation: .named)))"
    }
}
