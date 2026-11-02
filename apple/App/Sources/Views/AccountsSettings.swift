import DesignSystem
import HostKit
import SwiftUI
import GudoCore

/// The core's agent kind (the app's own `AgentKind` also names other programs).
typealias AccountAgent = GudoCore.AgentKind

/// Settings ▸ Agents ▸ Accounts: each owned host's Claude Code and Codex sign-ins (docs/DAEMON.md
/// "Agent accounts"). An account is a directory on the host the agent is launched with; signing
/// in is the agent's own login in a terminal tab, finished by the user. Nothing here sees a
/// password or a token.
struct AccountsSettingsSection: View {
    private let hosts = AppModel.shared.hosts

    var body: some View {
        let owned = DeviceHosts.owned(hosts)
        Section {
            if owned.isEmpty {
                Text("No paired hosts. Each host you own keeps its own agent accounts.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(owned, id: \.id) { host in
                NavigationLink(value: SettingsPage.hostAccounts(host.id)) {
                    LabeledContent {
                        Text(AccountHosts.summary(host.id, hosts: hosts))
                    } label: {
                        Label(host.name, systemImage: "person.2")
                    }
                }
                .accessibilityIdentifier("accounts-host-\(host.id)")
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Sign in to Claude Code or Codex more than once on a host, such as Personal and Work. Each project picks its account; a pane shows which one it uses.")
        }
        .settingAnchor("accounts")
    }
}

/// The accounts of a host: live from its helper, or the fixture under `-mock`.
@MainActor
enum AccountHosts {
    static func workspace(_ id: String, hosts: HostsModel) -> DaemonWorkspace? {
        guard let daemon = hosts.connection(id) as? DaemonConnection, daemon.daemonInfo?.accounts == true else { return nil }
        return daemon.workspace
    }

    static func book(_ id: String, hosts: HostsModel) -> AccountBook? {
        if LaunchOptions.mock { return MockAccounts.book }
        return (hosts.connection(id) as? DaemonConnection)?.existingWorkspace?.accountBook
    }

    /// "Claude: 2 · Codex: 1", or why there is nothing to show.
    static func summary(_ id: String, hosts: HostsModel) -> String {
        guard let book = book(id, hosts: hosts) else {
            guard let daemon = hosts.connection(id) as? DaemonConnection, daemon.isReady else { return "Not connected" }
            return daemon.daemonInfo?.accounts == true ? "" : "Update the helper"
        }
        return [AccountAgent.claude, .codex]
            .map { "\(UsageText.name($0)): \(book.accounts(of: $0).count)" }
            .joined(separator: " · ")
    }

    /// Codex signs in with a device code unless the host is this Mac, whose browser can answer
    /// Codex's own localhost callback. Claude prints a URL and takes a pasted code either way.
    static func usesDeviceCode(_ id: String, hosts: HostsModel) -> Bool {
        #if os(macOS)
        guard let host = (hosts.connection(id) as? DaemonConnection)?.daemonInfo?.hostname else { return true }
        return host != ProcessInfo.processInfo.hostName
            && host + ".local" != ProcessInfo.processInfo.hostName
        #else
        return true
        #endif
    }
}

/// The accounts the fixtures and screenshots show: Claude signed in as Personal (the system
/// account) and Work, one Codex sign-in; the mock's Claude pane runs under Work.
@MainActor
enum MockAccounts {
    static let personal = AccountIdentity(email: "sam@hey.example", plan: "max", organization: nil, method: "claude.ai")
    static let work = AccountIdentity(email: "sam@acme.example", plan: "team", organization: "Acme", method: "claude.ai")

    static var book: AccountBook {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let limits = { (permille: UInt16, limited: Bool) in
            [UsageWindow(name: "5h", minutes: 300, usedPermille: permille, resetsAtMs: now + 5_400_000, limited: limited),
             UsageWindow(name: "weekly", minutes: 10_080, usedPermille: 410, resetsAtMs: now + 300_000_000, limited: false)]
        }
        let usage = { (id: String, permille: UInt16, limited: Bool) in
            AccountUsage(account: id, usage: AgentUsage(agent: .claude, plan: "max", windows: limits(permille, limited), source: .statusLine, asOfMs: now, note: nil))
        }
        return AccountBook(
            report: AccountsReport(
                accounts: [
                    AgentAccount(id: systemAccount, agent: .claude, label: "Personal", color: 0, status: .signedIn(identity: personal)),
                    AgentAccount(id: "a1b2c3d4", agent: .claude, label: "Work", color: 6, status: .signedIn(identity: work)),
                    AgentAccount(id: "e5f6a7b8", agent: .claude, label: "Side Project", color: 3, status: .signedOut),
                    AgentAccount(id: systemAccount, agent: .codex, label: "System", color: 0,
                                 status: .signedIn(identity: AccountIdentity(email: "sam@hey.example", plan: "plus", organization: nil, method: "chatgpt"))),
                ],
                defaults: [
                    AccountDefault(agent: .claude, project: nil, account: systemAccount),
                    AccountDefault(agent: .claude, project: "acme-api", account: "a1b2c3d4"),
                ],
                panes: [PaneAccount(paneId: 3, agent: .claude, account: "a1b2c3d4")]),
            usage: AccountUsageReport(accounts: [usage(systemAccount, 220, false), usage("a1b2c3d4", 1000, true)]))
    }
}

extension AgentAccount {
    /// Unique across agents, for lists that show both.
    var listId: String { "\(UsageText.name(agent))/\(id)" }
}

/// An account's colour: a dot in its palette colour (the same hues as projects).
struct AccountDot: View {
    let color: UInt8
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(DS.Palette.project(Int(color)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// One host's accounts, per agent, with sign-in, default, rename and remove.
struct HostAccountsView: View {
    let hostId: String
    private let hosts = AppModel.shared.hosts
    @State private var adding: AccountAgent?
    @State private var renaming: AgentAccount?
    @State private var removing: AgentAccount?
    @State private var failure: String?

    var body: some View {
        let name = DeviceHosts.name(hostId, hosts: hosts)
        Group {
            if let book = AccountHosts.book(hostId, hosts: hosts) {
                // A grouped form, as the other Settings panes: its footers wrap.
                Form {
                    ForEach([AccountAgent.claude, .codex], id: \.self) { agent in
                        section(agent, book: book)
                    }
                }
                .formStyle(.grouped)
                .chromeGrouped()
            } else if AccountHosts.workspace(hostId, hosts: hosts) != nil {
                ProgressView("Reading accounts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState("Not Available", systemImage: "person.2", message: "Connect to \(name) with an up-to-date helper to manage its agent accounts.") {
                    EmptyView()
                }
            }
        }
        .navigationTitle("\(name) Accounts")
        .accessibilityIdentifier("host-accounts")
        .task { await AccountHosts.workspace(hostId, hosts: hosts)?.loadAccounts() }
        .sheet(item: Binding(get: { adding.map(AddingAgent.init) }, set: { adding = $0?.agent })) { item in
            AddAccountSheet(agent: item.agent, title: "Add \(UsageText.name(item.agent)) Account") { label, color in
                await add(item.agent, label: label, color: color)
            }
        }
        .sheet(item: Binding(get: { renaming.map(Renaming.init) }, set: { renaming = $0?.account })) { item in
            let account = item.account
            AddAccountSheet(agent: account.agent, title: "Rename Account", label: account.label, color: account.color, confirm: "Save") { label, color in
                await change { try await $0.accountEdit(agent: account.agent, account: account.id, label: label, color: color) }
            }
        }
        .confirmationDialog(removing.map { "Remove \($0.label)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let account = removing {
                Button("Sign Out and Remove", role: .destructive) {
                    Task { await change { try await $0.accountRemove(agent: account.agent, account: account.id) } }
                }
            }
        } message: {
            Text("\(removing.map { UsageText.name($0.agent) } ?? "The agent") signs out of it on the host first, then its folder, settings and session history there are deleted.")
        }
        .alert("Couldn't Change Accounts", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// An account to rename; ids repeat across agents (each has a system account).
    private struct Renaming: Identifiable {
        let account: AgentAccount
        var id: String { account.listId }
    }

    private struct AddingAgent: Identifiable {
        let agent: AccountAgent
        var id: String { UsageText.name(agent) }
    }

    @ViewBuilder private func section(_ agent: AccountAgent, book: AccountBook) -> some View {
        let hostDefault = book.defaultAccount(agent, project: nil)
        Section {
            // Keyed by agent too: both agents have a `system` account, and one list holds both.
            ForEach(book.accounts(of: agent), id: \.listId) { account in
                AccountRow(account: account, isDefault: account.id == hostDefault && book.hasChoice(agent), usage: book.usage(agent, account.id))
                    .contextMenu { menu(account, isDefault: account.id == hostDefault) }
                    .accessibilityIdentifier("account-\(UsageText.name(agent))-\(account.label)")
            }
            Button {
                adding = agent
            } label: {
                Label("Add \(UsageText.name(agent)) Account…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DS.Palette.accent)
        } header: {
            Text(agent == .claude ? "Claude Code" : "Codex")
        } footer: {
            if !book.hasChoice(agent) || agent == .codex {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !book.hasChoice(agent) {
                    Text("Uses \(agent == .claude ? "~/.claude" : "~/.codex") on the host, as in its terminal.")
                }
                if agent == .codex {
                    Text("Each account is a folder on \(DeviceHosts.name(hostId, hosts: hosts)) that only your user there can open. Signing in and out runs Claude Code's or Codex's own command in a terminal tab; this app never sees a password or token.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            }
        }
        .chromeRows()
    }

    @ViewBuilder private func menu(_ account: AgentAccount, isDefault: Bool) -> some View {
        Button(AccountText.isSignedIn(account.status) ? "Sign In Again…" : "Sign In…") {
            Task { await signIn(account) }
        }
        if !isDefault {
            Button("Use by Default") {
                Task { await change { try await $0.accountSetDefault(agent: account.agent, project: nil, account: account.id) } }
            }
        }
        if account.id != systemAccount {
            Button("Rename…") { renaming = account }
            Divider()
            Button("Sign Out and Remove…", role: .destructive) { removing = account }
        }
    }

    private func change(_ body: (any DaemonAccountsAPI) async throws -> AccountsReport) async {
        guard let workspace = AccountHosts.workspace(hostId, hosts: hosts) else { return }
        do {
            try await workspace.changeAccounts(body)
        } catch {
            failure = ScreenError.describe(error)
        }
    }

    private func add(_ agent: AccountAgent, label: String, color: UInt8) async {
        guard let workspace = AccountHosts.workspace(hostId, hosts: hosts) else { return }
        do {
            let account = try await workspace.accountsClient().accountAdd(agent: agent, label: label, color: color)
            await workspace.loadAccounts()
            await signIn(account)
        } catch {
            failure = ScreenError.describe(error)
        }
    }

    /// Opens the agent's own sign-in in a new tab on the host and shows it.
    private func signIn(_ account: AgentAccount) async {
        guard let daemon = hosts.connection(hostId) as? DaemonConnection,
              let session = daemon.layout.sessionId,
              let api = try? daemon.workspace.accountsClient()
        else { return }
        do {
            let pane = try await api.accountSignIn(
                session: session, agent: account.agent, account: account.id,
                deviceCode: AccountHosts.usesDeviceCode(hostId, hosts: hosts))
            ActiveWindow.model?.reveal(host: hostId, pane: pane)
        } catch {
            failure = ScreenError.describe(error)
        }
    }
}

/// An account: its colour, name, who it is signed in as, and its tightest limit.
struct AccountRow: View {
    let account: AgentAccount
    let isDefault: Bool
    let usage: AgentUsage?

    var body: some View {
        HStack(spacing: DS.Space.gap10) {
            AccountDot(color: account.color, size: 10)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.row) {
                    Text(account.label).font(DS.Font.rowTitle)
                    if isDefault {
                        Text("Default")
                            .font(DS.Font.badge)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.badgeH)
                            .padding(.vertical, DS.Space.badgeV)
                            .background(DS.Palette.selectedFill, in: .capsule)
                    }
                }
                Text(AccountText.status(account.status))
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            if let usage, let meter = UsageMeter.compact(usage) {
                // The section already names the agent.
                Text(meter.text.components(separatedBy: " · ").dropFirst().joined(separator: " · "))
                    .font(DS.Font.meta)
                    .foregroundStyle(meter.tone == .limited ? DS.Palette.error : DS.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: AnyShapeStyle {
        switch account.status {
        case .signedOut: AnyShapeStyle(DS.Palette.attention)
        case .failed: AnyShapeStyle(DS.Palette.error)
        default: AnyShapeStyle(DS.Palette.textSecondary)
        }
    }
}

/// Names a new account (or renames one) and picks its colour.
struct AddAccountSheet: View {
    let agent: AccountAgent
    let title: String
    @State var label = ""
    @State var color: UInt8 = 1
    var confirm = "Add and Sign In"
    let done: (String, UInt8) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    init(agent: AccountAgent, title: String, label: String = "", color: UInt8 = 1, confirm: String = "Add and Sign In", done: @escaping (String, UInt8) async -> Void) {
        self.agent = agent
        self.title = title
        _label = State(initialValue: label)
        _color = State(initialValue: color)
        self.confirm = confirm
        self.done = done
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $label, prompt: Text("Work"))
                        .accessibilityIdentifier("account-name")
                    HStack(spacing: DS.Space.s) {
                        ForEach(0..<ProjectColor.names.count, id: \.self) { index in
                            Button {
                                color = UInt8(index)
                            } label: {
                                AccountDot(color: UInt8(index), size: 16)
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(DS.Palette.accent, lineWidth: color == UInt8(index) ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ProjectColor.names[index])
                        }
                    }
                } footer: {
                    if confirm == "Add and Sign In" {
                        Text("\(UsageText.name(agent)) then signs in to it in a new tab on the host. Finish there; the account shows who it is signed in as.")
                    }
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
                        busy = true
                        Task {
                            await done(label.trimmingCharacters(in: .whitespaces), color)
                            dismiss()
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 220)
        #endif
    }
}
