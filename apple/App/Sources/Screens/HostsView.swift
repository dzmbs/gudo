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

/// Hosts: daemon and SSH hosts, "Needs you" first, then active, pinned and the rest
/// (docs/DESIGN.md "Hosts"). A quick-connect field on top takes `user@host` and Return.
struct HostsView: View {
    let directory: any HostDirectory
    /// The real hosts model, for ssh_config import (nil with mock data).
    var live: HostsModel?
    var onAdd: () -> Void = {}
    var onOpen: (HostSummary) -> Void = { _ in }

    @Environment(WindowModel.self) private var model
    @State private var destination = ""
    @State private var forgetting: HostSummary?
    @State private var renaming: HostSummary?
    @State private var newName = ""
    @State private var importingFile = false
    @FocusState private var isQuickConnectFocused: Bool

    var body: some View {
        let hosts = directory.hosts
        Group {
            if hosts.isEmpty {
                EmptyState(
                    "No Hosts", systemImage: "server.rack",
                    message: "Add a machine running the daemon, or connect to any SSH host with user@host."
                ) {
                    Button("Add Host", action: onAdd)
                        .buttonStyle(.glassProminent)
                }
            } else {
                list(hosts)
            }
        }
        .navigationTitle("Hosts")
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
                    .accessibilityIdentifier("hosts-add")
            }
        }
        .confirmationDialog(
            "Forget \(forgetting?.name ?? "")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { host in
            Button("Forget Host", role: .destructive) {
                withAnimation(DS.Motion.snappy) { directory.forget(host.id) }
            }
        } message: { host in
            Text("Sessions on \(host.name) keep running. You can add it again later.")
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
    }

    // MARK: List

    private func list(_ hosts: [HostSummary]) -> some View {
        let groups = HostGroups(hosts)
        return List {
            Section {
                quickConnect
            }
            .raisedRows()
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
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .terminalGrouped()
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
                    .swipeActions(edge: .leading) {
                        if !host.isLocal {
                            Button(host.isPinned ? "Unpin" : "Pin", systemImage: host.isPinned ? "pin.slash" : "pin") {
                                withAnimation(DS.Motion.snappy) { directory.togglePin(host.id) }
                            }
                            .tint(DS.Palette.accent)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if !host.isLocal {
                            Button("Forget", systemImage: "trash", role: .destructive) { forgetting = host }
                        }
                    }
                    .contextMenu { menu(host) }
                    .accessibilityIdentifier("host-\(host.name)")
                    .raisedRows()
                }
            } header: {
                SectionTitle(title, count: hosts.count)
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
            Button(host.isPinned ? "Unpin" : "Pin", systemImage: host.isPinned ? "pin.slash" : "pin") {
                withAnimation(DS.Motion.snappy) { directory.togglePin(host.id) }
            }
            Button("Rename…", systemImage: "pencil") {
                newName = host.name
                renaming = host
            }
        }
        Button("Copy Address", systemImage: "doc.on.doc") { copy(host.address) }
        if !host.isLocal {
            if host.connection != .disconnected {
                Button("Disconnect", systemImage: "bolt.slash") { directory.disconnect(host.id) }
            }
            Divider()
            Button("Forget…", systemImage: "trash", role: .destructive) { forgetting = host }
        }
    }

    private var quickConnect: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            TextField("user@host", text: $destination)
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
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
            }
        }
    }

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

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { model.report(error, "Couldn't read the ssh_config") }
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Image(systemName: glyph)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.s) {
                    Text(host.name)
                        .font(DS.Font.rowTitleEmphasis)
                        .lineLimit(1)
                    ConnectionGlyph(host.connection)
                        .font(.caption)
                    if host.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: DS.Space.s)
                    trailing
                }
                Text(host.address)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
        }
        .padding(.vertical, DS.Space.xxs)
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
            .foregroundStyle(.secondary)
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
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.working)
                .monospacedDigit()
                .lineLimit(1)
        } else if emphasizeNeedsYou, let needsYou = host.needsYou {
            Text(needsYou)
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
        } else {
            switch host.connection {
            case .reconnecting(let attempt, _):
                Text("Reconnecting… · attempt \(attempt)")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.secondary)
            case .connecting, .offline:
                Text(host.connection.title)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.secondary)
            case .unreachable(let reason, let hint):
                let why = [reason, hint].compactMap(\.self).joined(separator: " ")
                Text("\(Text("Can't reach").foregroundStyle(DS.Palette.error)) · \(why)")
                    .foregroundStyle(.secondary)
                    .font(DS.Font.rowSubtitle)
                    .lineLimit(2)
            case .needsAttention(let reason, _):
                Text("\(Text("Can't connect").foregroundStyle(DS.Palette.error)) · \(reason)")
                    .foregroundStyle(.secondary)
                    .font(DS.Font.rowSubtitle)
                    .lineLimit(2)
            case .disconnected:
                Text(host.statusLine ?? lastUsed)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.tertiary)
            case .connected, .slow, .paused:
                if let line = host.lastLine {
                    Text(line)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let status = host.statusLine {
                    Text(status)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(.tertiary)
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
