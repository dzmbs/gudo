import Foundation

/// Paces the streaming reply's rows on screen: the rows it has fully revealed show whole, the
/// one being written shows its revealed characters, and later ones wait at no height. The frame
/// keeps the full text, so copying, selecting and the turn's footer read all of it. Work per
/// frame is the reply's own rows, never the history above it.
@MainActor
final class ChatReplyReveal {
    enum Shown: Equatable {
        case whole
        case partial(Int)
        case waiting
    }

    private struct Part {
        let id: ChatRowID
        let revision: UInt32
        let length: Int
    }

    /// A reply with more rows than this shows whole rather than being paced.
    static let partLimit = 3_000

    private var reply: String?
    private var parts: [Part] = []
    private var reveal = ChatTextReveal(showing: 0)
    private var shown: [ChatRowID: Shown] = [:]
    private var lastFrameTime: ContinuousClock.Instant?

    var isSettled: Bool { reveal.isSettled }
    /// Rendered characters of the reply on screen, for measuring how smoothly it grows.
    var revealedLength: Int { reveal.revealed }

    func shown(_ id: ChatRowID) -> Shown { shown[id] ?? .whole }

    /// The row as it is on screen, or nil while it waits.
    func display(_ row: ChatRow) -> ChatRow? {
        switch shown(row.id) {
        case .whole: return row
        case .waiting: return nil
        case .partial(let length):
            guard case .markdown(var block) = row.content else { return row }
            block.revealed = length
            var display = ChatRow(id: row.id, revision: row.revision, turn: row.turn, content: .markdown(block))
            display.preview = row.preview
            return display
        }
    }

    /// Follows `frame`'s streaming reply; returns the rows whose display changed. Without
    /// `paces`, as when nothing paints, the reply shows whole.
    func update(_ frame: TimelineFrame, paces: Bool) -> Set<ChatRowID> {
        guard paces, let replyID = frame.streamingReply else { return snap() }
        var start = frame.rows.endIndex
        while start > frame.rows.startIndex, frame.rows[start - 1].id.item == replyID,
              frame.rows.endIndex - start < Self.partLimit {
            start -= 1
        }
        guard start < frame.rows.endIndex else { return snap() }
        let previous = reply == replyID ? parts : []
        parts = frame.rows[start...].enumerated().map { index, row in
            if previous.indices.contains(index), previous[index].id == row.id, previous[index].revision == row.revision {
                return previous[index]
            }
            let length = if case .markdown(let block) = row.content { block.revealLength } else { 1 }
            return Part(id: row.id, revision: row.revision, length: length)
        }
        let total = parts.reduce(0) { $0 + $1.length }
        if reply != replyID {
            reply = replyID
            reveal = ChatTextReveal(showing: total)
            lastFrameTime = nil
        } else {
            reveal.retarget(total)
        }
        return layOut()
    }

    /// Advances the reveal for the display frame at `now`; returns the rows whose display changed.
    func advance(at now: ContinuousClock.Instant) -> Set<ChatRowID> {
        guard !reveal.isSettled else { lastFrameTime = nil; return [] }
        guard let frame = ChatTextReveal.frame(after: lastFrameTime, at: now) else { return [] }
        lastFrameTime = frame.frameTime
        reveal.advance(by: frame.elapsed)
        return layOut()
    }

    /// Shows the whole reply; returns the rows that were held back.
    func snap() -> Set<ChatRowID> {
        guard reply != nil || !shown.isEmpty else { return [] }
        let changed = Set(shown.keys)
        reply = nil
        parts.removeAll(keepingCapacity: true)
        reveal = ChatTextReveal(showing: 0)
        shown.removeAll(keepingCapacity: true)
        lastFrameTime = nil
        return changed
    }

    private func layOut() -> Set<ChatRowID> {
        var next: [ChatRowID: Shown] = [:]
        var start = 0
        for part in parts {
            let end = start + part.length
            if end > reveal.revealed {
                next[part.id] = start < reveal.revealed ? .partial(reveal.revealed - start) : .waiting
            }
            start = end
        }
        assert(start == reveal.target, "the reveal counts a different reply")
        var changed: Set<ChatRowID> = []
        for (id, state) in next where shown[id] != state { changed.insert(id) }
        for id in shown.keys where next[id] == nil { changed.insert(id) }
        shown = next
        return changed
    }
}
