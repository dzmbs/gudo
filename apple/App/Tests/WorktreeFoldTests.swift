import Foundation
import GudoCore
import HostKit
import PaneLayout
import XCTest
@testable import App

/// Which of a repository's worktrees the sidebar shows, and which fold behind "N more".
@MainActor
final class WorktreeFoldTests: XCTestCase {
    private func worktree(_ path: String, main: Bool = false, added: UInt32 = 0, dirty: Bool = false) -> WorktreeState {
        WorktreeState(
            path: path, repo: "/r", repoName: "r", name: (path as NSString).lastPathComponent, main: main,
            branch: (path as NSString).lastPathComponent, head: "abcdef1234",
            upstream: nil, ahead: 0, behind: 0, added: added, removed: 0, changedFiles: dirty ? 1 : 0, dirty: dirty,
            pr: nil, scripts: [], setup: nil, teardown: nil, managed: !main, mergedAtMs: nil, updatedAtMs: 1)
    }

    private func tab(_ id: UInt64, pane: UInt64) -> Tab {
        Tab(id: TabId(id), root: .leaf(PaneId(pane)), focused: PaneId(pane))
    }

    private func repo(tabs: [Tab], panes: [(UInt64, String)]) throws -> RepoSidebar.Repo {
        let snapshot = RepoSnapshot(
            rev: 1,
            panes: panes.map { PaneRepo(paneId: $0.0, worktree: $0.1) },
            worktrees: [
                worktree("/r", main: true),
                worktree("/w/bench"),
                worktree("/w/bonds"),
                worktree("/w/dirty", added: 29, dirty: true),
                worktree("/w/harness"),
            ],
            gh: .unknown)
        return try XCTUnwrap(RepoSidebar.build(tabs: tabs, snapshot: snapshot).repos.first)
    }

    func testOnlyWorktreesWithTabsShowTheRestFold() throws {
        let fold = WorktreeFold(try repo(tabs: [tab(1, pane: 10)], panes: [(10, "/w/bonds")]))
        XCTAssertEqual(fold.shown.map(\.id), ["/w/bonds"])
        XCTAssertEqual(fold.folded.map(\.id), ["/r", "/w/bench", "/w/dirty", "/w/harness"])
        XCTAssertEqual(fold.foldedTitle, "4 more worktrees")
    }

    func testMainWorktreeShowsOnlyWithTabs() throws {
        let fold = WorktreeFold(try repo(tabs: [tab(1, pane: 10), tab(2, pane: 20)], panes: [(10, "/r"), (20, "/w/bench")]))
        XCTAssertEqual(fold.shown.map(\.id), ["/r", "/w/bench"], "the daemon's order is kept")
        XCTAssertFalse(fold.folded.contains { $0.state.main })
    }

    func testUncommittedChangesWithoutTabsStayFolded() throws {
        let fold = WorktreeFold(try repo(tabs: [tab(1, pane: 10)], panes: [(10, "/w/bonds")]))
        let dirty = try XCTUnwrap(fold.folded.first { $0.id == "/w/dirty" })
        XCTAssertEqual(dirty.state.added, 29, "its badge comes along when expanded")
    }

    func testAWorktreeThatGainsATabJoinsTheShownSet() throws {
        let before = WorktreeFold(try repo(tabs: [tab(1, pane: 10)], panes: [(10, "/w/bonds")]))
        XCTAssertTrue(before.folded.contains { $0.id == "/w/harness" })
        let after = WorktreeFold(try repo(tabs: [tab(1, pane: 10), tab(2, pane: 20)], panes: [(10, "/w/bonds"), (20, "/w/harness")]))
        XCTAssertEqual(after.shown.map(\.id), ["/w/bonds", "/w/harness"])
        XCTAssertEqual(after.foldedTitle, "3 more worktrees")
    }

    func testTheSelectedTabsWorktreeShows() throws {
        let tabs = [tab(1, pane: 10), tab(2, pane: 20)]
        let fold = WorktreeFold(try repo(tabs: tabs, panes: [(10, "/w/bonds"), (20, "/w/bench")]))
        let selected = TabId(2)
        XCTAssertTrue(fold.shown.contains { $0.tabs.contains(selected) })
    }

    func testNothingFoldsWhenEveryWorktreeHasATab() throws {
        let paths = ["/r", "/w/bench", "/w/bonds", "/w/dirty", "/w/harness"]
        let tabs = paths.indices.map { tab(UInt64($0 + 1), pane: UInt64($0 + 10)) }
        let fold = WorktreeFold(try repo(tabs: tabs, panes: paths.indices.map { (UInt64($0 + 10), paths[$0]) }))
        XCTAssertEqual(fold.shown.count, 5)
        XCTAssertTrue(fold.folded.isEmpty)
    }

    func testSingularTitle() throws {
        let paths = ["/r", "/w/bench", "/w/bonds", "/w/dirty"]
        let tabs = paths.indices.map { tab(UInt64($0 + 1), pane: UInt64($0 + 10)) }
        let fold = WorktreeFold(try repo(tabs: tabs, panes: paths.indices.map { (UInt64($0 + 10), paths[$0]) }))
        XCTAssertEqual(fold.foldedTitle, "1 more worktree")
    }

    func testExpandedIsRememberedPerRepositoryAndHost() throws {
        let suite = "worktree-fold-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WorktreeFoldStore(defaults: defaults)
        XCTAssertFalse(store.isExpanded(repo: "/r", host: "a"), "folded by default")
        store.toggle(repo: "/r", host: "a")
        XCTAssertTrue(store.isExpanded(repo: "/r", host: "a"))
        XCTAssertFalse(store.isExpanded(repo: "/r", host: "b"), "per host")
        XCTAssertFalse(store.isExpanded(repo: "/s", host: "a"), "per repository")

        let relaunched = WorktreeFoldStore(defaults: defaults)
        XCTAssertTrue(relaunched.isExpanded(repo: "/r", host: "a"))
        relaunched.toggle(repo: "/r", host: "a")
        XCTAssertFalse(WorktreeFoldStore(defaults: defaults).isExpanded(repo: "/r", host: "a"), "collapsing is remembered too")
    }
}
