import Observation
import PaneLayout

/// Values per pane that views observe one pane at a time. Reading `table[pane]` depends on
/// that pane alone, so a sidebar row re-renders when its own agent changes, not when any of a
/// host's hundreds of panes does; `all` depends on every change.
@MainActor
@Observable
public final class PaneTable<Value: Equatable> {
    /// Every value, for readers that look at all panes.
    public private(set) var all: [PaneId: Value] = [:]
    @ObservationIgnored private var cells: [PaneId: PaneCell<Value>] = [:]

    public init() {}

    public subscript(pane: PaneId) -> Value? {
        if let cell = cells[pane] { return cell.value }
        // Not there yet: depend on the table until it is.
        return all[pane]
    }

    public var isEmpty: Bool { all.isEmpty }

    /// Sets a pane's value (nil removes it); an equal value changes nothing.
    func set(_ value: Value?, for pane: PaneId) {
        guard all[pane] != value else { return }
        all[pane] = value
        if let value {
            if let cell = cells[pane] { cell.value = value } else { cells[pane] = PaneCell(value) }
        } else if let cell = cells.removeValue(forKey: pane) {
            cell.value = nil
        }
    }
}

@MainActor
@Observable
final class PaneCell<Value> {
    var value: Value?
    init(_ value: Value) { self.value = value }
}
