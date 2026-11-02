import Synchronization
import TerminalCore

/// Names rows of a pane's terminal the way the daemon does — "`fromBottom` rows above the
/// bottom at output offset `atSeq`" (`RowAnchor`, docs/DAEMON.md §7.3) — and pins them in the
/// app's own terminal, which has applied more or less output than the daemon's VT at that
/// moment (the client half of `daemon::anchor::ScrollLog`).
///
/// After every chunk the terminal applies, `observe` records how many rows the primary screen
/// has scrolled so far, measured with a reference pin near the top of the active area (its
/// distance from the bottom grows by one per scrolled row, whether scrollback grows or is
/// pruned). Converting between an anchor and a pin then needs only the reference pin, which is
/// read under the terminal's lock together with the target, so output written concurrently
/// (on the connection's thread) never skews the result.
///
/// Lock order: the tracker's mutex, then the terminal's.
public final class RowTracker: Sendable {
    /// Scroll samples kept: a few seconds of chunks during a flood.
    static let maxSamples = 4096
    /// The reference pin is moved back near the bottom once this far up, so it is never pruned.
    static let referenceReset = 1000

    private struct State {
        var reference: RowPin?
        /// `scrolled = base + fromBottom(reference)`.
        var base = 0
        var scrolled = 0
        var applied: UInt64 = 0
        var samples: [(seq: UInt64, scrolled: Int)] = []
        /// The grid size the baseline was taken at.
        var size: (cols: Int, rows: Int) = (0, 0)
    }

    public let terminal: Terminal
    private let state = Mutex(State())

    public init(terminal: Terminal) {
        self.terminal = terminal
    }

    public var appliedSeq: UInt64 { state.withLock { $0.applied } }

    /// Call after the terminal applied output up to `seq` (`snapshot`: its state was replaced by
    /// a snapshot taken at `seq`; earlier samples no longer describe it).
    public func observe(seq: UInt64, snapshot: Bool = false) {
        // Pins dropped here are freed after the mutex is released (their deinit locks the terminal).
        var dropped: RowPin?
        state.withLock { state in
            if snapshot {
                state.samples.removeAll()
                dropped = state.reference
                state.reference = nil
            }
            rebaselineIfResized(&state)
            if !terminal.isAlternateScreen {
                if let reference = state.reference, let referenceFromBottom = terminal.fromBottom(of: reference) {
                    state.scrolled = max(state.scrolled, state.base + referenceFromBottom)
                    if referenceFromBottom > Self.referenceReset { dropped = repin(&state) }
                } else {
                    dropped = repin(&state) ?? dropped
                }
            }
            state.applied = seq
            state.samples.append((seq, state.scrolled))
            if state.samples.count > Self.maxSamples { state.samples.removeFirst(state.samples.count - Self.maxSamples) }
        }
        _ = dropped
    }

    /// A resize moves the bottom row without scrolling anything (rows are added or taken at the
    /// bottom, or pulled back from scrollback): keep `scrolled` and move the baseline instead, so
    /// distances from the bottom are measured on the grid as it is now (both VTs resize alike).
    private func rebaselineIfResized(_ state: inout State) {
        let size = terminal.size
        guard size != state.size else { return }
        state.size = size
        if let reference = state.reference, let referenceFromBottom = terminal.fromBottom(of: reference) {
            state.base = state.scrolled - referenceFromBottom
        }
    }

    /// Pins the reference near the top of the active area; returns the old one to free.
    private func repin(_ state: inout State) -> RowPin? {
        let rows = terminal.size.rows
        guard let pin = terminal.pinRow(fromBottom: max(rows - 1, 0)), let pinFromBottom = terminal.fromBottom(of: pin) else { return nil }
        let old = state.reference
        state.reference = pin
        state.base = state.scrolled - pinFromBottom
        return old
    }

    /// Pins the row of an anchor; nil while the terminal has not applied `atSeq` yet, or when
    /// the row is no longer on the screen.
    public func pin(atSeq: UInt64, fromBottom: UInt64) -> RowPin? {
        state.withLock { state in
            rebaselineIfResized(&state)
            guard atSeq <= state.applied, let reference = state.reference else { return nil }
            let scrolledThen = state.samples.last(where: { $0.seq <= atSeq })?.scrolled
                ?? state.samples.first?.scrolled ?? state.scrolled
            // target.fromBottom(now) = fromBottom + scrolled(now) − scrolled(atSeq), and
            // scrolled(now) = base + reference.fromBottom(now), so the target sits a fixed
            // distance from the reference.
            let distance = Int(fromBottom) + state.base - scrolledThen
            return terminal.pinRow(relativeTo: reference, offset: -distance)
        }
    }

    /// The anchor naming a pinned row: `fromBottom` as of the last applied offset.
    public func anchor(of pin: RowPin) -> (atSeq: UInt64, fromBottom: UInt64)? {
        state.withLock { state in
            rebaselineIfResized(&state)
            guard let reference = state.reference else { return nil }
            let rows = terminal.screenRows(of: [reference, pin])
            guard let referenceRow = rows[0], let row = rows[1] else { return nil }
            let fromBottom = (referenceRow - row) + state.scrolled - state.base
            return (state.applied, UInt64(max(fromBottom, 0)))
        }
    }
}
