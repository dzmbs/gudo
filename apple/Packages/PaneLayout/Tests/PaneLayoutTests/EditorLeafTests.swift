import Foundation
import Testing
@testable import PaneLayout

/// VS Code editors as leaves of a window's tabs (docs/APP-ARCHITECTURE.md §20).
@MainActor
@Suite struct EditorLeafTests {
    private let proj = EditorMember(hostId: "alpha", folder: "/home/me/proj")
    private let other = EditorMember(hostId: "beta", folder: "/srv/other/")

    @Test func anEditorOpensInATabOfItsOwn() {
        let hosts = Hosts()
        let first = hosts.store.openEditor(proj)
        let second = hosts.store.openEditor(other)
        #expect(first != second)
        let tab = hosts.tab(first)
        #expect(tab.isEditorOnly)
        #expect(tab.focusedEditor == proj)
        #expect(tab.focusedMember == nil)
        #expect(tab.hosts == ["alpha"], "the row names the editor's host")
        #expect(tab.paneHosts.isEmpty)
        #expect(tab.carriers.isEmpty, "no host holds anything for it")
        #expect(hosts.sent.isEmpty, "no host is asked for anything")
        #expect(hosts.store.editors == [proj, other])
        #expect(hosts.store.tab(containingEditor: other.id)?.id == second)
        hosts.store.reconcile()
        #expect(hosts.store.tabs.count == 2, "an editor tab never dissolves")
        #expect(hosts.dissolved.isEmpty)
    }

    @Test func aClosedEditorTabReopensAsItWasUnderANewId() {
        let hosts = Hosts()
        let first = hosts.store.openEditor(proj)
        hosts.store.addEditor(other, to: first)
        let closed = hosts.tab(first)
        hosts.store.closeTab(first)
        let later = hosts.store.openEditor(EditorMember(hostId: "alpha", folder: "/tmp"))
        let reopened = hosts.store.reopen(closed)
        #expect(reopened != nil && reopened != later)
        let tab = hosts.tab(reopened!)
        #expect(tab.leaves.compactMap { tab.editors[$0] } == [proj, other], "the same editors, in place")
        #expect(tab.focusedEditor == closed.focusedEditor)
    }

    @Test func aTabWithHostPanesDoesNotReopen() {
        let hosts = Hosts()
        let id = hosts.store.addEditor(proj, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        let closed = hosts.tab(id)
        hosts.store.closeTab(id)
        #expect(hosts.store.reopen(closed) == nil, "its host panes ended with it")
    }

    @Test func besideATerminalTheHostTabBecomesAComposite() {
        let hosts = Hosts()
        let id = hosts.store.addEditor(proj, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        let tab = hosts.tab(id)
        #expect(!tab.isEditorOnly)
        #expect(tab.leaves.count == 2)
        #expect(tab.members[tab.leaves[0]] == HostPane(hostId: "alpha", pane: PaneId(1)))
        #expect(tab.editors[tab.leaves[1]] == proj)
        #expect(tab.focusedEditor == proj, "the editor takes focus")
        #expect(tab.carriers == ["alpha": TabId(2)])
        guard case .split(.horizontal, _, _, _) = tab.layout.root else {
            Issue.record("side by side")
            return
        }
        hosts.store.reconcile()
        #expect(hosts.store.tab(id) != nil, "one host plus an editor stays a composite")
        #expect(hosts.store.carriers["alpha"] == [TabId(2)], "the host tab is shown by the composite")
        #expect(hosts.store.ordered.map(\.id) == [id])
    }

    @Test func closingTheEditorGivesTheHostTabBack() {
        let hosts = Hosts()
        let id = hosts.store.addEditor(proj, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        let leaf = hosts.tab(id).leaf(forEditor: proj.id)!
        hosts.store.close(leaf: leaf, in: id)
        #expect(!hosts.sent.contains { if case .close = $0.1 { true } else { false } }, "no host pane closes")
        #expect(hosts.store.tab(id) == nil)
        #expect(hosts.dissolved.first?.1 == CompositeTabs.TabRefParts(hostId: "alpha", tab: TabId(2)))
    }

    @Test func closingTheLastEditorEndsItsTab() {
        let hosts = Hosts()
        let id = hosts.store.openEditor(proj)
        hosts.store.close(leaf: hosts.tab(id).focusedLeaf, in: id)
        #expect(hosts.store.tabs.isEmpty)
        #expect(hosts.dissolved.count == 1)
        #expect(hosts.dissolved.first?.1 == nil)
    }

    @Test func editorsSitBesideEachOtherAndAcrossHosts() {
        let hosts = Hosts()
        let id = hosts.store.openEditor(proj)
        hosts.store.addEditor(other, to: id, axis: .vertical)
        let tab = hosts.tab(id)
        #expect(tab.isEditorOnly)
        #expect(tab.hosts == ["alpha", "beta"])
        #expect(tab.focusedEditor == other)
        // ⌘D on an editor opens a pane on the editor's host.
        hosts.store.split(id, axis: .horizontal)
        #expect(hosts.sent.last?.0 == "beta")
        #expect(hosts.sent.last?.1 == .newTab, "beta has no carrier yet")
        #expect(!hosts.tab(id).isEditorOnly)
    }

    @Test func closingAHostDropsItsEditors() {
        let hosts = Hosts()
        let tab = hosts.store.openEditor(other)
        let mixed = hosts.store.addEditor(other, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        hosts.store.dropHost("beta")
        #expect(hosts.store.tab(tab) == nil, "its editor tab closes")
        #expect(hosts.store.tab(mixed) == nil, "the composite dissolves into alpha's tab")
        #expect(hosts.dissolved.last?.1 == CompositeTabs.TabRefParts(hostId: "alpha", tab: TabId(2)))
    }

    @Test func editorTabsListFirst() {
        let hosts = Hosts()
        let mixed = hosts.mixed()
        let editor = hosts.store.openEditor(proj)
        #expect(hosts.store.ordered.map(\.id) == [editor, mixed])
    }

    @Test func editorsSurviveARelaunchAndOldSavesStillLoad() throws {
        let hosts = Hosts()
        let id = hosts.store.addEditor(proj, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        hosts.store.openEditor(other)
        let data = try JSONEncoder().encode(hosts.store.tabs)
        let decoded = try JSONDecoder().decode([CompositeTab].self, from: data)
        #expect(decoded == hosts.store.tabs)
        #expect(decoded.first { $0.id == id }?.focusedEditor == proj)

        // A save from before editors were leaves has no "editors" key.
        let plain = Hosts()
        let saved = try JSONEncoder().encode([plain.tab(plain.mixed())])
        var json = try #require(try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        json[0]["editors"] = nil
        let old = try JSONDecoder().decode([CompositeTab].self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.first?.editors.isEmpty == true)
        #expect(old.first?.hosts == ["alpha", "beta"])
    }

    @Test func folderNamesAndPaths() {
        #expect(proj.folderName == "proj")
        #expect(other.folderName == "other")
        #expect(EditorMember(hostId: "a", folder: "~").folderName == "~")
        #expect(EditorMember(hostId: "a", folder: "/").folderName == "/")
        #expect(proj.contains(path: "/home/me/proj/src/main.rs"))
        #expect(proj.contains(path: "/home/me/proj"))
        #expect(!proj.contains(path: "/home/me/project/x"))
        #expect(other.contains(path: "/srv/other/a"))
    }
}
