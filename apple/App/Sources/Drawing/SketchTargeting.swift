import Foundation
import PaneLayout

/// Which pane a sketch is on and where it goes, as decisions without views: the tab's other panes
/// are shielded while sketching, a click on one moves the sketch there, and Send goes to the
/// target pane's own agent.
enum SketchTargeting {
    enum Click: Equatable {
        /// The sketch is already on that pane.
        case stay
        /// The sketch moves to that pane (asking first when it holds strokes).
        case retarget
        /// The pane cannot be sketched on (a local shell, a canvas, view only).
        case unavailable
    }

    static func click(on pane: PaneId, target: PaneId, canSketch: Bool) -> Click {
        if pane == target { return .stay }
        return canSketch ? .retarget : .unavailable
    }

    /// Every pane of the tab but the target.
    static func shielded(tabPanes: [PaneId], target: PaneId) -> [PaneId] {
        tabPanes.filter { $0 != target }
    }

    /// The Send button's agent: only one running in the sketched pane itself. Without one the
    /// button becomes a menu that lists the tab's agents first.
    static func primary(target: UInt64, in destinations: [AgentDestination]) -> AgentDestination? {
        destinations.first { $0.sameHost && $0.pane == target }
    }

    /// The target pane's agent first, then its tab's, then the host's, then other hosts'.
    static func ordered(_ destinations: [AgentDestination], target: UInt64?, tabPanes: Set<UInt64>) -> [AgentDestination] {
        func rank(_ destination: AgentDestination) -> Int {
            guard destination.sameHost else { return 3 }
            if destination.pane == target { return 0 }
            return tabPanes.contains(destination.pane) ? 1 : 2
        }
        return destinations.sorted { (rank($0), $0.hostName, $0.pane) < (rank($1), $1.hostName, $1.pane) }
    }
}
