import DesignSystem
import Foundation
import Observation
import PaneLayout
import SwiftUI

/// Cards for agents this window isn't showing that start waiting, finish or fail. Only the front
/// window shows them, and none expires while the pointer or a finger is on the stack.
@MainActor
@Observable
final class AgentToasts {
    enum Kind: Hashable, Sendable {
        case needsYou, finished, failed
    }

    struct Card: Identifiable, Hashable {
        /// A new request on the same agent is a new card.
        var id: String
        var kind: Kind
        var item: AgentItem
        var expires: Date
    }

    static let lifetime: TimeInterval = 8
    static let maxShown = 3

    /// Newest first.
    private(set) var cards: [Card] = []
    private(set) var isHeld = false
    @ObservationIgnored private var heldSince: Date?
    /// Nil until the first look: what already waits when the window opens is in the Inbox, not a toast.
    @ObservationIgnored private var known: [AgentItem.ID: Snapshot]?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    struct Snapshot: Hashable {
        var state: AgentState
        var request: AgentItem.Request?
    }

    /// What became a toast between two looks at the feed. Commands and anything `isShown` are left out.
    static func arrivals(
        _ items: [AgentItem], known: [AgentItem.ID: Snapshot], isShown: (AgentItem) -> Bool
    ) -> [(Kind, AgentItem)] {
        items.compactMap { item in
            guard !item.isCommand, item.paneId != nil, let before = known[item.id] else { return nil }
            let now = Snapshot(state: item.state, request: item.request)
            guard now != before, !isShown(item) else { return nil }
            switch item.state {
            case .blocked where before.state != .blocked || before.request != item.request:
                return (.needsYou, item)
            case .done where before.state == .working:
                return (.finished, item)
            case .error where before.state == .working || before.state == .blocked:
                return (.failed, item)
            default:
                return nil
            }
        }
    }

    func update(_ items: [AgentItem], isShown: (AgentItem) -> Bool, now: Date = .now) {
        let snapshots = Dictionary(items.map { ($0.id, Snapshot(state: $0.state, request: $0.request)) }, uniquingKeysWith: { first, _ in first })
        defer { known = snapshots }
        guard let known else { return }
        // A card that no longer says what is true goes (answered in the Inbox or on another device).
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cards = self.cards
        cards.removeAll { card in
            guard let item = current[card.item.id] else { return true }
            switch card.kind {
            case .needsYou: return item.state != .blocked || item.request != card.item.request
            case .finished, .failed: return item.state == .working || item.state == .blocked
            }
        }
        for (kind, item) in Self.arrivals(items, known: known, isShown: isShown) {
            let id = "\(item.id)/\(kind)/\(item.request.map { "\($0.hashValue)" } ?? "")"
            cards.removeAll { $0.item.id == item.id }
            cards.insert(Card(id: id, kind: kind, item: item, expires: now + Self.lifetime), at: 0)
        }
        if cards.count > Self.maxShown { cards.removeLast(cards.count - Self.maxShown) }
        guard cards != self.cards else { return }
        self.cards = cards
        scheduleExpiry()
    }

    func dismiss(item id: AgentItem.ID) {
        cards.removeAll { $0.item.id == id }
        scheduleExpiry()
    }

    func dismiss(_ card: Card.ID) {
        cards.removeAll { $0.id == card }
        scheduleExpiry()
    }

    /// Time held is given back to every card.
    func hold(_ held: Bool, now: Date = .now) {
        guard held != isHeld else { return }
        isHeld = held
        if held {
            heldSince = now
            expiry?.cancel()
        } else {
            let paused = now.timeIntervalSince(heldSince ?? now)
            // Half a second of grace after the pointer leaves.
            for index in cards.indices { cards[index].expires += paused + 0.5 }
            heldSince = nil
            scheduleExpiry()
        }
    }

    func expire(now: Date = .now) {
        guard !isHeld else { return }
        cards.removeAll { $0.expires <= now }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard !isHeld, let next = cards.map(\.expires).min() else { return }
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            withAnimation(DS.Motion.overlay) { self.expire() }
            self.scheduleExpiry()
        }
    }
}

extension WindowModel {
    /// Shows the agent that has waited longest, on any host.
    func jumpToWaitingAgent() {
        let waiting = agents.items.filter { $0.state == .blocked && $0.paneId != nil }
        guard let oldest = waiting.min(by: { $0.since < $1.since }) else {
            toasts.show(Toast("No agent is waiting for you", systemImage: "checkmark.circle", style: .neutral))
            return
        }
        agentToasts.dismiss(item: oldest.id)
        destination = .terminal
        agents.open(oldest.id)
    }

    func isShowing(_ item: AgentItem) -> Bool {
        guard destination == .terminal, isOnScreen, let pane = item.paneId, let host = item.hostId,
              workspace?.hostId == host, let tab = workspace?.session.activeTab
        else { return false }
        return tab.root.panes.contains(PaneId(pane))
    }

    func followAgentToasts() {
        guard !isClosed else { return }
        let items = withObservationTracking {
            _ = (destination, isOnScreen, workspace?.session.activeTab)
            return agents.items
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAgentToasts() }
        }
        updateAgentToasts(items)
    }

    private func updateAgentToasts(_ items: [AgentItem]) {
        let front = ActiveWindow.model === self && !isPresentation
        agentToasts.update(items, isShown: { item in
            guard front else { return true }
            return destination == .inbox || isShowing(item)
        })
    }
}
