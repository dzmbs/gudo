#if os(macOS)
import AppKit
import HostKit
import XCTest
@testable import App

/// The pinned project header while the sidebar scrolls under a wheel: at the list's top edge
/// (or pushed up by the next project's header) on every step, naming the project whose rows run
/// under it.
@MainActor
final class StickyHeaderScrollTests: XCTestCase {
    private var driver: WorkspaceDriver!
    private var projectsBefore: Set<String> = []
    private let names = ["humble-valley", "brisk-lynx", "amber-finch", "misty-lagoon"]

    override func setUp() async throws {
        driver = try await WorkspaceDriver.start(height: 560)
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

    func testThePinnedHeaderTracksTheListOnEveryWheelStep() async throws {
        let tabsPerProject = 7
        while model.groups.tabs.count < names.count * tabsPerProject { model.newTab() }
        await driver.expect("the tabs are listed") { self.model.groups.tabs.count == self.names.count * tabsPerProject }
        let tabs = model.groups.tabs
        for (index, name) in names.enumerated() {
            model.newProject(from: Array(tabs[index * tabsPerProject..<(index + 1) * tabsPerProject]), name: name, naming: false)
        }
        await driver.settle()
        let table = try XCTUnwrap(driver.sidebarTable())
        let scrollView = try XCTUnwrap(table.enclosingScrollView)

        var checked = 0
        let steps = Array(repeating: Int32(-9), count: 100) + Array(repeating: Int32(13), count: 50)
        for (step, pixels) in steps.enumerated() {
            scroll(scrollView, by: pixels)
            // One pass of the window's layout, as one display frame gives it.
            await driver.pump(0.017)
            guard let expected = expectedPinned(in: table) else { continue }
            checked += 1
            let shown = pinnedHeaders(in: table)
            XCTAssertEqual(shown.map(\.name), [expected.name], "step \(step): one pinned header, naming the project under the top")
            if let header = shown.first {
                XCTAssertEqual(header.top, expected.top, accuracy: 0.5, "step \(step): \(expected.name) sits at the top edge, or where its rows end")
            }
        }
        XCTAssertGreaterThan(checked, 40, "the list scrolled through its projects")
    }

    /// A wheel moved `pixels` (negative scrolls toward the end) over the list.
    private func scroll(_ scrollView: NSScrollView, by pixels: Int32) {
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else {
            return XCTFail("could not make the wheel event")
        }
        let point = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
        wheel.location = driver.window.convertPoint(toScreen: point)
        guard let event = NSEvent(cgEvent: wheel) else { return XCTFail("could not make the wheel event") }
        scrollView.scrollWheel(with: event)
    }

    /// The list's top edge, in the window: where its content starts under the window's bars.
    private func topEdge(of table: NSTableView) -> CGFloat {
        guard let scrollView = table.enclosingScrollView else { return 0 }
        let clip = scrollView.contentView
        let edge = NSPoint(x: 0, y: clip.bounds.minY + scrollView.contentInsets.top)
        return table.convert(edge, from: clip).y
    }

    /// The project the native list has under its top edge, and where its header should sit:
    /// at the edge, or pushed up by the end of its rows. Read from the table's own rows, as
    /// distances down from the window's top.
    private func expectedPinned(in table: NSTableView) -> (name: String, top: CGFloat)? {
        let ids = model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id)
        let leading = table.numberOfRows - ids.count
        let edge = topEdge(of: table)
        func rowRect(_ index: Int) -> CGRect { table.rect(ofRow: index + leading) }
        for project in model.projects {
            let rowIds = Set(project.tabs.map { "tab/\($0)" })
            guard let headerIndex = ids.firstIndex(of: "project/\(project.id)"), let lastIndex = ids.lastIndex(where: { rowIds.contains($0) })
            else { continue }
            let header = rowRect(headerIndex)
            let bottom = rowRect(lastIndex).maxY
            guard header.minY < edge, bottom > edge else { continue }
            return (project.name, windowTop(ofTableY: edge + min(0, bottom - edge - header.height), in: table))
        }
        return nil
    }

    private func windowTop(ofTableY y: CGFloat, in table: NSTableView) -> CGFloat {
        let window = table.convert(NSPoint(x: 0, y: y), to: nil)
        return (driver.window.contentView?.bounds.height ?? 0) - window.y
    }

    /// The project headers drawn over the list rather than in it, by name and distance from the
    /// window's top.
    private func pinnedHeaders(in table: NSTableView) -> [(name: String, top: CGFloat)] {
        let contentHeight = driver.window.contentView?.bounds.height ?? 0
        let ids = model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id)
        let leading = table.numberOfRows - ids.count
        var found: [(name: String, top: CGFloat)] = []
        for element in HostWindow.elements(under: driver.window.contentView ?? NSView()) {
            guard let project = model.projects.first(where: { element.identifier == "project-\($0.name)" }),
                  let headerIndex = ids.firstIndex(of: "project/\(project.id)") else { continue }
            let frame = driver.window.convertFromScreen(element.frame)
            let headerRow = table.convert(table.rect(ofRow: headerIndex + leading), to: nil)
            let top = contentHeight - frame.maxY
            let isListRow = abs(headerRow.minY - frame.minY) < 0.5 && abs(headerRow.maxY - frame.maxY) < 0.5
            if !isListRow, !found.contains(where: { $0.name == project.name && abs($0.top - top) < 0.5 }) {
                found.append((project.name, top))
            }
        }
        return found
    }
}
#endif
