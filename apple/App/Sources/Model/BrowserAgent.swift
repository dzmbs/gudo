import DesignSystem
import Foundation
import HostKit
import PaneLayout
import WebKit

/// One action an agent took on a page, reported after it ran (`BrowserAgent.onAction`);
/// recordings build on these.
struct BrowserActionEntry {
    /// The tool (`browser_click`, …).
    var tool: String
    /// The element acted on: its ref, role, accessible name and index among the elements with
    /// both, as the agent's last snapshot showed it.
    var ref: String?
    var role: String?
    var name: String?
    var nth: Int?
    /// The tool's arguments, as JSON.
    var args: String
    var urlBefore: URL?
    var urlAfter: URL?
    var time: Date
    /// What came of it: "done", what changed, or why nothing did.
    var verdict: String
    /// Playwright's selector for the element (`internal:role=button[name="Go"i]`), taken
    /// before the action, and the locator it makes (`getByRole('button', { name: 'Go' })`).
    var selector: String?
    var locator: String?
    /// The page (`BrowserPane.id`) and the agent's pane.
    var page: UUID
    var pane: HostPane

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs agents' browser tools (`browser_*`, `crates/hostd/src/browser_tools.rs`) on the page
/// beside the agent's pane, the one the user sees: a browser leaf in the pane's tab, opened by
/// the first `browser_navigate`. Steps that are the user's (sign-ins, payments, purchases) wait
/// for them on the device; the user can take the page over at any time.
///
/// Every action waits for what it started (a navigation, requests, the DOM settling), then says
/// what changed; one that changed nothing is retried once as a plain `click()`, and then
/// reported as having no effect, with why it may have been ignored.
@MainActor
final class BrowserAgent {
    static let shared = BrowserAgent()

    /// Calls in flight, by id (a closed call is cancelled).
    private var calls: [UInt64: Task<Void, Never>] = [:]
    /// The page each agent's pane acts on, once it switched tabs.
    private var active: [HostPane: UUID] = [:]
    /// Tab numbers (`t1`, `t2`, …), never reused.
    private var tabNumbers: [UUID: Int] = [:]
    private var nextTab = 1

    /// Called after each action an agent takes on a page, on the main actor.
    var onAction: ((BrowserActionEntry) -> Void)?

    /// One answer: text, and an image for screenshots.
    struct Answer {
        var text: String
        var image: Data?
        var mime = "image/jpeg"
        /// A step to put to the agent's client for approval (it asks, then calls again approved).
        var approval: String?

        var json: String {
            var object: [String: Any] = ["text": text]
            if let approval { object["approval"] = ["message": approval] }
            if let image { object["image"] = ["data": image.base64EncodedString(), "mimeType": mime] }
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    func run(
        _ id: UInt64, tool: String, args: String, pane: HostPane, app: AppModel,
        reply: @escaping (Result<String, BrowserCallError>) -> Void
    ) {
        let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        calls[id] = Task { [weak self] in
            defer { self?.calls[id] = nil }
            do {
                guard let window = app.window(forHost: pane.hostId) else {
                    throw BrowserCallError("The app shows no window with this host.")
                }
                let answer = try await self?.perform(tool, input, pane: pane, window: window)
                guard !Task.isCancelled else { return }
                reply(.success(answer?.json ?? "{}"))
            } catch let error as BrowserCallError {
                reply(.failure(error))
            } catch {
                reply(.failure(BrowserCallError(Self.describe(error))))
            }
        }
    }

    func cancel(_ id: UInt64) {
        calls.removeValue(forKey: id)?.cancel()
    }

    // MARK: Tools

    private func perform(_ tool: String, _ args: [String: Any], pane: HostPane, window: WindowModel) async throws -> Answer {
        switch tool {
        case "browser_navigate":
            return try await navigate(args["url"] as? String ?? "", pane: pane, window: window)
        case "browser_tabs":
            return try await tabs(args, pane: pane, window: window)
        default:
            break
        }
        let (member, page) = try await self.page(for: pane, in: window)
        // A dialog stops the page's scripts until it is answered.
        if let dialog = page.dialog, tool != "browser_dialog" {
            throw BrowserCallError(Self.dialogNote(dialog))
        }
        switch tool {
        case "browser_snapshot":
            return Answer(text: try await page.snapshot(args))
        case "browser_find":
            return Answer(text: try await page.find(args["query"] as? String ?? ""))
        case "browser_get_text":
            return Answer(text: try await page.js("return window.__un.text()", [:]))
        case "browser_click", "browser_double_click", "browser_hover", "browser_type", "browser_fill",
             "browser_press", "browser_scroll", "browser_scroll_to", "browser_upload", "browser_drag":
            return try await act(tool, args, page: page, member: member, pane: pane, window: window)
        case "browser_dialog":
            return try await answerDialog(args, page: page)
        case "browser_wait":
            return try await wait(args, page: page)
        case "browser_screenshot":
            return try await screenshot(page, annotate: args["annotate"] as? Bool ?? false)
        case "browser_zoom":
            return try await zoom(page, region: (args["region"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [])
        case "browser_console":
            let entries: [[String: Any]] = try await page.recorded("console")
            let lines = entries.map { "[\($0["level"] as? String ?? "log")] \($0["text"] as? String ?? "")" }
            return Answer(text: lines.isEmpty ? "No console messages since the last read." : lines.joined(separator: "\n"))
        case "browser_network":
            let entries: [[String: Any]] = try await page.recorded("network")
            let lines = entries.map { entry in
                let status = (entry["status"] as? NSNumber)?.intValue ?? 0
                let ms = (entry["ms"] as? NSNumber)?.intValue ?? 0
                return "\(entry["method"] as? String ?? "GET") \(status) \(entry["url"] as? String ?? "") (\(entry["type"] as? String ?? ""), \(ms) ms)"
            }
            return Answer(text: lines.isEmpty ? "No requests since the last read." : lines.joined(separator: "\n"))
        default:
            throw BrowserCallError("Unknown tool \(tool).")
        }
    }

    /// The page beside the agent's pane (the one it switched to, else the first).
    private func page(for pane: HostPane, in window: WindowModel) async throws -> (BrowserMember, BrowserPane) {
        let members = pages(beside: pane, in: window)
        guard let member = members.first(where: { $0.id == active[pane] }) ?? members.first else {
            throw BrowserCallError("No page is open beside this terminal: call browser_navigate first.")
        }
        guard let page = await window.browsers.pane(for: member, app: window.app) else {
            throw BrowserCallError("The page could not be opened.")
        }
        page.start()
        if page.userHasControl {
            throw BrowserCallError("The user has taken over this page. Wait, then try again once they hand it back, or ask them what they want.")
        }
        return (member, page)
    }

    private func pages(beside pane: HostPane, in window: WindowModel) -> [BrowserMember] {
        guard let tab = window.composites.tab(containing: pane) else { return [] }
        return tab.leaves.compactMap { tab.browsers[$0] }
    }

    private func tabId(_ member: BrowserMember) -> String {
        if let n = tabNumbers[member.id] { return "t\(n)" }
        tabNumbers[member.id] = nextTab
        nextTab += 1
        return "t\(nextTab - 1)"
    }

    private func navigate(_ text: String, pane: HostPane, window: WindowModel) async throws -> Answer {
        let existing = pages(beside: pane, in: window).first { $0.id == active[pane] } ?? pages(beside: pane, in: window).first
        if let existing, let page = await window.browsers.pane(for: existing, app: window.app) {
            if page.userHasControl { throw BrowserCallError("The user has taken over this page.") }
            page.dialog?.answer(false, nil)
            page.start()
            let before = page.page.url
            let url = ["back", "forward", "reload"].contains(text.lowercased()) ? nil : try Self.url(text)
            let go: @MainActor @Sendable () -> Void = { [weak page] in
                guard let page else { return }
                switch text.lowercased() {
                case "back": if let item = page.page.backForwardList.backList.last { _ = page.page.load(item) }
                case "forward": if let item = page.page.backForwardList.forwardList.first { _ = page.page.load(item) }
                case "reload": _ = page.page.reload()
                default: if let url { page.load(url) }
                }
            }
            if let note = await leave(page, then: go) { return Answer(text: note) }
            page.agentActivity = "Opening \(text)"
            defer { done(page) }
            await page.settleNavigation()
            reportNavigation(text, from: before, page: page, pane: pane)
            return Answer(text: try await page.snapshot(["full": true]))
        }
        let url = try Self.url(text)
        let member = window.openBrowser(url, beside: pane)
        active[pane] = member.id
        guard let page = await window.browsers.pane(for: member, app: window.app) else {
            throw BrowserCallError("The page could not be opened.")
        }
        page.agentActivity = "Opening \(url.host() ?? text)"
        page.start()
        defer { done(page) }
        await page.settleNavigation()
        reportNavigation(text, from: nil, page: page, pane: pane)
        return Answer(text: try await page.snapshot(["full": true]))
    }

    private func reportNavigation(_ url: String, from before: URL?, page: BrowserPane, pane: HostPane) {
        onAction?(BrowserActionEntry(
            tool: "browser_navigate", args: BrowserActionEntry.json(["url": url]), urlBefore: before, urlAfter: page.page.url,
            time: .now, verdict: page.page.url == nil ? "did not load" : "done", page: page.id, pane: pane))
    }

    /// An http(s) URL from what an agent wrote (`example.com`, `localhost:3000`).
    static func url(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let full: String
        if trimmed.contains("://") {
            full = trimmed
        } else if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.") || trimmed.hasPrefix("[::1]") {
            full = "http://" + trimmed
        } else {
            full = "https://" + trimmed
        }
        guard let url = URL(string: full), url.scheme == "http" || url.scheme == "https", url.host() != nil else {
            throw BrowserCallError("Only http and https URLs open: \(text)")
        }
        return url
    }

    private func tabs(_ args: [String: Any], pane: HostPane, window: WindowModel) async throws -> Answer {
        let members = pages(beside: pane, in: window)
        let current = members.first { $0.id == active[pane] }?.id ?? members.first?.id
        let wanted = (args["tab_id"] as? String)?.lowercased()
        let target = members.first { tabId($0) == wanted }
        switch args["action"] as? String {
        case "new":
            let url = try (args["url"] as? String).map(Self.url) ?? URL(string: "about:blank")!
            let member = window.openBrowser(url, beside: pane)
            active[pane] = member.id
            if let page = await window.browsers.pane(for: member, app: window.app) {
                page.start()
                await page.settleNavigation()
            }
            return Answer(text: "Opened tab \(tabId(member)).")
        case "switch":
            guard let target else { throw BrowserCallError("No tab \(wanted ?? "?"). Call browser_tabs with action list.") }
            active[pane] = target.id
            if let tab = window.composites.tab(containingBrowser: target.id), let leaf = tab.leaf(forBrowser: target.id) {
                window.focusLeaf(leaf, inMixedTab: tab.id)
            }
            return Answer(text: "Switched to tab \(tabId(target)).")
        case "close":
            guard let target else { throw BrowserCallError("No tab \(wanted ?? "?"). Call browser_tabs with action list.") }
            let id = target.id
            let close: @MainActor @Sendable () -> Void = { [weak window] in window?.closeBrowser(id) }
            if let page = window.browsers.existing(target.id), let note = await leave(page, then: close) {
                return Answer(text: note)
            }
            close()
            return Answer(text: "Closed tab \(tabId(target)).")
        default:
            if members.isEmpty { return Answer(text: "No pages are open beside this terminal.") }
            let lines = members.map { member in
                let title = window.browsers.existing(member.id)?.page.title ?? ""
                let url = window.browsers.existing(member.id)?.page.url?.absoluteString ?? member.url
                return "\(member.id == current ? "* " : "  ")\(tabId(member)) \(title.isEmpty ? "" : "\"\(title)\" ")\(url)"
            }
            return Answer(text: lines.joined(separator: "\n"))
        }
    }

    // MARK: Acting

    private func act(
        _ tool: String, _ args: [String: Any], page: BrowserPane, member: BrowserMember, pane: HostPane, window: WindowModel
    ) async throws -> Answer {
        let kind = String(tool.dropFirst("browser_".count))
        if kind == "upload", args["target"] == nil {
            return try await choose(args, page: page)
        }
        var input = args
        input["kind"] = kind
        if kind == "upload" { input["files"] = Self.payloads(args) }
        let target = try await page.locate(args["target"] as? [String: Any])
        input["target"] = target.target
        if kind == "drag" {
            let to = try await page.locate(args["to"] as? [String: Any])
            guard to.target != nil, to.frame == target.frame else { throw BrowserCallError("Drag needs a to target in the same frame as target.") }
            input["to"] = to.target
        }
        page.agentActivity = Self.activity(kind, args)
        defer { done(page) }

        let urlBefore = page.page.url
        let tabsBefore = Set(pages(beside: pane, in: window).map(\.id))
        var note = ""
        var result = try await act(page, input, frame: target.frame, wait: true)
        if let need = result.needsUser {
            let message = need["reason"] as? String ?? "The agent needs you."
            let handoff = need["kind"] as? String == "handoff"
            // The agent's client asks its user (MCP elicitation); typing secrets stays here.
            if !handoff, args["approval_by"] as? String == "client" {
                return Answer(text: "", approval: message)
            }
            bringForward(member, in: window)
            let ok = await ask(page, kind: handoff ? .handoff : .approve, message: message)
            guard ok else { throw BrowserCallError("The user declined: \(message)") }
            if handoff {
                note = "The user did this step on the device.\n"
                result = ActResult(done: [:], changes: ["the user acted"])
            } else {
                input["approved"] = true
                result = try await act(page, input, frame: target.frame, wait: true)
            }
        }

        // Nothing changed: once more as the element's own click(), which some sites need.
        var changes = result.changes
        if changes.isEmpty, kind == "click", target.frame != nil || args["target"].flatMap({ ($0 as? [String: Any])?["ref"] }) != nil,
           args["force"] as? Bool != true, page.dialog == nil {
            var again = input
            again["kind"] = "click_element"
            again["approved"] = true
            let retry = try await act(page, again, frame: target.frame, wait: true)
            if !retry.changes.isEmpty {
                changes = retry.changes
                note += "The click itself did nothing; the element's click() did.\n"
            }
        }
        let newTabs = pages(beside: pane, in: window).filter { !tabsBefore.contains($0.id) }
        changes += newTabs.map { "opened tab \(tabId($0)) (\($0.url))" }
        if page.dialog != nil { changes.append("opened a dialog") }
        if page.fileChooser != nil { changes.append("opened a file picker") }

        let verdict = changes.isEmpty ? Self.noEffect(kind, intercepted: result.intercepted) : "Done. Changed: " + changes.joined(separator: ", ") + "."
        let info = result.done["target"] as? [String: Any]
        onAction?(BrowserActionEntry(
            tool: tool, ref: (args["target"] as? [String: Any])?["ref"] as? String,
            role: info?["role"] as? String, name: info?["name"] as? String, nth: (info?["nth"] as? NSNumber)?.intValue,
            args: BrowserActionEntry.json(BrowserTools.own(args)), urlBefore: urlBefore, urlAfter: page.page.url, time: .now,
            verdict: verdict, selector: info?["selector"] as? String, locator: info?["locator"] as? String, page: page.id, pane: pane))

        if let healed = result.done["note"] as? String { note += healed + "\n" }
        if !newTabs.isEmpty { note += "browser_tabs with action switch moves to a new tab.\n" }
        if let dialog = page.dialog { return Answer(text: note + verdict + "\n" + Self.dialogNote(dialog)) }
        if page.fileChooser != nil {
            return Answer(text: note + verdict + "\nThe page waits for files: call browser_upload with paths and no target, or with cancel: true.")
        }
        let snapshot = try await page.snapshot(["filter": "interactive"])
        return Answer(text: note + verdict + "\n" + snapshot)
    }

    struct ActResult {
        var done: [String: Any]
        var changes: [String]
        var intercepted: String?
        var needsUser: [String: Any]? { done["needsUser"] as? [String: Any] }
    }

    /// Highlights the target, waits a moment so the user sees it, acts, waits for what the
    /// action started and asks the page what changed.
    private func act(_ page: BrowserPane, _ args: [String: Any], frame: String?, wait: Bool) async throws -> ActResult {
        var input = args
        input["phase"] = "show"
        let shown = try await page.js("return window.__un.act(args)", input, frame: frame, as: [String: Any].self)
        guard shown["shown"] as? Bool == true else { return ActResult(done: shown, changes: []) }
        if shown["hidden"] as? Bool != true { try? await Task.sleep(for: .milliseconds(350)) }
        input["phase"] = "do"
        let id = UUID().uuidString
        input["id"] = id
        // The Mac's own input when the page is on screen; the page script checks and lists the
        // events, the app sends them.
        let native = frame == nil && Self.nativeKinds.contains(input["kind"] as? String ?? "") ? await BrowserNativeInput.for(page.page) : nil
        if native != nil { input["native"] = true }
        let before = await page.activity()
        page.agentActing = true
        defer { page.agentActing = false }
        // A dialog or file picker the action opens holds the page's scripts: stop waiting then.
        let done = try await page.untilBlocked {
            try await page.js("return window.__un.act(args)", input, frame: frame, as: [String: Any].self)
        }
        guard let done else { return ActResult(done: [:], changes: []) }
        #if os(macOS)
        if let native, let ops = done["native"] as? [[String: Any]] { await native.perform(ops) }
        #endif
        if wait { await page.settle(after: before) }
        guard page.dialog == nil, page.fileChooser == nil else { return ActResult(done: done, changes: []) }
        let effect = (try? await page.js("return window.__un.effect(args.id)", ["id": id], frame: frame, as: [String: Any].self)) ?? [:]
        var changes = effect["changes"] as? [String] ?? []
        if page.page.url != before.url, !changes.contains("navigated") { changes.insert("navigated", at: 0) }
        return ActResult(done: done, changes: changes, intercepted: effect["intercepted"] as? String)
    }

    /// What goes through the Mac's own input (`BrowserNativeInput`) when it is there.
    static let nativeKinds: Set<String> = ["click", "double_click", "hover", "type", "press", "scroll", "drag", "fill"]

    /// Why an action may have done nothing, and what to try instead.
    static func noEffect(_ kind: String, intercepted: String?) -> String {
        switch kind {
        case "hover":
            #if os(macOS)
            return "Nothing changed on the page: nothing reacts to the pointer there, or the page's window is not in front. A click may open the menu."
            #else
            return "Nothing changed on the page. Hover effects made in CSS alone do not show for a script's pointer; a click may open the menu."
            #endif
        case "scroll", "scroll_to":
            return "Nothing scrolled: the page or element may be at its end, or not scrollable."
        default:
            var text = "No observable effect: no navigation, DOM, focus or value change."
            if let intercepted { text += " The point was covered by \(intercepted)." }
            return text + " The site may ignore synthetic input: try the keyboard (browser_press Enter or Space on the focused element), a coordinate target from browser_screenshot, or ask the user to tap it."
        }
    }

    /// Runs `go` (leaving the page) once the page lets it, now or after its leave check is
    /// answered: then the note saying the check waits.
    private func leave(_ page: BrowserPane, then go: @escaping @MainActor @Sendable () -> Void) async -> String? {
        let allowed = Task { await page.leavingAllowed() }
        guard let now = try? await page.untilBlocked({ await allowed.value }) else {
            Task { if await allowed.value { go() } }
            return page.dialog.map(Self.dialogNote) ?? "The page asks before it is left."
        }
        if now { go() }
        return nil
    }

    static func dialogNote(_ dialog: BrowserPane.PageDialog) -> String {
        if dialog.kind == .beforeunload {
            return "The page asks before it is left (unsaved changes): “\(dialog.message)”. Call browser_dialog with accept true to leave, or false to stay."
        }
        return "The page shows a\(dialog.kind == .alert ? "n" : "") \(dialog.kind.rawValue) dialog: “\(dialog.message)”"
            + (dialog.defaultText.map { " (default “\($0)”)" } ?? "")
            + ". It waits until it is answered: call browser_dialog with accept true or false"
            + (dialog.kind == .prompt ? " (and text to answer)." : ".")
    }

    private func answerDialog(_ args: [String: Any], page: BrowserPane) async throws -> Answer {
        guard let dialog = page.dialog else { throw BrowserCallError("No dialog is open on the page.") }
        let accept = args["accept"] as? Bool ?? true
        let before = await page.activity()
        dialog.answer(accept, args["text"] as? String)
        await page.settle(after: before)
        if let next = page.dialog { return Answer(text: "Answered. " + Self.dialogNote(next)) }
        return Answer(text: (accept ? "Accepted" : "Dismissed") + " the \(dialog.kind.rawValue).\n" + (try await page.snapshot(["filter": "interactive"])))
    }

    /// Files an action's file picker waits for (or none, to cancel it).
    private func choose(_ args: [String: Any], page: BrowserPane) async throws -> Answer {
        guard let chooser = page.fileChooser else {
            throw BrowserCallError("No file picker is open. Pass target (the file field, or the button or label that opens it).")
        }
        if args["cancel"] as? Bool == true {
            chooser.answer(nil)
            return Answer(text: "Cancelled the file picker.")
        }
        let files = Self.payloads(args)
        guard !files.isEmpty else { throw BrowserCallError("paths names no files.") }
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for file in files.prefix(chooser.multiple ? files.count : 1) {
            let url = dir.appending(path: (file["name"] as? String ?? "file").replacingOccurrences(of: "/", with: "_"))
            try Data(base64Encoded: file["buffer"] as? String ?? "")?.write(to: url)
            urls.append(url)
        }
        let before = await page.activity()
        chooser.answer(urls)
        await page.settle(after: before)
        return Answer(text: "Chose \(urls.map(\.lastPathComponent).joined(separator: ", ")).\n" + (try await page.snapshot(["filter": "interactive"])))
    }

    /// The files `browser_upload` carries (`files: [{name, mime_type, data}]`, read on the host)
    /// as Playwright's payloads.
    static func payloads(_ args: [String: Any]) -> [[String: Any]] {
        (args["files"] as? [[String: Any]] ?? []).map {
            ["name": $0["name"] as? String ?? "file", "mimeType": $0["mime_type"] as? String ?? "application/octet-stream",
             "buffer": $0["data"] as? String ?? ""]
        }
    }

    private static func activity(_ kind: String, _ args: [String: Any]) -> String {
        switch kind {
        case "type", "fill": "Typing"
        case "press": "Pressing \(args["keys"] as? String ?? "keys")"
        case "scroll", "scroll_to": "Scrolling"
        case "hover": "Pointing"
        case "upload": "Choosing files"
        case "drag": "Dragging"
        default: "Clicking"
        }
    }

    private func wait(_ args: [String: Any], page: BrowserPane) async throws -> Answer {
        let seconds = min(30, (args["seconds"] as? NSNumber)?.doubleValue ?? 10)
        var met = true
        if args["text"] != nil || args["selector"] != nil {
            let deadline = ContinuousClock.now + .seconds(seconds)
            met = false
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if (try? await page.js("return window.__un.met(args)", args, as: Bool.self)) == true {
                    met = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else if let until = args["until"] as? String {
            let deadline = ContinuousClock.now + .seconds(seconds)
            met = false
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if until == "load", !page.page.isLoading { met = true; break }
                if until == "network_idle", !page.page.isLoading, await page.networkIdle() { met = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        let snapshot = try await page.snapshot(["filter": "interactive"])
        return Answer(text: (met ? "Done waiting.\n" : "Still not there after \(Int(seconds)) s.\n") + snapshot)
    }

    // MARK: Pictures

    private func screenshot(_ page: BrowserPane, annotate: Bool) async throws -> Answer {
        if annotate { await page.label(true) }
        defer { if annotate { Task { await page.label(false) } } }
        let view = try await page.viewport()
        let scale = min(1, BrowserPane.maxShotWidth / max(view.width, 1))
        page.shotScale = scale
        let region = CGRect(x: view.x, y: view.y, width: view.width, height: view.height)
        let image = try await page.picture(view, region: region, width: view.width * scale)
        return Answer(
            text: "Screenshot of the visible page, \(Int(view.width * scale))×\(Int(view.height * scale)) px; targets use these pixels."
                + (annotate ? " Red labels are refs (12 = ref_12, f1_3 = ref_f1_3)." : ""),
            image: image)
    }

    private func zoom(_ page: BrowserPane, region: [Double]) async throws -> Answer {
        guard region.count == 4, region[2] > region[0], region[3] > region[1] else {
            throw BrowserCallError("region is [x0, y0, x1, y1] with x1 > x0 and y1 > y0, in screenshot pixels.")
        }
        let view = try await page.viewport()
        let s = page.shotScale
        let rect = CGRect(x: view.x + region[0] / s, y: view.y + region[1] / s, width: (region[2] - region[0]) / s, height: (region[3] - region[1]) / s)
        let image = try await page.picture(view, region: rect, width: min(BrowserPane.maxShotWidth, rect.width * 2))
        return Answer(text: "Close-up of [\(region.map { String(Int($0)) }.joined(separator: ", "))].", image: image)
    }

    // MARK: The user

    /// Waits for the user on the device: approve a step, or do it themselves.
    private func ask(_ page: BrowserPane, kind: BrowserPane.AgentRequest.Kind, message: String) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                page.agentRequest = BrowserPane.AgentRequest(kind: kind, message: message) { [weak page] ok in
                    page?.agentRequest = nil
                    continuation.resume(returning: ok)
                }
            }
        } onCancel: {
            Task { @MainActor in page.agentRequest?.answer(false) }
        }
    }

    private func bringForward(_ member: BrowserMember, in window: WindowModel) {
        guard let tab = window.composites.tab(containingBrowser: member.id), let leaf = tab.leaf(forBrowser: member.id) else { return }
        window.focusLeaf(leaf, inMixedTab: tab.id)
    }

    private func done(_ page: BrowserPane) {
        Task { [weak page] in
            try? await Task.sleep(for: .seconds(1.5))
            if page?.agentRequest == nil { page?.agentActivity = nil }
        }
    }

    /// A WebKit JavaScript error's own message (the page's exception), else the error.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        if let message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message.replacingOccurrences(of: "Error: ", with: "")
        }
        return ns.localizedDescription
    }
}

/// Arguments only the agent's tools set, kept out of what is recorded.
enum BrowserTools {
    static func own(_ args: [String: Any]) -> [String: Any] {
        var args = args
        for key in ["approved", "approval_by", "files"] { args.removeValue(forKey: key) }
        return args
    }
}
