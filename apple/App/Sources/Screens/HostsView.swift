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
    @Environment(\.chrome) private var chrome
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
                        .buttonStyle(.primaryGlass)
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
        // the text column), not a stock grouped Settings list.
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
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(chrome.hairline)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in HostRow.textColumn }
                }
            } header: {
                SectionTitle(title, count: hosts.count)
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
            Button(host.isPinned ? "Unpin" : "Pin", systemImage: host.isPinned ? "pin.slash" : "pin") {
                withAnimation(DS.Motion.snappy) { directory.togglePin(host.id) }
            }
            Button("Rename…", systemImage: "pencil") {
                newName = host.name
                renaming = host
            }
        }
        if host.isTailscale, TailscaleApp.isInstalled {
            Button("Open Tailscale", systemImage: "arrow.up.forward.app", action: TailscaleApp.open)
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

    /// radius 6, on the raised surface with a hairline: not a full-width system capsule.
    private var quickConnect: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "terminal")
                .font(.subheadline)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 16)
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
        .padding(.horizontal, DS.Space.gap10)
        .frame(height: Self.fieldHeight)
        .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(isQuickConnectFocused ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.hairline), lineWidth: isQuickConnectFocused ? 1 : 0.5))
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

    /// A 16 pt glyph slot (18 on touch), then the text column where separators start.
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
                let why = [reason, hint].compactMap(\.self).joined(separator: " ")
                Text("\(Text("Can't reach").foregroundStyle(DS.Palette.error)) · \(why)")
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
                    // Quiet: a newer helper is an offer, not a problem (the menu has the action).
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
