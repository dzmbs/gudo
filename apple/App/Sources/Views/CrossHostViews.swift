import DesignSystem
import GudoCore
import HostKit
import SwiftUI

/// An agent on one host asking to act on another: the exact action and the three answers. One
/// of the agents' cards, in their stack, so it never covers a composer. It stays until it is
/// answered here or on another device, or the request lapses.
struct CrossHostCardView: View {
    let request: CrossHostRequestInfo
    var answer: (CrossHostRequestInfo, CrossHostChoice) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            mark
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                header
                Text(verbatim: request.action)
                    .font(DS.Font.literalSmall)
                    .lineLimit(3)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field, style: .continuous))
                    .hairlineBorder(RoundedRectangle.rounded(DS.Radius.field), style: DS.Palette.hairline)
                    .accessibilityLabel("Action: \(request.action)")
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                    .padding(.top, DS.Space.xxs)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingPanel(cornerRadius: DS.Radius.panel)
        .onHover { hovering in withAnimation(DS.Motion.standard) { isHovered = hovering } }
        .chromeContent()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cross-host-\(request.id)")
    }

    private var mark: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .overlay(alignment: .bottomTrailing) {
                StatusIndicator(.blocked, size: 14)
                    .background(Circle().fill(DS.Palette.overlay).padding(-1.5))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(request.headline)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("\(request.fromName) → \(request.toName)")
                .font(.footnote)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
                .accessibilityLabel("From \(request.fromName) to \(request.toName)")
        }
        .accessibilityElement(children: .combine)
    }

    private var notes: [String] {
        var notes: [String] = []
        if request.isRead { notes.append("What it reads goes to the agent and its model provider.") }
        if let guest = request.guestDriving { notes.append("Asked while \(guest) is driving the agent.") }
        return notes
    }

    private var actions: some View {
        HStack(spacing: DS.Space.s) {
            Spacer(minLength: 0)
            Button("Deny") { decide(.deny) }
                .buttonStyle(.glass)
                .keyboardShortcut(isHovered ? .cancelAction : nil)
                .help("Deny (Esc)")
                .accessibilityIdentifier("cross-host-deny")
            Button("Allow All") { decide(.allowAgent) }
                .buttonStyle(.glass)
                .help("Allow everything this agent asks on \(request.toName) until its pane closes")
                .accessibilityLabel("Allow all for this agent on \(request.toName)")
                .accessibilityIdentifier("cross-host-allow-all")
            Button("Allow Once") { decide(.allowOnce) }
                .buttonStyle(.primaryGlass)
                .keyboardShortcut(isHovered ? .defaultAction : nil)
                .help("Allow this one action (↩)")
                .accessibilityIdentifier("cross-host-allow-once")
        }
        .controlSize(.small)
    }

    private func decide(_ choice: CrossHostChoice) {
        withAnimation(DS.Motion.standard) { answer(request, choice) }
    }
}

/// The owner's other hosts, for the switches: daemon hosts this device owns.
@MainActor
enum CrossHostHosts {
    struct Host: Identifiable, Hashable {
        var id: String
        var name: String
    }

    static func owned(_ hosts: HostsModel) -> [Host] {
        if LaunchOptions.mock {
            return [Host(id: "studio", name: "studio"), Host(id: "ops", name: "ops"), Host(id: "mini", name: "mini")]
        }
        return hosts.records
            .filter { $0.kind == .daemon && !$0.isGuest }
            .map { Host(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Off", "From mac", "From mac and mini".
    static func summary(_ target: Host, hosts: [Host], session: CrossHostSession) -> String {
        let from = hosts.filter { $0.id != target.id && session.isEnabled(from: $0.id, to: target.id) }.map(\.name)
        return from.isEmpty ? "Off" : "From \(ListFormatter.localizedString(byJoining: from))"
    }
}

/// Agents settings: one row per host, leading to which hosts' agents may reach it.
struct CrossHostSettingsSection: View {
    private let hosts = AppModel.shared.hosts
    private let session = AppModel.shared.crossHost

    var body: some View {
        let owned = CrossHostHosts.owned(hosts)
        Section {
            if owned.count < 2 {
                Text("Pair a second host to let agents on one reach the other.")
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                ForEach(owned) { host in
                    NavigationLink(value: SettingsPage.hostReach(host.id)) {
                        LabeledContent {
                            Text(CrossHostHosts.summary(host, hosts: owned, session: session))
                        } label: {
                            Label(host.name, systemImage: "arrow.left.arrow.right")
                        }
                    }
                    .accessibilityIdentifier("cross-host-host-\(host.id)")
                }
            }
        } header: {
            Text("Agents on Other Hosts")
        } footer: {
            Text("Off for every host until you turn it on. This device carries each request and asks you first.")
        }
        .settingAnchor("cross-host")
    }
}

/// A host's page: which other hosts' agents may reach it, and the yeses standing now.
struct HostReachView: View {
    let hostId: String
    private let hosts = AppModel.shared.hosts
    private let session = AppModel.shared.crossHost

    var body: some View {
        let owned = CrossHostHosts.owned(hosts)
        let name = owned.first { $0.id == hostId }?.name ?? "this host"
        let others = owned.filter { $0.id != hostId }
        Form {
            Section {
                if others.isEmpty {
                    Text("Pair another host first.")
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ForEach(others) { other in
                    Toggle(isOn: Binding(
                        get: { session.isEnabled(from: other.id, to: hostId) },
                        set: { enabled in withAnimation(DS.Motion.standard) { session.setEnabled(enabled, from: other.id, to: hostId) } }
                    )) {
                        Label("Agents on \(other.name)", systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("cross-host-pair-\(other.id)")
                }
            } header: {
                Text("May Reach \(name)")
            } footer: {
                Text("An agent's first request to \(name) asks you on this device: Allow Once lets that action through and its reads after it; Allow All lets everything it asks on \(name) through until its pane closes. Turning a host off ends every Allow All from it at once.")
            }
            standing(name: name, others: others)
        }
        .formStyle(.grouped)
        .chromeGrouped()
        .navigationTitle("Agents on Other Hosts")
        .accessibilityIdentifier("host-reach")
    }

    @ViewBuilder
    private func standing(name: String, others: [CrossHostHosts.Host]) -> some View {
        let allows = session.allows.filter { $0.to == hostId }
        if !allows.isEmpty {
            Section {
                ForEach(allows) { allow in
                    LabeledContent {
                        Button("Revoke", role: .destructive) {
                            withAnimation(DS.Motion.standard) { session.endAllows(from: allow.from, to: hostId) }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("cross-host-revoke-\(allow.id)")
                    } label: {
                        Text(allow.summary)
                    }
                }
            } header: {
                Text("Allowed Now")
            } footer: {
                Text("Revoke ends it now; the agent's next request to \(name) asks you again.")
            }
        }
    }
}
