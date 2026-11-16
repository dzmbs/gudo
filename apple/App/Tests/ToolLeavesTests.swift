import HostKit
import PaneLayout
import GudoCore
import XCTest
@testable import App
#if os(iOS)
import UIKit
#endif

/// Files, Changes, Ports and Replays open as leaves beside the focused pane on the Mac: asked
/// again, the open leaf comes forward instead of a second one. A phone keeps sheets.
@MainActor
final class ToolLeavesTests: XCTestCase {
    func testAToolOpensBesideThePaneAndIsReused() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let id = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.activeMixedTab = id

        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // A phone keeps sheets: a split has no room there.
            model.sheet = .diff
            XCTAssertEqual(model.sheet, .diff)
            XCTAssertEqual(model.activeMixed?.leaves.count, 2)
            return
        }
        #endif
        model.sheet = .diff
        XCTAssertNil(model.sheet, "no sheet: a leaf")
        let tab = try XCTUnwrap(model.activeMixed)
        XCTAssertEqual(tab.leaves.count, 3, "two terminals and Changes")
        XCTAssertEqual(tab.focusedTool?.tool, .changes)
        let changes = try XCTUnwrap(tab.focusedTool)

        // Focus a terminal, ask again: the same leaf takes the focus.
        model.focusLeaf(tab.leaves[0], inMixedTab: id)
        model.sheet = .diff
        XCTAssertEqual(model.activeMixed?.leaves.count, 3)
        XCTAssertEqual(model.activeMixed?.focusedTool, changes)

        // Another tool is a leaf of its own.
        model.sheet = .files
        XCTAssertEqual(model.activeMixed?.leaves.count, 4)
        XCTAssertEqual(model.activeMixed?.focusedTool?.tool, .files)
        XCTAssertNotEqual(model.title(ofMixedTab: try XCTUnwrap(model.activeMixed)), "Files", "the tab keeps its terminal's name")

        model.closeTool(changes.id)
        XCTAssertNil(model.composites.tab(containingTool: changes.id))
        XCTAssertEqual(model.activeMixed?.leaves.count, 3)
    }

    func testFocusNextPaneVisitsEveryLeafOfAMixedTab() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let id = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.activeMixedTab = id
        _ = model.composites.addTool(ToolMember(hostId: "h1", tool: .files), to: id)
        let leaves = try XCTUnwrap(model.activeMixed?.leaves)
        XCTAssertEqual(leaves.count, 3)
        model.focusLeaf(leaves[0], inMixedTab: id)

        var visited: [PaneId] = []
        for _ in leaves {
            model.focusPane(offset: 1)
            visited.append(try XCTUnwrap(model.activeMixed?.focusedLeaf))
        }
        XCTAssertEqual(visited, [leaves[1], leaves[2], leaves[0]], "⌘] reaches the tool leaf and wraps")
        model.focusPane(offset: -1)
        XCTAssertEqual(model.activeMixed?.focusedLeaf, leaves[2], "⌘[ goes back")
    }

    /// Errors become calm states; the host's own words are a detail, never the message.
    func testProblemsAreClassifiedNotEchoed() {
        let git = "fatal: not a git repository (or any of the parent directories): .git"
        let notRepo = ToolProblem(WorkspaceError.NotFound(message: git), path: "/home/me/notes")
        XCTAssertEqual(notRepo, .notARepository(folder: "/home/me/notes"))
        XCTAssertEqual(notRepo.title, "Not a Git Repository")
        XCTAssertEqual(notRepo.message, "“notes” isn't inside a Git repository.")
        XCTAssertFalse(notRepo.message.contains("fatal"))

        let gone = ToolProblem(WorkspaceError.NotFound(message: "/home/me/old"), path: "/home/me/old")
        XCTAssertEqual(gone, .folderNotFound(path: "/home/me/old"))
        XCTAssertEqual(gone.title, "Folder Not Found")

        XCTAssertEqual(ToolProblem(HostError.notConnected), .disconnected)
        XCTAssertEqual(ToolProblem(WorkspaceError.Disconnected), .disconnected)
        let failed = ToolProblem(WorkspaceError.Failed(message: "git log: boom"))
        XCTAssertNil(failed.title, "the screen names what failed")
        XCTAssertEqual(failed.detail, "git log: boom")
        XCTAssertFalse(failed.message.contains("boom"))
        XCTAssertEqual(ToolProblem(notRepo), notRepo, "a classified problem passes through")
    }

    func testNoAccessNamesTheSharedFoldersAndHowToChangeThem() {
        let denied = ToolProblem(
            WorkspaceError.Denied(message: "/private/tmp/qa is outside the allowed directories"), path: "/private/tmp/qa")
        XCTAssertEqual(denied.title, "No Access")
        XCTAssertTrue(denied.message.contains("“qa” is outside the folders the host shares"), denied.message)
        XCTAssertTrue(denied.message.contains("home folder"))
        XCTAssertTrue(denied.message.contains("files.allow"), "says how to change them")
        XCTAssertEqual(denied.detail, "/private/tmp/qa", "the folder, not the host's sentence cut in the middle")
        XCTAssertFalse(denied.canRetry, "asking again can't help")
        XCTAssertTrue(ToolProblem(WorkspaceError.Failed(message: "boom")).canRetry)
    }

    func testOtherSheetsStaySheets() {
        let model = WindowModel(app: .shared)
        model.sheet = .shortcuts
        XCTAssertEqual(model.sheet, .shortcuts)
        model.sheet = nil
    }

    #if os(macOS)
    /// Settings is its own window on the Mac, never a sheet over the workspace.
    func testSettingsOpensItsWindowOnTheMac() {
        let model = WindowModel(app: .shared)
        let requests = SettingsLink.shared.openRequests
        model.sheet = .settings
        XCTAssertNil(model.sheet)
        XCTAssertEqual(SettingsLink.shared.openRequests, requests + 1)
    }
    #endif
}
