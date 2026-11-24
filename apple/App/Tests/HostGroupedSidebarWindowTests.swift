#if os(macOS)
import AppKit
import HostKit
import XCTest
@testable import App

/// The sidebar grouped by host in a window: the host's header pinned over its section with the
/// project's under it while the list scrolls across hosts, the keys walking the rows across
/// host boundaries, and what VoiceOver reads on the headers.
@MainActor
final class HostGroupedSidebarWindowTests: XCTestCase {
    private var driver: WorkspaceDriver!
    private let fixtureHosts = ["fixture-studio", "fixture-hetzner", "fixture-box"]

    override func setUp() async throws {
        driver = try await WorkspaceDriver.start(height: 560)
        DesignFixtures.projectHosts(driver.model)
    }

    override func tearDown() async throws {
        if let model = driver?.model {
            for project in model.projects { model.ungroupProject(project.id) }
        }
        driver?.close()
        driver = nil
        for id in fixtureHosts { AppModel.shared.hosts.disconnect(id) }
    }

    private var model: WindowModel { driver.model }
    private var ids: [String] { model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id) }

    /// Seven more tabs on studio and on hetzner, six of each host's in a project.
    private func arrangeLongHosts() async throws {
        for (host, name) in [("fixture-studio", "alpha"), ("fixture-hetzner", "beta")] {
            let connection = try XCTUnwrap(model.app.hosts.connection(host) as? PreviewConnection)
            for index in 0..<7 {
                connection.layout.apply(.newTab)
                if let id = connection.layout.session.activeTabId { connection.layout.apply(.rename(id, "\(name)-\(index)")) }
            }
            let group = try XCTUnwrap(model.groups.group(host))
            let refs = group.tabs.filter { $0.title?.hasPrefix(name) == true }.prefix(6).map { group.ref($0.id) }
            model.newProject(from: Array(refs), name: name, naming: false)
        }
        await driver.settle()
    }

    func testPinnedHostAndProjectHeadersTrackTheListAcrossHosts() async throws {
        try await arrangeLongHosts()
        XCTAssertTrue(model.groups.groupsByHost)
        let table = try XCTUnwrap(driver.sidebarTable())
        let scrollView = try XCTUnwrap(table.enclosingScrollView)

        var checkedHosts = Set<String>()
        var checkedProjects = 0
        let steps = Array(repeating: Int32(-9), count: 160) + Array(repeating: Int32(13), count: 60)
        for (step, pixels) in steps.enumerated() {
            scroll(scrollView, by: pixels)
            await driver.pump(0.017)
            let expected = expectedPinned(in: table)
            let shown = pinnedHeaders(in: table)
            XCTAssertEqual(shown.map(\.id), expected.map(\.id), "step \(step): the headers pinned over the list")
            for (shownHeader, expectedHeader) in zip(shown, expected) {
                XCTAssertEqual(shownHeader.top, expectedHeader.top, accuracy: 0.5, "step \(step): \(expectedHeader.id)")
                if expectedHeader.id.hasPrefix("host-group-") { checkedHosts.insert(expectedHeader.id) } else { checkedProjects += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(checkedHosts.count, 2, "the list scrolled across host boundaries")
        XCTAssertGreaterThan(checkedProjects, 20, "the project's header pinned under its host's")
    }

    /// ⇧⌘] walks every row as drawn, across hosts; ⌘1 is the first row.
    func testNextTabKeysWalkTheRowsAcrossHosts() async throws {
        let rows = model.sidebarItems(drop: nil, projectMove: nil).items.compactMap { if case .row(let ref, _) = $0 { ref } else { nil } }
        XCTAssertGreaterThan(Set(rows.map(\.hostId)).count, 2)
        driver.command("1")
        await driver.expect("⌘1 shows the first row") { self.model.currentTab == rows.first }
        for next in rows.dropFirst() {
            driver.command("]", .shift)
            await driver.expect("⇧⌘] shows \(next)") { self.model.currentTab == next }
        }
        driver.command("]", .shift)
        await driver.expect("and wraps to the first") { self.model.currentTab == rows.first }
    }

    func testHeadersReadTheirHostToVoiceOver() async throws {
        let app = try XCTUnwrap({ () -> String? in
            let studio = model.groups.group("fixture-studio"), hetzner = model.groups.group("fixture-hetzner")
            guard let studio, let hetzner, let api = studio.tabs.first, let web = hetzner.tabs.first else { return nil }
            model.newProject(from: [studio.ref(api.id), hetzner.ref(web.id)], name: "acme-app", naming: false)
            return model.projects.first { $0.name == "acme-app" }?.id
        }())
        await driver.settle()
        let elements = HostWindow.elements(under: driver.window.contentView ?? NSView())
        let studioHeader = elements.first { $0.identifier == "project-acme-app-studio" }
        let hetznerHeader = elements.first { $0.identifier == "project-acme-app-hetzner" }
        XCTAssertEqual(studioHeader?.label, "acme-app, on studio, project, 1 tab")
        XCTAssertEqual(hetznerHeader?.label, "acme-app, on hetzner, project, 1 tab")
        XCTAssertEqual(elements.first { $0.identifier == "host-group-studio" }?.label, "studio, Connected")
        XCTAssertEqual(model.groups.places(of: app).count, 2)
    }

    // MARK: Reading the list

    private func scroll(_ scrollView: NSScrollView, by pixels: Int32) {
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else {
            return XCTFail("could not make the wheel event")
        }
        let point = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
        wheel.location = driver.window.convertPoint(toScreen: point)
        guard let event = NSEvent(cgEvent: wheel) else { return XCTFail("could not make the wheel event") }
        scrollView.scrollWheel(with: event)
    }

    private func topEdge(of table: NSTableView) -> CGFloat {
        guard let scrollView = table.enclosingScrollView else { return 0 }
        let clip = scrollView.contentView
        return table.convert(NSPoint(x: 0, y: clip.bounds.minY + scrollView.contentInsets.top), from: clip).y
    }

    private func windowTop(ofTableY y: CGFloat, in table: NSTableView) -> CGFloat {
        let point = table.convert(NSPoint(x: 0, y: y), to: nil)
        return (driver.window.contentView?.bounds.height ?? 0) - point.y
    }

    /// The headers the table's own rows say should be pinned, top first, by accessibility
    /// identifier: the host whose section runs under the top edge, and the project whose rows
    /// run under that host's pinned header.
    private func expectedPinned(in table: NSTableView) -> [(id: String, top: CGFloat)] {
        let items = model.sidebarItems(drop: nil, projectMove: nil).items
        let ids = items.map(\.id)
        let leading = table.numberOfRows - ids.count
        func rect(_ index: Int) -> CGRect { table.rect(ofRow: index + leading) }
        /// Where a run's header sits under `edge`, if the run crosses it.
        func pinned(header: Int, last: Int, edge: CGFloat) -> CGFloat? {
            let headerRect = rect(header), bottom = rect(last).maxY
            guard headerRect.minY < edge, bottom > edge else { return nil }
            return edge + min(0, bottom - edge - headerRect.height)
        }
        var found: [(id: String, top: CGFloat)] = []
        var projectEdge = topEdge(of: table)
        for group in model.groups.groups {
            guard let header = ids.firstIndex(of: SidebarItem.hostHeader(group.id).id),
                  let last = items.lastIndex(where: { $0.hostSection == group.id }),
                  let top = pinned(header: header, last: last, edge: projectEdge)
            else { continue }
            found.append(("host-group-\(group.name)", windowTop(ofTableY: top, in: table)))
            projectEdge = top + rect(header).height
            break
        }
        for (index, item) in items.enumerated() {
            guard case .projectHeader(let place) = item, let project = model.groups.project(place.project),
                  let last = items.lastIndex(where: { $0.projectPlace == place }),
                  let top = pinned(header: index, last: last, edge: projectEdge)
            else { continue }
            let host = place.host.flatMap { model.groups.group($0)?.name }
            found.append((host.map { "project-\(project.name)-\($0)" } ?? "project-\(project.name)", windowTop(ofTableY: top, in: table)))
            break
        }
        return found
    }

    /// The host and project headers drawn over the list rather than in it, top first.
    private func pinnedHeaders(in table: NSTableView) -> [(id: String, top: CGFloat)] {
        let contentHeight = driver.window.contentView?.bounds.height ?? 0
        let all = HostWindow.elements(under: driver.window.contentView ?? NSView())
        guard let layer = all.first(where: { $0.identifier == "sidebar-pinned-headers" }) else { return [] }
        var found: [(id: String, top: CGFloat)] = []
        for element in HostWindow.elements(under: layer.object) {
            guard let id = element.identifier, id.hasPrefix("host-group-") || id.hasPrefix("project-"),
                  !id.hasPrefix("project-new-tab"), !id.hasPrefix("project-name")
            else { continue }
            let top = contentHeight - driver.window.convertFromScreen(element.frame).maxY
            if !found.contains(where: { $0.id == id }) { found.append((id, top)) }
        }
        return found.sorted { $0.top < $1.top }
    }
}
#endif
