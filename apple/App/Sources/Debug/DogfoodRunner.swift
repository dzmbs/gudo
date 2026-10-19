#if DEBUG && os(macOS)
import AppKit
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer

/// In-app end-to-end scenario runner ("dogfood"), debug builds only.
///
///     unnamed.app/Contents/MacOS/unnamed -dogfood core.json -dogfoodOut /tmp/out
///
/// Drives the app through its real input paths (synthesized `NSEvent`s posted to its own queue: see
/// `DogfoodEvents`), checks the terminal screen (`Terminal.visibleText`), the pane's process tree
/// (the PTY child's pid and `sysctl`) and the layout, captures PNGs without Screen Recording
/// (`DogfoodScreenshot`), writes `report.json` to the out directory, then quits, killing its shells.
/// Exit status: 0 all cases passed, 1 a case failed, 2 the scenario could not be loaded, 3 hang or
/// time limit (`DogfoodWatchdog`). Scenario format: apple/Dogfood/README.md.
@MainActor
final class DogfoodRunner {
    private static var current: DogfoodRunner?

    static func startIfRequested(workspace: Workspace) {
        guard current == nil, let path = UserDefaults.standard.string(forKey: "dogfood"), !path.isEmpty else { return }
        let out = UserDefaults.standard.string(forKey: "dogfoodOut")
            ?? NSTemporaryDirectory() + "dogfood-\(Int(Date().timeIntervalSince1970))"
        let runner = DogfoodRunner(scenarioURL: URL(fileURLWithPath: path), outDir: URL(fileURLWithPath: out), workspace: workspace)
        current = runner
        Task { await runner.run() }
    }

    // MARK: Report

    struct StepReport: Codable {
        var index: Int
        var action: String
        var name: String?
        var passed: Bool
        var ms: Double
        var detail: String?
        var error: String?
        var screenshot: String?
        var metrics: [String: Double]?
    }

    struct CaseReport: Codable {
        var name: String
        var passed: Bool
        var ms: Double
        var steps: [StepReport]
        var failureScreenshot: String?
    }

    struct LatencyStats: Codable {
        var count: Int
        var meanMs: Double
        var p50Ms: Double
        var p95Ms: Double
        var maxMs: Double

        init?(_ samples: [Double]) {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            count = sorted.count
            meanMs = sorted.reduce(0, +) / Double(sorted.count)
            p50Ms = sorted[sorted.count / 2]
            p95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            maxMs = sorted.last!
        }
    }

    struct Report: Codable {
        var scenario: String
        var started: String
        var durationMs: Double = 0
        var passed = false
        var casesPassed = 0
        var casesFailed = 0
        var cases: [CaseReport] = []
        /// Keystroke posted → the shell's echo in the terminal state (cursor or text changed), over
        /// every `type` step with `"latency": true`.
        var keystrokeToEcho: LatencyStats?
        /// Keystroke posted → the next frame the pane rendered after the echo. Missing when the
        /// display link does not run (window occluded, screen locked): see `framesMissed`.
        var keystrokeToFrame: LatencyStats?
        var framesMissed = 0
        var maxMainThreadStallMs = 0.0
        var leakedProcesses: [DogfoodProcesses.Process] = []
        var environment: [String: String] = [:]
        var error: String?
    }

    // MARK: State

    private let scenarioURL: URL
    private let outDir: URL
    private let workspace: Workspace
    private let pump = DogfoodEventPump()
    private var report: Report
    private var watchdog: DogfoodWatchdog?
    private var echoLatencies: [Double] = []
    private var frameLatencies: [Double] = []
    private var framesMissed = 0
    private var rememberedFocus: [String: PaneId] = [:]
    private var capturedPids: [String: [Int32]] = [:]
    private var rememberedScreens: [String: String] = [:]
    private let startTime = ProcessInfo.processInfo.systemUptime

    private init(scenarioURL: URL, outDir: URL, workspace: Workspace) {
        self.scenarioURL = scenarioURL
        self.outDir = outDir
        self.workspace = workspace
        report = Report(scenario: scenarioURL.path, started: ISO8601DateFormatter().string(from: Date()))
        pump.performDisabledShortcut = { [weak self] event in self?.performWorkspaceShortcut(event) ?? false }
    }

    /// The workspace action bound to `event`'s shortcut, run as its menu item would run it.
    private func performWorkspaceShortcut(_ event: NSEvent) -> Bool {
        var mods: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        let actions = WorkspaceAction.fileActions + WorkspaceAction.paneActions + WorkspaceAction.tabActions
        guard let action = actions.first(where: {
            $0.shortcut.modifiers == mods && DogfoodEvents.keyCode(for: $0.shortcut.key.character) == event.keyCode
        }) else { return false }
        action.perform(on: workspace, window: ActiveWindow.model(for: workspace))
        return true
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private var window: NSWindow? {
        workspace.panes.values.lazy.compactMap { $0.view.window }.first
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    // MARK: Run

    private func run() async {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let scenario: [String: Any]
        do {
            let data = try Data(contentsOf: scenarioURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("not a JSON object") }
            scenario = json
        } catch {
            report.error = "cannot load scenario: \(error)"
            return finish(exitCode: 2)
        }
        let watchdog = DogfoodWatchdog(
            hangSeconds: scenario["hangSeconds"] as? Double ?? 15,
            timeoutSeconds: scenario["timeoutSeconds"] as? Double ?? 900,
            reportURL: outDir.appendingPathComponent("report.json"))
        watchdog.start()
        self.watchdog = watchdog
        log("scenario \(scenarioURL.lastPathComponent) → \(outDir.path)")

        do {
            try await prepareWindow(scenario)
        } catch {
            report.error = "window never appeared: \(error)"
            return finish(exitCode: 1)
        }

        let cases = scenario["cases"] as? [[String: Any]] ?? []
        let only = UserDefaults.standard.string(forKey: "dogfoodCase")
        var needsRecovery = false
        for testCase in cases {
            let name = testCase["name"] as? String ?? "case \(report.cases.count + 1)"
            if let only, !name.contains(only) { continue }
            if needsRecovery || testCase["fresh"] as? Bool == true {
                await recover()
                needsRecovery = false
            }
            let result = await runCase(name: name, steps: testCase["steps"] as? [[String: Any]] ?? [])
            report.cases.append(result)
            if result.passed { report.casesPassed += 1 } else { report.casesFailed += 1; needsRecovery = true }
            log("\(result.passed ? "PASS" : "FAIL") \(name) (\(Int(result.ms)) ms)")
            publishPartial()
        }
        finish(exitCode: report.casesFailed == 0 && !report.cases.isEmpty ? 0 : 1)
    }

    private func prepareWindow(_ scenario: [String: Any]) async throws {
        try await poll(timeout: 20, what: "the first pane in a window") {
            guard let pane = self.focusedPaneOrNil, pane.view.window != nil else { return false }
            return true
        }
        guard let window else { throw Failure("no window") }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if let size = scenario["window"] as? [String: Any], let w = size["width"] as? Double, let h = size["height"] as? Double {
            setWindowSize(window, width: w, height: h)
        }
        try? await Task.sleep(for: .milliseconds(300))
        report.environment = [
            "isActive": "\(NSApp.isActive)",
            "isKeyWindow": "\(window.isKeyWindow)",
            "firstResponderIsTerminal": "\(window.firstResponder is TerminalView)",
            "backingScale": "\(window.backingScaleFactor)",
            "windowVisible": "\(window.occlusionState.contains(.visible))",
            "inactiveDelivery": NSApp.keyWindow == nil ? "keys → window first responder; disabled ⌘ menu items → their actions" : "none",
            "shell": ProcessInfo.processInfo.environment["SHELL"] ?? "",
            "zdotdir": ProcessInfo.processInfo.environment["ZDOTDIR"] ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        log("window key=\(window.isKeyWindow) active=\(NSApp.isActive)")
    }

    private func runCase(name: String, steps: [[String: Any]]) async -> CaseReport {
        let caseStart = ProcessInfo.processInfo.systemUptime
        var result = CaseReport(name: name, passed: true, ms: 0, steps: [])
        for (index, step) in steps.enumerated() {
            let action = step["do"] as? String ?? "?"
            var stepReport = StepReport(index: index, action: action, name: step["name"] as? String, passed: true, ms: 0)
            _ = watchdog?.takeMaxStall()
            let t0 = ProcessInfo.processInfo.systemUptime
            do {
                var metrics: [String: Double] = [:]
                stepReport.detail = try await perform(action, step, report: &stepReport, metrics: &metrics)
                if !metrics.isEmpty { stepReport.metrics = metrics }
            } catch {
                stepReport.passed = false
                var message = String(describing: error)
                if let modal = NSApp.modalWindow {
                    message += " [a modal window was up: \"\(modal.title)\"; aborted]"
                    NSApp.abortModal()
                }
                stepReport.error = message
            }
            stepReport.ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            let stall = (watchdog?.takeMaxStall() ?? 0) * 1000
            // A screenshot blocks the main thread by design (cacheDisplay + GPU readback): not the app's stall.
            if action != "screenshot" { report.maxMainThreadStallMs = max(report.maxMainThreadStallMs, stall) }
            if stall > 100 { stepReport.metrics = (stepReport.metrics ?? [:]).merging(["mainThreadStallMs": stall]) { $1 } }
            result.steps.append(stepReport)
            if !stepReport.passed {
                log("  step \(index) \(action) failed: \(stepReport.error ?? "")")
                result.passed = false
                result.failureScreenshot = screenshot(named: "FAIL-\(slug(name))")?.path
                break
            }
        }
        result.ms = (ProcessInfo.processInfo.systemUptime - caseStart) * 1000
        return result
    }

    /// After a failed case: a fresh tab with a new shell, and every other tab closed.
    private func recover() async {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        workspace.apply(.newTab)
        guard let keep = workspace.session.activeTabId else { return }
        for tab in workspace.session.tabs where tab.id != keep { workspace.apply(.closeTab(tab.id)) }
        try? await waitIdle(pane: focusedPaneOrNil, quiet: 0.5, timeout: 15)
    }

    private func finish(exitCode: Int32) {
        report.durationMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
        report.passed = exitCode == 0
        report.keystrokeToEcho = LatencyStats(echoLatencies)
        report.keystrokeToFrame = LatencyStats(frameLatencies)
        report.framesMissed = framesMissed
        // Quit like closing the window: hang up every shell, then make sure nothing outlives us.
        for pane in workspace.panes.values { pane.terminate() }
        let deadline = Date().addingTimeInterval(3)
        var leftovers = DogfoodProcesses.tree(of: getpid()).filter { $0.pid != getpid() }
        while !leftovers.isEmpty, Date() < deadline {
            usleep(50_000)
            leftovers = DogfoodProcesses.tree(of: getpid()).filter { $0.pid != getpid() }
        }
        report.leakedProcesses = leftovers
        DogfoodWatchdog.killChildren(signal: SIGKILL)
        var code = exitCode
        if !leftovers.isEmpty, code == 0 { code = 1 }
        writeReport()
        log(summary())
        exit(code)
    }

    private func writeReport() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(report) {
            try? data.write(to: outDir.appendingPathComponent("report.json"))
        }
    }

    private func publishPartial() {
        if let data = try? JSONEncoder().encode(report) { watchdog?.setPartialReport(data) }
        writeReport()
    }

    private func summary() -> String {
        var lines = ["dogfood: \(report.passed ? "PASSED" : "FAILED") \(report.casesPassed)/\(report.cases.count) cases in \(Int(report.durationMs / 1000)) s"]
        if let error = report.error { lines.append("  error: \(error)") }
        if let l = report.keystrokeToEcho {
            lines.append(String(format: "  keystroke→echo: p50 %.1f ms, p95 %.1f ms, max %.1f ms (n=%d)", l.p50Ms, l.p95Ms, l.maxMs, l.count))
        }
        if let l = report.keystrokeToFrame {
            lines.append(String(format: "  keystroke→frame: p50 %.1f ms, p95 %.1f ms, max %.1f ms (n=%d)", l.p50Ms, l.p95Ms, l.maxMs, l.count))
        }
        if !report.leakedProcesses.isEmpty {
            lines.append("  leaked processes: \(report.leakedProcesses.map { "\($0.name)(\($0.pid))" }.joined(separator: ", "))")
        }
        lines.append("  report: \(outDir.appendingPathComponent("report.json").path)")
        return lines.joined(separator: "\n")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("dogfood: \(message)\n".utf8))
    }

    // MARK: Steps

    private func perform(_ action: String, _ step: [String: Any], report stepReport: inout StepReport, metrics: inout [String: Double]) async throws -> String? {
        guard let window else { throw Failure("no window") }
        switch action {
        case "type":
            let text = substitute(try string(step, "text"))
            let pane = try resolvePane(step)
            if step["latency"] as? Bool == true {
                var echoes: [Double] = [], frames: [Double] = []
                for char in text {
                    let key = DogfoodEvents.typing(char)
                    if char == "\n" {
                        await pump.post(DogfoodEvents.keyEvents(key, window: window), window: window)
                        continue
                    }
                    let sample = try await measureEcho(pane: pane, key: key, window: window)
                    echoes.append(sample.echo)
                    if let frame = sample.frame { frames.append(frame) } else { framesMissed += 1 }
                }
                echoLatencies += echoes
                frameLatencies += frames
                if let stats = LatencyStats(echoes) {
                    metrics["echoP50Ms"] = stats.p50Ms
                    metrics["echoP95Ms"] = stats.p95Ms
                    metrics["echoMaxMs"] = stats.maxMs
                }
                if let stats = LatencyStats(frames) {
                    metrics["frameP50Ms"] = stats.p50Ms
                    metrics["frameP95Ms"] = stats.p95Ms
                    metrics["frameMaxMs"] = stats.maxMs
                }
            } else {
                let events = text.flatMap { DogfoodEvents.keyEvents(DogfoodEvents.typing($0), window: window) }
                await pump.post(events, window: window)
            }
            return "\(text.count) characters"

        case "key", "shortcut":
            let spec = try string(step, action == "key" ? "key" : "keys")
            let key = try DogfoodEvents.parse(spec)
            let count = step["repeat"] as? Int ?? 1
            for _ in 0..<count { await pump.post(DogfoodEvents.keyEvents(key, window: window), window: window) }
            // Menu commands mutate the layout, which SwiftUI applies on the next turn.
            try? await Task.sleep(for: .milliseconds(step["settleMs"] as? Int ?? (key.flags.contains(.command) ? 250 : 20)))
            if NSApp.keyWindow == nil, key.flags.contains(.command) {
                if pump.lastShortcutRoute == "unhandled" { throw Failure("\(spec): no window view, menu item or action took it") }
                return "\(spec) via \(pump.lastShortcutRoute) (app inactive)"
            }
            return spec

        case "paste":
            let text = substitute(try string(step, "text"))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            await pump.post(DogfoodEvents.keyEvents(try DogfoodEvents.parse("cmd+v"), window: window), window: window)
            try? await Task.sleep(for: .milliseconds(50))
            return "\(text.count) characters, \(text.split(separator: "\n").count) lines"

        case "waitText":
            let pane = try resolvePane(step)
            let matcher = try textMatcher(step)
            let absent = step["absent"] as? Bool == true
            let timeout = step["timeout"] as? Double ?? 10
            do {
                try await poll(timeout: timeout, what: "text") { matcher(pane.view.surface.terminal.visibleText()) != absent }
            } catch {
                throw Failure("\(absent ? "still showing" : "never saw") \(matcher.description) within \(timeout) s; screen tail:\n\(tail(pane))")
            }
            return matcher.description

        case "waitIdle":
            try await waitIdle(pane: try resolvePane(step), quiet: step["quiet"] as? Double ?? 0.5, timeout: step["timeout"] as? Double ?? 20)
            return nil

        case "rememberScreen":
            rememberedScreens[try string(step, "as")] = try resolvePane(step).view.surface.terminal.visibleText()
            return nil

        case "waitScreenChanged":
            let pane = try resolvePane(step)
            let label = try string(step, "from")
            guard let before = rememberedScreens[label] else { throw Failure("no screen remembered as \(label)") }
            try await poll(timeout: step["timeout"] as? Double ?? 5, what: "screen change") {
                pane.view.surface.terminal.visibleText() != before
            }
            return nil

        case "waitProcess":
            let pane = try resolvePane(step)
            let name = try string(step, "name")
            let state = step["state"] as? String ?? "running"
            guard let shell = shellPid(pane) else { throw Failure("pane has no local shell pid") }
            var last: [DogfoodProcesses.Process] = []
            do {
                try await poll(timeout: step["timeout"] as? Double ?? 10, what: "process") {
                    last = DogfoodProcesses.tree(of: shell).filter { $0.name == name }
                    switch state {
                    case "gone": return last.isEmpty
                    case "stopped": return !last.isEmpty && last.allSatisfy(\.isStopped)
                    case "exists": return !last.isEmpty
                    default: return !last.isEmpty && last.contains { !$0.isStopped }
                    }
                }
            } catch {
                throw Failure("\(name) never \(state) under shell \(shell); found \(describe(last)); tree: \(describe(DogfoodProcesses.tree(of: shell)))")
            }
            return "\(name) \(state): \(describe(last))"

        case "capturePids":
            let pane = try resolvePane(step)
            guard let shell = shellPid(pane) else { throw Failure("pane has no local shell pid") }
            let tree = DogfoodProcesses.tree(of: shell)
            capturedPids[try string(step, "as")] = tree.map(\.pid)
            return describe(tree)

        case "waitPidsGone":
            let label = try string(step, "of")
            guard let pids = capturedPids[label] else { throw Failure("no pids captured as \(label)") }
            var alive: [DogfoodProcesses.Process] = []
            do {
                try await poll(timeout: step["timeout"] as? Double ?? 5, what: "processes to exit") {
                    alive = DogfoodProcesses.alive(pids)
                    return alive.isEmpty
                }
            } catch {
                throw Failure("still alive: \(describe(alive))")
            }
            return "\(pids.count) processes gone"

        case "screenshot":
            let name = try string(step, "name")
            guard let result = DogfoodScreenshot.capture(window: window, panes: Array(workspace.panes.values)) else {
                throw Failure("capture failed")
            }
            let url = outDir.appendingPathComponent("\(slug(name)).png")
            guard DogfoodScreenshot.writePNG(result.image, to: url) else { throw Failure("cannot write \(url.path)") }
            stepReport.screenshot = url.path
            for ink in result.panes { metrics["ink.\(ink.pane)"] = (ink.ink * 10000).rounded() / 10000 }
            if step["expectInk"] as? Bool ?? true {
                if result.panes.isEmpty { throw Failure("no pane drawn into \(url.lastPathComponent)") }
                if let blank = result.panes.first(where: { $0.ink < 0.0005 }) {
                    throw Failure("\(blank.pane) looks blank in \(url.lastPathComponent) (ink \(blank.ink))")
                }
            }
            return url.lastPathComponent

        case "remember":
            guard let focused = workspace.focusedPane else { throw Failure("no focused pane") }
            rememberedFocus[try string(step, "focus")] = focused
            return focused.description

        case "assert":
            let timeout = step["timeout"] as? Double ?? 2
            var message = ""
            do {
                try await poll(timeout: timeout, what: "assertion") {
                    let (ok, detail) = self.check(step)
                    message = detail
                    return ok
                }
            } catch {
                throw Failure("assertion failed: \(message)")
            }
            return message

        case "destination":
            // Switches the window's screen (terminal, inbox, hosts) as the sidebar rows do.
            let name = try string(step, "to")
            guard let destination = Destination(rawValue: name) else { throw Failure("unknown destination \(name)") }
            ActiveWindow.model?.destination = destination
            try await Task.sleep(for: .milliseconds(400))
            return name
        case "sleep":
            try await Task.sleep(for: .seconds(step["seconds"] as? Double ?? 1))
            return nil

        case "resize":
            setWindowSize(window, width: try double(step, "width"), height: try double(step, "height"))
            try? await Task.sleep(for: .milliseconds(100))
            return "\(window.frame.size)"

        case "resizeLoop":
            let sizes = (step["sizes"] as? [[Double]] ?? [[900, 600], [1200, 800]]).filter { $0.count == 2 }
            let count = step["count"] as? Int ?? 10
            let interval = step["intervalMs"] as? Int ?? 100
            for i in 0..<count {
                let size = sizes[i % sizes.count]
                setWindowSize(window, width: size[0], height: size[1])
                try? await Task.sleep(for: .milliseconds(interval))
            }
            return "\(count) resizes"

        case "click":
            let pane = try resolvePane(step)
            let point = pane.view.convert(CGPoint(x: pane.view.bounds.midX, y: pane.view.bounds.midY), to: nil)
            let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { DogfoodEvents.mouse($0, at: point, window: window) }
            await pump.sendMouse(events, window: window)
            try? await Task.sleep(for: .milliseconds(150))
            return nil

        case "selectText":
            return try await selectText(substitute(try string(step, "text")), pane: try resolvePane(step), window: window)

        case "scroll":
            let pane = try resolvePane(step)
            let lines = Int32(step["lines"] as? Int ?? -5)
            let point = pane.view.convert(CGPoint(x: pane.view.bounds.midX, y: pane.view.bounds.midY), to: nil)
            guard let event = DogfoodEvents.scroll(lines: lines, at: point, window: window) else { throw Failure("cannot make scroll event") }
            await pump.sendMouse([event], window: window)
            return "\(lines) lines"

        default:
            throw Failure("unknown step \"\(action)\"")
        }
    }

    private func check(_ step: [String: Any]) -> (Bool, String) {
        let tab = workspace.session.activeTab
        if let expected = step["panes"] as? Int {
            let count = tab?.root.panes.count ?? 0
            return (count == expected, "panes in tab = \(count), expected \(expected)")
        }
        if let expected = step["tabs"] as? Int {
            let count = workspace.session.tabs.count
            return (count == expected, "tabs = \(count), expected \(expected)")
        }
        if let label = step["focusIs"] as? String {
            return (workspace.focusedPane == rememberedFocus[label], "focused \(workspace.focusedPane?.description ?? "nil"), \(label) = \(rememberedFocus[label]?.description ?? "nil")")
        }
        if let label = step["focusIsNot"] as? String {
            return (workspace.focusedPane != rememberedFocus[label], "focused \(workspace.focusedPane?.description ?? "nil"), \(label) = \(rememberedFocus[label]?.description ?? "nil")")
        }
        if let index = step["focusIndex"] as? Int {
            let actual = tab.flatMap { $0.root.panes.firstIndex(of: $0.focused) }
            return (actual == index, "focused index \(actual.map(String.init) ?? "nil"), expected \(index)")
        }
        if let title = step["tabTitle"] as? String {
            let actual = tab.map(workspace.title(of:)) ?? ""
            return (actual == title, "tab title \"\(actual)\", expected \"\(title)\"")
        }
        if let context = step["tabContext"] as? String {
            let actual = tab.flatMap(workspace.context(of:)) ?? ""
            let name = tab.map(workspace.title(of:)) ?? ""
            return (actual == context && name != context, "tab \"\(name)\" context \"\(actual)\", expected context \"\(context)\"")
        }
        if let text = step["pasteboard"] as? String {
            let actual = NSPasteboard.general.string(forType: .string) ?? "<none>"
            return (actual == text, "pasteboard \"\(actual)\", expected \"\(text)\"")
        }
        if let first = step["firstResponderIsFocusedPane"] as? Bool {
            let pane = workspace.focusedPane.flatMap { workspace.panes[$0] }
            let actual = pane.map { $0.view.window?.firstResponder === $0.view } ?? false
            return (actual == first, "first responder is focused pane: \(actual)")
        }
        if step["detailFillsWindow"] as? Bool == true {
            // Whatever the screen shows, the detail column runs from the sidebar to the window's
            // right edge (an empty Inbox once shrank and centred the whole window).
            guard let window, let content = window.contentView, let frame = ActiveWindow.model?.detailFrame else {
                return (false, "no window or detail frame")
            }
            let sidebar = UserDefaults.standard.bool(forKey: "sidebarShown") || UserDefaults.standard.object(forKey: "sidebarShown") == nil
            let width = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 248
            let leading = sidebar ? width + 1 : 0
            let ok = abs(frame.maxX - content.bounds.width) <= 2 && frame.minX <= leading + 2
            return (ok, "detail \(frame), window \(content.bounds.size), sidebar \(sidebar ? "\(width)" : "hidden")")
        }
        let pane = focusedPaneOrNil
        if step["ptySizeMatchesGrid"] as? Bool == true {
            // The kernel's window size on the PTY (what the shell's SIGWINCH reads) vs the grid
            // the view laid out.
            guard let pane, let pty = (SharedPaneBackend.underlying(pane.backend) as? LocalPTYBackend)?.pty, let grid = pane.view.surface.grid else {
                let view = pane?.view
                return (false, "no pty or grid (view in window: \(view?.window != nil), superview: \(view?.superview.map { "\(type(of: $0))" } ?? "nil"), hosts: \(pane?.hosts.allObjects.map { "window=\($0.window != nil) size=\($0.bounds.size)" } ?? []), size \(view?.bounds.size ?? .zero))")
            }
            var size = winsize()
            guard ioctl(pty.fd, TIOCGWINSZ, &size) == 0 else { return (false, "TIOCGWINSZ failed") }
            let terminal = pane.view.surface.terminal.size
            return (size.ws_col == grid.cols && size.ws_row == grid.rows && terminal.cols == Int(grid.cols) && terminal.rows == Int(grid.rows),
                    "pty \(size.ws_col)x\(size.ws_row), grid \(grid.cols)x\(grid.rows), terminal \(terminal.cols)x\(terminal.rows)")
        }
        let modes = pane?.view.surface.terminal.modes
        if let expected = step["bracketedPaste"] as? Bool {
            return (modes?.bracketedPaste == expected, "bracketed paste \(modes?.bracketedPaste.description ?? "nil")")
        }
        if let expected = step["altScreen"] as? Bool {
            return (modes?.altScreen == expected, "alt screen \(modes?.altScreen.description ?? "nil")")
        }
        return (false, "unknown assertion \(step)")
    }

    // MARK: Helpers

    private var focusedPaneOrNil: Pane? { workspace.focusedPane.flatMap { workspace.panes[$0] } }

    private func resolvePane(_ step: [String: Any]) throws -> Pane {
        if let index = step["pane"] as? Int {
            guard let tab = workspace.session.activeTab, tab.root.panes.indices.contains(index),
                  let pane = workspace.panes[tab.root.panes[index]] else { throw Failure("no pane \(index) in the active tab") }
            return pane
        }
        guard let pane = focusedPaneOrNil else { throw Failure("no focused pane") }
        return pane
    }

    private func shellPid(_ pane: Pane) -> Int32? {
        (SharedPaneBackend.underlying(pane.backend) as? LocalPTYBackend)?.pty.pid
    }

    private func string(_ step: [String: Any], _ key: String) throws -> String {
        guard let value = step[key] as? String else { throw Failure("step needs \"\(key)\"") }
        return value
    }

    private func double(_ step: [String: Any], _ key: String) throws -> Double {
        guard let value = step[key] as? Double else { throw Failure("step needs \"\(key)\"") }
        return value
    }

    private func substitute(_ text: String) -> String {
        text.replacingOccurrences(of: "${OUT}", with: outDir.path)
    }

    private struct Matcher {
        var description: String
        var test: (String) -> Bool
        func callAsFunction(_ s: String) -> Bool { test(s) }
    }

    private func textMatcher(_ step: [String: Any]) throws -> Matcher {
        if let text = step["text"] as? String {
            let text = substitute(text)
            return Matcher(description: "\"\(text)\"") { $0.contains(text) }
        }
        if let pattern = step["regex"] as? String {
            let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            return Matcher(description: "/\(pattern)/") { s in
                regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
        }
        throw Failure("waitText needs \"text\" or \"regex\"")
    }

    private func poll(timeout: Double, what: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if condition() { return }
            if ProcessInfo.processInfo.systemUptime > deadline { throw Failure("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func waitIdle(pane: Pane?, quiet: Double, timeout: Double) async throws {
        guard let pane else { throw Failure("no pane") }
        var last = ""
        var stableSince = ProcessInfo.processInfo.systemUptime
        try await poll(timeout: timeout, what: "a quiet, non-empty screen") {
            let now = ProcessInfo.processInfo.systemUptime
            let text = pane.view.surface.terminal.visibleText()
            if text != last {
                last = text
                stableSince = now
                return false
            }
            return !text.isEmpty && now - stableSince >= quiet
        }
    }

    /// Posts one keystroke and returns the ms until the screen changed and the next frame rendered.
    private func measureEcho(pane: Pane, key: DogfoodEvents.Key, window: NSWindow) async throws -> (echo: Double, frame: Double?) {
        let terminal = pane.view.surface.terminal
        // The cursor moves even when the echo only replaces an autosuggestion (same text).
        func screen() -> String { "\(terminal.cursorPosition.x),\(terminal.cursorPosition.y)|" + terminal.visibleText() }
        let before = screen()
        let t0 = ProcessInfo.processInfo.systemUptime
        await pump.post(DogfoodEvents.keyEvents(key, window: window), window: window)
        let deadline = t0 + 2
        while screen() == before {
            if ProcessInfo.processInfo.systemUptime > deadline { throw Failure("no echo for \"\(key.characters)\" within 2 s; screen tail:\n\(tail(pane))") }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let echo = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        let rendered = await nextFrame(pane.view.surface)
        return (echo, rendered ? (ProcessInfo.processInfo.systemUptime - t0) * 1000 : nil)
    }

    /// Waits for the surface's next rendered frame; false if none came within 150 ms.
    private func nextFrame(_ surface: TerminalSurface) async -> Bool {
        let previous = surface.onFrameRendered
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let resume = { (rendered: Bool) in
                guard !resumed else { return }
                resumed = true
                surface.onFrameRendered = previous
                continuation.resume(returning: rendered)
            }
            surface.onFrameRendered = {
                previous?()
                resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                resume(false)
            }
        }
    }

    /// Drags the mouse over the last on-screen occurrence of `text`, as a user selecting it would.
    private func selectText(_ text: String, pane: Pane, window: NSWindow) async throws -> String {
        let lines = pane.view.surface.terminal.visibleText().components(separatedBy: "\n")
        guard let row = lines.lastIndex(where: { $0.contains(text) }),
              let range = lines[row].range(of: text, options: .backwards) else { throw Failure("\"\(text)\" not on screen") }
        let column = lines[row].distance(from: lines[row].startIndex, to: range.lowerBound)
        let surface = pane.view.surface
        let first = surface.rect(for: GridPoint(x: column, y: row))
        let last = surface.rect(for: GridPoint(x: column + text.count - 1, y: row))
        let start = CGPoint(x: first.minX + 1, y: first.midY)
        let end = CGPoint(x: last.maxX - 1, y: last.midY)
        func windowPoint(_ p: CGPoint) -> CGPoint { pane.view.convert(p, to: nil) }
        // The view AppKit's hit test (as in `NSWindow.sendEvent`) gives the press to.
        if let root = window.contentView?.superview, let hit = root.hitTest(root.convert(windowPoint(start), from: nil)), hit !== pane.view {
            throw Failure("a press on \"\(text)\" at window \(windowPoint(start)) hits \(type(of: hit)) (frame \(hit.convert(hit.bounds, to: nil))), not the terminal (frame \(pane.view.convert(pane.view.bounds, to: nil)))")
        }
        var events: [NSEvent] = []
        if let down = DogfoodEvents.mouse(.leftMouseDown, at: windowPoint(start), window: window) { events.append(down) }
        for i in 1...8 {
            let t = CGFloat(i) / 8
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
            if let drag = DogfoodEvents.mouse(.leftMouseDragged, at: windowPoint(p), window: window) { events.append(drag) }
        }
        if let up = DogfoodEvents.mouse(.leftMouseUp, at: windowPoint(end), window: window) { events.append(up) }
        await pump.sendMouse(events, window: window)
        let selected = pane.view.surface.terminal.selectionText() ?? "<none>"
        guard selected == text else {
            let selection = pane.view.surface.terminal.selection
            throw Failure(
                "selection is \"\(selected)\", expected \"\(text)\" (row \(row), col \(column); pressed at \(start) = cell \(surface.cell(at: start)), "
                    + "released at \(end) = cell \(surface.cell(at: end)); selection \(selection.map { "\($0.start)…\($0.end)" } ?? "nil"); "
                    + "cell \(surface.cellSize ?? .zero), padding \(surface.paddingPoints))")
        }
        return "row \(row) col \(column)"
    }

    private func setWindowSize(_ window: NSWindow, width: Double, height: Double) {
        var frame = window.frame
        let top = frame.maxY
        frame.size = CGSize(width: width, height: height)
        frame.origin.y = top - height
        window.setFrame(frame, display: true)
    }

    private func screenshot(named name: String) -> URL? {
        guard let window, let result = DogfoodScreenshot.capture(window: window, panes: Array(workspace.panes.values)) else { return nil }
        let url = outDir.appendingPathComponent("\(name).png")
        return DogfoodScreenshot.writePNG(result.image, to: url) ? url : nil
    }

    private func tail(_ pane: Pane) -> String {
        pane.view.surface.terminal.visibleText().components(separatedBy: "\n").suffix(8).joined(separator: "\n")
    }

    private func describe(_ processes: [DogfoodProcesses.Process]) -> String {
        processes.isEmpty ? "none" : processes.map { "\($0.name)(\($0.pid),\($0.state))" }.joined(separator: " ")
    }

    private func slug(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}
#endif
