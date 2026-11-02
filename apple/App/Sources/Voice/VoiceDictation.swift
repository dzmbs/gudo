import Foundation
import HostKit
import os
import TerminalCore
import TerminalRenderer
import VoiceKit

/// The app's push-to-talk: one `PushToTalk` for every window. `voice.start()` dictates into the
/// terminal that is first responder, else the key window's focused pane.
@MainActor
final class VoiceDictation {
    static let shared = VoiceDictation()

    let voice: PushToTalk
    private var shortcut = HoldShortcut()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "voice")

    private init() {
        voice = PushToTalk(recognizer: { SystemSpeechRecognizer() })
        voice.targetProvider = { Self.focusedTarget() }
    }

    @discardableResult
    func start(pane: Pane, in workspace: Workspace) -> Bool {
        voice.start(target: PaneDictationTarget(pane: pane, workspace: workspace))
    }

    // MARK: Hardware chord (hold ⌃⌥Space)

    /// Installed as each terminal view's `keyInterceptor` (Pane). Holding ⌃⌥Space dictates;
    /// releasing Space commits. Other keys pass through untouched.
    func handleKey(_ event: KeyEvent, pane: Pane) -> Bool {
        let chord = event.mods.contains([.control, .alt]) && event.mods.isDisjoint(with: [.super, .shift])
        let phase: HoldShortcut.Phase = switch event.action {
        case .press: .press
        case .repeat: .repeat
        case .release: .release
        }
        switch shortcut.handle(isTriggerKey: event.key == .space, chordHeld: chord, phase: phase) {
        case .pass:
            return false
        case .swallow:
            return true
        case .start:
            guard let workspace = Self.workspace(of: pane) else { return false }
            if !start(pane: pane, in: workspace) {
                Self.log.info("dictation did not start: \(String(describing: self.voice.phase), privacy: .public)")
            }
            return true
        case .stop:
            Task { await voice.stop() }
            return true
        }
    }

    // MARK: Finding the pane

    private static var workspaces: [Workspace] { AppModel.shared.openWorkspaces }

    private static func workspace(of pane: Pane) -> Workspace? {
        workspaces.first { $0.pane(pane.id) === pane }
    }

    /// The terminal that holds the keyboard; else the key window's focused pane.
    static func focusedTarget() -> (any DictationTarget)? {
        for workspace in workspaces {
            for pane in workspace.panes.values where pane.view.hasKeyboardFocus {
                return PaneDictationTarget(pane: pane, workspace: workspace)
            }
        }
        for workspace in workspaces {
            guard let id = workspace.focusedPane, let pane = workspace.pane(id), pane.view.isInKeyWindow else { continue }
            return PaneDictationTarget(pane: pane, workspace: workspace)
        }
        return nil
    }
}

/// Dictation into one terminal pane: the transcript as marked text at the cursor, the result as
/// a paste (bracketed when the program enabled it) or, for a guest who may only prompt, as an
/// unsubmitted agent prompt.
@MainActor
final class PaneDictationTarget: DictationTarget {
    private weak var pane: Pane?
    private weak var workspace: Workspace?
    private var showsPreview = false

    init(pane: Pane, workspace: Workspace) {
        self.pane = pane
        self.workspace = workspace
    }

    var route: DictationRoute {
        guard let pane, let workspace else { return .refused(VoiceError.noTarget.message) }
        let kind: DictationRoute.PaneKind = workspace.isAgentPane(pane.id) ? .agent : .shell
        guard let session = workspace.multiplayer else { return .paste }
        let otherDriver = session.isDrivenByOther(pane.id.rawValue) ? session.holderName(pane.id.rawValue) : nil
        return .resolve(
            kind: kind, canType: session.canDrive && otherDriver == nil, canPrompt: session.canPrompt, drivenBy: otherDriver)
    }

    func showPreview(_ text: String?) {
        guard let surface = pane?.view.surface else { return }
        guard let text, !text.isEmpty else {
            if showsPreview { surface.preedit = nil }
            showsPreview = false
            return
        }
        surface.preedit = TerminalSurface.Preedit(text: DictationPreview.fit(text, columns: Self.columnsLeft(surface)))
        showsPreview = true
    }

    func commit(_ text: String, via route: DictationRoute) {
        guard let pane else { return }
        switch route {
        case .paste:
            // Text-sourced paste (Ghostty's rules for dictation): one line, so never "unsafe".
            _ = pane.view.surface.paste(text, source: .text)
        case .agentPrompt:
            guard let session = workspace?.multiplayer else { return }
            let id = pane.id.rawValue
            Task {
                do {
                    try await session.prompt(id, text, submit: false)
                } catch {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "voice")
                        .error("dictated prompt refused: \(String(describing: error), privacy: .public)")
                }
            }
        case .refused:
            break
        }
    }

    /// Cells from the cursor to the end of its row (the preview is drawn there).
    private static func columnsLeft(_ surface: TerminalSurface) -> Int {
        guard let grid = surface.grid else { return 40 }
        let columns = Int(grid.cols)
        guard let cursor = surface.cursorRect, cursor.width > 0 else { return columns / 2 }
        return max(1, columns - Int((cursor.minX / cursor.width).rounded(.down)) - 1)
    }
}

extension TerminalView {
    var hasKeyboardFocus: Bool {
        #if os(macOS)
        window?.firstResponder === self
        #else
        isFirstResponder
        #endif
    }

    var isInKeyWindow: Bool {
        window?.isKeyWindow == true
    }
}
