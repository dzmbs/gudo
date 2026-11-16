import Foundation
import HostKit
import TerminalCore
import os

/// A remote pane's stream, held at a resize that gives the grid more rows than its terminal
/// holds above the screen, until the host's older scrollback is in.
///
/// A snapshot brings only the screen and a few rows above it; the rest comes in pages when
/// asked. A terminal whose rows grow pulls rows down from its scrollback, so a grid grown past
/// what is held (⌘−, a pinch, a taller window) would pull fewer than the host's terminal did and
/// keep blank rows where the host shows its older output. The host's pages are prepended first,
/// so the resize finds them; output after the resize waits behind it, in order.
nonisolated final class ScrollbackRefill: Sendable {
    /// The longest the stream waits for a page before resizing with what it has.
    static let longestWait = Duration.milliseconds(400)

    private struct State {
        var held: [PaneEvent]?
        var rowsNeeded = 0
        var historyDone = false
        var holds = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let terminal: Terminal
    private let requestHistory: @Sendable () -> Bool
    private let apply: @Sendable (PaneEvent) -> Void

    init(terminal: Terminal, requestHistory: @escaping @Sendable () -> Bool, apply: @escaping @Sendable (PaneEvent) -> Void) {
        self.terminal = terminal
        self.requestHistory = requestHistory
        self.apply = apply
    }

    /// Applies `event` now, or after the resize it is held behind. Events are applied under the
    /// lock, so the release after `longestWait` keeps the stream's order.
    func deliver(_ event: PaneEvent) {
        state.withLock { state in
            switch event {
            case .snapshot: state.historyDone = false
            case .history(_, let done): if done { state.historyDone = true }
            default: break
            }
            if state.held != nil {
                hold(event, in: &state)
            } else if case .resized(_, let rows, _, _) = event, let missing = missingRows(growingTo: rows), !state.historyDone,
                      requestHistory()
            {
                state.held = [event]
                state.rowsNeeded = missing
                state.holds += 1
                releaseLater(hold: state.holds)
            } else {
                apply(event)
            }
        }
    }

    private func hold(_ event: PaneEvent, in state: inout State) {
        switch event {
        case .history:
            apply(event)
            if state.historyDone || rowsAbove >= state.rowsNeeded || !requestHistory() { release(&state) }
        case .connection, .sizingChanged:
            apply(event)
        default:
            state.held?.append(event)
        }
    }

    private func release(_ state: inout State) {
        let held = state.held ?? []
        state.held = nil
        held.forEach(apply)
    }

    private func releaseLater(hold: Int) {
        Task.detached { [weak self] in
            try? await Task.sleep(for: Self.longestWait)
            guard let refill = self else { return }
            refill.state.withLock { state in
                if state.holds == hold, state.held != nil { refill.release(&state) }
            }
        }
    }

    private var rowsAbove: Int {
        let scrollbar = terminal.scrollbar
        return max(0, scrollbar.total - scrollbar.visible)
    }

    /// The rows a grid of `rows` pulls down that the terminal does not hold; nil when it holds them.
    private func missingRows(growingTo rows: UInt16) -> Int? {
        let added = Int(rows) - terminal.size.rows
        guard added > rowsAbove else { return nil }
        return added
    }
}
