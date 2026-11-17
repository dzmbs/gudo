#if os(macOS)
import AppKit
import HostKit
import XCTest
@testable import App

/// The sidebar used by hand: folding a host or a project, a project made and named in place,
/// a tab moved into it and out again, the Agents and Hosts rows, and the sidebar itself hidden,
/// shown and narrowed away.
@MainActor
final class SidebarByHandTests: XCTestCase {
    private var driver: WorkspaceDriver!
    private var projectsBefore: Set<String> = []

    override func setUp() async throws {
        driver = try await WorkspaceDriver.start()
        projectsBefore = Set(driver.model.projects.map(\.id))
    }

    override func tearDown() async throws {
        if let model = driver?.model {
            for project in model.projects where !projectsBefore.contains(project.id) { model.ungroupProject(project.id) }
        }
        driver?.close()
        driver = nil
    }

    private var model: WindowModel { driver.model }
    private var items: [String] { model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id) }

    /// The sidebar's list is within the window (hidden, it slides out past the leading edge).
    private var sidebarOnScreen: Bool {
        guard let table = driver.sidebarTable(), table.window != nil else { return false }
        return driver.frame(of: table).maxX > 50
    }

    private func newTabs(_ count: Int) async {
        for _ in 0..<count {
            driver.command("t")
            await driver.settle()
        }
    }

    // MARK: Folding

    func testAHostsMenuFoldsAndUnfoldsItsTabs() async throws {
        await newTabs(1)
        let tabs = model.groups.tabs
        let titles = await driver.contextMenu(on: driver.sidebarRowFrame("host/local"), choose: ["Collapse"])
        XCTAssertNotNil(titles, "the host's header has a menu")
        await driver.expect("the host's tabs fold away") { !self.items.contains { $0.hasPrefix("tab/") } }
        await driver.settle()
        XCTAssertNil(driver.sidebarRowFrame(of: tabs[0]), "no row is drawn for a folded tab")

        await driver.contextMenu(on: driver.sidebarRowFrame("host/local"), choose: ["Expand"])
        await driver.expect("the tabs come back") { tabs.allSatisfy { self.items.contains("tab/\($0)") } }
        await driver.settle()
        XCTAssertNotNil(driver.sidebarRowFrame(of: tabs[1]))
    }

    // MARK: Projects

    func testANewProjectIsNamedInPlaceTakesATabAndFolds() async throws {
        await newTabs(1)
        let tab = try XCTUnwrap(model.groups.tabs.last)
        driver.command("n", .control)
        await driver.expect("a new project") { self.model.projects.count == self.projectsBefore.count + 1 }
        let project = try XCTUnwrap(model.projects.first { !projectsBefore.contains($0.id) })
        await driver.expect("its name field takes the keyboard") { self.driver.window.firstResponder is NSTextView }
        (driver.window.firstResponder as? NSTextView)?.selectAll(nil)
        driver.type("infra")
        driver.pressReturn()
        await driver.expect("the project takes the name") { self.model.projects.first { $0.id == project.id }?.name == "infra" }
        XCTAssertTrue(items.contains("project/\(project.id)"))

        await driver.contextMenu(on: driver.sidebarRowFrame(of: tab), choose: ["Move to Project", "infra"])
        await driver.expect("the tab joins the project") { self.model.groups.project(of: tab)?.id == project.id }
        await driver.settle()
        let header = try XCTUnwrap(items.firstIndex(of: "project/\(project.id)"))
        XCTAssertEqual(items.firstIndex(of: "tab/\(tab)"), header + 1, "its row is listed under the project: \(items)")

        await driver.click(driver.sidebarRowFrame("project/\(project.id)"))
        await driver.expect("the project folds") { !self.items.contains("tab/\(tab)") }
        await driver.click(driver.sidebarRowFrame("project/\(project.id)"))
        await driver.expect("and unfolds") { self.items.contains("tab/\(tab)") }
        await driver.settle()

        await driver.contextMenu(on: driver.sidebarRowFrame(of: tab), choose: ["Remove from infra"])
        await driver.expect("the tab leaves the project") { self.model.groups.project(of: tab) == nil }
        XCTAssertTrue(items.contains("tab/\(tab)"), "it is listed under its host again")
    }

    func testNewProjectFromATabsMenu() async throws {
        let tab = try XCTUnwrap(model.groups.tabs.first)
        await driver.contextMenu(on: driver.sidebarRowFrame(of: tab), choose: ["New Project from Tab"])
        await driver.expect("a project holds the tab") { self.model.groups.project(of: tab) != nil }
        let project = try XCTUnwrap(model.groups.project(of: tab))
        XCTAssertTrue(items.contains("project/\(project.id)"))
        await driver.expect("its name is offered for editing") { self.driver.window.firstResponder is NSTextView }
        driver.pressEscape()
        await driver.settle()
    }

    // MARK: Agents and Hosts

    func testTheAgentsAndHostsRowsShowTheirPagesAndATabRowComesBack() async throws {
        let tab = try XCTUnwrap(model.groups.tabs.first)
        let table = try XCTUnwrap(driver.sidebarTable())
        let destinations = driver.frame(of: table)
        let first = table.convert(table.rect(ofRow: 0), to: nil)
        // Agents, then Hosts, in the list's first row.
        await driver.click(CGPoint(x: first.midX, y: first.maxY - first.height / 4))
        await driver.expect("Agents shows the inbox") { self.model.destination == .inbox }
        await driver.settle()
        XCTAssertNil(driver.terminal()?.window, "the terminal leaves the window")

        await driver.click(CGPoint(x: first.midX, y: first.minY + first.height / 4))
        await driver.expect("Hosts shows the hosts") { self.model.destination == .hosts }
        await driver.settle()

        await driver.click(driver.sidebarRowFrame(of: tab))
        await driver.expect("a tab's row brings the terminal back") { self.model.destination == .terminal }
        await driver.settle()
        XCTAssertTrue(driver.window.firstResponder === driver.terminal(), "with the keyboard")
        XCTAssertGreaterThan(destinations.width, 0)
    }

    // MARK: Showing

    func testCommandBHidesAndShowsTheSidebarAndThePaneTakesItsRoom() async throws {
        XCTAssertTrue(sidebarOnScreen)
        let terminal = try XCTUnwrap(driver.terminal())
        let beside = driver.frame(of: terminal)
        driver.command("b")
        await driver.expect("the sidebar goes") { !self.sidebarOnScreen }
        await driver.settle()
        XCTAssertLessThan(driver.frame(of: terminal).minX, beside.minX, "the pane starts at the window's edge")
        XCTAssertGreaterThan(driver.frame(of: terminal).width, beside.width)

        driver.command("b")
        await driver.expect("the sidebar comes back") { self.sidebarOnScreen }
        await driver.settle()
        XCTAssertEqual(driver.frame(of: terminal).minX, beside.minX, accuracy: 1)
    }

    func testANarrowWindowHidesTheSidebarAndWideningBringsItBack() async throws {
        XCTAssertTrue(sidebarOnScreen)
        var frame = driver.window.frame
        frame.size.width = 560
        driver.window.setFrame(frame, display: true)
        await driver.expect("the sidebar gives way") { !self.sidebarOnScreen }
        await driver.settle()
        let terminal = try XCTUnwrap(driver.terminal())
        XCTAssertGreaterThan(driver.frame(of: terminal).width, 500, "the pane keeps the window")

        frame.size.width = 1200
        driver.window.setFrame(frame, display: true)
        await driver.expect("the sidebar comes back") { self.sidebarOnScreen }
    }
}
#endif
