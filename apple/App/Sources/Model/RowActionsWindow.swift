import DesignSystem
import Foundation
import HostKit
import PaneLayout

// What the rows' actions (`RowActions`) do in a window, with Undo where a close can come back.

extension WindowModel {
    /// Closes a host tab into Recently Closed. With `undoable`, Undo brings it back where it was
    /// (its agent resuming its session).
    func closeTab(_ ref: TabRef, undoable: Bool) {
        closeTabs([ref], undoable: undoable)
    }

    /// Closes a tab the window owns (VS Code, a page, a mixed tab). Editors and pages come back
    /// with Undo as they were; an editor's server keeps running meanwhile.
    func closeWindowTab(_ id: TabId, undoable: Bool) {
        guard let tab = composites.tab(id) else { return }
        let title = title(ofMixedTab: tab)
        closeMixedTab(id)
        guard undoable, tab.members.isEmpty else { return }
        offerUndo("Closed “\(title)”") { [weak self] in
            guard let self, let reopened = composites.reopen(tab) else { return }
            AppModel.log.info("undo: reopened \(title, privacy: .public)")
            noteLeavingTab()
            focus(Self.mixedRef(reopened))
        }
    }

    /// Stops every VS Code server a window tab's editors run, and closes the tab.
    func stopEditorServers(inTab id: TabId) {
        guard let tab = composites.tab(id) else { return }
        for editor in tab.leaves.compactMap({ tab.editors[$0] }) {
            closeEditor(editor.id, stopServer: true)
        }
    }

    /// Ends an agent: closes the pane it runs in.
    func stopAgent(pane: PaneId, onGroup id: String) {
        workspace(ofGroup: id)?.apply(.close(pane))
    }

    /// Marks what an agent said seen on every device.
    func markAgentRead(pane: PaneId, onGroup id: String) {
        guard let daemon = app.hosts.connection(id) as? DaemonConnection else { return }
        Task { await daemon.workspace.markSeen(pane: pane.rawValue) }
    }

    /// The toast that offers a close back for a few seconds.
    func offerUndo(_ message: String, _ undo: @escaping @MainActor @Sendable () -> Void) {
        toasts.show(Toast(message, systemImage: "xmark.circle", action: Toast.Action("Undo", perform: undo)))
    }
}
