import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Tabs that called for the user while out of sight (a bell, an agent turning to need them),
/// until the user shows them. Each call is one beat of `attentionCue`.
struct TabAttention: Equatable {
    private var waiting: Set<TabRef> = []
    /// Only ever grows, so clearing a tab plays no beat.
    private var beats: [TabRef: Int] = [:]

    var isEmpty: Bool { waiting.isEmpty }

    func contains(_ ref: TabRef) -> Bool { waiting.contains(ref) }

    func beat(of ref: TabRef) -> Int { beats[ref] ?? 0 }

    mutating func raise(_ ref: TabRef) {
        waiting.insert(ref)
        beats[ref, default: 0] += 1
    }

    mutating func shown(_ ref: TabRef) {
        waiting.remove(ref)
    }

    /// Tabs whose most urgent agent turned to need the user between two looks.
    static func newlyBlocked(from previous: [TabRef: AgentState], to current: [TabRef: AgentState]) -> Set<TabRef> {
        Set(current.compactMap { ref, state in state == .blocked && previous[ref] != .blocked ? ref : nil })
    }
}

extension WindowModel {
    /// The tab is in front of the user: the current tab, or the other column's.
    func isShowingTab(_ ref: TabRef) -> Bool {
        destination == .terminal && (currentTab == ref || pairedTab == ref)
    }

    func noteBell(inPane pane: PaneId, onGroup id: String) {
        guard let tab = workspaces[id]?.session.tabs.first(where: { $0.root.panes.contains(pane) }) else { return }
        let ref = TabRef(hostId: id, tab: tab.id)
        guard !isShowingTab(ref) else { return }
        attention.raise(ref)
    }

    /// The tab on screen has been seen.
    func clearShownAttention() {
        for ref in [currentTab, pairedTab].compactMap(\.self) where isShowingTab(ref) && attention.contains(ref) {
            attention.shown(ref)
        }
    }

    /// Follows every tab's most urgent agent state: one turning to need the user out of sight
    /// calls for attention.
    func followAgentAttention() {
        guard !isClosed else { return }
        withObservationTracking {
            noteAgentStates()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAgentAttention() }
        }
    }

    func noteAgentStates() {
        let states = tabAgentStates()
        if let previous = attentionStates {
            for ref in TabAttention.newlyBlocked(from: previous, to: states) where !isShowingTab(ref) {
                attention.raise(ref)
            }
        }
        attentionStates = states
    }

    private func tabAgentStates() -> [TabRef: AgentState] {
        var states: [TabRef: AgentState] = [:]
        for group in groups.groups {
            for tab in group.tabs {
                let panes = tab.root.panes.compactMap { agentState(ofPane: $0, onGroup: group.id) }
                if let state = AgentState.mostUrgent(panes) { states[group.ref(tab.id)] = state }
            }
        }
        return states
    }
}
