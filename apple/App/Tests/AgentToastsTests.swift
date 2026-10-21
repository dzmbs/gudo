import DesignSystem
import Foundation
import XCTest
@testable import App

/// Agent toasts, Inbox filters and Settings search: the models, no UI.
@MainActor
final class AgentToastsTests: XCTestCase {
    private func item(_ id: String, _ state: AgentState, request: AgentItem.Request? = nil, pane: UInt64? = 1, command: Bool = false, unseen: Bool = false) -> AgentItem {
        AgentItem(id: id, agent: .claude, hostName: "studio", sessionTitle: "proj", state: state, since: .now, prompt: "fix it",
                  request: request, hostId: "h", paneId: pane, unseen: unseen, isCommand: command)
    }

    // MARK: Toasts

    func testTheFirstLookIsABaselineNotAToast() {
        let toasts = AgentToasts()
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "ls"))], isShown: { _ in false })
        XCTAssertTrue(toasts.cards.isEmpty)
    }

    func testNeedsYouFinishedAndFailedBecomeCardsNewestFirst() {
        let toasts = AgentToasts()
        toasts.update([item("a", .working), item("b", .working), item("c", .working)], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "rm -rf build")), item("b", .working), item("c", .working)], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "rm -rf build")), item("b", .done), item("c", .error)], isShown: { _ in false })
        XCTAssertEqual(toasts.cards.map(\.item.id), ["c", "b", "a"])
        XCTAssertEqual(Set(toasts.cards.map(\.kind)), [.needsYou, .finished, .failed])
        XCTAssertEqual(toasts.cards.last?.item.id, "a", "the oldest card is at the bottom")
    }

    func testAShownAgentACommandAndHistoryNeverToast() {
        let toasts = AgentToasts()
        let before = [item("a", .working), item("cmd", .working, command: true), item("gone", .working, pane: nil)]
        toasts.update(before, isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .question("?")), item("cmd", .done, command: true), item("gone", .done, pane: nil)],
                      isShown: { $0.id == "a" })
        XCTAssertTrue(toasts.cards.isEmpty)
    }

    func testANewRequestOnTheSameAgentToastsAgainAndReplacesItsCard() {
        let toasts = AgentToasts()
        toasts.update([item("a", .working)], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "one"))], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "two"))], isShown: { _ in false })
        XCTAssertEqual(toasts.cards.count, 1)
        XCTAssertEqual(toasts.cards.first?.item.request, .permission(tool: "Bash", detail: "two"))
    }

    func testACardGoesWhenItsAgentMovesOn() {
        let toasts = AgentToasts()
        toasts.update([item("a", .working)], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "ls"))], isShown: { _ in false })
        XCTAssertEqual(toasts.cards.count, 1)
        // Approved on another device: the agent works again.
        toasts.update([item("a", .working)], isShown: { _ in false })
        XCTAssertTrue(toasts.cards.isEmpty)
    }

    func testAtMostThreeCards() {
        let toasts = AgentToasts()
        let ids = ["a", "b", "c", "d", "e"]
        toasts.update(ids.map { item($0, .working) }, isShown: { _ in false })
        toasts.update(ids.map { item($0, .done) }, isShown: { _ in false })
        XCTAssertEqual(toasts.cards.count, AgentToasts.maxShown)
    }

    func testCardsExpireAfterEightSecondsButNotWhileHeld() {
        let toasts = AgentToasts()
        let start = Date(timeIntervalSince1970: 1000)
        toasts.update([item("a", .working)], isShown: { _ in false }, now: start)
        toasts.update([item("a", .done)], isShown: { _ in false }, now: start)
        toasts.expire(now: start + 7)
        XCTAssertEqual(toasts.cards.count, 1)
        // Held from 7 s to 20 s: the 13 s are given back (plus a moment).
        toasts.hold(true, now: start + 7)
        toasts.expire(now: start + 20)
        XCTAssertEqual(toasts.cards.count, 1, "nothing leaves while held")
        toasts.hold(false, now: start + 20)
        toasts.expire(now: start + 21)
        XCTAssertEqual(toasts.cards.count, 1)
        toasts.expire(now: start + 22)
        XCTAssertTrue(toasts.cards.isEmpty)
    }

    // MARK: Inbox filters

    func testInboxFilters() {
        let items = [
            item("blocked", .blocked, request: .question("?")), item("working", .working),
            item("done", .done, unseen: true), item("failed", .error),
        ]
        func ids(_ filter: InboxFilter) -> [String] { items.filter(filter.includes).map(\.id) }
        XCTAssertEqual(ids(.all).count, 4)
        XCTAssertEqual(ids(.needsYou), ["blocked"])
        XCTAssertEqual(ids(.running), ["working"])
        XCTAssertEqual(ids(.unread), ["done"])
        XCTAssertEqual(ids(.errors), ["failed"])
    }

    // MARK: Settings search

    func testSettingsSearchMatchesGhosttyKeysTitlesAndSynonyms() {
        XCTAssertEqual(SettingsIndex.search("cursor-style").first?.id, "cursor-style")
        XCTAssertEqual(SettingsIndex.search("Option Sends").first?.id, "macos-option-as-alt")
        XCTAssertEqual(SettingsIndex.search("caret").map(\.id).prefix(2).sorted(), ["cursor-style", "cursor-style-blink"])
        // Every word must match.
        XCTAssertEqual(SettingsIndex.search("cursor blink").map(\.id), ["cursor-style-blink"])
        XCTAssertTrue(SettingsIndex.search("no such setting").isEmpty)
        XCTAssertTrue(SettingsIndex.search("  ").isEmpty)
    }

    func testEverySettingsEntryHasAUniqueAnchor() {
        let ids = SettingsIndex.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
