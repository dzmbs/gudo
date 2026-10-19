import Foundation
import PaneLayout
import UnnamedCore

/// The git-native workspace half of `UnnamedCore.DaemonClient` (docs/DAEMON.md §5.11,
/// `proto::repo`): the repository snapshot, pull request actions through the host's `gh`, the
/// worktree lifecycle and scripts. Kept apart from `DaemonWorkspaceAPI` so fakes of that one
/// need not grow; `DaemonClient` conforms as is.
nonisolated public protocol DaemonRepoAPI: AnyObject, Sendable {
    func repos() -> RepoSnapshot?
    func repoRefresh(path: String?) async throws -> RepoSnapshot
    func prMerge(path: String, number: UInt32, strategy: MergeStrategy) async throws -> PullRequest?
    func prRerunFailed(path: String) async throws -> PullRequest?
    func prCreate(path: String, draft: Bool, base: String?) async throws -> PullRequest?
    func prCheckout(repo: String, number: UInt32) async throws -> WorktreeInfo
    func worktreeArchive(path: String, force: Bool) async throws
    func worktreeArchived(repo: String?) async throws -> [ArchivedWorktree]
    func worktreeRestore(id: UInt64) async throws -> WorktreeInfo
    func worktreeRemove(path: String, force: Bool, deleteBranch: Bool) async throws
    func worktreeAutoDeleteDays(set: UInt32?) async throws -> UInt32
    func taskCreate(task: TaskCreate) async throws -> TaskCreated
    func scriptRun(cwd: String, sessionId: UInt64, name: String, command: String) async throws -> UInt64
}

extension DaemonClient: DaemonRepoAPI {}

/// running is pending; else passing).
nonisolated public enum ChecksSummary: Equatable, Sendable {
    case none
    case passing(Int)
    case pending(failed: Int, running: Int, passed: Int)
    case failing(failed: Int, running: Int, passed: Int)

    public init(_ checks: [PrCheck]) {
        self.init(statuses: checks.map(\.status))
    }

    public init(statuses checks: [CheckStatus]) {
        let failed = checks.filter { $0 == .failure }.count
        let running = checks.filter { $0 == .pending }.count
        let passed = checks.filter { $0 == .success }.count
        if checks.isEmpty {
            self = .none
        } else if failed > 0 {
            self = .failing(failed: failed, running: running, passed: passed)
        } else if running > 0 {
            self = .pending(failed: 0, running: running, passed: passed)
        } else {
            self = .passing(passed)
        }
    }

    /// "1 failed, 2 in progress, 3 successful".
    public var words: String {
        switch self {
        case .none: return "No checks"
        case .passing(let n): return n == 1 ? "1 successful check" : "\(n) successful checks"
        case .pending(let f, let r, let p), .failing(let f, let r, let p):
            var parts: [String] = []
            if f > 0 { parts.append("\(f) failed") }
            if r > 0 { parts.append("\(r) in progress") }
            if p > 0 { parts.append("\(p) successful") }
            return parts.joined(separator: ", ")
        }
    }
}

extension WorktreeState: Identifiable {
    nonisolated public var id: String { path }

    /// The branch, or the short commit when detached.
    nonisolated public var displayBranch: String {
        if let branch { return branch }
        if let head { return "detached at \(head.prefix(7))" }
        return "detached"
    }

    /// subtitle equal to the branch's last component). The main worktree has none.
    nonisolated public var subtitle: String? {
        if main { return nil }
        let last = branch.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        return name == last || name == branch?.replacingOccurrences(of: "/", with: "-") ? nil : name
    }

    /// The pull request worth showing: open ones, merged ones, not closed ones.
    nonisolated public var visiblePR: PullRequest? {
        guard let pr, pr.state != .closed else { return nil }
        return pr
    }

    /// Merged and long enough ago for the daemon's clock to have started.
    nonisolated public var isMerged: Bool { pr?.state == .merged }
}

extension PullRequest {
    /// "Open", "Draft", "Merged", "Closed".
    nonisolated public var stateWord: String {
        switch state {
        case .open: return draft ? "Draft" : "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    nonisolated public var checksSummary: ChecksSummary { ChecksSummary(checks) }

    /// Why Merge is not offered, in words; nil when it can be merged.
    nonisolated public var mergeBlocker: String? {
        guard state == .open else { return "#\(number) is \(stateWord.lowercased())" }
        switch mergeState {
        case .clean, .hasHooks, .unstable: return nil
        case .behind: return "The branch is behind its base. Update it first."
        case .blocked: return "Required reviews or checks are missing."
        case .dirty: return "It has merge conflicts."
        case .draft: return "Drafts cannot be merged."
        case .unknown: return "GitHub is still checking whether it can be merged."
        }
    }

    /// The failed checks have Actions runs to re-run.
    nonisolated public var hasRerunnableFailures: Bool {
        checks.contains { $0.status == .failure && ($0.url?.contains("/actions/runs/") ?? false) }
    }
}

/// What `gh` needs on the host, in words, with the command that fixes it (shown once in the
/// PR popover).
nonisolated public struct GhHint: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var command: String?

    public init?(_ status: GhStatus) {
        switch status {
        case .unknown, .ready: return nil
        case .missing:
            title = "GitHub CLI not found on the host"
            detail = "Pull requests come from the host's own gh; no token is stored in the app."
            command = "brew install gh   # or see cli.github.com"
        case .notAuthenticated:
            title = "GitHub CLI is not signed in"
            detail = "Sign in once on the host; the app never sees the token."
            command = "gh auth login"
        }
    }
}

/// A host's tabs grouped the git way: repository, then worktree (branch), then the tabs in it.
/// Tabs outside any repository stay as they are, in host order.
nonisolated public struct RepoSidebar: Equatable, Sendable {
    public struct Worktree: Identifiable, Equatable, Sendable {
        public var state: WorktreeState
        /// Tabs whose focused pane (else any pane) is in this worktree, in host order.
        public var tabs: [TabId]
        public var id: String { state.path }
    }

    public struct Repo: Identifiable, Equatable, Sendable {
        /// The main worktree's path.
        public var id: String
        public var name: String
        /// Main first, then the others as the daemon ordered them.
        public var worktrees: [Worktree]
        public var tabCount: Int { worktrees.reduce(0) { $0 + $1.tabs.count } }
    }

    /// Before any repository: tabs not in one, in host order.
    public var looseTabs: [TabId]
    public var repos: [Repo]

    public init(looseTabs: [TabId], repos: [Repo]) {
        self.looseTabs = looseTabs
        self.repos = repos
    }

    /// Groups `tabs`. Worktrees without tabs are kept (the sidebar shows them quietly) only
    /// when `includeIdle`.
    public static func build(tabs: [Tab], snapshot: RepoSnapshot?, includeIdle: Bool = true) -> RepoSidebar {
        guard let snapshot, !snapshot.worktrees.isEmpty else {
            return RepoSidebar(looseTabs: tabs.map(\.id), repos: [])
        }
        let paneWorktree = Dictionary(snapshot.panes.map { ($0.paneId, $0.worktree) }, uniquingKeysWith: { a, _ in a })
        var tabsByWorktree: [String: [TabId]] = [:]
        var loose: [TabId] = []
        for tab in tabs {
            let focused = paneWorktree[tab.focused.rawValue]
            let any = tab.root.panes.lazy.compactMap { paneWorktree[$0.rawValue] }.first
            if let path = focused ?? any {
                tabsByWorktree[path, default: []].append(tab.id)
            } else {
                loose.append(tab.id)
            }
        }
        var repos: [Repo] = []
        var index: [String: Int] = [:]
        for state in snapshot.worktrees {
            let tabs = tabsByWorktree[state.path] ?? []
            if tabs.isEmpty && !includeIdle { continue }
            let entry = Worktree(state: state, tabs: tabs)
            if let i = index[state.repo] {
                repos[i].worktrees.append(entry)
            } else {
                index[state.repo] = repos.count
                repos.append(Repo(id: state.repo, name: state.repoName, worktrees: [entry]))
            }
        }
        // A repository only shows while one of its worktrees has a tab.
        repos.removeAll { $0.tabCount == 0 }
        return RepoSidebar(looseTabs: loose, repos: repos)
    }

    /// The worktree a tab is in.
    public func worktree(of tab: TabId) -> WorktreeState? {
        for repo in repos {
            for wt in repo.worktrees where wt.tabs.contains(tab) { return wt.state }
        }
        return nil
    }

    /// Tabs in display order (loose first, then by repository and worktree), for ⌘1–9.
    public var orderedTabs: [TabId] {
        looseTabs + repos.flatMap { $0.worktrees.flatMap(\.tabs) }
    }
}
