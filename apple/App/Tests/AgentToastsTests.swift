import DesignSystem
import Foundation
import SwiftUI
import XCTest
@testable import App

/// Agent toasts, Inbox filters and Settings search: the models, no UI.
@MainActor
final class AgentToastsTests: XCTestCase {
    private func item(_ id: String, _ state: AgentState, request: AgentItem.Request? = nil, pane: UInt64? = 1, command: Bool = false, unseen: Bool = false) -> AgentItem {
        AgentItem(id: id, agent: .claude, hostName: "studio", sessionTitle: "proj", state: state, since: .now, prompt: "fix it",
                  request: request, hostId: "h", paneId: pane, unseen: unseen, isCommand: command)
    }

    func testTheFirstLookIsABaselineNotAToast() {
        let toasts = AgentToasts()
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "ls"))], isShown: { _ in false })
        XCTAssertTrue(toasts.cards.isEmpty)
    }

    func testNeedsYouFinishedAndFailedBecomeCardsNewestAtTheBottom() {
        let toasts = AgentToasts()
        toasts.update([item("a", .working), item("b", .working), item("c", .working)], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "rm -rf build")), item("b", .working), item("c", .working)], isShown: { _ in false })
        toasts.update([item("a", .blocked, request: .permission(tool: "Bash", detail: "rm -rf build")), item("b", .done), item("c", .error)], isShown: { _ in false })
        XCTAssertEqual(toasts.cards.map(\.item.id), ["a", "b", "c"])
        XCTAssertEqual(Set(toasts.cards.map(\.kind)), [.needsYou, .finished, .failed])
        XCTAssertEqual(toasts.cards.last?.item.id, "c", "the newest card is at the bottom")
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

    func testAHoldThatIsNeverReleasedStillEnds() {
        let toasts = AgentToasts()
        let start = Date(timeIntervalSince1970: 1000)
        toasts.update([item("a", .working)], isShown: { _ in false }, now: start)
        toasts.update([item("a", .done)], isShown: { _ in false }, now: start)
        // A touch the system cancels never reports its end.
        toasts.hold(true, now: start + 1)
        toasts.expire(now: start + 1 + AgentToasts.maximumHold - 1)
        XCTAssertEqual(toasts.cards.count, 1, "held up to the bound")
        toasts.expire(now: start + 1 + AgentToasts.maximumHold + AgentToasts.lifetime)
        XCTAssertTrue(toasts.cards.isEmpty, "a stuck hold gives up and the card leaves")
        XCTAssertFalse(toasts.isHeld)
    }

    func testASwipeSidewaysOrTowardTheEdgeDismissesAndASmallDragSettlesBack() {
        let small = CGSize(width: 12, height: 6)
        XCTAssertFalse(AgentToasts.swipeDismisses(translation: small, predicted: small, edge: .bottom))
        XCTAssertTrue(AgentToasts.swipeDismisses(translation: CGSize(width: -90, height: 4), predicted: CGSize(width: -90, height: 4), edge: .bottom))
        XCTAssertTrue(AgentToasts.swipeDismisses(translation: CGSize(width: 90, height: 0), predicted: CGSize(width: 90, height: 0), edge: .bottom))
        XCTAssertTrue(AgentToasts.swipeDismisses(translation: CGSize(width: 0, height: 70), predicted: CGSize(width: 0, height: 70), edge: .bottom))
        XCTAssertFalse(AgentToasts.swipeDismisses(translation: CGSize(width: 0, height: -70), predicted: CGSize(width: 0, height: -70), edge: .bottom),
                       "away from the edge it sits on is not a dismissal")
        XCTAssertTrue(AgentToasts.swipeDismisses(translation: CGSize(width: 0, height: -70), predicted: CGSize(width: 0, height: -70), edge: .top))
        XCTAssertTrue(AgentToasts.swipeDismisses(translation: CGSize(width: 0, height: 20), predicted: CGSize(width: 0, height: 240), edge: .bottom),
                      "a quick flick counts by where it was headed")
    }

    func testAMessageArrivingAfterCompletionUpdatesTheCardWithoutExtendingItsLifetime() {
        let toasts = AgentToasts()
        var agent = item("late", .working)
        toasts.update([agent], isShown: { _ in false })
        agent.state = .done
        toasts.update([agent], isShown: { _ in false })
        let expiry = toasts.cards.first?.expires
        agent.summary = "Added retry handling"
        toasts.update([agent], isShown: { _ in false })
        XCTAssertEqual(toasts.cards.first?.item.summary, "Added retry handling")
        XCTAssertEqual(toasts.cards.first?.expires, expiry)
    }

    func testToastBodiesUseTheFirstMessageLineAndNeverTheTerminalTitle() {
        var agent = item("message", .done)
        agent.prompt = "[ ! ] Action Required | Fix download flow | project"
        XCTAssertNil(AgentToasts.summary(for: agent))
        agent.summary = "claude finished"
        XCTAssertNil(AgentToasts.summary(for: agent))
        agent.summary = "[✓] Added retry handling | Tests pass\nDetailed output"
        XCTAssertEqual(AgentToasts.summary(for: agent), "Added retry handling. Tests pass.")
        agent.summary = "Fixed the build · ready to merge? | 3 files"
        XCTAssertEqual(AgentToasts.summary(for: agent), "Fixed the build. Ready to merge? 3 files.")
        agent.summary = "Action Required: Which branch should I use?"
        XCTAssertEqual(AgentToasts.summary(for: agent), "Which branch should I use?")
        agent.summary = nil
        agent.request = .question("[ ! ] Which branch should I use?\nMore context")
        XCTAssertEqual(AgentToasts.summary(for: agent), "Which branch should I use?")
    }

    func testInboxFilters() {
        let items = [
            item("blocked", .blocked, request: .question("?")), item("working", .working),
            item("done", .done, unseen: true), item("failed", .error),
        ]
        func ids(_ filter: InboxFilter) -> [String] { items.filter(filter.includes).map(\.id) }
        XCTAssertEqual(ids(.all).count, 4)
        XCTAssertEqual(ids(.needsYou), ["blocked", "failed"])
        XCTAssertEqual(ids(.running), ["working"])
        XCTAssertEqual(ids(.unread), ["done"])
        XCTAssertEqual(ids(.errors), ["failed"])
    }

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

@MainActor
enum AgentToastTestFixtures {
    static func seed(_ toasts: AgentToasts) {
        var waiting = AgentItem(id: "waiting", agent: .claude, hostName: "Host", sessionTitle: "project", state: .working,
                                since: .now, prompt: "[ ! ] Action Required | task | project", hostId: "host", paneId: 1)
        var finished = AgentItem(id: "finished", agent: .codex, hostName: "Host", sessionTitle: "project", state: .working,
                                 since: .now, prompt: "terminal title", hostId: "host", paneId: 2)
        toasts.update([waiting, finished], isShown: { _ in false })
        waiting.state = .blocked
        waiting.request = .permission(tool: "Bash", detail: "cargo test")
        finished.state = .done
        finished.summary = "[✓] Added retry handling | Tests pass\nDetailed output"
        toasts.update([waiting, finished], isShown: { _ in false })
        toasts.hold(true)
    }

    /// One agent on another computer finishing, with a long reply.
    static func seedFinished(_ toasts: AgentToasts) {
        var finished = AgentItem(id: "finished", agent: .claude, hostName: "studio", sessionTitle: "pool", state: .working,
                                 since: .now, prompt: "check the miners", hostId: "host", paneId: 2)
        toasts.update([finished], isShown: { _ in false })
        finished.state = .done
        finished.summary = "At 09:12 UTC two of the new outside miners started reporting stale shares again"
        toasts.update([finished], isShown: { _ in false })
        toasts.hold(true)
    }
}
