import DesignSystem
import DrawingKit
import Foundation
import HostKit
import PaneLayout
import TerminalCore
import TerminalRenderer
import UnnamedCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shell commands in one daemon pane (OSC 133 marks, docs/DAEMON.md "Shell integration"): a
/// thin stripe in the left gutter beside each command's rows (ANSI red for a non-zero exit,
/// faint otherwise), drawn by the renderer pinned to the rows so it scrolls with the output;
/// a menu on a command's rows (long-press, secondary click, right-click) with Copy Command,
/// Copy Output, Re-run and Ask Agent; and ⌘↑/⌘↓ between prompts.
///
/// The rows come from the daemon (`Commands`: rows from the bottom at an output offset), so
/// they survive a resume: after a snapshot the list is read again and pinned in the restored
/// terminal. Attached once per pane by `Workspace`; local and plain-SSH panes have none (⌘↑
/// there uses the prompts libghostty-vt saw).
@MainActor
final class PaneCommandMarks: NSObject {
    let paneId: UInt64
    weak var pane: Pane?
    weak var workspace: Workspace?
    let tracker: RowTracker
    private let daemon: DaemonConnection

    private struct Entry {
        var block: CommandBlock
        var first: RowPin?
        var last: RowPin?
    }

    /// Oldest first.
    private var entries: [Entry] = []
    private var markToken: UUID?
    private var reloadTask: Task<Void, Never>?
    private var pendingPins: Flag
    private var markers: [UInt64: CommandMarker] = [:]

    private static let registry = NSMapTable<NSNumber, PaneCommandMarks>.strongToWeakObjects()
    private static nonisolated(unsafe) var associationKey: UInt8 = 0

    /// The marks of a pane, if it is on a daemon.
    static func of(_ pane: PaneId) -> PaneCommandMarks? { registry.object(forKey: NSNumber(value: pane.rawValue)) }

    /// Attaches command marks to a pane whose backend is a daemon pane; no-op otherwise.
    @discardableResult
    static func attach(to pane: Pane, workspace: Workspace) -> PaneCommandMarks? {
        guard let backend = pane.backend as? DaemonPaneBackend, backend.daemonClient != nil,
              let daemon = workspace.host as? DaemonConnection else { return nil }
        let marks = PaneCommandMarks(pane: pane, backend: backend, daemon: daemon, workspace: workspace)
        objc_setAssociatedObject(pane.view, &associationKey, marks, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        registry.setObject(marks, forKey: NSNumber(value: pane.id.rawValue))
        return marks
    }

    private init(pane: Pane, backend: DaemonPaneBackend, daemon: DaemonConnection, workspace: Workspace) {
        paneId = pane.id.rawValue
        self.pane = pane
        self.workspace = workspace
        self.daemon = daemon
        tracker = RowTracker(terminal: pane.view.surface.terminal)
        pendingPins = Flag()
        super.init()

        let tracker = tracker
        let pending = pendingPins
        backend.onOutputApplied(observer: "command-marks") { [weak self] seq, snapshot in
            tracker.observe(seq: seq, snapshot: snapshot)
            guard snapshot || pending.value.load(ordering: .relaxed) else { return }
            Task { @MainActor in
                guard let self else { return }
                // A snapshot replaced the terminal (attach, resume): its pins are gone.
                if snapshot { self.scheduleReload(after: .zero) } else { self.repin() }
            }
        }
        markToken = daemon.workspace.observeCommandMarks { [weak self] mark in
            guard let self, mark.paneId == self.paneId else { return }
            // A start or an end: read the rows again once the shell drew what follows (the
            // next prompt decides where a finished command's rows end).
            self.scheduleReload(after: .milliseconds(mark.finished == nil ? 60 : 150))
        }

        let surface = pane.view.surface
        surface.gutterMarks = { [weak self] in self?.gutterMarks() ?? [] }
        let previous = surface.onFrameRendered
        surface.onFrameRendered = { [weak self] in
            previous?()
            self?.updateMarkers()
        }
        #if os(iOS)
        pane.view.contextActions = { [weak self] point in self?.menu(at: point) }
        #else
        pane.view.contextActions = { [weak self] point in self?.menu(at: point) ?? [] }
        #endif
    }

    isolated deinit {
        if let markToken { daemon.existingWorkspace?.removeObserver(markToken) }
        reloadTask?.cancel()
    }

    private var surface: TerminalSurface? { pane?.view.surface }

    // MARK: Rows

    private func scheduleReload(after delay: Duration) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay > .zero {
                guard (try? await Task.sleep(for: delay)) != nil else { return }
            }
            await self?.reload()
        }
    }

    private func reload() async {
        guard let list = try? await daemon.workspace.commands(pane: paneId), !Task.isCancelled else { return }
        let blocks = CommandBlocks.blocks(list)
        entries = blocks.map { Entry(block: $0, first: nil, last: nil) }
        repin()
    }

    /// Pins every block's rows the terminal has reached; the rest wait for output.
    private func repin() {
        var waiting = false
        for index in entries.indices {
            let block = entries[index].block
            if entries[index].first == nil {
                entries[index].first = tracker.pin(atSeq: block.atSeq, fromBottom: block.first)
            }
            if entries[index].last == nil, let last = block.last {
                entries[index].last = tracker.pin(atSeq: block.atSeq, fromBottom: last)
            }
            if entries[index].first == nil, block.atSeq > tracker.appliedSeq { waiting = true }
        }
        pendingPins.value.store(waiting, ordering: .relaxed)
        surface?.invalidateGutterMarks()
    }

    /// Each command's rows as screen rows (first, last), read under one lock per call. Nil
    /// for commands whose rows are not pinned (yet).
    private func screenRows() -> [(entry: Entry, first: Int, last: Int)] {
        guard let terminal = pane?.view.surface.terminal, !terminal.isAlternateScreen else { return [] }
        let pins = entries.flatMap { [$0.first, $0.last] }
        guard pins.contains(where: { $0 != nil }) else { return [] }
        let rows = terminal.screenRows(of: pins.compactMap { $0 })
        var resolved = rows.makeIterator()
        let cursor = terminal.totalRows - Int(terminal.size.rows) + terminal.cursorPosition.y
        var result: [(Entry, Int, Int)] = []
        for entry in entries {
            let first = entry.first.flatMap { _ in resolved.next() ?? nil }
            let lastRow = entry.last.flatMap { _ in resolved.next() ?? nil }
            guard let first else { continue }
            var last: Int
            if entry.block.last == nil {
                // Running: its output ends at the cursor.
                last = max(first, cursor)
            } else if let lastRow {
                last = lastRow
                // The end mark's row is the next prompt when the output ended with a newline.
                if entry.block.lastMayBePrompt, lastRow > first,
                   lastRow >= cursor || entry.last.flatMap(terminal.isPromptRow) == true
                {
                    last = lastRow - 1
                }
            } else {
                continue
            }
            result.append((entry, first, max(first, last)))
        }
        return result
    }

    private func gutterMarks() -> [GutterMark] {
        guard let terminal = pane?.view.surface.terminal else { return [] }
        let top = terminal.viewportTopRow
        return screenRows().map { entry, first, last in
            let (tint, opacity) = Self.style(entry.block.status)
            return GutterMark(id: entry.block.id, row: first - top, rows: last - first + 1, tint: tint, opacity: opacity)
        }
    }

    /// faintly for a success, a little stronger while it runs.
    static func style(_ status: CommandStatus) -> (GutterMark.Tint, Double) {
        switch status {
        case .failed: (.palette(1), 0.95)
        case .running: (.foreground, 0.38)
        case .succeeded, .finished: (.foreground, 0.16)
        }
    }

    private func block(at point: CGPoint) -> CommandBlock? {
        guard let id = surface?.gutterMark(at: point)?.id else { return nil }
        return entries.first { $0.block.id == id }?.block
    }

    // MARK: Prompt jumps (⌘↑ / ⌘↓)

    /// Scrolls so the previous (`direction` < 0) or next prompt is the top row; past the last
    /// prompt, back to the bottom.
    func jumpToPrompt(_ direction: Int) {
        guard let surface, let terminal = pane?.view.surface.terminal else { return }
        let prompts = screenRows().map(\.first)
        Pane.log.debug("jump to prompt \(direction): \(prompts.count) prompts, top \(terminal.viewportTopRow), \(self.entries.count) commands")
        guard !prompts.isEmpty else {
            terminal.scrollViewport(byPrompts: direction)
            surface.setNeedsRender()
            return
        }
        if let target = CommandBlocks.promptTarget(prompts: prompts, viewportTop: terminal.viewportTopRow, direction: direction) {
            terminal.scrollViewport(toScreenRow: target)
            // Reaching the top of what this terminal holds asks the host for older scrollback.
            if terminal.viewportTopRow == 0 { surface.onScroll?(-1) }
        } else if direction > 0 {
            terminal.scrollToBottom()
        }
        surface.setNeedsRender()
    }

    /// ⌘↑/⌘↓ on a workspace's focused pane: its marks, else libghostty-vt's own prompts.
    static func jumpToPrompt(_ direction: Int, in workspace: Workspace) {
        guard let id = workspace.focusedPane, let pane = workspace.panes[id] else { return }
        if let marks = of(id) {
            marks.jumpToPrompt(direction)
        } else {
            pane.view.surface.terminal.scrollViewport(byPrompts: direction)
            pane.view.surface.setNeedsRender()
        }
    }

    // MARK: Actions

    private var window: WindowModel? { workspace.flatMap(ActiveWindow.model(for:)) ?? ActiveWindow.model }

    func copyCommand(_ block: CommandBlock) {
        guard let command = block.mark.command else { return }
        #if os(iOS)
        UIPasteboard.general.string = command
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        #endif
        window?.toasts.show(Toast("Copied `\(command)`", systemImage: "doc.on.doc", style: .success))
    }

    func copyOutput(_ block: CommandBlock) {
        let hub = daemon.workspace
        let pane = paneId
        Task {
            await window?.copyCommandOutput {
                let output = try await hub.commandOutput(pane: pane, command: block.id)
                return (output.mark.command, output.text)
            }
        }
    }

    /// Types the command again at the prompt (bracketed, so a multi-line command stays one).
    func rerun(_ block: CommandBlock) {
        guard let command = block.mark.command, let pane else { return }
        if let running = daemon.existingWorkspace?.runningCommands[paneId] {
            window?.toasts.show(Toast(
                "Wait for `\(running.command ?? "the running command")` to finish", systemImage: "hourglass", style: .neutral))
            return
        }
        guard pane.view.surface.paste(command) == .written else { return }
        pane.view.onInput?(Array("\r".utf8))
    }

    /// The agent to ask: one in this pane's tab first, then anywhere in the window.
    private func agentPane() -> (pane: UInt64, name: String)? {
        guard let workspace else { return nil }
        func name(_ id: PaneId) -> String? {
            daemon.meta[id]?.agent.map { AgentKind($0.kind).title }
        }
        let me = PaneId(paneId)
        let tab = workspace.session.tabs.first { $0.root.panes.contains(me) }
        let order = (tab?.root.panes ?? []) + workspace.session.tabs.flatMap(\.root.panes)
        for id in order where id != me {
            if let agent = name(id) { return (id.rawValue, agent) }
        }
        return nil
    }

    /// Hands the command and its output to an agent: typed into the agent running in this
    /// window (not sent, so you add your question), else New Task with it as the prompt.
    func askAgent(_ block: CommandBlock) {
        let hub = daemon.workspace
        let pane = paneId
        let target = agentPane()
        let hostId = workspace?.hostId
        Task { [weak self] in
            let text: String
            do {
                let output = try await hub.commandOutput(pane: pane, command: block.id)
                text = CommandBlocks.agentPrompt(command: block.mark.command, status: block.status, output: output.text)
            } catch {
                self?.window?.toasts.show(Toast("No output to send: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
                return
            }
            guard let window = self?.window else { return }
            guard let target else {
                window.newTaskPrompt = text
                window.sheet = .launchAgent
                return
            }
            do {
                _ = try await hub.client().prompt(paneId: target.pane, text: text, submit: false)
                if let hostId { window.reveal(host: hostId, pane: target.pane) }
                window.toasts.show(Toast("Sent to \(target.name): add your question", systemImage: "arrow.up.circle.fill", style: .success))
            } catch {
                window.toasts.show(Toast("\(target.name) did not get it: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    // MARK: Menus

    #if os(iOS)
    private func menu(at point: CGPoint) -> UIMenu? {
        guard let block = block(at: point) else { return nil }
        let actions: [UIMenuElement] = Self.actions(for: block).map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { [weak self] _ in self?.run(action, on: block) }
        }
        return UIMenu(title: block.mark.command ?? "", options: .displayInline, children: actions)
    }
    #else
    private func menu(at point: CGPoint) -> [NSMenuItem] {
        guard let block = block(at: point) else { return [] }
        return Self.actions(for: block).map { action in
            MenuAction.item(action.title, action.symbol) { [weak self] in self?.run(action, on: block) }
        }
    }
    #endif

    enum Action: CaseIterable {
        case copyOutput, askAgent, rerun, copyCommand

        var title: String {
            switch self {
            case .copyOutput: "Copy Output"
            case .askAgent: "Ask Agent"
            case .rerun: "Re-run"
            case .copyCommand: "Copy Command"
            }
        }

        var symbol: String {
            switch self {
            case .copyOutput: "doc.on.clipboard"
            case .askAgent: "sparkle"
            case .rerun: "arrow.clockwise"
            case .copyCommand: "terminal"
            }
        }
    }

    /// The command's actions, the likeliest next step first (the touch edit menu shows three
    /// before it pages): after a failure, asking an agent; after a success, running it again.
    static func actions(for block: CommandBlock) -> [Action] {
        let order: [Action] = block.status.isFailure
            ? [.copyOutput, .askAgent, .rerun, .copyCommand]
            : [.copyOutput, .rerun, .copyCommand, .askAgent]
        return order.filter { block.mark.command != nil || ($0 != .rerun && $0 != .copyCommand) }
    }

    private func run(_ action: Action, on block: CommandBlock) {
        switch action {
        case .copyOutput: copyOutput(block)
        case .askAgent: askAgent(block)
        case .rerun: rerun(block)
        case .copyCommand: copyCommand(block)
        }
    }

    // MARK: Accessibility

    /// An element beside each command's rows on screen ("Command: false", "Failed, exit 1"),
    /// for VoiceOver and UI tests; it takes no touches.
    private func updateMarkers() {
        guard let surface, let view = pane?.view else { return }
        var seen: Set<UInt64> = []
        let width = max(surface.paddingPoints, 4)
        for (mark, rect) in surface.gutterMarkFrames {
            guard let block = entries.first(where: { $0.block.id == mark.id })?.block else { continue }
            seen.insert(mark.id)
            let frame = CGRect(x: 0, y: rect.minY, width: width, height: rect.height)
            let marker = markers[mark.id] ?? {
                let marker = CommandMarker(frame: frame)
                view.addSubview(marker)
                markers[mark.id] = marker
                return marker
            }()
            if marker.frame != frame { marker.frame = frame }
            marker.describe(id: mark.id, command: block.mark.command, status: block.status)
        }
        for (id, marker) in markers where !seen.contains(id) {
            marker.removeFromSuperview()
            markers[id] = nil
        }
    }
}

extension CommandStatus {
    /// In words, for accessibility.
    var words: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed(let code): "Failed, exit \(code)"
        case .finished: "Finished"
        }
    }
}

#if os(iOS)
/// The accessibility element of a command's stripe.
final class CommandMarker: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func describe(id: UInt64, command: String?, status: CommandStatus) {
        let identifier = "command-mark-\(id)"
        if accessibilityIdentifier != identifier { accessibilityIdentifier = identifier }
        let label = "Command: \(command ?? "unknown")"
        if accessibilityLabel != label { accessibilityLabel = label }
        if accessibilityValue != status.words { accessibilityValue = status.words }
    }
}
#else
/// The accessibility element of a command's stripe.
final class CommandMarker: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func describe(id: UInt64, command: String?, status: CommandStatus) {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("command-mark-\(id)")
        setAccessibilityLabel("Command: \(command ?? "unknown")")
        setAccessibilityValue(status.words)
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSObject {
    private let action: () -> Void

    private init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc private func run() { action() }

    static func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        // The item holds its target weakly; keep it alive with the item.
        item.representedObject = target
        return item
    }
}
#endif
