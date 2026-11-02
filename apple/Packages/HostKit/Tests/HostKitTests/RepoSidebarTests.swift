import Foundation
@testable import HostKit
import PaneLayout
import Testing
import GudoCore

/// The git grouping of a host's tabs (repository → worktree → tabs) and the PR helpers.
@Suite struct RepoSidebarTests {
    static func worktree(
        _ path: String, repo: String = "/r", main: Bool = false, branch: String? = nil,
        pr: PullRequest? = nil
    ) -> WorktreeState {
        WorktreeState(
            path: path, repo: repo, repoName: (repo as NSString).lastPathComponent,
            name: (path as NSString).lastPathComponent, main: main, branch: branch, head: "abcdef1234",
            upstream: nil, ahead: 0, behind: 0, added: 0, removed: 0, changedFiles: 0, dirty: false,
            pr: pr, scripts: [], setup: nil, teardown: nil, managed: !main, mergedAtMs: nil, updatedAtMs: 1)
    }

    static func pr(_ checks: [CheckStatus], state: PrState = .open, merge: MergeState = .clean) -> PullRequest {
        PullRequest(
            number: 7, title: "T", state: state, draft: false, url: "https://github.com/o/r/pull/7",
            headRef: "b", additions: 3, deletions: 1, mergeState: merge,
            checks: checks.enumerated().map { i, s in
                PrCheck(name: "c\(i)", status: s, url: "https://github.com/o/r/actions/runs/\(i)/job/1", workflow: nil)
            },
            fetchedAtMs: 0)
    }

    static func tab(_ id: UInt64, panes: [UInt64], focused: UInt64? = nil) -> Tab {
        let nodes = panes.map { Node.leaf(PaneId($0)) }
        let root = nodes.dropFirst().reduce(nodes[0]) { .split(axis: .horizontal, ratio: 0.5, first: $0, second: $1) }
        return Tab(id: TabId(id), root: root, focused: PaneId(focused ?? panes[0]))
    }

    @Test func groupsTabsByRepositoryThenWorktree() {
        let snapshot = RepoSnapshot(
            rev: 3,
            panes: [
                PaneRepo(paneId: 11, worktree: "/r"), PaneRepo(paneId: 21, worktree: "/w/feat"),
                PaneRepo(paneId: 22, worktree: "/r"), PaneRepo(paneId: 41, worktree: "/s"),
            ],
            worktrees: [
                Self.worktree("/r", main: true, branch: "main"),
                Self.worktree("/w/feat", branch: "feat"),
                Self.worktree("/w/idle", branch: "idle"),
                Self.worktree("/s", repo: "/s", main: true, branch: "main"),
                Self.worktree("/q", repo: "/q", main: true, branch: "main"),
            ],
            gh: .unknown)
        let tabs = [
            Self.tab(1, panes: [11]),
            Self.tab(2, panes: [21, 22], focused: 21), // focused pane decides
            Self.tab(3, panes: [31]), // no repository
            Self.tab(4, panes: [41]),
        ]
        let sidebar = RepoSidebar.build(tabs: tabs, snapshot: snapshot)
        #expect(sidebar.looseTabs == [TabId(3)])
        #expect(sidebar.repos.map(\.id) == ["/r", "/s"]) // "/q" has no tab
        #expect(sidebar.repos[0].worktrees.map(\.id) == ["/r", "/w/feat", "/w/idle"])
        #expect(sidebar.repos[0].worktrees.map(\.tabs) == [[TabId(1)], [TabId(2)], []])
        #expect(sidebar.orderedTabs == [TabId(3), TabId(1), TabId(2), TabId(4)])
        #expect(sidebar.worktree(of: TabId(2))?.branch == "feat")
        let busy = RepoSidebar.build(tabs: tabs, snapshot: snapshot, includeIdle: false)
        #expect(busy.repos[0].worktrees.map(\.id) == ["/r", "/w/feat"])
    }

    @Test func withoutASnapshotEveryTabIsLoose() {
        let tabs = [Self.tab(1, panes: [1]), Self.tab(2, panes: [2])]
        #expect(RepoSidebar.build(tabs: tabs, snapshot: nil).looseTabs == [TabId(1), TabId(2)])
    }

    @Test func subtitleHidesWhenItRepeatsTheBranch() {
        #expect(Self.worktree("/w/feat", branch: "user/feat").subtitle == nil)
        #expect(Self.worktree("/w/quiet-otter", branch: "fix-login").subtitle == "quiet-otter")
        #expect(Self.worktree("/r", main: true, branch: "main").subtitle == nil)
        #expect(Self.worktree("/w/x", branch: nil).displayBranch == "detached at abcdef1")
    }

    @Test func checksSummaryFollowsSupacodesRule() {
        #expect(ChecksSummary(statuses: []) == .none)
        #expect(ChecksSummary(statuses: [.success, .success]) == .passing(2))
        #expect(ChecksSummary(statuses: [.success, .pending]) == .pending(failed: 0, running: 1, passed: 1))
        #expect(ChecksSummary(statuses: [.failure, .pending, .success]) == .failing(failed: 1, running: 1, passed: 1))
        #expect(ChecksSummary(statuses: [.failure, .pending, .success]).words == "1 failed, 1 in progress, 1 successful")
    }

    @Test func mergeIsOfferedOnlyWhenGitHubAllowsIt() {
        #expect(Self.pr([], merge: .clean).mergeBlocker == nil)
        #expect(Self.pr([.failure], merge: .unstable).mergeBlocker == nil)
        #expect(Self.pr([], merge: .blocked).mergeBlocker != nil)
        #expect(Self.pr([], merge: .behind).mergeBlocker != nil)
        #expect(Self.pr([], state: .merged).mergeBlocker == "#7 is merged")
        #expect(Self.pr([.failure]).hasRerunnableFailures)
        #expect(!Self.pr([.success]).hasRerunnableFailures)
    }

    @Test func ghHintsNameTheFix() {
        #expect(GhHint(.ready(account: "me")) == nil)
        #expect(GhHint(.missing)?.command?.contains("gh") == true)
        #expect(GhHint(.notAuthenticated(message: "x"))?.command == "gh auth login")
    }
}
