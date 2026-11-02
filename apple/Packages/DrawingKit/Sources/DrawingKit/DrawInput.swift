import Foundation

/// The draw overlay's tools: one choice shared by the toolbar, Excalidraw's active tool and the
/// PencilKit layer, so a finger and the Pencil draw with the same tool.
public enum DrawTool: String, CaseIterable, Sendable, Hashable {
    case select, pen, rectangle, ellipse, arrow, text, eraser

    /// Excalidraw's `activeTool.type` for this tool (`pen` is PencilKit on iPad and iPhone and
    /// Excalidraw's own `freedraw` on the Mac).
    public var excalidrawType: String {
        switch self {
        case .select: "selection"
        case .pen: "freedraw"
        default: rawValue
        }
    }

    /// The tool for an Excalidraw `activeTool.type` the editor reports (keyboard shortcuts, the
    /// editor switching back to selection after text); nil for tools the toolbar does not offer.
    public init?(excalidrawType: String) {
        switch excalidrawType {
        case "selection", "lasso": self = .select
        case "freedraw": self = .pen
        case "rectangle", "diamond": self = .rectangle
        case "ellipse": self = .ellipse
        case "arrow", "line": self = .arrow
        case "text": self = .text
        case "eraser": self = .eraser
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .text: "Text"
        case .eraser: "Eraser"
        }
    }

    public var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }

    /// Single-key shortcuts while the overlay has the keyboard (Excalidraw's own letters).
    public var key: Character {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .text: "t"
        case .eraser: "e"
        }
    }
}

public enum DrawLayer: Sendable, Equatable {
    /// PencilKit (`InkCanvas`): Apple's latency and prediction, converted to `freedraw` on lift.
    case ink
    case editor
}

/// Touch routing on iPad and iPhone. One finger and the Pencil draw with the chosen tool; two
/// fingers scroll the terminal (handled above both layers); the Pencil always draws, so with
/// Select it inks rather than selecting.
public enum DrawRouting {
    public enum Touch: Sendable { case pencil, finger }

    public static func layer(for tool: DrawTool, touch: Touch) -> DrawLayer {
        switch tool {
        case .pen: .ink
        case .select: touch == .pencil ? .ink : .editor
        case .rectangle, .ellipse, .arrow, .text, .eraser: .editor
        }
    }

    /// Whether the ink layer takes touches at all for `tool`, and whether it must tell Pencil
    /// from finger in hit-testing (only Select does).
    public static func inkLayer(for tool: DrawTool) -> (interactive: Bool, pencilOnly: Bool) {
        switch tool {
        case .pen: (true, false)
        case .select: (true, true)
        default: (false, false)
        }
    }
}

/// The Pencil → Excalidraw hand-off of committed strokes, as bookkeeping without PencilKit: a
/// stroke is converted on lift and sent to the page; the PencilKit stroke stays until the page
/// confirms it drew the element (`inkApplied`). Elements made before the page has loaded its
/// scene wait, since the scene load would replace them. Removing PencilKit strokes while the
/// Pencil is down cancels the stroke in flight, so confirmed strokes are only removed between
/// strokes.
public struct InkHandoff: Sendable {
    public struct Pending: Sendable, Equatable {
        public var id: String
        public var sentAt: Double?
        public var attempts: Int
    }

    public private(set) var pending: [Pending] = []
    /// Confirmed by the page, waiting for the Pencil to lift before PencilKit drops them.
    public private(set) var confirmed: [String] = []
    public private(set) var pageLoaded = false
    public private(set) var strokeActive = false

    public init() {}

    /// A stroke was converted; returns whether to send it now.
    public mutating func converted(_ id: String, at time: Double) -> Bool {
        pending.append(Pending(id: id, sentAt: pageLoaded ? time : nil, attempts: pageLoaded ? 1 : 0))
        return pageLoaded
    }

    /// The page loaded its scene: the ids to send now (held until then).
    public mutating func loaded(at time: Double) -> [String] {
        pageLoaded = true
        var toSend: [String] = []
        for i in pending.indices where pending[i].sentAt == nil {
            pending[i].sentAt = time
            pending[i].attempts += 1
            toSend.append(pending[i].id)
        }
        return toSend
    }

    /// The page is loading a new scene (a reload): later strokes wait again.
    public mutating func reloading() {
        pageLoaded = false
        for i in pending.indices { pending[i].sentAt = nil }
    }

    public mutating func strokeBegan() { strokeActive = true }

    /// The Pencil lifted: confirmed strokes PencilKit may drop now.
    public mutating func strokeEnded() -> [String] {
        strokeActive = false
        defer { confirmed = [] }
        return confirmed
    }

    /// The page drew these elements. Returns the ids PencilKit may drop now (empty while a
    /// stroke is in flight; they come back from `strokeEnded`) and the confirmation latency.
    public mutating func applied(_ ids: [String], at time: Double) -> (drop: [String], latency: [String: Double]) {
        var latency: [String: Double] = [:]
        var known: [String] = []
        for id in ids {
            guard let index = pending.firstIndex(where: { $0.id == id }) else { continue }
            if let sent = pending[index].sentAt { latency[id] = time - sent }
            pending.remove(at: index)
            known.append(id)
        }
        if strokeActive {
            confirmed += known
            return ([], latency)
        }
        return (known, latency)
    }

    /// Strokes sent longer than `timeout` ago without a confirmation (resend them).
    public mutating func overdue(at time: Double, timeout: Double) -> [String] {
        var resend: [String] = []
        for i in pending.indices {
            guard let sent = pending[i].sentAt, time - sent > timeout, pending[i].attempts < 4 else { continue }
            pending[i].sentAt = time
            pending[i].attempts += 1
            resend.append(pending[i].id)
        }
        return resend
    }

    public var isSettled: Bool { pending.isEmpty }
}

/// One pane draws (or writes) at a time.
public enum DrawExclusivity {
    public enum Decision: Sendable, Equatable {
        case open
        case alreadyOpen
        /// Another pane draws with nothing on it: close it quietly and open.
        case closeOtherAndOpen
        /// Another pane holds a drawing: ask whether to place or discard it first.
        case ask
    }

    public static func decide(requester: UInt64, active: UInt64?, activeHasContent: Bool) -> Decision {
        guard let active else { return .open }
        if active == requester { return .alreadyOpen }
        return activeHasContent ? .ask : .closeOtherAndOpen
    }
}

/// Placements that can no longer be drawn at their row go to the pane's loose tray instead of
/// vanishing (docs/DAEMON.md §7.11).
public enum PlacementPlace: Sendable, Equatable {
    case pinned
    /// Waiting for the terminal to apply the output it was anchored to.
    case pending
    /// The anchor detached (cleared, scrolled out of the scrollback ring, daemon restart) or
    /// its row is gone from this device's scrollback.
    case loose

    public static func classify(live: Bool, pinned: Bool, rowOnScreen: Bool, atSeq: UInt64, applied: UInt64) -> PlacementPlace {
        guard live else { return .loose }
        if pinned { return rowOnScreen ? .pinned : .loose }
        return atSeq <= applied ? .loose : .pending
    }
}

/// Handwriting at the prompt ("Write" mode): what Scribble recognises collects here and shows
/// at the terminal prompt as marked text; nothing reaches the shell until it is committed.
public struct HandwritingDraft: Sendable, Equatable {
    public private(set) var text = ""

    public init(text: String = "") {
        self.text = text
    }

    /// The field's whole text after an edit (Scribble inserts, strike-through deletes, a
    /// keyboard edit).
    public mutating func update(_ text: String) {
        self.text = text
    }

    public mutating func clear() { text = "" }

    /// What the prompt shows: one line, as it will be typed.
    public var preview: String { Self.line(text) }

    public var isEmpty: Bool { preview.isEmpty }

    /// Commits: the text to type (one line) and clears the draft; nil when there is nothing.
    public mutating func commit() -> String? {
        let line = preview
        text = ""
        return line.isEmpty ? nil : line
    }

    /// Newlines and runs of whitespace become one space (Scribble breaks lines where the hand
    /// did; a shell line or an agent prompt wants one line), trimmed at both ends.
    static func line(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
