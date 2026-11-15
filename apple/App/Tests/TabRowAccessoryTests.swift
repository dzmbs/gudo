import DesignSystem
import XCTest
@testable import App

/// A tab row ends in one thing, the most pressing; ⌘ swaps it for the row's shortcut.
@MainActor
final class TabRowAccessoryTests: XCTestCase {
    private func pick(
        selecting: Bool = false, shortcut: Int? = nil, state: AgentState? = nil, panes: Int = 1, expanded: Bool = false,
        hovered: Bool = false, attention: Bool = false, diff: Bool = false, presence: Bool = false
    ) -> TabRowAccessory {
        TabRowAccessory.pick(
            isSelecting: selecting, isSelected: false, shortcut: shortcut, state: state, paneCount: panes, opensPanes: true,
            isExpanded: expanded, isHovered: hovered, needsAttention: attention, hasDiff: diff, hasPresence: presence)
    }

    func testAQuietRowEndsInNothing() {
        XCTAssertEqual(pick(), .none)
        XCTAssertEqual(pick(state: .working), .none, "a working agent is the dot on its tile")
    }

    func testTheShortcutShowsOnlyWhileCommandIsHeld() {
        XCTAssertEqual(pick(shortcut: 3, state: .blocked, diff: true), .shortcut(3))
        XCTAssertEqual(pick(state: .blocked, diff: true), .pill(.blocked))
    }

    func testWhatNeedsYouComesBeforeTheDiff() {
        XCTAssertEqual(pick(state: .error, attention: true, diff: true, presence: true), .pill(.error))
        XCTAssertEqual(pick(attention: true, diff: true, presence: true), .attention)
        XCTAssertEqual(pick(diff: true, presence: true), .diff)
        XCTAssertEqual(pick(presence: true), .presence)
    }

    func testThePanesChevronComesWithTheHoverOrWhileOpen() {
        XCTAssertEqual(pick(panes: 2, diff: true), .diff)
        XCTAssertEqual(pick(panes: 2, hovered: true, diff: true), .panes(isExpanded: false))
        XCTAssertEqual(pick(panes: 2, expanded: true, diff: true), .panes(isExpanded: true))
        XCTAssertEqual(pick(panes: 1, hovered: true), .none)
        XCTAssertEqual(pick(state: .blocked, panes: 2, hovered: true), .pill(.blocked), "what needs you stays")
    }

    func testSelectModeShowsOnlyTheCheck() {
        XCTAssertEqual(pick(selecting: true, shortcut: 2, state: .blocked), .selection(isSelected: false))
    }
}
