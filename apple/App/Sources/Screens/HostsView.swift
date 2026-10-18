import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Hosts: daemon and SSH hosts, "Needs you" first, then active, pinned and the rest
/// (docs/DESIGN.md "Hosts"). A quick-connect field on top takes `user@host` and Return.
struct HostsView: View {
    let directory: any HostDirectory
    var onAdd: () -> Void = {}
    var onOpen: (HostSummary) -> Void = { _ in }

    @State private var destination = ""
    @State private var forgetting: HostSummary?
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
    }

    // MARK: List

    private func list(_ hosts: [HostSummary]) -> some View {
        let groups = HostGroups(hosts)
        return List {
            Section {
                quickConnect
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
                        Button(host.isPinned ? "Unpin" : "Pin", systemImage: host.isPinned ? "pin.slash" : "pin") {
                            withAnimation(DS.Motion.snappy) { directory.togglePin(host.id) }
                        }
                        .tint(DS.Palette.accent)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Forget", systemImage: "trash", role: .destructive) { forgetting = host }
                    }
                    .contextMenu { menu(host) }
                    .accessibilityIdentifier("host-\(host.id)")
                }
            } header: {
                SectionTitle(title, count: hosts.count)
            }
        }
    }

    @ViewBuilder
    private func menu(_ host: HostSummary) -> some View {
        Button("Connect", systemImage: "bolt.horizontal") { open(host) }
        Button(host.isPinned ? "Unpin" : "Pin", systemImage: host.isPinned ? "pin.slash" : "pin") {
            withAnimation(DS.Motion.snappy) { directory.togglePin(host.id) }
        }
        Button("Copy Address", systemImage: "doc.on.doc") { copy(host.address) }
        Divider()
        Button("Forget…", systemImage: "trash", role: .destructive) { forgetting = host }
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

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            } else if host.sessionCount > 0, host.connection.isDialledOrLive {
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
        case .connected, .connecting, .reconnecting: true
        case .unreachable: false
        }
    }
}

/// One host: kind glyph, name and status line, address in SF Mono, then the most useful detail
/// for its state (why it needs you, the last output line, or why it is unreachable).
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
                    ConnectionDot(host.connection)
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
        case .local: "laptopcomputer"
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
                    Text(host.sessionCount == 1 ? "1 session" : "\(host.sessionCount) sessions")
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
        switch host.connection {
        case .reconnecting(let attempt, _):
            Text("Reconnecting · attempt \(attempt)")
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.working)
        case .connecting:
            Text("Connecting")
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.working)
        case .unreachable(let reason, let hint):
            let why = [reason, hint].compactMap(\.self).joined(separator: " ")
            Text("\(Text("Unreachable").foregroundStyle(DS.Palette.error)) · \(why)")
                .foregroundStyle(.secondary)
                .font(DS.Font.rowSubtitle)
                .lineLimit(2)
        case .connected:
            if emphasizeNeedsYou, let needsYou = host.needsYou {
                Text(needsYou)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            } else if let line = host.lastLine {
                Text(line)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
