import DesignSystem
import HostKit
import PaneLayout
import GudoCore

extension WindowModel {
    /// The account book of a group's host; nil for hosts without accounts (and this device).
    func accountBook(onGroup id: String) -> AccountBook? {
        if LaunchOptions.mock { return MockAccounts.book }
        return (app.hosts.connection(id) as? DaemonConnection)?.existingWorkspace?.accountBook
    }

    func loadAccounts(onGroup id: String) {
        guard !LaunchOptions.mock, let daemon = app.hosts.connection(id) as? DaemonConnection,
              daemon.daemonInfo?.accounts == true else { return }
        daemon.workspace.loadAccountsIfNeeded()
    }

    /// The project of the window's current tab, whose defaults a new agent follows.
    var currentProjectId: String? {
        currentTab.flatMap { groups.project(of: $0)?.info.id }
    }

    /// Starts `agent` under `account` in a new tab in `pane`'s directory, leaving the running session as is.
    func startAgent(onGroup id: String, agent: AccountAgent, account: String, from pane: PaneId) {
        guard let daemon = app.hosts.connection(id) as? DaemonConnection,
              let api = try? daemon.workspace.client() else { return }
        let launch = AgentLaunch(
            splitFrom: pane.rawValue, agent: agent, axis: .horizontal, worktree: nil,
            cwd: daemon.meta[pane]?.cwd, resume: nil, prompt: nil, submit: true, readyTimeoutMs: 30_000,
            newTabIn: daemon.layout.sessionId, account: account)
        Task { [weak self] in
            do {
                let launched = try await api.launchAgentPane(launch: launch)
                self?.reveal(host: id, pane: launched.paneId)
            } catch {
                self?.toasts.show(Toast(ScreenError.describe(error), systemImage: "exclamationmark.circle", style: .failure))
            }
        }
    }
}
