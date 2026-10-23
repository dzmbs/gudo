import Foundation
import Testing
@testable import PaneLayout

/// Files, Changes, Ports and Replays as leaves of a window's tabs: beside a terminal, closed
/// without touching the host's panes, found again by kind, and saved for a relaunch.
@MainActor
@Suite struct ToolLeafTests {
    private let files = ToolMember(hostId: "alpha", tool: .files)
    private let changes = ToolMember(hostId: "alpha", tool: .changes)

    @Test func besideATerminalTheHostTabBecomesAComposite() {
        let hosts = Hosts()
        let id = hosts.store.addTool(changes, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        let tab = hosts.tab(id)
        #expect(!tab.isBrowserOnly && !tab.isEditorOnly)
        #expect(tab.members[tab.leaves[0]] == HostPane(hostId: "alpha", pane: PaneId(1)))
        #expect(tab.tools[tab.leaves[1]] == changes)
        #expect(tab.focusedTool == changes, "the tool takes focus")
        if case .split(let axis, _, _, _) = tab.layout.root { #expect(axis == .horizontal, "to the right of the pane") }
        hosts.store.reconcile()
        #expect(hosts.store.tab(id) != nil, "one host plus a tool stays a composite")
        // Closing the tool gives the host tab back; no host pane closes.
        hosts.store.close(leaf: tab.leaf(forTool: changes.id)!, in: id)
        #expect(!hosts.sent.contains { if case .close = $0.1 { true } else { false } })
        #expect(hosts.dissolved.first?.1 == CompositeTabs.TabRefParts(hostId: "alpha", tab: TabId(2)))
        #expect(hosts.store.tools.isEmpty)
    }

    @Test func aToolIsFoundByKind() {
        let hosts = Hosts()
        let id = hosts.store.addTool(files, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        hosts.store.addTool(changes, to: id)
        let tab = hosts.tab(id)
        #expect(tab.leaf(showing: .files) == tab.leaf(forTool: files.id))
        #expect(tab.leaf(showing: .changes) == tab.leaf(forTool: changes.id))
        #expect(tab.leaf(showing: .ports) == nil)
        #expect(hosts.store.tab(containingTool: files.id)?.id == id)
        #expect(hosts.store.tools == [files, changes])
    }

    @Test func aToolAloneIsATabOfItsOwnAndOutlivesItsTerminal() {
        let hosts = Hosts()
        let alone = hosts.store.openTool(files)
        #expect(hosts.tab(alone).focusedTool == files)
        #expect(hosts.tab(alone).hosts == ["alpha"])
        let id = hosts.store.addTool(changes, besideHost: "alpha", tab: hosts.sessions["alpha"]!.tabs[0])
        let pane = hosts.tab(id).leaves[0]
        hosts.store.close(leaf: pane, in: id)
        #expect(hosts.store.tab(id)?.leaves.count == 1, "the tool stays in the tab")
        #expect(hosts.store.tab(id)?.focusedTool == changes)
    }

    @Test func toolsAreRestoredAndOlderSavesStillDecode() throws {
        let hosts = Hosts()
        let id = hosts.store.openTool(files)
        hosts.store.addTool(changes, to: id, axis: .vertical)
        let data = try JSONEncoder().encode(hosts.store.tabs)
        let back = try JSONDecoder().decode([CompositeTab].self, from: data)
        #expect(back == hosts.store.tabs)
        #expect(Set(back[0].tools.values) == [files, changes])

        // Saved before tools were leaves: no `tools` key.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        object[0]["tools"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode([CompositeTab].self, from: old)
        #expect(decoded[0].tools.isEmpty)
    }

    @Test func droppingItsHostClosesItsTools() {
        let hosts = Hosts()
        let id = hosts.store.openBrowser(BrowserMember(hostId: nil, url: "https://example.com"))
        hosts.store.addTool(files, to: id)
        hosts.store.dropHost("alpha")
        #expect(hosts.store.tools.isEmpty)
        #expect(hosts.store.tab(id)?.leaves.count == 1)
    }
}
