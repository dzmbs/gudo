import DesignSystem
import DrawingKit
import Foundation
import HostKit
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer
import GudoCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shell commands in one daemon pane (OSC 133 marks): a gutter stripe beside each command's rows,
/// a context menu on them, and ⌘↑/⌘↓ between prompts.
///
/// The rows come from the daemon as rows from the bottom at an output offset, so they survive a
/// resume: after a snapshot the list is read again and pinned in the restored terminal. Local and
/// plain-SSH panes have none; ⌘↑ there uses the prompts libghostty-vt saw.
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

    private static nonisolated(unsafe) var associationKey: UInt8 = 0

    /// The marks of a pane, if it is on a daemon.
    static func of(_ pane: Pane) -> PaneCommandMarks? {
        objc_getAssociatedObject(pane.view, &associationKey) as? PaneCommandMarks
    }

    /// Attaches command marks to a pane whose backend is a daemon pane; no-op otherwise.
    @discardableResult
    static func attach(to pane: Pane, workspace: Workspace) -> PaneCommandMarks? {
        guard let backend = pane.backend as? DaemonPaneBackend, backend.daemonClient != nil,
              let daemon = workspace.host as? DaemonConnection else { return nil }
        return attach(to: pane, backend: backend, daemon: daemon, workspace: workspace)
    }

    @discardableResult
    static func attach(to pane: Pane, backend: DaemonPaneBackend, daemon: DaemonConnection,
                       workspace: Workspace) -> PaneCommandMarks {
        let marks = PaneCommandMarks(pane: pane, backend: backend, daemon: daemon, workspace: workspace)
        objc_setAssociatedObject(pane.view, &associationKey, marks, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
                // A snapshot replaced the terminal, so its pins are gone.
                if snapshot { self.scheduleReload(after: .zero) } else { self.repin() }
            }
        }
        markToken = daemon.workspace.observeCommandMarks { [weak self] mark in
            guard let self, mark.paneId == self.paneId else { return }
            // Read the rows again once the shell drew what follows: the next prompt decides
            // where a finished command's rows end.
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
        let previousPointer = pane.view.onPointerMoved
        pane.view.onPointerMoved = { [weak self] point in
            previousPointer?(point)
            self?.pointer = point
            self?.updateOverlays()
        }
    }

    // MARK: Hover result and sticky header

    private var pointer: CGPoint?
    private lazy var resultBadge = CommandBadge(identifier: "command-result")
    private lazy var stickyHeader = CommandBadge(identifier: "command-sticky", sticky: true)

    /// The hovered command's result at the right of its prompt row, and a sticky header for the
    /// command whose output fills the top of the pane.
    private func updateOverlays() {
        guard let view = pane?.view, let surface else { return }
        let frames = surface.gutterMarkFrames
        let palette = Self.palette()
        var shownResult = false
        if let pointer, let hit = frames.last(where: { $0.rect.minY <= pointer.y && pointer.y < $0.rect.maxY }),
           hit.mark.row >= 0, let block = entries.first(where: { $0.block.id == hit.mark.id })?.block,
           let text = Self.result(block)
        {
            let color = block.status.isFailure ? palette.error.color : palette.done.color
            resultBadge.show(text, color: color, palette: palette, in: view)
            resultBadge.place(trailing: view.bounds.width - 8, top: hit.rect.minY + 1, in: view)
            shownResult = true
        }
        if !shownResult { resultBadge.hide() }
        if let top = frames.first(where: { $0.mark.row < 0 && $0.rect.maxY > 24 }),
           let block = entries.first(where: { $0.block.id == top.mark.id })?.block, let command = block.mark.command
        {
            let status = Self.result(block).map { "  \($0)" } ?? ""
            stickyHeader.show("$ \(command.prefix { !$0.isNewline })\(status)", color: palette.textSecondary, palette: palette, in: view)
            stickyHeader.place(leading: max(surface.paddingPoints, 4) + 4, top: 2, maxWidth: view.bounds.width - 16, in: view)
        } else {
            stickyHeader.hide()
        }
    }

    /// Cached per theme because overlays update every frame.
    private static var cachedPalette: (key: String, palette: ChromePalette)?

    private static func palette() -> ChromePalette {
        let defaults = UserDefaults.standard
        let key = "\(defaults.string(forKey: TerminalPreferences.Key.theme) ?? "")|\(defaults.string(forKey: TerminalPreferences.Key.windowTheme) ?? "")"
        if let cachedPalette, cachedPalette.key == key { return cachedPalette.palette }
        let palette = ChromePalette.fromPreferences()
        cachedPalette = (key, palette)
        return palette
    }

    /// "✓ 4s", "✗ 1 · 2m 03s", nil while running.
    static func result(_ block: CommandBlock) -> String? {
        guard let end = block.mark.finished else { return nil }
        let time = CommandBlocks.elapsed(seconds: Int((Double(end.durationMs) / 1000).rounded()))
        switch block.status {
        case .failed(let code): return "✗ \(code) · \(time)"
        default: return "✓ \(time)"
        }
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
        reconcile(list)
    }

    func reconcile(_ list: CommandList) {
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

    /// Each pinned command's first and last screen rows, read under one lock per call.
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
            let rowTint = entry.block.status.isFailure ? Self.failedRowTint : 0
            return GutterMark(id: entry.block.id, row: first - top, rows: last - first + 1, tint: tint, opacity: opacity, rowTint: rowTint)
        }
    }

    static let failedRowTint = 0.06

    static func style(_ status: CommandStatus) -> (GutterMark.Tint, Double) {
        switch status {
        case .failed: (.palette(1), 0.95)
        case .running: (.foreground, 0.38)
        case .succeeded, .finished: (.foreground, 0.16)
        }
    }

    func block(atViewportRow row: Int) -> CommandBlock? {
        guard let top = pane?.view.surface.terminal.viewportTopRow else { return nil }
        let screenRow = top + row
        return screenRows().last { $0.first <= screenRow && screenRow <= $0.last }?.entry.block
    }

    private func block(at point: CGPoint) -> CommandBlock? {
        guard let id = surface?.gutterMark(at: point)?.id else { return nil }
        return entries.first { $0.block.id == id }?.block
    }

    // MARK: Prompt jumps (⌘↑ / ⌘↓)

    @discardableResult
    func reveal(command: UInt64) -> Bool {
        guard let surface, let terminal = pane?.view.surface.terminal, !terminal.isAlternateScreen,
              let entry = entries.first(where: { $0.block.id == command && $0.block.mark.paneId == paneId }),
              let pin = entry.first, let row = terminal.screenRow(of: pin) else { return false }
        terminal.scrollViewport(toScreenRow: row)
        if terminal.viewportTopRow == 0 { surface.onScroll?(-1) }
        surface.setNeedsRender()
        return true
    }

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
            // Reaching the top asks the host for older scrollback.
            if terminal.viewportTopRow == 0 { surface.onScroll?(-1) }
        } else if direction > 0 {
            terminal.scrollToBottom()
        }
        surface.setNeedsRender()
    }

    /// ⌘↑/⌘↓ on a workspace's focused pane: its marks, else libghostty-vt's own prompts.
    static func jumpToPrompt(_ direction: Int, in workspace: Workspace) {
        guard let id = workspace.focusedPane, let pane = workspace.pane(id) else { return }
        if let marks = of(pane) {
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
        func agentName(_ id: PaneId) -> String? {
            daemon.meta[id]?.agent.map { AgentKind($0.kind).title }
        }
        let thisPane = PaneId(paneId)
        let tab = workspace.session.tabs.first { $0.root.panes.contains(thisPane) }
        let order = (tab?.root.panes ?? []) + workspace.session.tabs.flatMap(\.root.panes)
        for id in order where id != thisPane {
            if let agent = agentName(id) { return (id.rawValue, agent) }
        }
        return nil
    }

    /// Types the command and its output into an agent in this window without submitting, so the
    /// user adds a question; else starts a new agent with it as the prompt.
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
                window.newAgentSeed.prompt = text
                window.newAgent(onGroup: hostId)
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

    /// The likeliest next step first, because the touch edit menu shows only three before it pages.
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

    /// An accessibility element beside each command's rows on screen, for VoiceOver and UI tests.
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
        updateOverlays()
    }
}

extension CommandStatus {
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

/// A small label over the grid: the hovered command's result, or the sticky command header.
#if os(iOS)
@MainActor
final class CommandBadge {
    private let label = PaddedLabel()
    private let sticky: Bool

    init(identifier: String, sticky: Bool = false) {
        self.sticky = sticky
        label.isUserInteractionEnabled = false
        label.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        label.layer.cornerRadius = DS.Radius.chip
        label.layer.masksToBounds = true
        label.layer.borderWidth = 0.5
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        label.accessibilityIdentifier = identifier
    }

    func show(_ text: String, color: Color, palette: ChromePalette, in view: UIView) {
        if label.superview !== view { view.addSubview(label) }
        let text = String(text.prefix { !$0.isNewline })
        if label.text != text { label.text = text }
        label.textColor = UIColor(color)
        label.backgroundColor = UIColor(palette.raisedColor)
        label.layer.borderColor = UIColor(palette.hairline).cgColor
        label.isHidden = false
    }

    func place(trailing: CGFloat, top: CGFloat, in view: UIView) {
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: trailing - size.width, y: top, width: size.width, height: size.height)
    }

    func place(leading: CGFloat, top: CGFloat, maxWidth: CGFloat, in view: UIView) {
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: leading, y: top, width: min(size.width, max(0, maxWidth - leading)), height: size.height)
    }

    func hide() { label.isHidden = true }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 6, dy: 2)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}
#else
@MainActor
final class CommandBadge {
    private let field = NSTextField(labelWithString: "")
    private let sticky: Bool

    init(identifier: String, sticky: Bool = false) {
        self.sticky = sticky
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        field.wantsLayer = true
        field.layer?.cornerRadius = DS.Radius.chip
        field.layer?.borderWidth = 0.5
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.drawsBackground = true
        field.setAccessibilityIdentifier(identifier)
    }

    func show(_ text: String, color: Color, palette: ChromePalette, in view: NSView) {
        if field.superview !== view { view.addSubview(field) }
        let text = " \(text.prefix { !$0.isNewline }) "
        if field.stringValue != text { field.stringValue = text }
        field.textColor = NSColor(color)
        field.backgroundColor = NSColor(palette.raisedColor)
        field.layer?.borderColor = NSColor(palette.hairline).cgColor
        field.isHidden = false
    }

    func place(trailing: CGFloat, top: CGFloat, in view: NSView) {
        let size = field.intrinsicContentSize
        field.frame = CGRect(x: trailing - size.width, y: top, width: size.width, height: size.height + 2)
    }

    func place(leading: CGFloat, top: CGFloat, maxWidth: CGFloat, in view: NSView) {
        let size = field.intrinsicContentSize
        field.frame = CGRect(x: leading, y: top, width: min(size.width, max(0, maxWidth - leading)), height: size.height + 2)
    }

    func hide() { field.isHidden = true }
}
#endif
