import DesignSystem
import XCTest
@testable import App

/// What each row offers on a swipe and in its menu, and what asks first or comes back.
final class RowActionsTests: XCTestCase {
    func testATerminalTabClosesWithUndoUnlessAnAgentIsAtWork() {
        let quiet = RowActions(.terminalTab(isBusy: false))
        XCTAssertEqual(quiet.trailing, [.closeTab])
        XCTAssertEqual(quiet.leading, [.rename])
        XCTAssertEqual(quiet.fullSwipe, .closeTab)
        XCTAssertFalse(quiet.needsConfirmation(.closeTab))
        XCTAssertTrue(quiet.undoable.contains(.closeTab))

        let busy = RowActions(.terminalTab(isBusy: true))
        XCTAssertTrue(busy.needsConfirmation(.closeTab), "closing ends the agent")
        XCTAssertFalse(busy.undoable.contains(.closeTab))
    }

    func testAnEditorClosesWithUndoAndStoppingItsServerAsksFirst() {
        let editor = RowActions(.editorTab)
        XCTAssertEqual(editor.trailing, [.closeEditor, .stopServer])
        XCTAssertEqual(editor.fullSwipe, .closeEditor)
        XCTAssertTrue(editor.undoable.contains(.closeEditor))
        XCTAssertFalse(editor.needsConfirmation(.closeEditor))
        XCTAssertTrue(editor.needsConfirmation(.stopServer))
    }

    func testPagesCloseWithUndoAndMixedTabsWithout() {
        XCTAssertTrue(RowActions(.browserTab).undoable.contains(.closeTab))
        XCTAssertTrue(RowActions(.mixedTab(isBusy: false)).undoable.isEmpty, "host panes end with the tab")
        XCTAssertTrue(RowActions(.mixedTab(isBusy: true)).needsConfirmation(.closeTab))
    }

    func testAnAgentStopsAndIsMarkedReadOnlyOnceItIsDone() {
        let working = RowActions(.agent(.working, canMarkRead: true))
        XCTAssertEqual(working.trailing, [.stopAgent, .closeTab])
        XCTAssertTrue(working.leading.isEmpty)
        XCTAssertTrue(working.needsConfirmation(.stopAgent))

        let done = RowActions(.agent(.done, canMarkRead: true))
        XCTAssertEqual(done.leading, [.markRead])
        XCTAssertFalse(done.needsConfirmation(.stopAgent), "nothing left to lose")
        XCTAssertTrue(RowActions(.agent(.done, canMarkRead: false)).leading.isEmpty)
    }

    func testAgentsScreenItemsOfferStopOnlyWhileLive() {
        XCTAssertEqual(RowActions(.agentItem(.blocked, canStop: true)).trailing, [.markDone, .stopAgent])
        XCTAssertEqual(RowActions(.agentItem(.done, canStop: true)).trailing, [.markDone])
        XCTAssertEqual(RowActions(.agentItem(.working, canStop: false)).trailing, [.markDone])
        XCTAssertEqual(RowActions(.agentItem(.done, canStop: true)).fullSwipe, .markDone)
    }

    func testTheMainWorktreeIsNeverDeleted() {
        XCTAssertTrue(RowActions(.worktree(isMain: true)).all.isEmpty)
        XCTAssertEqual(RowActions(.worktree(isMain: false)).trailing, [.deleteWorktree, .archiveWorktree])
    }

    func testHostsDisconnectOnAFullSwipeAndRemovingAsksFirst() {
        let open = RowActions(.host(isLocal: false, isOpen: true, isPinned: false))
        XCTAssertEqual(open.fullSwipe, .disconnect)
        XCTAssertEqual(open.trailing, [.disconnect, .removeHost])
        XCTAssertEqual(open.leading, [.pin])
        XCTAssertTrue(open.needsConfirmation(.removeHost))
        XCTAssertFalse(open.needsConfirmation(.disconnect))

        let closed = RowActions(.host(isLocal: false, isOpen: false, isPinned: true))
        XCTAssertEqual(closed.fullSwipe, .removeHost)
        XCTAssertEqual(closed.leading, [.unpin])
        XCTAssertTrue(RowActions(.host(isLocal: true, isOpen: true, isPinned: false)).all.isEmpty, "this device stays")
    }

    func testOneVocabulary() {
        for action in RowAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertLessThanOrEqual(action.shortTitle.count, 10, "a swipe button holds one short word")
            XCTAssertEqual(action.tint == .red, action.isDestructive && action != .stopServer, "\(action): red means it ends something")
        }
        XCTAssertEqual(RowAction.closeTab.systemImage, RowAction.closeEditor.systemImage)
        XCTAssertEqual(RowAction.removeHost.confirmation("studio").title, "Remove “studio”?")
    }
}
