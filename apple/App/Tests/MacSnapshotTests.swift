#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// Design review of the Mac window, its sheets and popovers without putting anything on screen:
/// each fixture is drawn in-process into an offscreen window (titlebar and toolbar bridged from
/// SwiftUI) and written as `<dir>/mac-<name>-<mode>.png`. Runs only with `SNAPSHOT_DIR` and
/// `GUDO_MOCK` set (`TEST_RUNNER_SNAPSHOT_DIR`, `TEST_RUNNER_GUDO_MOCK=1`);
/// `SNAPSHOT_MODE` is `dark` (default) or `light`, `SNAPSHOT_ONLY` a comma list of fixtures.
@MainActor
final class MacSnapshotTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        try XCTSkipIf(environment["SNAPSHOT_DIR"] == nil || !LaunchOptions.mock, "snapshots run on request")
    }

    private var mode: String { environment["SNAPSHOT_MODE"] ?? "dark" }
    /// `SNAPSHOT_THEME` picks another terminal theme than the mode's default.
    private var themeName: String {
        environment["SNAPSHOT_THEME"] ?? (mode == "light" ? "Apple System Colors Light" : "Ghostty Default")
    }
    /// The fixture's window, for captures made while it runs.
    private var current: NSWindow?

    private func wanted(_ name: String) -> Bool {
        guard let only = environment["SNAPSHOT_ONLY"] else { return true }
        return only.split(separator: ",").contains { $0 == name }
    }

    /// A window that never reaches the screen: far off it, never key, never ordered in front of
    /// another app.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func makeWindow(_ root: some View, size: CGSize) -> NSWindow {
        let theme = themeName
        // The argument domain: it wins over the app's saved settings and is never written to
        // disk, so a snapshot run leaves the real app's theme alone.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TerminalPreferences.Key.theme] = theme
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        // What `toolbarBackgroundVisibility(.hidden)` asks of a scene window.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        return window
    }

    private func capture(_ window: NSWindow, _ name: String) throws {
        guard let frameView = window.contentView?.superview else { return XCTFail("no frame view") }
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        let bitmap: NSBitmapImageRep
        // `SNAPSHOT_DRAW=1`: the views' own drawing, for when the window server hands back blank
        // pictures (a locked or sleeping display).
        if environment["SNAPSHOT_DRAW"] == nil, let image = Self.windowImage(window.windowNumber) {
            // The window server's picture of our own window (no recording permission needed):
            // glass and vibrancy included, which `cacheDisplay` draws as white slabs.
            bitmap = NSBitmapImageRep(cgImage: drawsTerminals ? terminalsDrawn(over: image, in: frameView) ?? image : image)
        } else {
            guard let cached = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return XCTFail("no bitmap") }
            frameView.cacheDisplay(in: bounds, to: cached)
            bitmap = cached
        }
        let directory = URL(fileURLWithPath: environment["SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mac-\(name)-\(mode).png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }

    /// The floating-pane fixtures: their terminals are drawn into the capture from each
    /// surface's own frame (see `terminalsDrawn`).
    private var drawsTerminals = false
    private var currentModel: WindowModel?
    /// Each terminal's frame as presented before a layout motion (`motion`).
    private var heldFrames: [PaneId: CGImage] = [:]

    /// `image` with every terminal drawn in from its surface's own complete frame. A window off
    /// every display presents Metal frames only when it gets drawables, so the window server's
    /// picture can show an older frame, or one with glyphs still missing. Tiled panes first
    /// (dimmed as `UnfocusedDim` dims them), then each window back to front as captured, with
    /// its shadow, and its panes in it; then what floats above the panes, as captured.
    private func terminalsDrawn(over image: CGImage, in frameView: NSView) -> CGImage? {
        guard let model = currentModel, let workspace = model.workspace, let target = model.arrangement.layout else { return nil }
        // As drawn: part way through a scrubbed change, too.
        let shown = model.arrangement.preview ?? target
        let layout = model.arrangement.scrub.map { shown.blended(from: $0.from, progress: $0.progress) } ?? shown
        let scale = CGFloat(image.width) / frameView.bounds.width
        let height = CGFloat(image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Top-left window points to the bitmap's bottom-left pixels, and to crops of `image`.
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        func restore(_ rect: CGRect) {
            let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            if let part = image.cropping(to: crop) { context.draw(part, in: pixels(rect)) }
        }
        let theme = ThemeCatalog.theme(named: themeName)
        let dark = mode != "light"
        // Canvas points to window points, from a pane's terminal and its leaf.
        guard let (anchorPane, anchor) = workspace.panes.first(where: { pane, _ in
                  model.arrangement.still(of: pane) == nil && layout.leaves.contains { $0.pane == pane && $0.visible && $0.window == nil } }),
              let anchorLeaf = layout.leaves.first(where: { $0.pane == anchorPane })
        else { return nil }
        let anchorRect = anchor.view.convert(anchor.view.bounds, to: nil)
        let canvas = CGPoint(x: anchorRect.minX - anchorLeaf.frame.minX, y: (frameView.bounds.height - anchorRect.minY) - anchorLeaf.frame.maxY)
        func window(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: canvas.x, dy: canvas.y) }

        // Each terminal where it is on screen now (part way through a motion, too).
        func onScreen(_ pane: PaneId) -> CGRect? {
            guard let terminal = workspace.panes[pane], model.arrangement.still(of: pane) == nil,
                  terminal.view.window != nil, !terminal.view.isHiddenOrHasHiddenAncestor else { return nil }
            let inWindow = terminal.view.convert(terminal.view.bounds, to: nil)
            return CGRect(x: inWindow.minX, y: frameView.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        }
        func drawTerminal(_ pane: PaneId) {
            guard let rect = onScreen(pane), let surface = workspace.panes[pane]?.view.surface else { return }
            // A terminal in a layout motion shows the frame it last presented (its layer keeps
            // it, anchored top-left, on its background).
            let held = surface.isHoldingFrame ? heldFrames[pane] : nil
            if held == nil { _ = surface.renderIfDirty(offscreen: true) }
            guard let still = held ?? surface.snapshot() else { return }
            context.saveGState()
            context.clip(to: pixels(rect))
            context.setFillColor(NSColor(theme.background).cgColor)
            context.fill(pixels(rect))
            context.draw(still, in: CGRect(x: pixels(rect).minX, y: pixels(rect).maxY - CGFloat(still.height), width: CGFloat(still.width), height: CGFloat(still.height)))
            context.restoreGState()
        }
        let focused = workspace.focusedPane
        let dim = NSColor(theme.background).withAlphaComponent(1 - TerminalPreferences.Default.unfocusedSplitOpacity).cgColor
        let tiled = layout.leaves.filter { $0.window == nil && $0.visible }.sorted { $0.z < $1.z }
        for leaf in tiled {
            guard let rect = onScreen(leaf.pane) else { continue }
            drawTerminal(leaf.pane)
            if leaf.pane != focused, tiled.count + layout.cards.count > 1 {
                context.setFillColor(dim)
                context.fill(pixels(rect))
            }
            // The pane being dragged is washed (`FloatingChrome`).
            if leaf.pane == model.arrangement.paneDrag?.pane {
                context.setFillColor(NSColor(theme.background).withAlphaComponent(0.55).cgColor)
                context.fill(pixels(rect))
            }
        }
        // A pane drawn over the others (zooming) keeps its header over their terminals.
        for leaf in tiled where leaf.z > 0 {
            restore(window(CGRect(x: leaf.frame.minX, y: leaf.frame.minY, width: leaf.frame.width, height: PaneHeader.height)))
        }
        // Windows back to front, from where their panes are now: as captured (header, rim,
        // backdrop) with the panel shadow, then their terminals.
        let windows = Dictionary(grouping: layout.leaves.filter { $0.window != nil && $0.opacity > 0.01 }, by: { $0.window! })
        for (id, leaves) in windows.sorted(by: { ($0.value.first?.z ?? 0) < ($1.value.first?.z ?? 0) }) {
            // Where the window is drawn: its panes' frames, shrunk as the tray shrinks them.
            let drawn = leaves.map { leaf -> CGRect in
                let frame = leaf.frame
                let pivot = CGPoint(x: frame.minX + leaf.hiddenAnchor.x * frame.width, y: frame.minY + leaf.hiddenAnchor.y * frame.height)
                let shrink = leaf.scale
                return CGRect(
                    x: pivot.x + (frame.minX - pivot.x) * shrink, y: pivot.y + (frame.minY - pivot.y) * shrink,
                    width: frame.width * shrink, height: frame.height * shrink)
            }
            guard var rect = drawn.first.map(window) else { continue }
            for other in drawn.dropFirst() { rect = rect.union(window(other)) }
            if layout.card(id)?.multi == true { rect = rect.insetBy(dx: -1, dy: 0); rect.origin.y -= CanvasLayout.grip; rect.size.height += CanvasLayout.grip + 1 }
            let shape = CGPath(roundedRect: pixels(rect), cornerWidth: CanvasLayout.radius * scale, cornerHeight: CanvasLayout.radius * scale, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -DS.Shadow.panel.y * scale), blur: DS.Shadow.panel.radius * scale,
                          color: CGColor(gray: 0, alpha: DS.Shadow.panel.opacity(dark: dark)))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(shape)
            context.clip()
            restore(rect)
            context.endTransparencyLayer()
            context.restoreGState()
            context.saveGState()
            context.addPath(shape)
            context.clip()
            for leaf in leaves { drawTerminal(leaf.pane) }
            context.restoreGState()
        }
        // Above the panes, as captured: the tray, a drag's region, chip and Float target, guides.
        for chip in layout.chips { restore(window(chip.frame).insetBy(dx: -2, dy: -2)) }
        let arrangement = model.arrangement
        // The drop region drawn again as `DropRegion` draws it (the terminal under it is new).
        let accent = ChromePalette.fromPreferences().accent
        func accentColor(_ alpha: Double) -> CGColor { CGColor(srgbRed: accent.r, green: accent.g, blue: accent.b, alpha: alpha) }
        if let region = arrangement.dockPreview ?? arrangement.paneDrag?.preview ?? arrangement.landing {
            let inset = window(region).insetBy(dx: DS.Space.xs, dy: DS.Space.xs)
            let path = CGPath(roundedRect: pixels(inset), cornerWidth: DS.Radius.pane * scale, cornerHeight: DS.Radius.pane * scale, transform: nil)
            context.addPath(path)
            context.setFillColor(accentColor(0.2))
            context.fillPath()
            let rim = CGPath(roundedRect: pixels(inset).insetBy(dx: 0.75 * scale, dy: 0.75 * scale), cornerWidth: DS.Radius.pane * scale, cornerHeight: DS.Radius.pane * scale, transform: nil)
            context.addPath(rim)
            context.setStrokeColor(accentColor(0.65))
            context.setLineWidth(1.5 * scale)
            context.strokePath()
        }
        if let drag = arrangement.paneDrag {
            restore(window(layout.floatTarget).insetBy(dx: -4, dy: -4))
            // The chip that follows the hand: centred 12 right of and 18 under the pointer.
            restore(window(CGRect(x: drag.point.x + 12 - 70, y: drag.point.y + 18 - 15, width: 140, height: 30)))
        }
        for guide in arrangement.guides {
            let line = guide.axis == .vertical
                ? CGRect(x: guide.position - 2, y: guide.from, width: 4, height: guide.to - guide.from)
                : CGRect(x: guide.from, y: guide.position - 2, width: guide.to - guide.from, height: 4)
            restore(window(line))
        }
        return context.makeImage()
    }

    /// `CGWindowListCreateImage`, looked up at run time: the SDK marks it unavailable, and it is
    /// the one capture of an app's own window that asks no permission.
    private static func windowImage(_ number: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .optionIncludingWindow; .boundsIgnoreFraming | .bestResolution
        return create(.null, 1 << 3, UInt32(number), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// The window on the design fixture `screen`, then whatever `then` opens over it.
    private func window(
        _ name: String, screen: String = "splits", size: CGSize = CGSize(width: 1180, height: 760),
        early: String? = nil, then: ((WindowModel) async -> Void)? = nil
    ) async throws {
        guard wanted(name) else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: size)
        current = window
        currentModel = model
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        model.isSidebarShown = true
        if let workspace = model.workspace {
            // The local layout outlives each window: start every fixture from one fresh tab.
            for tab in workspace.session.tabs { workspace.apply(.closeTab(tab.id)) }
            workspace.apply(.newTab)
            for _ in 0..<20 where workspace.focusedPane == nil { await pump(0.1) }
            await DesignFixtures.apply(screen, workspace: workspace, model: model)
        }
        if let early {
            await pump(2)
            try capture(window, early)
        }
        await then?(model)
        await pump(2)
        try capture(window, name)
        if let sheet = window.attachedSheet {
            try capture(sheet, name + "-sheet")
        }
        for child in window.childWindows ?? [] where child.isVisible {
            try capture(child, name + "-popover")
        }
        model.sheet = nil
        // Window tabs outlive the window: a page left in one would be shown by the next
        // fixture's window too, which WebKit does not allow.
        for tab in model.composites.tabs where !tab.browsers.isEmpty { model.closeMixedTab(tab.id) }
        await pump(0.3)
        window.close()
        model.close()
    }

    func testMainWindow() async throws {
        try await window("splits")
        try await window("single", screen: "single")
        try await window("hosts", screen: "hosts")
        try await window("inbox", screen: "inbox")
        try await window("narrow", size: CGSize(width: 820, height: 600))
        try await window("nosidebar") { $0.isSidebarShown = false }
    }

    /// Projects across hosts in the sidebar, then a reorder recorded frame by frame: the rows
    /// must slide apart (never overlap) and the drop must not move anything again.
    func testProjects() async throws {
        try await window("projects", screen: "projects")
        try await window("projects-drag", screen: "projects") { model in
            let drag = model.sidebarDrag
            guard let app = model.projects.first(where: { $0.name == "acme-app" }), let last = app.tabs.last,
                  let logs = model.groups.sections.first(where: { $0.container == .host("fixture-studio") })?.rows.first
            else { return XCTFail("fixture") }
            await self.pump(1.5)
            // Within a project: the last tab to the top.
            let plan = SidebarDrop.insert(last, into: .project(app.id), at: 0)
            drag.dragging = last
            withAnimation(DS.Motion.reorder) { drag.plan = plan }
            for (index, delay) in [0.0, 0.04, 0.04, 0.05, 0.06, 0.08, 0.12, 0.3].enumerated() {
                await self.pump(delay)
                try? self.capture(self.current!, "projects-reorder-\(index)")
            }
            withAnimation(DS.Motion.reorder) {
                model.commit(plan)
                drag.reset()
            }
            for index in 0..<3 {
                await self.pump(0.05)
                try? self.capture(self.current!, "projects-dropped-\(index)")
            }
            XCTAssertEqual(model.projects.first { $0.id == app.id }?.tabs.first, last)
            // A loose tab hovering the middle of a project's row: "will group".
            drag.dragging = logs
            withAnimation(DS.Motion.reorder) { drag.plan = .group(logs, onto: app.tabs[0]) }
            await self.pump(0.5)
            try? self.capture(self.current!, "projects-will-group")
            // Into another project between its rows: the row leaves its host and slides in.
            guard let infra = model.projects.first(where: { $0.name == "infra" }) else { return XCTFail("infra") }
            withAnimation(DS.Motion.reorder) { drag.plan = .insert(logs, into: .project(infra.id), at: 1) }
            for (index, delay) in [0.03, 0.05, 0.08, 0.3].enumerated() {
                await self.pump(delay)
                try? self.capture(self.current!, "projects-into-\(index)")
            }
            withAnimation(DS.Motion.reorder) { drag.reset() }
        }
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }

    /// Tabs in a repository keep their rows with the branch and changes on them; the worktrees
    /// without tabs fold after the host's tabs.
    func testRepositoryTabs() async throws {
        try await window("repositories", screen: "repositories")
        try await window("repositories-expanded", screen: "repositories") { _ in
            let folds = WorktreeFoldStore.shared
            if !folds.isExpanded(repo: "/src/harness-lab", host: "fixture-studio") { folds.toggle(repo: "/src/harness-lab", host: "fixture-studio") }
        }
        let folds = WorktreeFoldStore.shared
        if folds.isExpanded(repo: "/src/harness-lab", host: "fixture-studio") { folds.toggle(repo: "/src/harness-lab", host: "fixture-studio") }
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }

    /// Making projects: the first-run hint, New Project's name field and empty line, what a drop
    /// says it will do, a terminal joining from ⌘T, and the sidebar that leaves.
    func testProjectsUX() async throws {
        defer { for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) } }
        // The argument domain shows the hint whatever the app saved (and is never written).
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[ProjectsIntroRow.dismissedKey] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        try await window("projects-intro", screen: "project-hosts")
        arguments[ProjectsIntroRow.dismissedKey] = nil
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        try await window("projects-new", screen: "projects") { model in
            await self.pump(1)
            withAnimation(DS.Motion.reorder) { model.newEmptyProject() }
        }
        try await window("projects-drop", screen: "projects") { model in
            let drag = model.sidebarDrag
            guard let app = model.projects.first(where: { $0.name == "acme-app" }),
                  let logs = model.groups.sections.first(where: { $0.container == .host("fixture-studio") })?.rows.first,
                  let migrate = model.groups.sections.first(where: { $0.container == .host(HostGroups.localId) })?.rows.last
            else { return XCTFail("fixture") }
            await self.pump(1.5)
            drag.dragging = logs
            withAnimation(DS.Motion.reorder) { drag.plan = .group(logs, onto: app.tabs[1]) }
            await self.pump(0.6)
            try? self.capture(self.current!, "projects-drop-add")
            withAnimation(DS.Motion.reorder) { drag.plan = .group(logs, onto: migrate) }
            await self.pump(0.6)
            try? self.capture(self.current!, "projects-drop-group")
            withAnimation(DS.Motion.reorder) { drag.reset() }
        }
        try await window("projects-after", screen: "projects") { model in
            guard let app = model.projects.first(where: { $0.name == "acme-app" }),
                  let infra = model.projects.first(where: { $0.name == "infra" })
            else { return XCTFail("fixture") }
            await self.pump(1.5)
            model.focus(app.tabs[0])
            model.newTab()
            await self.pump(0.4)
            try? self.capture(self.current!, "projects-joined")
            model.groups.toggleCollapsed(project: infra.id)
        }
    }

    /// Tab history: the Restore and idle rows, Recently Closed in the palette, a selection of
    /// three tabs with its bar, touch Select mode, and the launch setting.
    func testTabHistory() async throws {
        defer { for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) } }
        try await window("tab-history", screen: "tab-history")
        try await window("tab-history-palette", screen: "tab-history") { model in
            await self.pump(1)
            model.showRecentlyClosed()
        }
        try await window("tab-selection", screen: "tab-selection")
        try await window("tab-select-mode", screen: "tab-history") { model in
            await self.pump(1)
            model.isSelectingTabs = true
            model.tabSelection.select(model.groups.tabs[2])
            model.tabSelection.toggle(model.groups.tabs[4], current: nil)
        }
        try await settings("settings-tabs", SettingsNavigation(pane: .appearance))
        // The argument domain shows the other choice whatever the app saved (never written).
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[LaunchTabs.key] = LaunchTabs.newTerminal.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            arguments[LaunchTabs.key] = nil
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        try await settings("settings-tabs-new-terminal", SettingsNavigation(pane: .appearance))
    }

    /// Instant start: the saved workspace before the host answers (quietly washed, "Connecting…"
    /// in the header), then the same host live, in place; at the Mac's width and an iPad's.
    func testInstantStart() async throws {
        for (suffix, size) in [("", CGSize(width: 1180, height: 760)), ("-ipad", CGSize(width: 1024, height: 768))] {
            guard wanted("instant-start" + suffix) else { continue }
            let (_, client) = try InstantStartFixture.attach(.shared)
            defer { AppModel.shared.hosts.disconnect(InstantStartFixture.hostId) }
            let model = WindowModel(app: .shared)
            // The window (and its theme) first: panes take the theme they are made with.
            let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: size)
            model.start()
            model.isSidebarShown = true
            model.show(.host(InstantStartFixture.hostId))
            // Before the connection notice's grace: what the first second looks like.
            await pump(1)
            try capture(window, "instant-start-cached" + suffix)
            InstantStartFixture.goLive(client)
            await pump(1.5)
            // A window far off screen gets no display-link ticks: present the frames by hand.
            for pane in model.workspace.map({ Array($0.panes.values) }) ?? [] { pane.view.surface.renderIfDirty() }
            await pump(0.3)
            try capture(window, "instant-start-live" + suffix)
            window.close()
            model.close()
        }
    }

    /// Any program's own status (pi blocked on a question) in its pane header and tab glyph.
    func testProgramStatus() async throws {
        defer {
            MockPaneStatus.fixture = nil
            MockPaneStatus.details = [:]
        }
        try await window("program-status", screen: "program-status")
    }

    /// A kitty graphics image a program printed, drawn in the pane by the Metal renderer from
    /// the render state's placements: a gradient over 24 × 6 cells between lines of text.
    func testKittyImageInAPane() async throws {
        try await window("kitty-image", screen: "single") { model in
            guard let workspace = model.workspace, let id = workspace.focusedPane, let pane = workspace.panes[id] else {
                return XCTFail("no pane")
            }
            let surface = pane.view.surface
            let (width, height) = (240, 120)
            var pixels: [UInt8] = []
            for y in 0..<height {
                for x in 0..<width { pixels += [UInt8(x * 255 / width), UInt8(y * 255 / height), 210, 255] }
            }
            let image = "\u{1b}_Ga=T,f=32,s=\(width),v=\(height),i=1,c=24,r=6,q=2;\(Data(pixels).base64EncodedString())\u{1b}\\"
            surface.terminal.write(Array("\r\n$ kitten icat gradient.png\r\n\(image)\r\n$ echo after\r\nafter\r\n".utf8))
            surface.outputArrived()
            await self.pump(1)
            XCTAssertEqual(surface.kittyPlacements.map(\.imageID), [1])
        }
    }

    func testSheets() async throws {
        for route in ["links", "launchAgent", "pairing", "join", "invite", "shortcuts"] {
            try await window(route, screen: route)
        }
        try await window("ticket", screen: "ticket")
    }

    /// Form sheets are as tall as their rows: macOS 26 centres a sheet shorter than its window,
    /// so blank space under a form would show as a sheet that opens low.
    func testFormSheetsFitTheirRows() async throws {
        guard wanted("sheet-fit") else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: CGSize(width: 1180, height: 760))
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        // The mock's empty Add Host and Join forms: a field, its note and the buttons.
        for route in [SheetRoute.pairing, .join] {
            model.sheet = route
            await pump(1.5)
            let sheet = try XCTUnwrap(window.attachedSheet, "\(route)")
            XCTAssertLessThan(sheet.frame.height, 320, "\(route) has blank space under its form")
            model.sheet = nil
            for _ in 0..<30 where window.attachedSheet != nil { await pump(0.1) }
        }
        window.close()
        model.close()
    }

    /// Files, Changes, Ports and Replays beside the focused pane (the default on the Mac).
    func testToolLeaves() async throws {
        for route in [SheetRoute.files, .diff, .browser, .replays] {
            try await window("leaf-\(route.rawValue)") { $0.sheet = route }
        }
    }

    /// A page opened from the Ports leaf opens in a browser leaf beside it; Ports stays a list.
    func testPortsLeafOpensPagesBeside() async throws {
        try await window("leaf-browser-open") { model in
            model.sheet = .browser
            await model.openPort(model.ports.ports[0])
            let tab = try? XCTUnwrap(model.activeMixed)
            XCTAssertEqual(tab?.tools.values.map(\.tool), [.ports], "Ports stays a leaf")
            XCTAssertEqual(tab?.browsers.count, 1, "the page is a leaf of its own")
            XCTAssertNotNil(tab?.focusedBrowser, "and has the focus")
            XCTAssertNil(model.browserURL, "the Ports leaf shows no page")
            // Again: the leaf showing it comes forward.
            await model.openPort(model.ports.ports[0])
            XCTAssertEqual(model.activeMixed?.browsers.count, 1)
        }
    }

    /// Pane ▸ Open in New Window moves the focused tool leaf to a window, with ⌥⌘N.
    func testOpenInNewWindowIsInTheMenuBar() throws {
        guard wanted("menu") else { return }
        let item = NSApp.mainMenu?.item(withTitle: "Pane")?.submenu?.item(withTitle: "Open in New Window")
        XCTAssertNotNil(item, "Pane ▸ Open in New Window")
        XCTAssertEqual(item?.keyEquivalent, "n")
        XCTAssertEqual(item?.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]), [.command, .option])
    }

    /// A new browser tab's start page while its host's dev servers are found, and after: they
    /// arrive below Frequently and Recently Visited, which stay where they were.
    func testStartPageKeepsItsPlace() async throws {
        try await window("start-page", screen: "start-page", early: "start-page-scanning") { _ in await self.pump(3) }
    }

    /// Add Host fits its mode: compact for SSH, a ticket's lines, the sign-in section with the
    /// real hosts model; an address typed changes values, never the sheet's size.
    func testAddHostFitsItsMode() async throws {
        guard wanted("addHost") else { return }
        let model = WindowModel(app: .shared)
        for live in [false, true] {
            for (mode, destination) in [(PairingSheet.Mode.ssh, ""), (.ssh, "me@devbox:2222"), (.ticket, "")] {
                let window = makeWindow(ThemedRoot {
                    Color.clear.sheet(isPresented: .constant(true)) {
                        PairingSheet(directory: model.hosts, live: live ? model.app.hosts : nil, initialMode: mode, destination: destination)
                            .environment(model).environment(model.app)
                    }
                }, size: CGSize(width: 1180, height: 760))
                await pump(1.5)
                let sheet = try XCTUnwrap(window.attachedSheet)
                try capture(sheet, "addHost-\(mode.rawValue)\(destination.isEmpty ? "" : "-typed")\(live ? "-live" : "")")
                window.close()
            }
        }
    }

    /// Changes on a folder outside any repository: a calm state, not git's words.
    func testToolProblems() async throws {
        final class NotARepository: DiffSource {
            var title: String { "Changes" }
            var unavailableReason: String? { nil }
            func repository() async throws -> DiffRepository { throw ToolProblem.notARepository(folder: "/Users/me/notes") }
            func files(_ scope: DiffScope) async throws -> [DiffFile] { [] }
            func turns() async throws -> [DiffTurn] { [] }
            func reviewer(for scope: DiffScope) -> String? { nil }
            func sendReview(_ notes: [ReviewNote], scope: DiffScope, preamble: String?) async throws {}
        }
        try await tool("diff-not-a-repository", size: CGSize(width: 720, height: 480)) {
            NavigationStack { DiffReviewView(source: NotARepository()) }
        }
    }

    /// New Agent opens at its final size: the host's answer (Claude Code off the PATH here)
    /// changes the status row, never the sheet. Its height is its form's, with nothing blank
    /// under the prompt.
    func testNewAgentKeepsItsSize() async throws {
        guard wanted("launchAgent-steady") else { return }
        for answer in ["installed", "notOnPath", "missing"] {
            try await newAgent(answer: answer)
        }
    }

    private func newAgent(answer: String) async throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["mockAgentInstall"] = answer
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            arguments["mockAgentInstall"] = nil
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(WindowContent(request: nil, model: model).environment(AppModel.shared), size: CGSize(width: 1180, height: 760))
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        model.sheet = .launchAgent
        var opened: NSRect?
        for _ in 0..<40 where opened == nil {
            await pump(0.05)
            opened = window.attachedSheet?.frame
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try capture(sheet, "launchAgent-checking-\(answer)")
        await pump(2.5)
        XCTAssertEqual(sheet.frame.size, opened?.size, "the sheet keeps the size it opened at")
        try capture(sheet, "launchAgent-\(answer)")
        model.sheet = nil
        await pump(0.3)
        window.close()
        model.close()
    }

    /// Files, Changes, Ports and Replays: windows of their own on the Mac.
    func testToolWindows() async throws {
        for route in [SheetRoute.files, .diff, .browser, .replays] {
            try await tool("tool-\(route.rawValue)") { ToolWindowContent(route: route) }
        }
        let entry = FileEntry(path: "~/projects/gudo/Cargo.toml", name: "Cargo.toml", isDirectory: false, size: 1_412)
        try await tool("file-preview") {
            NavigationStack {
                FilePreviewScreen(
                    source: MockFileSource(), entry: entry,
                    actions: FileActions(openInEditor: { _ in }, revealInTerminal: { _ in }, insertPath: { _ in }))
            }
        }
    }

    private func tool(_ name: String, size: CGSize = CGSize(width: 960, height: 680), _ content: () -> some View) async throws {
        guard wanted(name) else { return }
        let model = WindowModel(app: .shared)
        model.start()
        let window = makeWindow(
            ThemedRoot { content().environment(model).environment(model.app).environment(\.isToolWindow, true) },
            size: size)
        await pump(2)
        try capture(window, name)
        window.close()
        model.close()
    }

    func testHostSwitcher() async throws {
        try await window("host-switcher", screen: "host-switcher")
    }

    func testEmptyStates() async throws {
        guard wanted("empty") else { return }
        let window = makeWindow(ThemedRoot {
            HStack(spacing: 0) {
                EmptyState("No Agents Yet", systemImage: "tray", message: "Start Claude Code or Codex on a host. Agents show here, and say when they need you or finish.") {
                    Button("New Agent", systemImage: "sparkle") {}.buttonStyle(.primaryGlass)
                }
                Divider()
                EmptyState("No Host", systemImage: "server.rack", message: "Connect a host to browse its files.") {}
            }
            .chromeBackground(DS.Palette.base)
            .chromeContent()
        }, size: CGSize(width: 1000, height: 640))
        await pump(1.5)
        try capture(window, "empty")
        window.close()
    }

    /// The sketch toolbar (Send to the pane's own agent, or a Send To menu), a shielded pane's
    /// hint, and a standalone drawing's chrome.
    func testDrawingChrome() async throws {
        guard wanted("drawing") else { return }
        let agent = AgentDestination(hostId: "h1", hostName: "studio", pane: 2, agent: .claude, title: "Claude Code", sameHost: true)
        let withAgent = OverlayModel()
        withAgent.primary = agent
        withAgent.destinations = [agent]
        withAgent.loaded = true
        let withoutAgent = OverlayModel()
        withoutAgent.destinations = [agent]
        withoutAgent.loaded = true
        let canvas = CanvasChromeModel()
        canvas.fileName = "drawing-2026-11-03-1412.excalidraw"
        canvas.destinations = [agent]
        let window = makeWindow(ThemedRoot {
            VStack(spacing: 28) {
                OverlayToolbar(model: withAgent)
                OverlayToolbar(model: withoutAgent)
                ZStack {
                    Color.black.opacity(0.28)
                    SketchHereHint()
                }
                .frame(width: 420, height: 120)
                CanvasChrome(model: canvas)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .chromeBackground(DS.Palette.base)
            .chromeContent()
        }, size: CGSize(width: 900, height: 520))
        await pump(1.5)
        try capture(window, "drawing")
        window.close()
    }

    func testSettings() async throws {
        try await settings("settings")
        try await settings("settings-theme", SettingsNavigation(path: [.theme]))
        try await settings("settings-acknowledgements", SettingsNavigation(pane: .about, path: [.acknowledgements]))
        try await settings("settings-privacy", SettingsNavigation(pane: .privacy))
    }

    /// Agent accounts: Settings › Agents with the hosts, one host's accounts, and a pane under
    /// the Work account (its header names it; Work is at its limit, so the suggestion shows).
    func testAccounts() async throws {
        try await settings("settings-agents", SettingsNavigation(pane: .agents))
        try await settings("settings-accounts", SettingsNavigation(pane: .agents, path: [.hostAccounts("studio")]))
        try await window("account-pane")
    }

    /// App Lock's screen, as it covers a locked window.
    func testAppLockScreen() async throws {
        struct Owner: AppLockAuthenticator {
            func method() -> AppLockMethod? { .touchID }
            func authenticate(reason: String) async -> AppLockAuthResult { .cancelled }
        }
        let suite = "app-lock-snapshot"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = AppLock(defaults: defaults, authenticator: Owner())
        guard wanted("app-lock") else { return }
        let window = makeWindow(AppLockScreen(lock: lock, prompts: false), size: CGSize(width: 1180, height: 760))
        await pump(1)
        try capture(window, "app-lock")
        window.close()
    }

    // MARK: Floating panes

    /// The Mac's width and an iPad's (the same canvas at 1024 × 768).
    private static let floatingSizes: [(String, CGSize)] = [("", CGSize(width: 1180, height: 760)), ("-ipad", CGSize(width: 1024, height: 768))]

    /// Repaints the fixture's screens at the grids the panes settled at, until every pane
    /// shows its screen (a pane made late greets after an earlier paint).
    private func repaint(_ model: WindowModel) async {
        guard let workspace = model.workspace, let panes = FloatingFixtures.last else { return }
        let marks: [(PaneId?, String)] = [
            (panes.shell, "git log"), (panes.tests, "cargo test"), (panes.htop, "PID"), (panes.agent, "dock a floating"), (panes.logs, "hostd:"),
        ]
        for _ in 0..<10 {
            FloatingFixtures.paint(workspace, panes)
            await pump(0.4)
            let shown = marks.allSatisfy { pane, mark in
                guard let pane, let terminal = workspace.panes[pane]?.view.surface.terminal else { return true }
                return terminal.visibleText().contains(mark)
            }
            if shown { break }
        }
        await present(model)
    }

    /// Draws every pane's latest frame: a window off screen gets no display-link ticks. New
    /// glyphs are drawn a frame's budget at a time, so it draws frame by frame until done.
    private func present(_ model: WindowModel) async {
        if let current, current.level.rawValue < 0 { return }
        let surfaces = model.workspace.map { $0.panes.values.map(\.view.surface) } ?? []
        for round in 0..<2 {
            for _ in 0..<120 {
                var drew = false
                for surface in surfaces { drew = surface.renderIfDirty() || drew }
                CATransaction.flush()
                guard drew else { break }
                await pump(1.0 / 60)
            }
            // Once more from scratch: rows built while glyphs were still on their way.
            if round == 0 {
                for surface in surfaces { surface.outputArrived() }
                await pump(0.1)
            }
        }
        await pump(0.1)
    }

    /// Puts the fixture's window on the main display below the desktop picture: invisible to
    /// anyone at the Mac, never active, but on a display, so its animations get frames (a window
    /// off every display gets no display-link ticks and jumps to the end of each animation).
    private func animating(_ window: NSWindow) {
        // A locked display hands back blank pictures of windows on it: stay off it.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["CGSSessionScreenIsLocked"] as? Bool != true, let screen = NSScreen.main else { return }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        window.orderBack(nil)
    }

    /// Captures `name-0…` through `change`: in real time on a display; off it (a locked Mac)
    /// the canvas is drawn at points along the `lift` spring, as its animation would draw it.
    private func frames(_ name: String, _ model: WindowModel, _ change: () -> Void) async {
        guard let window = current else { return }
        if window.level.rawValue >= 0 {
            animating(window)
            if window.level.rawValue < 0 { await pump(0.5) }
        }
        if window.level.rawValue < 0 {
            change()
            for (index, gap) in [0, 0.016, 0.016, 0.016, 0.016, 0.03, 0.06, 0.3].enumerated() {
                await pump(gap)
                try? capture(window, "\(name)-\(index)")
            }
        } else {
            let arrangement = model.arrangement
            guard let from = arrangement.layout else { return }
            // The grids hold through the motion, as they do while it animates, with no
            // cols × rows overlay; the canvas's own animation stays off while it is scrubbed.
            let start = ContinuousClock.now
            TerminalSurface.holdGrids(for: .seconds(6))
            PaneArrangement.stillDuration = 6
            defer { PaneArrangement.stillDuration = DS.Motion.liftDuration }
            model.workspace?.layoutChangeUntil = .now + .seconds(8)
            arrangement.scrub = .init(from: from, progress: 0)
            change()
            await pump(0.1)
            model.workspace?.layoutChangeUntil = .now + .seconds(8)
            let spring = Spring(duration: 0.42, bounce: 0.12)
            for (index, time) in [0, 0.03, 0.06, 0.1, 0.15, 0.22, 0.3, 0.5].enumerated() {
                arrangement.scrub = .init(from: from, progress: spring.value(target: 1.0, time: time))
                await pump(0.08)
                await present(model)
                try? capture(window, "\(name)-\(index)")
            }
            arrangement.scrub = nil
            try? await Task.sleep(until: start + .seconds(6.3), clock: .continuous)
        }
        // At rest the grids reflow once and the programs redraw at their new size.
        await pump(0.8)
        await repaint(model)
        try? capture(window, "\(name)-8")
    }

    /// htop floating over a shell and a test run, several windows with a split
    /// inside one, the tray, and a zoomed pane with its way back.
    func testFloatingStills() async throws {
        drawsTerminals = true
        defer { drawsTerminals = false }
        defer { MockPaneStatus.fixture = nil; MockPaneStatus.details = [:] }
        for (suffix, size) in Self.floatingSizes {
            for screen in ["floating", "floating-multi", "floating-tray", "floating-zoom"] {
                try await window(screen + suffix, screen: screen, size: size) { model in
                    await self.pump(0.8)
                    await self.repaint(model)
                }
            }
        }
    }

    /// A tiled pane dragged by its header onto another's right half: the chip follows, the
    /// region lights, and on drop the panes move into place in one spring.
    func testFloatingDragSequence() async throws {
        drawsTerminals = true
        defer { drawsTerminals = false }
        defer { MockPaneStatus.fixture = nil; MockPaneStatus.details = [:] }
        try await window("floating-drag-end", screen: "floating-tiled") { model in
            await self.pump(0.8)
            self.animating(self.current!)
            await self.repaint(model)
            let arrangement = model.arrangement
            guard let workspace = model.workspace, let layout = arrangement.layout, layout.tiled.count == 3 else { return XCTFail("three tiled panes") }
            let (dragged, from) = layout.tiled[0]
            let (_, onto) = layout.tiled[2]
            let start = CGPoint(x: from.midX, y: from.minY + 12)
            let end = CGPoint(x: onto.maxX - onto.width / 6, y: onto.midY)
            for step in 0...8 {
                let progress = CGFloat(step) / 8
                arrangement.drag(dragged, to: CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
                await self.pump(0.05)
                await self.present(model)
                try? self.capture(self.current!, "floating-drag-\(step)")
            }
            XCTAssertNotNil(arrangement.paneDrag?.preview, "the drop region is lit")
            await self.frames("floating-drop", model) { arrangement.endDrag(dragged, at: end) }
            XCTAssertEqual(workspace.session.activeTab.flatMap { workspace.session.tiledRoot(of: $0) }?.panes.last, dragged)
        }
    }

    /// Float, then dock, then minimize and restore, then a split inside the window: each as
    /// frames, so the motion can be reviewed one step at a time.
    func testFloatingSequences() async throws {
        drawsTerminals = true
        defer { drawsTerminals = false }
        defer { MockPaneStatus.fixture = nil; MockPaneStatus.details = [:] }
        try await window("floating-split-end", screen: "floating-tiled") { model in
            await self.pump(0.8)
            await self.repaint(model)
            guard let workspace = model.workspace, let htop = workspace.focusedPane else { return XCTFail("no pane") }
            await self.frames("floating-lift", model) { model.toggleFloat(htop, in: workspace) }
            XCTAssertTrue(workspace.session.isFloating(htop))
            await self.pump(0.5)
            await self.frames("floating-dock", model) { model.toggleFloat(htop, in: workspace) }
            XCTAssertFalse(workspace.session.isFloating(htop))
            await self.pump(0.5)
            model.toggleFloat(htop, in: workspace)
            await self.pump(0.8)
            await self.frames("floating-minimize", model) { model.toggleMinimized(htop, in: workspace) }
            XCTAssertEqual(workspace.window(of: htop)?.minimized, true)
            await self.pump(0.5)
            await self.frames("floating-restore", model) { model.toggleMinimized(htop, in: workspace) }
            XCTAssertEqual(workspace.window(of: htop)?.minimized, false)
            await self.pump(0.5)
            await self.frames("floating-split", model) { WorkspaceAction.splitDown.perform(on: workspace, window: model) }
            XCTAssertEqual(workspace.window(of: htop)?.panes.count, 2, "the new pane joins the window")
            // Held 4 pt off the tab's middle: it snaps there and the guide shows.
            await self.pump(0.5)
            let arrangement = model.arrangement
            guard let card = arrangement.layout?.cards.first(where: { $0.panes.contains(htop) }), let bounds = arrangement.layout?.bounds else {
                return XCTFail("no window")
            }
            let dx = bounds.midX + 4 - card.frame.minX
            arrangement.move(card.id, by: CGSize(width: dx, height: 20), at: CGPoint(x: card.frame.midX + dx, y: card.frame.minY + 8))
            await self.pump(0.3)
            XCTAssertFalse(arrangement.guides.isEmpty, "a snap guide shows")
            try? self.capture(self.current!, "floating-guides")
            arrangement.endMove(card.id, by: CGSize(width: dx, height: 20), velocity: .zero)
        }
    }

    // MARK: Layout motion

    /// The moments of a motion each sequence shows: every 30 ms of its first 0.3 s, then later.
    private static let motionTimes = [0, 0.03, 0.06, 0.09, 0.12, 0.15, 0.18, 0.21, 0.24, 0.3, 0.42]

    /// Captures `name-0…` through `change`, the canvas drawn at points along `spring` as its
    /// animation draws it (a capture takes longer than a frame), each terminal as it shows
    /// then (its held last frame); then `name-rest` once it has settled and redrawn.
    private func motion(_ name: String, _ model: WindowModel, spring: Spring = Spring(duration: DS.Motion.splitDuration, bounce: 0), _ change: () -> Void) async {
        guard let window = current else { return }
        let arrangement = model.arrangement
        guard let from = arrangement.preview ?? arrangement.layout else { return }
        keepFrames(model)
        PaneArrangement.settleStretch = 40
        model.workspace?.layoutChangeUntil = .now + .seconds(20)
        arrangement.scrub = .init(from: from, progress: 0)
        change()
        await pump(0.1)
        for (index, time) in Self.motionTimes.enumerated() {
            arrangement.scrub = .init(from: from, progress: spring.value(target: 1.0, time: time))
            await pump(0.08)
            try? capture(window, "\(name)-\(index)")
        }
        arrangement.scrub = nil
        PaneArrangement.settleStretch = 1
        await pump(0.8)
        await present(model)
        try? capture(window, "\(name)-rest")
    }

    /// Keeps what each terminal shows now, for the frames of a motion that holds it.
    private func keepFrames(_ model: WindowModel) {
        for (pane, terminal) in model.workspace?.panes ?? [:] where !terminal.view.surface.isHoldingFrame {
            _ = terminal.view.surface.renderIfDirty(offscreen: true)
            heldFrames[pane] = terminal.view.surface.snapshot()
        }
    }

    /// The terminals' grid changes so far, by pane: each is one SIGWINCH to its shell.
    private func resizes(_ model: WindowModel) -> [PaneId: Int] {
        model.workspace?.panes.mapValues(\.resizesSent) ?? [:]
    }

    /// Zoom in and out of the right pane of two side by side, and the lower of two stacked, each
    /// shell at a prompt with a clock at its right edge: the pane moves as a picture of its last
    /// frame, its grid changes once (one SIGWINCH, before it moves) and the shell's redraw shows
    /// when it lands. Then a split and a close.
    func testTransitions() async throws {
        drawsTerminals = true
        defer { drawsTerminals = false }
        defer { MockPaneStatus.fixture = nil }
        for (layout, screen) in [("columns", "transitions-columns"), ("rows", "transitions-rows")] {
            try await window("transitions-\(layout)", screen: screen) { model in
                self.animating(self.current!)
                await self.pump(0.8)
                await self.present(model)
                guard let workspace = model.workspace, let (first, second) = TransitionFixtures.last else { return XCTFail("no panes") }
                workspace.apply(.focus(second))
                await self.pump(0.5)
                await self.present(model)

                var before = self.resizes(model)
                await self.motion("zoom-\(layout)-in", model) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) }
                var after = self.resizes(model)
                XCTAssertEqual(after[second], (before[second] ?? 0) + 1, "the zoomed pane resizes once")
                XCTAssertEqual(after[first], before[first], "the pane under it keeps its size")

                before = after
                await self.motion("zoom-\(layout)-out", model) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) }
                after = self.resizes(model)
                XCTAssertEqual(after[second], (before[second] ?? 0) + 1, "back to its place: one resize")
                XCTAssertEqual(after[first], before[first])

                guard layout == "columns" else { return }
                await self.motion("split-\(layout)", model) { WorkspaceAction.splitDown.perform(on: workspace, window: model) }
                await self.motion("close-\(layout)", model) { WorkspaceAction.closePane.perform(on: workspace, window: model) }
            }
        }
    }

    /// Two panes stacked, the bottom one dragged by its header over the left
    /// part of the top one. The preview shows the panes as the drop leaves them (the dragged
    /// one the tab's whole left half), and the drop settles exactly there.
    func testDragPreview() async throws {
        drawsTerminals = true
        defer { drawsTerminals = false }
        defer { MockPaneStatus.fixture = nil }
        try await window("drag-preview", screen: "transitions-rows") { model in
            self.animating(self.current!)
            await self.pump(0.8)
            await self.present(model)
            let arrangement = model.arrangement
            guard let workspace = model.workspace, let (top, bottom) = TransitionFixtures.last, let layout = arrangement.layout,
                  let from = layout.leaf(bottom)?.frame, let onto = layout.leaf(top)?.frame else { return XCTFail("no panes") }
            let start = CGPoint(x: from.midX, y: from.minY + 12)
            let end = CGPoint(x: onto.minX + onto.width * 0.18, y: onto.midY)
            self.keepFrames(model)
            for step in 0...10 {
                let progress = CGFloat(step) / 10
                let shown = arrangement.preview ?? layout
                let drop = arrangement.paneDrag?.drop
                arrangement.scrub = .init(from: shown, progress: 0)
                arrangement.drag(bottom, to: CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
                if step > 0, arrangement.paneDrag?.drop != drop {
                    // The panes making room, along the `reorder` spring.
                    let spring = Spring(response: 0.3, dampingRatio: 0.84)
                    for (index, time) in Self.motionTimes.enumerated() {
                        arrangement.scrub = .init(from: shown, progress: spring.value(target: 1.0, time: time))
                        await self.pump(0.08)
                        try? self.capture(self.current!, "drag-room-\(step)-\(index)")
                    }
                }
                arrangement.scrub = nil
                await self.pump(step == 10 ? 0.5 : 0.1)
                try? self.capture(self.current!, "drag-preview-\(step)")
            }
            let lit = arrangement.paneDrag?.preview
            XCTAssertEqual(arrangement.paneDrag?.drop, .beside(top, .left))
            XCTAssertEqual(lit?.height ?? 0, layout.bounds.height, accuracy: 1, "lit: the whole left half")
            await self.motion("drag-drop", model) { arrangement.endDrag(bottom, at: end) }
            XCTAssertEqual(arrangement.layout?.leaf(bottom)?.frame, lit, "dropped where it was lit")
            _ = workspace
        }
    }

    // MARK: Updates

    private final class IdleUpdater: UpdateChecking {
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var allowsAutomaticUpdates: Bool { true }
        func checkForUpdates() {}
    }

    /// The sidebar's update control: in the window with its notes open, then each state at the
    /// sidebar's width.
    func testUpdateCard() async throws {
        let suite = "update-card-snapshot"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = AppUpdater.shared
        defer { AppUpdater.shared = saved }
        let offer = UpdateOffer(
            version: "815", displayVersion: "0.1.4",
            notes: "• Updates arrive in the sidebar\n• Faster reconnects after sleep\n• Fixes a crash when closing a split")
        func prompt(_ configure: (UpdatePrompt) -> Void) -> UpdatePrompt {
            let prompt = UpdatePrompt(defaults: defaults, upToDateDuration: .seconds(600))
            prompt.isMinimized = false
            configure(prompt)
            return prompt
        }
        func offered(_ prompt: UpdatePrompt, stage: UpdateStage = .notDownloaded) {
            prompt.found(offer, stage: stage, userInitiated: false) { _ in }
        }

        AppUpdater.shared = AppUpdater(updater: IdleUpdater(), prompt: prompt { offered($0); $0.toggleNotes() })
        try await window("update-sidebar")

        guard wanted("update-states") else { return }
        let states: [[UpdatePrompt]] = [
            [
                prompt { offered($0) },
                prompt { offered($0); $0.accept(); $0.downloadExpects(1000); $0.downloadReceived(420) },
                prompt { offered($0, stage: .downloaded) },
                prompt { $0.checkStarted {} },
            ],
            [
                prompt { $0.checkStarted {}; $0.notFound(upToDate: true, message: "") },
                prompt { $0.checkStarted {}; $0.notFound(upToDate: false, message: "The update feed could not be reached.") },
                prompt { offered($0); $0.accept(); $0.extractionStarted(); $0.extractionProgressed(0.7) },
                prompt { offered($0); $0.isMinimized = true },
            ],
        ]
        let window = makeWindow(ThemedRoot {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(states.indices, id: \.self) { row in
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(states[row].indices, id: \.self) { column in
                            let state = states[row][column]
                            VStack(spacing: DS.Space.s) {
                                Spacer(minLength: 0)
                                if state.showsCard { UpdateCard(prompt: state) }
                                HStack(spacing: DS.Space.s) {
                                    Label("New Project", systemImage: "plus")
                                        .font(DS.Font.sidebarSubtitle)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                    Spacer()
                                    if state.showsIndicator { UpdateIndicator(prompt: state) }
                                    Image(systemName: "gearshape").foregroundStyle(DS.Palette.textSecondary).frame(width: 26, height: 26)
                                }
                                .padding(.horizontal, DS.Space.l)
                                .padding(.bottom, DS.Space.s)
                            }
                            .frame(width: SidebarWidth.standard, height: 290)
                            .chromeBackground(DS.Palette.sidebar)
                            .padding(DS.Space.s)
                        }
                    }
                }
            }
            .padding(DS.Space.s)
            .chromeContent()
            .chromeBackground(DS.Palette.base)
        }, size: CGSize(width: 4 * (SidebarWidth.standard + 16) + 16, height: 2 * 306 + 16 + 28))
        await pump(1.5)
        try capture(window, "update-states")
        window.close()
    }

    private func settings(_ name: String, _ navigation: SettingsNavigation = SettingsNavigation()) async throws {
        guard wanted(name) else { return }
        let window = makeWindow(ThemedRoot { SettingsView(navigation: navigation) }, size: CGSize(width: 820, height: 560))
        await pump(1.5)
        try capture(window, name)
        window.close()
    }
}
#endif
