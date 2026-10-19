import Synchronization
import TerminalCore

/// Names rows of a pane's terminal the way the daemon does — "`fromBottom` rows above the
/// bottom at output offset `atSeq`" (`RowAnchor`, docs/DAEMON.md §7.3) — and pins them in the
/// app's own terminal, which has applied more or less output than the daemon's VT at that
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

    /// The output offset the terminal has applied.
    public var appliedSeq: UInt64 { state.withLock { $0.applied } }

    /// Call after the terminal applied output up to `seq` (`snapshot`: its state was replaced by
    /// a snapshot taken at `seq`; earlier samples no longer describe it).
    public func observe(seq: UInt64, snapshot: Bool = false) {
        // Pins dropped here are freed after the mutex is released (their deinit locks the terminal).
        var dropped: RowPin?
        state.withLock { s in
            if snapshot {
                s.samples.removeAll()
                dropped = s.reference
                s.reference = nil
            }
            rebaselineIfResized(&s)
            if !terminal.isAlternateScreen {
                if let ref = s.reference, let fb = terminal.fromBottom(of: ref) {
                    s.scrolled = max(s.scrolled, s.base + fb)
                    if fb > Self.referenceReset { dropped = repin(&s) }
                } else {
                    dropped = repin(&s) ?? dropped
                }
            }
            s.applied = seq
            s.samples.append((seq, s.scrolled))
            if s.samples.count > Self.maxSamples { s.samples.removeFirst(s.samples.count - Self.maxSamples) }
        }
        _ = dropped
    }

    /// A resize moves the bottom row without scrolling anything (rows are added or taken at the
    /// bottom, or pulled back from scrollback): keep `scrolled` and move the baseline instead, so
    /// distances from the bottom are measured on the grid as it is now (both VTs resize alike).
    private func rebaselineIfResized(_ s: inout State) {
        let size = terminal.size
        guard size != s.size else { return }
        s.size = size
        if let ref = s.reference, let fb = terminal.fromBottom(of: ref) { s.base = s.scrolled - fb }
    }

    /// Pins the reference near the top of the active area; returns the old one to free.
    private func repin(_ s: inout State) -> RowPin? {
        let rows = terminal.size.rows
        guard let pin = terminal.pinRow(fromBottom: max(rows - 1, 0)), let fb = terminal.fromBottom(of: pin) else { return nil }
        let old = s.reference
        s.reference = pin
        s.base = s.scrolled - fb
        return old
    }

    /// Pins the row of an anchor; nil while the terminal has not applied `atSeq` yet, or when
    /// the row is no longer on the screen.
    public func pin(atSeq: UInt64, fromBottom: UInt64) -> RowPin? {
        state.withLock { s in
            rebaselineIfResized(&s)
            guard atSeq <= s.applied, let ref = s.reference else { return nil }
            let then = s.samples.last(where: { $0.seq <= atSeq })?.scrolled ?? s.samples.first?.scrolled ?? s.scrolled
            // target.fromBottom(now) = fromBottom + scrolled(now) − scrolled(atSeq), and
            // scrolled(now) = base + ref.fromBottom(now), so the target sits a fixed distance
            // from the reference.
            let distance = Int(fromBottom) + s.base - then
            return terminal.pinRow(relativeTo: ref, offset: -distance)
        }
    }

    /// The anchor naming a pinned row: `fromBottom` as of the last applied offset.
    public func anchor(of pin: RowPin) -> (atSeq: UInt64, fromBottom: UInt64)? {
        state.withLock { s in
            rebaselineIfResized(&s)
            guard let ref = s.reference else { return nil }
            let rows = terminal.screenRows(of: [ref, pin])
            guard let refRow = rows[0], let row = rows[1] else { return nil }
            let fromBottom = (refRow - row) + s.scrolled - s.base
            return (s.applied, UInt64(max(fromBottom, 0)))
        }
    }
}
