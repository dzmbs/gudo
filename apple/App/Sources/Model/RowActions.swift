import DesignSystem
import Foundation

/// What a list row offers on a swipe, a long press or a right-click. One vocabulary for every row
/// (sidebar tabs, editors, pages, agents, worktrees, hosts; the Agents and Hosts screens): the same
/// names and symbols wherever an action appears.
nonisolated enum RowAction: String, Hashable, CaseIterable, Sendable {
    case closeTab, closeEditor, stopServer, rename, openInNewWindow
    case stopAgent, markRead, markDone, open
    case archiveWorktree, deleteWorktree
    case disconnect, removeHost, pin, unpin

    /// The menu title.
    var title: String {
        switch self {
        case .closeTab: "Close Tab"
        case .closeEditor: "Close Editor"
        case .stopServer: "Stop Server"
        case .rename: "Rename…"
        case .openInNewWindow: "Open in New Window"
        case .stopAgent: "Stop Agent"
        case .markRead: "Mark as Read"
        case .markDone: "Mark Done"
        case .open: "Open"
        case .archiveWorktree: "Archive Worktree…"
        case .deleteWorktree: "Delete Worktree…"
        case .disconnect: "Disconnect"
        case .removeHost: "Remove Host…"
        case .pin: "Pin"
        case .unpin: "Unpin"
        }
    }

    /// The swipe button's word (Mail's: one short word under the symbol).
    var shortTitle: String {
        switch self {
        case .closeTab, .closeEditor: "Close"
        case .stopServer, .stopAgent: "Stop"
        case .rename: "Rename"
        case .openInNewWindow: "Window"
        case .markRead: "Read"
        case .markDone: "Done"
        case .open: "Open"
        case .archiveWorktree: "Archive"
        case .deleteWorktree: "Delete"
        case .disconnect: "Disconnect"
        case .removeHost: "Remove"
        case .pin: "Pin"
        case .unpin: "Unpin"
        }
    }

    var systemImage: String {
        switch self {
        case .closeTab, .closeEditor: "xmark"
        case .stopServer: "stop.circle"
        case .rename: "pencil"
        case .openInNewWindow: "macwindow.badge.plus"
        case .stopAgent: "stop.fill"
        case .markRead: "envelope.open"
        case .markDone: "checkmark"
        case .open: "arrow.up.forward"
        case .archiveWorktree: "archivebox"
        case .deleteWorktree, .removeHost: "trash"
        case .disconnect: "bolt.horizontal.circle"
        case .pin: "pin"
        case .unpin: "pin.slash"
        }
    }

    /// Red in menus and on swipes.
    var isDestructive: Bool {
        switch self {
        case .closeTab, .closeEditor, .stopServer, .stopAgent, .deleteWorktree, .removeHost: true
        default: false
        }
    }

    /// The swipe button's fill, in Mail's vocabulary: red ends something, orange stops or puts
    /// away, blue goes somewhere, indigo edits, yellow pins. Never grey: a grey button reads as
    /// disabled.
    var tint: RowTint {
        switch self {
        case .closeTab, .closeEditor, .stopAgent, .deleteWorktree, .removeHost: .red
        case .stopServer, .disconnect, .archiveWorktree: .orange
        case .markRead, .open, .openInNewWindow: .blue
        case .markDone: .green
        case .rename: .indigo
        case .pin, .unpin: .yellow
        }
    }

    /// The test identifier of the swipe button.
    var identifier: String { "row-action-\(rawValue)" }
}

nonisolated enum RowTint: Sendable { case red, orange, yellow, green, blue, indigo }

/// A row's actions: what each swipe edge shows (outermost first) and what a full swipe does.
nonisolated struct RowActions: Equatable, Sendable {
    /// What a row is, as far as its actions go.
    enum Kind: Equatable, Sendable {
        /// A terminal tab; `isBusy` while an agent in it works or waits.
        case terminalTab(isBusy: Bool)
        case editorTab
        case browserTab
        /// Panes from several hosts in one tab.
        case mixedTab(isBusy: Bool)
        /// An agent in a pane: its state, and whether its host can mark it read.
        case agent(DesignSystem.AgentState, canMarkRead: Bool)
        /// An Agents-screen item.
        case agentItem(DesignSystem.AgentState, canStop: Bool)
        case worktree(isMain: Bool)
        /// A host: whether it is this device, open in the window, pinned.
        case host(isLocal: Bool, isOpen: Bool, isPinned: Bool)
    }

    var leading: [RowAction] = []
    var trailing: [RowAction] = []
    /// Asked before it runs (it cannot be undone and loses work).
    var confirms: Set<RowAction> = []
    /// Offered back for a few seconds after it runs.
    var undoable: Set<RowAction> = []

    /// What a full swipe from the trailing edge performs (the outermost action).
    var fullSwipe: RowAction? { trailing.first }
    var fullSwipeLeading: RowAction? { leading.first }

    /// Every action, for the context menu and accessibility: leading then trailing.
    var all: [RowAction] { leading + trailing }

    init(leading: [RowAction] = [], trailing: [RowAction] = [], confirms: Set<RowAction> = [], undoable: Set<RowAction> = []) {
        self.leading = leading
        self.trailing = trailing
        self.confirms = confirms
        self.undoable = undoable
    }

    init(_ kind: Kind) {
        switch kind {
        case .terminalTab(let busy):
            self.init(leading: [.rename], trailing: [.closeTab], confirms: busy ? [.closeTab] : [], undoable: busy ? [] : [.closeTab])
        case .editorTab:
            // Closing leaves the server running, so the same folder comes back as it was.
            self.init(leading: [.rename], trailing: [.closeEditor, .stopServer], confirms: [.stopServer], undoable: [.closeEditor])
        case .browserTab:
            self.init(leading: [.rename], trailing: [.closeTab], undoable: [.closeTab])
        case .mixedTab(let busy):
            self.init(leading: [.rename], trailing: [.closeTab], confirms: busy ? [.closeTab] : [])
        case .agent(let state, let canMarkRead):
            let read: [RowAction] = canMarkRead && (state == .done || state == .error) ? [.markRead] : []
            let live = state == .working || state == .blocked
            self.init(leading: read, trailing: [.stopAgent, .closeTab], confirms: live ? [.stopAgent, .closeTab] : [])
        case .agentItem(let state, let canStop):
            let live = state == .working || state == .blocked
            self.init(leading: [.open], trailing: [.markDone] + (canStop && live ? [.stopAgent] : []), confirms: [.stopAgent])
        case .worktree(let main):
            // Both ask first themselves when there is something to lose.
            self.init(trailing: main ? [] : [.deleteWorktree, .archiveWorktree])
        case .host(let local, let open, let pinned):
            guard !local else { self.init(); return }
            self.init(leading: [pinned ? .unpin : .pin], trailing: (open ? [.disconnect] : []) + [.removeHost], confirms: [.removeHost])
        }
    }

    /// Whether `action` asks first.
    func needsConfirmation(_ action: RowAction) -> Bool { confirms.contains(action) }
}

nonisolated extension RowAction {
    /// The confirmation's question and its explanation.
    func confirmation(_ name: String) -> (title: String, message: String) {
        switch self {
        case .closeTab: ("Close “\(name)”?", "An agent is working in this tab. Closing it ends the agent.")
        case .stopAgent: ("Stop the agent in “\(name)”?", "It is still working. Stopping it ends its pane.")
        case .stopServer: ("Stop the VS Code server for “\(name)”?", "Unsaved changes in the editor are lost.")
        case .removeHost: ("Remove “\(name)”?", "Sessions on \(name) keep running. You can add it again later.")
        default: ("\(title.replacingOccurrences(of: "…", with: "")) “\(name)”?", "")
        }
    }
}
