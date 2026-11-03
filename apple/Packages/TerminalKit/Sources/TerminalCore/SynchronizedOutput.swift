import Foundation

/// Synchronized output (DEC private mode 2026): a program brackets a redraw with `CSI ? 2026 h`
/// and `CSI ? 2026 l` so the screen never shows it half done. Output inside the brackets is held
/// here and parsed in one piece when the update ends, however the stream was cut on its way (PTY
/// reads, network packets). Every reader of the terminal (renderer, search, echo prediction)
/// then sees the frame before the update or the frame after it, never one in between.
///
/// A hold ends at `CSI ? 2026 l`; after `timeout`, as in Ghostty, so a program that crashed
/// mid-update cannot freeze the screen; past `maxHeldBytes`; and, when the terminal answers
/// queries itself, at a query (the program may be waiting for the reply before it finishes).
struct SynchronizedOutput {
    static let timeout = Duration.seconds(1)
    static let maxHeldBytes = 4 << 20

    private(set) var held: [UInt8] = []
    private(set) var heldSince: ContinuousClock.Instant?
    private var scanner = Scanner()

    var isHolding: Bool { heldSince != nil }

    /// Passes `bytes` on to `parse` in order, except what a synchronized update holds back.
    mutating func take(
        _ bytes: UnsafeBufferPointer<UInt8>, answersQueries: Bool, now: () -> ContinuousClock.Instant,
        parse: (UnsafeBufferPointer<UInt8>) -> Void
    ) {
        if let heldSince, now() - heldSince >= Self.timeout { release(parse) }
        var start = 0
        var index = 0
        while index < bytes.count {
            guard let event = scanner.next(bytes, from: &index, queries: isHolding && answersQueries) else { continue }
            let through = UnsafeBufferPointer(rebasing: bytes[start..<index])
            switch event {
            case .begin where !isHolding:
                parse(through)
                start = index
                heldSince = now()
            case .end where isHolding, .query where isHolding && answersQueries:
                held.append(contentsOf: through)
                start = index
                release(parse)
            default:
                break
            }
        }
        scanner.finish(bytes)
        let rest = UnsafeBufferPointer(rebasing: bytes[start...])
        guard isHolding else { return parse(rest) }
        held.append(contentsOf: rest)
        if held.count > Self.maxHeldBytes { release(parse) }
    }

    /// Parses everything held and ends the hold.
    mutating func release(_ parse: (UnsafeBufferPointer<UInt8>) -> Void) {
        let bytes = held
        held = []
        heldSince = nil
        bytes.withUnsafeBufferPointer(parse)
    }

    /// Ends the hold if it lasted `timeout`. Returns whether it did.
    mutating func releaseIfExpired(now: ContinuousClock.Instant, _ parse: (UnsafeBufferPointer<UInt8>) -> Void) -> Bool {
        guard let heldSince, now - heldSince >= Self.timeout else { return false }
        release(parse)
        return true
    }

    /// Starts over for a terminal replaced by a snapshot, holding at once if the snapshot was
    /// taken in the middle of an update.
    mutating func restart(inUpdate: Bool, now: ContinuousClock.Instant) {
        self = SynchronizedOutput()
        if inUpdate { heldSince = now }
    }
}

extension SynchronizedOutput {
    enum Event { case begin, end, query }

    /// Finds `CSI ? … 2026 … h/l` and the CSI queries a terminal answers (DSR, DA, DECRQM,
    /// XTVERSION, the kitty keyboard query), across chunk boundaries.
    struct Scanner {
        private enum State { case ground, escape, csiStart, csi }

        private var state = State.ground
        private var isPrivate = false
        private var prefix: UInt8 = 0
        private var intermediate: UInt8 = 0
        private var parameter = 0
        private var hasSynchronizedOutput = false
        /// The two bytes before the current chunk, for a `CSI ?` cut right before its `?`.
        private var carried: (UInt8, UInt8) = (0, 0)

        /// Advances `index` past the next byte that ends a sequence of interest (returning it), or
        /// to the end of `bytes` (returning nil). Without `queries`, only `CSI ?` sequences
        /// matter, so it jumps from `?` to `?`, which most output has none of.
        mutating func next(_ bytes: UnsafeBufferPointer<UInt8>, from index: inout Int, queries: Bool) -> Event? {
            let base = bytes.baseAddress!
            while index < bytes.count {
                if state == .ground {
                    let target: UInt8 = queries ? 0x1B : 0x3F
                    guard let found = memchr(base + index, Int32(target), bytes.count - index) else {
                        index = bytes.count
                        return nil
                    }
                    let at = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    index = at + 1
                    if queries {
                        state = .escape
                    } else if streamByte(at - 2, in: base) == 0x1B, streamByte(at - 1, in: base) == 0x5B {
                        state = .csiStart
                        resetSequence()
                        _ = step(0x3F)
                    }
                    continue
                }
                let byte = base[index]
                index += 1
                if state == .csiStart, byte != 0x3F, byte != 0x1B, !queries {
                    state = .ground
                    continue
                }
                if let event = step(byte) { return event }
            }
            return nil
        }

        /// Keeps the chunk's last two bytes for the next one.
        mutating func finish(_ bytes: UnsafeBufferPointer<UInt8>) {
            guard let base = bytes.baseAddress else { return }
            carried = (streamByte(bytes.count - 2, in: base), streamByte(bytes.count - 1, in: base))
        }

        /// The byte at `offset` in the current chunk, or before it for a negative offset.
        private func streamByte(_ offset: Int, in base: UnsafePointer<UInt8>) -> UInt8 {
            switch offset {
            case 0...: base[offset]
            case -1: carried.1
            default: carried.0
            }
        }

        private mutating func resetSequence() {
            isPrivate = false
            prefix = 0
            intermediate = 0
            parameter = 0
            hasSynchronizedOutput = false
        }

        private mutating func step(_ byte: UInt8) -> Event? {
            if state == .csiStart { state = .csi }
            switch (state, byte) {
            case (_, 0x1B):
                state = .escape
            case (_, 0x18), (_, 0x1A):
                state = .ground
            case (.escape, 0x5B):
                state = .csiStart
                resetSequence()
            case (.escape, _):
                state = .ground
            case (.csi, 0x30...0x39):
                parameter = min(parameter * 10 + Int(byte - 0x30), 100_000)
            case (.csi, 0x3A), (.csi, 0x3B):
                finishParameter()
            case (.csi, 0x3C...0x3F):
                if byte == 0x3F { isPrivate = true }
                prefix = byte
            case (.csi, 0x20...0x2F):
                intermediate = byte
            case (.csi, 0x40...0x7E):
                state = .ground
                finishParameter()
                return event(final: byte)
            case (.csi, _), (.ground, _), (.csiStart, _):
                break
            }
            return nil
        }

        private mutating func finishParameter() {
            if parameter == 2026 { hasSynchronizedOutput = true }
            parameter = 0
        }

        private func event(final: UInt8) -> Event? {
            switch final {
            case UInt8(ascii: "h") where isPrivate && hasSynchronizedOutput && intermediate == 0: .begin
            case UInt8(ascii: "l") where isPrivate && hasSynchronizedOutput && intermediate == 0: .end
            case UInt8(ascii: "n"), UInt8(ascii: "c"): .query
            case UInt8(ascii: "p") where intermediate == UInt8(ascii: "$"): .query
            case UInt8(ascii: "q") where prefix == UInt8(ascii: ">"): .query
            case UInt8(ascii: "u") where prefix == UInt8(ascii: "?"): .query
            default: nil
            }
        }
    }
}
