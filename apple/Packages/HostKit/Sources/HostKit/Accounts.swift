import Foundation
import UnnamedCore

/// Agent accounts on a host (daemons whose `DaemonInfo.accounts` is true; docs/DAEMON.md
/// "Agent accounts"): several Claude Code / Codex sign-ins, such as Personal and Work. Kept out
/// of `DaemonWorkspaceAPI`'s list so fakes that do not care need nothing.
nonisolated public protocol DaemonAccountsAPI: AnyObject, Sendable {
    func accounts() async throws -> AccountsReport
    func accountAdd(agent: AgentKind, label: String, color: UInt8) async throws -> AgentAccount
    func accountEdit(agent: AgentKind, account: String, label: String, color: UInt8) async throws -> AccountsReport
    func accountRemove(agent: AgentKind, account: String) async throws -> AccountsReport
    func accountCheck(agent: AgentKind, account: String) async throws -> AgentAccount
    func accountSetDefault(agent: AgentKind, project: String?, account: String?) async throws -> AccountsReport
    /// A new tab in `session` running the agent's own sign-in; returns its pane.
    func accountSignIn(session: UInt64, agent: AgentKind, account: String, deviceCode: Bool) async throws -> UInt64
}

extension DaemonClient: DaemonAccountsAPI {}

/// The id of each agent's account that is the host user's own setup.
public let systemAccount = "system"

/// Reading a host's accounts: which one a launch uses, what a pane shows, when to suggest
/// another. Pure, so the rules are tested without a daemon.
public struct AccountBook: Equatable, Sendable {
    public var report: AccountsReport
    public var usage: AccountUsageReport

    public init(report: AccountsReport, usage: AccountUsageReport = AccountUsageReport(accounts: [])) {
        self.report = report
        self.usage = usage
    }

    /// The agent's accounts, its system account first.
    public func accounts(of agent: AgentKind) -> [AgentAccount] {
        report.accounts.filter { $0.agent == agent }
    }

    public func account(_ agent: AgentKind, _ id: String) -> AgentAccount? {
        report.accounts.first { $0.agent == agent && $0.id == id }
    }

    /// More than the system account: only then does anything name an account, so a host
    /// without accounts looks as it always did.
    public func hasChoice(_ agent: AgentKind) -> Bool {
        accounts(of: agent).count > 1
    }

    /// The default for `agent` in `project`, else the host's, else the system account.
    public func defaultAccount(_ agent: AgentKind, project: String?) -> String {
        let find = { (project: String?) in
            report.defaults.first { $0.agent == agent && $0.project == project }?.account
        }
        let id = project.flatMap(find) ?? find(nil) ?? systemAccount
        return account(agent, id) == nil ? systemAccount : id
    }

    /// What a new agent tab runs under: the tab's own pick, else the project's default, else
    /// the host's.
    public func resolve(_ agent: AgentKind, project: String?, override: String?) -> String {
        if let override, account(agent, override) != nil { return override }
        return defaultAccount(agent, project: project)
    }

    /// The account of a daemon-launched agent pane.
    public func account(ofPane pane: UInt64) -> AgentAccount? {
        guard let entry = report.panes.first(where: { $0.paneId == pane }) else { return nil }
        return account(entry.agent, entry.account)
    }

    /// What a pane's header adds after the agent's name ("Work"), and its colour; nil when the
    /// agent has one account on this host.
    public func paneLabel(_ pane: UInt64) -> (name: String, color: UInt8)? {
        guard let account = account(ofPane: pane), hasChoice(account.agent) else { return nil }
        return (account.label, account.color)
    }

    /// An account's usage.
    public func usage(_ agent: AgentKind, _ id: String) -> AgentUsage? {
        usage.accounts.first { $0.account == id && $0.usage.agent == agent }?.usage
    }

    /// When a pane's account is at a plan limit and another signed-in account of the same agent
    /// is not: a suggestion to start a new tab with it. Never more: switching is the user's call.
    public func limitHint(forPane pane: UInt64, now: Date = Date()) -> LimitHint? {
        guard let current = account(ofPane: pane),
              let window = usage(current.agent, current.id)?.windows.first(where: { $0.limited || $0.usedPermille >= 1000 })
        else { return nil }
        if let reset = window.resetsAtMs, Date(timeIntervalSince1970: Double(reset) / 1000) <= now { return nil }
        let other = accounts(of: current.agent).first { candidate in
            guard candidate.id != current.id, case .signedIn = candidate.status else { return false }
            let windows = usage(candidate.agent, candidate.id)?.windows ?? []
            return !windows.contains { $0.limited || $0.usedPermille >= 1000 }
        }
        guard let other else { return nil }
        return LimitHint(limited: current, window: window, alternative: other)
    }
}

/// A non-modal suggestion: "Work is at its 5h limit · resets 14:20".
public struct LimitHint: Equatable, Sendable {
    public let limited: AgentAccount
    public let window: UsageWindow
    public let alternative: AgentAccount

    public func message(now: Date = Date()) -> String {
        var text = "\(limited.label) is at its \(window.name) limit"
        if let reset = window.resetsAtMs {
            text += " · resets \(UsageText.reset(Date(timeIntervalSince1970: Double(reset) / 1000), now: now))"
        }
        return text
    }

    /// The action's title: "New Tab with Personal".
    public var action: String { "New Tab with \(alternative.label)" }
}

/// An account's sign-in, in words.
public enum AccountText {
    public static func status(_ status: AccountStatus) -> String {
        switch status {
        case .unknown: "Checking…"
        case .signedOut: "Not signed in"
        case .failed(let message): message
        case .signedIn(let identity):
            [identity.email, identity.plan.map(UsageText.plan), identity.organization]
                .compactMap { $0 }
                .joined(separator: " · ")
                .nonEmpty ?? "Signed in"
        }
    }

    public static func isSignedIn(_ status: AccountStatus) -> Bool {
        if case .signedIn = status { return true }
        return false
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension DaemonWorkspace {
    /// The host's account book: accounts as last pushed or read, with their usage.
    public var accountBook: AccountBook? {
        accounts.map { AccountBook(report: $0, usage: accountUsage ?? AccountUsageReport(accounts: [])) }
    }

    /// The accounts API of the client of the moment, or `HostError.notConnected` (also for a
    /// daemon without accounts).
    public func accountsClient() throws -> any DaemonAccountsAPI {
        guard supportsAccounts(), let api = api as? any DaemonAccountsAPI else { throw HostError.notConnected }
        return api
    }

    /// Reads the accounts (the daemon also checks any it has not asked about yet; their sign-in
    /// arrives as a push).
    public func loadAccounts() async {
        guard let api = try? accountsClient() else { return }
        if let report = try? await api.accounts() { accounts = report }
    }

    /// Reads the accounts once per connection, for views that only label things.
    public func loadAccountsIfNeeded() {
        guard accounts == nil, !accountsLoading, supportsAccounts() else { return }
        accountsLoading = true
        Task { [weak self] in
            await self?.loadAccounts()
            self?.accountsLoading = false
        }
    }

    /// Runs `change` against the daemon and keeps the report it answers.
    public func changeAccounts(_ change: (any DaemonAccountsAPI) async throws -> AccountsReport) async throws {
        accounts = try await change(try accountsClient())
    }

    /// Tests and fixtures: accounts as if pushed.
    public func setAccounts(_ report: AccountsReport?, usage: AccountUsageReport? = nil) {
        accounts = report
        accountUsage = usage
    }
}
