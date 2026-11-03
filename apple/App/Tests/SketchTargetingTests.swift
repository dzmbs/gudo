import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Sketching covers the tab: the other panes are shielded, a click on one moves the sketch, and
/// Send goes to the sketched pane's own agent. New Drawing is its own action and shortcut.
@MainActor
final class SketchTargetingTests: XCTestCase {
    private let agentHere = AgentDestination(hostId: "h1", hostName: "studio", pane: 2, agent: .claude, title: "Claude Code", sameHost: true)
    private let agentInTab = AgentDestination(hostId: "h1", hostName: "studio", pane: 3, agent: .codex, title: "Codex", sameHost: true)
    private let agentOnHost = AgentDestination(hostId: "h1", hostName: "studio", pane: 9, agent: .claude, title: "api", sameHost: true)
    private let agentElsewhere = AgentDestination(hostId: "h2", hostName: "box", pane: 1, agent: .claude, title: "web", sameHost: false)

    func testEveryOtherPaneOfTheTabIsShielded() {
        XCTAssertEqual(SketchTargeting.shielded(tabPanes: [PaneId(1), PaneId(2), PaneId(3)], target: PaneId(2)), [PaneId(1), PaneId(3)])
        XCTAssertEqual(SketchTargeting.shielded(tabPanes: [PaneId(1)], target: PaneId(1)), [])
    }

    func testAClickOnAnotherPaneMovesTheSketchThere() {
        XCTAssertEqual(SketchTargeting.click(on: PaneId(3), target: PaneId(2), canSketch: true), .retarget)
        XCTAssertEqual(SketchTargeting.click(on: PaneId(2), target: PaneId(2), canSketch: true), .stay)
        XCTAssertEqual(SketchTargeting.click(on: PaneId(4), target: PaneId(2), canSketch: false), .unavailable, "a local shell or a canvas")
    }

    func testSendGoesToTheSketchedPanesOwnAgentOnly() {
        let list = [agentInTab, agentHere, agentElsewhere]
        XCTAssertEqual(SketchTargeting.primary(target: 2, in: list), agentHere)
        XCTAssertNil(SketchTargeting.primary(target: 5, in: list), "a pane without an agent offers a menu instead")
        let sameNumberElsewhere = AgentDestination(hostId: "h2", hostName: "box", pane: 5, agent: .codex, title: "", sameHost: false)
        XCTAssertNil(SketchTargeting.primary(target: 5, in: [sameNumberElsewhere]), "pane ids repeat across hosts")
    }

    func testTheMenuListsTheTabsAgentsFirst() {
        let ordered = SketchTargeting.ordered([agentElsewhere, agentOnHost, agentInTab, agentHere], target: 2, tabPanes: [1, 2, 3])
        XCTAssertEqual(ordered, [agentHere, agentInTab, agentOnHost, agentElsewhere])
        let withoutTarget = SketchTargeting.ordered([agentOnHost, agentInTab], target: 1, tabPanes: [1, 3])
        XCTAssertEqual(withoutTarget.first, agentInTab)
    }

    func testDrawActionsAreSketchAndNewDrawingWithTheirOwnShortcuts() {
        XCTAssertEqual(WorkspaceAction.drawActions, [.draw, .newDrawing])
        XCTAssertEqual(WorkspaceAction.draw.title, "Sketch on Pane")
        XCTAssertEqual(WorkspaceAction.newDrawing.title, "New Drawing")
        let shortcuts = WorkspaceAction.allShortcutActions.map { "\($0.shortcut.key.character)-\($0.shortcut.modifiers.rawValue)" }
        for action in WorkspaceAction.drawActions {
            let mine = "\(action.shortcut.key.character)-\(action.shortcut.modifiers.rawValue)"
            XCTAssertEqual(shortcuts.filter { $0 == mine }.count, 1, "\(action.title) shares its shortcut")
        }
    }

    func testNewDrawingsAreNamedByTheMinuteAndNumberedWhenTaken() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_620_440)
        XCTAssertEqual(DrawingFile.name(at: date, calendar: calendar), "drawing-2026-11-02-1154.excalidraw")
        XCTAssertEqual(DrawingFile.name(at: date, attempt: 2, calendar: calendar), "drawing-2026-11-02-1154-2.excalidraw")
    }

    func testRenamingKeepsTheExtension() {
        XCTAssertEqual(DrawingFile.renamed("login flow"), "login flow.excalidraw")
        XCTAssertEqual(DrawingFile.renamed("flow.Excalidraw"), "flow.Excalidraw")
        XCTAssertNil(DrawingFile.renamed("  "))
        XCTAssertNil(DrawingFile.renamed("a/b"))
        XCTAssertTrue(DrawingFile.isDrawing("/src/flow.excalidraw"))
        XCTAssertFalse(DrawingFile.isDrawing("/src/flow.json"))
    }

    func testNewDrawingsGoToTheRepositoryElseThePanesFolder() {
        XCTAssertEqual(DrawingFile.folder(directory: "/src/app/lib", repositoryRoot: "/src/app"), "/src/app")
        XCTAssertEqual(DrawingFile.folder(directory: "/tmp", repositoryRoot: nil), "/tmp")
        XCTAssertEqual(DrawingFile.folder(directory: nil, repositoryRoot: nil), "~")
    }

    func testTheFileKeepsTheSceneButNotTheHostsPath() throws {
        let export = #"{"type":"excalidraw","elements":[],"appState":{"filePath":"/src/a.excalidraw","gridSize":20},"files":{}}"#
        let written = DrawingFile.contents(fromExport: Data(export.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let appState = try XCTUnwrap(object["appState"] as? [String: Any])
        XCTAssertNil(appState["filePath"])
        XCTAssertEqual(appState["gridSize"] as? Int, 20)
    }

    func testReadingASceneKeepsLiveElementsAndImages() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let file = """
        {"type":"excalidraw","version":2,"elements":[{"id":"a","type":"rectangle"},{"id":"b","type":"ellipse","isDeleted":true}],
         "appState":{"viewBackgroundColor":"#fff","zoom":{"value":2}},
         "files":{"f1":{"id":"f1","mimeType":"image/png","dataURL":"data:image/png;base64,\(png.base64EncodedString())"}}}
        """
        let scene = try DrawingFile.scene(from: Data(file.utf8))
        XCTAssertEqual(scene.elements.count, 1, "tombstones are left out")
        XCTAssertTrue(scene.elements[0].contains("rectangle"))
        XCTAssertEqual(scene.appState.keys.sorted(), ["viewBackgroundColor"], "the viewport is not kept")
        XCTAssertEqual(scene.files, [DrawingFile.Embedded(id: "f1", mimeType: "image/png", data: png)])
        XCTAssertThrowsError(try DrawingFile.scene(from: Data("{\"a\":1}".utf8)))
    }
}
