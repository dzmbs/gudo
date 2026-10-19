import DesignSystem
import Foundation
import HostKit
import UnnamedCore
import XCTest
@testable import App

/// The git workspace's app-side pieces without a daemon: scripts, settings, PR kinds.
@MainActor
final class GitWorkspaceTests: XCTestCase {
    private func worktree(scripts: [RepoScript]) -> WorktreeState {
        WorktreeState(
            path: "/w/a", repo: "/r", repoName: "r", name: "a", main: false, branch: "a", head: nil,
            upstream: nil, ahead: 0, behind: 0, added: 0, removed: 0, changedFiles: 0, dirty: false,
            pr: nil, scripts: scripts, setup: nil, teardown: nil, managed: true, mergedAtMs: nil, updatedAtMs: 0)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: GitSettings.globalScriptsKey)
        UserDefaults.standard.removeObject(forKey: GitSettings.mergeStrategyKey)
    }

    func testRepositoryScriptsComeFirstAndTheDefaultRunsOnCommandR() {
        GitSettings.globalScripts = [ScriptDef(name: "Lint", command: "make lint", icon: "exclamationmark.triangle", tint: "blue")]
        let git = GitUI()
        let wt = worktree(scripts: [
            RepoScript(name: "Test", command: "make test", icon: nil, tint: "yellow", isDefault: false),
            RepoScript(name: "Dev", command: "make dev", icon: "play", tint: "green", isDefault: true),
        ])
        XCTAssertEqual(git.scripts(for: wt).map(\.name), ["Test", "Dev", "Lint"])
        XCTAssertEqual(git.defaultScript(for: wt)?.name, "Dev")
        XCTAssertEqual(git.defaultScript(for: worktree(scripts: []))?.name, "Lint", "a global script when the repository has none")
        XCTAssertEqual(git.scripts(for: wt)[0].systemImage, "play", "a script without a symbol plays")
    }

    func testMergeStrategyComesFromSettings() {
        XCTAssertEqual(GitSettings.mergeStrategy, .merge, "supacode's default: a merge commit")
        UserDefaults.standard.set("squash", forKey: GitSettings.mergeStrategyKey)
        XCTAssertEqual(GitSettings.mergeStrategy, .squash)
        XCTAssertEqual(GitSettings.name(.rebase), "Rebase and Merge")
    }

    func testPullRequestKindsAndChecks() {
        var pr = PullRequest(
            number: 1, title: "t", state: .open, draft: true, url: "", headRef: "b", additions: 0, deletions: 0,
            mergeState: .draft, checks: [PrCheck(name: "x", status: .failure, url: nil, workflow: nil)], fetchedAtMs: 0)
        XCTAssertEqual(pr.kind, .draft)
        XCTAssertEqual(pr.checkKinds, [.failure])
        pr.state = .merged
        XCTAssertEqual(pr.kind, .merged)
    }
}
