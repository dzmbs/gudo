import DesignSystem
import Foundation
import HostKit
import ImageIO
import PaneLayout
import WebKit

/// Runs agents' browser tools (`browser_*`, `crates/hostd/src/browser_tools.rs`) on the page
/// beside the agent's pane, the one the user sees: a browser leaf in the pane's tab, opened by
/// the first `browser_navigate`. Steps that are the user's (sign-ins, payments, purchases) wait
/// for them on the device; the user can take the page over at any time.
@MainActor
final class BrowserAgent {
    static let shared = BrowserAgent()

    /// Calls in flight, by id (a closed call is cancelled).
    private var calls: [UInt64: Task<Void, Never>] = [:]
    /// The page each agent's pane acts on, once it switched tabs.
    private var active: [HostPane: UUID] = [:]

    /// One action an agent took on a page, reported after it ran (recordings build on these).
    struct ActionRecord {
        /// The tool (`browser_click`, …) and its arguments.
        var tool: String
        var args: [String: Any]
        /// The element acted on: its ref, role, accessible name and index among elements with
        /// both, and a Playwright locator for it (`getByRole('button', { name: 'Go' })`).
        var ref: String?
        var role: String?
        var name: String?
        var nth: Int?
        var locator: String?
        var urlBefore: URL?
        var urlAfter: URL?
        var at: Date
        /// What came of it: "done", what changed, or why nothing did.
        var verdict: String
        /// The agent's pane and the page (`BrowserMember.id`).
        var pane: HostPane
        var page: UUID
    }

    /// Called after each action on a page, on the main actor.
    var onAction: ((ActionRecord, BrowserPane) -> Void)?

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
        switch tool {
        case "browser_snapshot":
            return Answer(text: try await js(page, "return window.__un.snapshot(args)", args))
        case "browser_find":
            return Answer(text: try await js(page, "return window.__un.find(args.query)", args))
        case "browser_get_text":
            return Answer(text: try await js(page, "return window.__un.text()", args))
        case "browser_click", "browser_double_click", "browser_hover", "browser_type", "browser_fill",
             "browser_press", "browser_scroll", "browser_scroll_to":
            return try await act(tool, args, page: page, member: member, pane: pane, window: window)
        case "browser_wait":
            return try await wait(args, page: page)
        case "browser_screenshot":
            return try await screenshot(page, annotate: args["annotate"] as? Bool ?? false)
        case "browser_zoom":
            return try await zoom(page, region: (args["region"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [])
        case "browser_console":
            let entries: [[String: Any]] = try await recorded(page, "console")
            let lines = entries.map { "[\($0["level"] as? String ?? "log")] \($0["text"] as? String ?? "")" }
            return Answer(text: lines.isEmpty ? "No console messages since the last read." : lines.joined(separator: "\n"))
        case "browser_network":
            let entries: [[String: Any]] = try await recorded(page, "network")
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

    private func navigate(_ text: String, pane: HostPane, window: WindowModel) async throws -> Answer {
        let existing = pages(beside: pane, in: window).first { $0.id == active[pane] } ?? pages(beside: pane, in: window).first
        if let existing, let page = await window.browsers.pane(for: existing, app: window.app) {
            if page.userHasControl { throw BrowserCallError("The user has taken over this page.") }
            page.start()
            await settle(page)
            switch text.lowercased() {
            case "back": if let item = page.page.backForwardList.backList.last { _ = page.page.load(item) }
            case "forward": if let item = page.page.backForwardList.forwardList.first { _ = page.page.load(item) }
            case "reload": _ = page.page.reload()
            default: page.load(try Self.url(text))
            }
            page.agentActivity = "Opening \(text)"
            let before = page.page.url
            await settle(page, navigating: true)
            defer { done(page) }
            reportNavigation(text, from: before, page: page, member: existing, pane: pane)
            return Answer(text: try await js(page, "return window.__un.snapshot(args)", ["full": true]))
        }
        let url = try Self.url(text)
        let member = window.openBrowser(url, beside: pane)
        active[pane] = member.id
        guard let page = await window.browsers.pane(for: member, app: window.app) else {
            throw BrowserCallError("The page could not be opened.")
        }
        page.agentActivity = "Opening \(url.host() ?? text)"
        page.start()
        await settle(page, navigating: true)
        defer { done(page) }
        reportNavigation(text, from: nil, page: page, member: member, pane: pane)
        return Answer(text: try await js(page, "return window.__un.snapshot(args)", ["full": true]))
    }

    private func reportNavigation(_ url: String, from before: URL?, page: BrowserPane, member: BrowserMember, pane: HostPane) {
        onAction?(ActionRecord(
            tool: "browser_navigate", args: ["url": url], urlBefore: before, urlAfter: page.page.url, at: .now,
            verdict: page.page.url == nil ? "did not load" : "done", pane: pane, page: member.id), page)
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
        let tabId: (BrowserMember) -> String = { String($0.id.uuidString.prefix(8)).lowercased() }
        let wanted = (args["tab_id"] as? String)?.lowercased()
        let target = members.first { tabId($0) == wanted }
        switch args["action"] as? String {
        case "new":
            let url = try (args["url"] as? String).map(Self.url) ?? URL(string: "about:blank")!
            let member = window.openBrowser(url, beside: pane)
            active[pane] = member.id
            if let page = await window.browsers.pane(for: member, app: window.app) {
                page.start()
                await settle(page, navigating: true)
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
            window.closeBrowser(target.id)
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
        let before = page.page.url
        var input = args
        input["kind"] = kind
        if var target = args["target"] as? [String: Any], target["type"] as? String == "coordinate" {
            // Screenshot pixels to the page's CSS pixels.
            for key in ["x", "y"] { target[key] = ((target[key] as? NSNumber)?.doubleValue ?? 0) / page.shotScale }
            input["target"] = target
        }
        page.agentActivity = Self.activity(kind, args)
        defer { done(page) }
        var result = try await act(page, input)
        var note = ""
        if let need = result["needsUser"] as? [String: Any] {
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
            } else {
                input["approved"] = true
                result = try await act(page, input)
            }
        }
        await settle(page, navigating: kind == "click" || kind == "press" || kind == "type")
        let target = result["target"] as? [String: Any]
        onAction?(ActionRecord(
            tool: tool, args: args, ref: (args["target"] as? [String: Any])?["ref"] as? String,
            role: target?["role"] as? String, name: target?["name"] as? String, nth: (target?["nth"] as? NSNumber)?.intValue,
            locator: target?["locator"] as? String, urlBefore: before, urlAfter: page.page.url, at: .now,
            verdict: result["verdict"] as? String ?? "done", pane: pane, page: member.id), page)
        let snapshot = try await js(page, "return window.__un.snapshot(args)", ["filter": "interactive"])
        return Answer(text: note + "Done.\n" + snapshot)
    }

    /// Highlights the target, waits a moment so the user sees it, then acts.
    private func act(_ page: BrowserPane, _ args: [String: Any]) async throws -> [String: Any] {
        var input = args
        input["phase"] = "show"
        let shown = try await js(page, "return window.__un.act(args)", input, as: [String: Any].self)
        guard shown["shown"] as? Bool == true else { return shown }
        if shown["hidden"] as? Bool != true { try? await Task.sleep(for: .milliseconds(350)) }
        input["phase"] = "do"
        return try await js(page, "return window.__un.act(args)", input, as: [String: Any].self)
    }

    private static func activity(_ kind: String, _ args: [String: Any]) -> String {
        switch kind {
        case "type", "fill": "Typing"
        case "press": "Pressing \(args["keys"] as? String ?? "keys")"
        case "scroll", "scroll_to": "Scrolling"
        case "hover": "Pointing"
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
                if (try? await js(page, "return window.__un.met(args)", args, as: Bool.self)) == true {
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
                if until == "network_idle", !page.page.isLoading,
                   let idle = try? await page.page.callJavaScript(
                       "const l = window.__unRecorder; return !l || (l.pending === 0 && Date.now() - l.lastActivity > 500)",
                       contentWorld: .page) as? Bool, idle {
                    met = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        let snapshot = try await js(page, "return window.__un.snapshot(args)", ["filter": "interactive"])
        return Answer(text: (met ? "Done waiting.\n" : "Still not there after \(Int(seconds)) s.\n") + snapshot)
    }

    // MARK: Pictures

    private struct Viewport: Decodable {
        var width: Double
        var height: Double
        var x: Double
        var y: Double
        var pageWidth: Double
        var pageHeight: Double
    }

    /// Screenshots at most this wide (pixels); wider viewports scale down.
    private static let maxShotWidth = 1280.0

    private func screenshot(_ page: BrowserPane, annotate: Bool) async throws -> Answer {
        if annotate { _ = try await js(page, "return window.__un.label(true)", [:], as: Int.self) }
        defer { if annotate { Task { _ = try? await self.js(page, "return window.__un.label(false)", [:], as: Int.self) } } }
        let view = try await viewport(page)
        let scale = min(1, Self.maxShotWidth / max(view.width, 1))
        page.shotScale = scale
        let region = CGRect(x: view.x, y: view.y, width: view.width, height: view.height)
        let image = try await picture(page, view, region: region, width: view.width * scale)
        return Answer(
            text: "Screenshot of the visible page, \(Int(view.width * scale))×\(Int(view.height * scale)) px; targets use these pixels."
                + (annotate ? " Red labels are refs (12 = ref_12)." : ""),
            image: image)
    }

    private func zoom(_ page: BrowserPane, region: [Double]) async throws -> Answer {
        guard region.count == 4, region[2] > region[0], region[3] > region[1] else {
            throw BrowserCallError("region is [x0, y0, x1, y1] with x1 > x0 and y1 > y0, in screenshot pixels.")
        }
        let view = try await viewport(page)
        let s = page.shotScale
        let rect = CGRect(x: view.x + region[0] / s, y: view.y + region[1] / s, width: (region[2] - region[0]) / s, height: (region[3] - region[1]) / s)
        let image = try await picture(page, view, region: rect, width: min(Self.maxShotWidth, rect.width * 2))
        return Answer(text: "Close-up of [\(region.map { String(Int($0)) }.joined(separator: ", "))].", image: image)
    }

    /// A region of the page (CSS pixels from the document's top left) as a JPEG `width` pixels
    /// wide: the whole page is drawn, then cut, so bars over the page never shift it.
    private func picture(_ page: BrowserPane, _ view: Viewport, region: CGRect, width: Double) async throws -> Data {
        let data = try await page.page.exported(as: .image(region: .contents, snapshotWidth: view.pageWidth))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let whole = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw BrowserCallError("The page could not be drawn.") }
        let ratio = Double(whole.width) / max(view.pageWidth, 1)
        let cut = CGRect(x: region.minX * ratio, y: region.minY * ratio, width: region.width * ratio, height: region.height * ratio)
            .integral.intersection(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
        guard let part = whole.cropping(to: cut) else { throw BrowserCallError("That region is off the page.") }
        let size = CGSize(width: width.rounded(), height: (width * cut.height / max(cut.width, 1)).rounded())
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw BrowserCallError("The page could not be drawn.") }
        context.interpolationQuality = .high
        context.draw(part, in: CGRect(origin: .zero, size: size))
        let out = NSMutableData()
        guard let scaled = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)
        else { throw BrowserCallError("The page could not be drawn.") }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BrowserCallError("The page could not be drawn.") }
        return out as Data
    }

    private func viewport(_ page: BrowserPane) async throws -> Viewport {
        let raw = try await js(page, "return window.__un.viewport()", [:], as: [String: Any].self)
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(Viewport.self, from: data)
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

    // MARK: Plumbing

    /// Lets the page react: a navigation an action started finishes (at most 10 s).
    private func settle(_ page: BrowserPane, navigating: Bool = false) async {
        try? await Task.sleep(for: .milliseconds(navigating ? 350 : 150))
        let deadline = ContinuousClock.now + .seconds(10)
        while page.page.isLoading, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func js(_ page: BrowserPane, _ body: String, _ args: [String: Any]) async throws -> String {
        try await js(page, body, args, as: String.self)
    }

    private func js<T>(_ page: BrowserPane, _ body: String, _ args: [String: Any], as: T.Type) async throws -> T {
        do {
            // Before the agent's script is in (a page still loading, about:blank): wait a moment.
            for attempt in 0..<20 {
                let ready = try await page.page.callJavaScript("return !!window.__un", contentWorld: BrowserAgentScript.world) as? Bool ?? false
                if ready { break }
                if page.page.url == nil || page.page.url?.scheme == "about" {
                    throw BrowserCallError("The page is empty: call browser_navigate with a URL.")
                }
                if attempt == 19 { throw BrowserCallError("The page did not finish loading.") }
                try await Task.sleep(for: .milliseconds(250))
            }
            let value = try await page.page.callJavaScript(body, arguments: ["args": args], contentWorld: BrowserAgentScript.world)
            guard let value = value as? T else { throw BrowserCallError("The page answered nothing.") }
            return value
        } catch let error as BrowserCallError {
            throw error
        } catch {
            throw BrowserCallError(Self.describe(error))
        }
    }

    private func recorded<T>(_ page: BrowserPane, _ list: String) async throws -> [T] {
        let value = try await page.page.callJavaScript(
            "const l = window.__unRecorder; return l ? l[name].splice(0) : []", arguments: ["name": list], contentWorld: .page)
        return value as? [T] ?? []
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
