import Foundation
import ImageIO
import WebKit

/// A page as agents' browser tools use it.
@MainActor
extension BrowserPane {
    // MARK: Calling the page

    func js(_ body: String, _ args: [String: Any], frame: String? = nil) async throws -> String {
        try await js(body, args, frame: frame, as: String.self)
    }

    /// Runs `body` in the agent's content world of the main frame, or of the frame with token `frame`.
    func js<T>(_ body: String, _ args: [String: Any], frame: String? = nil, as: T.Type) async throws -> T {
        do {
            let value: Any?
            if let frame, frame != frames.main {
                guard let info = frames.frame(frame), let webView = frames.webView else {
                    throw BrowserCallError("That frame is gone: snapshot again.")
                }
                value = try await webView.callAsyncJavaScript(body, arguments: ["args": args], in: info, contentWorld: BrowserAgentScript.world)
            } else {
                try await ready()
                value = try await page.run(body, arguments: ["args": args], in: BrowserAgentScript.world)
            }
            guard let value = value as? T else { throw BrowserCallError("The page answered nothing.") }
            return value
        } catch let error as BrowserCallError {
            throw error
        } catch {
            throw BrowserCallError(BrowserAgent.describe(error))
        }
    }

    /// Waits a moment for the agent's script to be injected.
    private func ready() async throws {
        for attempt in 0..<20 {
            let ready = try await page.run("return !!window.__un", in: BrowserAgentScript.world) as? Bool ?? false
            if ready { return }
            if page.url == nil || page.url?.scheme == "about" {
                throw BrowserCallError("The page is empty: call browser_navigate with a URL.")
            }
            if attempt == 19 { throw BrowserCallError("The page did not finish loading.") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Nil when a dialog or file picker comes up first: they hold the page's scripts, so
    /// `operation` would not finish until they are answered.
    func untilBlocked<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        let race = Race<T>()
        Task { @MainActor in
            do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
        }
        let watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if self?.dialog != nil || self?.fileChooser != nil { race.finish(.success(nil)); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { watch.cancel() }
        return try await race.value()
    }

    func recorded<T>(_ list: String) async throws -> [T] {
        let value = try await page.run(
            "const l = window.__gudoRecorder; return l ? l[name].splice(0) : []", arguments: ["name": list], in: .page)
        return value as? [T] ?? []
    }

    // MARK: Snapshots and refs

    /// Child frames are inlined under their iframe, with refs `ref_f<frame>_<n>`.
    func snapshot(_ args: [String: Any]) async throws -> String {
        try await snapshot(args, frame: nil, depth: 0)
    }

    private func snapshot(_ args: [String: Any], frame: String?, depth: Int) async throws -> String {
        var input = args
        if frame != nil { input["frame"] = true }
        var text = try await js("return window.__un.snapshot(args)", input, frame: frame)
        if let frame { text = text.replacingOccurrences(of: "[ref_", with: "[ref_f\(frames.number(of: frame))_") }
        let marker = /\s?⟦frame (\w+)⟧/
        let tokens = text.matches(of: marker).map { String($0.output.1) }
        guard !tokens.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        for token in tokens where depth < 3 {
            // A delta lists every frame on a `= iframe …` line, so its changes have a place.
            guard let index = lines.firstIndex(where: { $0.contains("⟦frame \(token)⟧") && !$0.hasPrefix("- ") }) else { continue }
            let frameNumber = frames.number(of: token)
            let child: String
            do {
                child = try await snapshot(args, frame: token, depth: depth + 1)
            } catch {
                lines[index] += " (frame f\(frameNumber) has not loaded)"
                continue
            }
            if child.hasPrefix("No change since") || child.isEmpty {
                if lines[index].hasPrefix("= ") { lines[index] = "" }
                continue
            }
            let line = lines[index]
            let own = ["+ ", "* ", "= "].contains(where: line.hasPrefix) ? line.dropFirst(2) : Substring(line)
            let indent = String(repeating: " ", count: own.prefix { $0 == " " }.count + 2)
            let body = child.components(separatedBy: "\n").filter { !$0.isEmpty }.map { indent + "  " + $0 }
            lines.insert(contentsOf: [indent + "frame f\(frameNumber):"] + body, at: index + 1)
        }
        return lines.filter { !$0.isEmpty }.map { $0.replacing(marker, with: "") }.joined(separator: "\n")
    }

    func find(_ query: String) async throws -> String {
        let text = try await snapshot(["filter": "all", "full": true, "depth": 64])
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        let interactive: Set<Substring> = ["link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "slider",
                                           "spinbutton", "switch", "tab", "menuitem", "option", "listbox", "treeitem"]
        let scored = text.components(separatedBy: "\n").compactMap { line -> (Double, String)? in
            guard line.contains("[ref_") else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let haystack = trimmed.lowercased()
            let role = trimmed.split(separator: " ").first ?? ""
            let score = Double(words.filter { haystack.contains($0) }.count) + (interactive.contains(role) ? 0.5 : 0)
            return score >= 1 ? (score, trimmed) : nil
        }
        let best = scored.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .prefix(20).map(\.element.1)
        return best.isEmpty ? "Nothing on the page matches “\(query)”." : best.joined(separator: "\n")
    }

    /// The target's frame (nil for the main one) and the target as that frame knows it.
    func locate(_ target: [String: Any]?) async throws -> (target: [String: Any]?, frame: String?) {
        guard var target else { return (nil, nil) }
        if target["type"] as? String == "coordinate" {
            var x = ((target["x"] as? NSNumber)?.doubleValue ?? 0) / shotScale
            var y = ((target["y"] as? NSNumber)?.doubleValue ?? 0) / shotScale
            var frame: String?
            for _ in 0..<3 {
                guard let inner = try? await js("return window.__un.frameAt(args.x, args.y)", ["x": x, "y": y], frame: frame, as: [String: Any].self),
                      let token = inner["token"] as? String
                else { break }
                frame = token
                x = (inner["x"] as? NSNumber)?.doubleValue ?? x
                y = (inner["y"] as? NSNumber)?.doubleValue ?? y
            }
            target["x"] = x
            target["y"] = y
            return (target, frame)
        }
        guard let ref = target["ref"] as? String else { throw BrowserCallError("target needs a ref, or x and y.") }
        guard let match = ref.wholeMatch(of: /ref_f(\d+)_(\d+)/) else { return (target, nil) }
        guard let token = frames.token(of: Int(match.output.1) ?? 0) else {
            throw BrowserCallError("\(ref) is stale or not found on the current page. Re-read the page with browser_snapshot to get fresh references.")
        }
        target["ref"] = "ref_\(match.output.2)"
        return (target, token)
    }

    func label(_ on: Bool) async {
        _ = try? await js("return window.__un.label(args.on, '')", ["on": on], as: Int.self)
        for token in frames.tokens where token != frames.main {
            _ = try? await js("return window.__un.label(args.on, args.prefix)", ["on": on, "prefix": "f\(frames.number(of: token))_"], frame: token, as: Int.self)
        }
    }

    // MARK: Waiting

    struct Activity {
        var url: URL?
        var started: Int
    }

    func activity() async -> Activity {
        let started = try? await page.run("const l = window.__gudoRecorder; return l ? l.started : 0", in: .page) as? Int
        return Activity(url: page.url, started: started ?? 0)
    }

    /// Waits for a navigation, else the requests the action made, then for the DOM to be quiet for 100 ms.
    func settle(after before: Activity) async {
        try? await Task.sleep(for: .milliseconds(60))
        guard dialog == nil, fileChooser == nil else { return }
        var busy = false
        if page.isLoading || page.url != before.url {
            busy = true
            await settleNavigation()
        } else if await activity().started > before.started {
            busy = true
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline, !Task.isCancelled, dialog == nil, !(await networkIdle(quiet: 0)) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if busy { try? await Task.sleep(for: .milliseconds(500)) }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, !Task.isCancelled, dialog == nil, fileChooser == nil {
            let quiet = (try? await page.run("return window.__un ? window.__un.quiet() : 1000", in: BrowserAgentScript.world) as? Int) ?? 1000
            if quiet >= 100 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func settleNavigation() async {
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = ContinuousClock.now + .seconds(10)
        while page.isLoading, ContinuousClock.now < deadline, !Task.isCancelled, dialog == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// No fetch or XHR in flight for `quiet` ms.
    func networkIdle(quiet: Int = 500) async -> Bool {
        let idle = try? await page.run(
            "const l = window.__gudoRecorder; return !l || (l.pending === 0 && Date.now() - l.lastActivity >= q)",
            arguments: ["q": quiet], in: .page) as? Bool
        return idle ?? true
    }

    // MARK: Pictures

    struct Viewport: Decodable {
        var width: Double
        var height: Double
        var x: Double
        var y: Double
        var pageWidth: Double
        var pageHeight: Double
    }

    static let maxShotWidth = 1280.0

    func viewport() async throws -> Viewport {
        let raw = try await js("return window.__un.viewport()", [:], as: [String: Any].self)
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(Viewport.self, from: data)
    }

    /// A region in document CSS pixels as a JPEG. The whole page is drawn, then cut, so bars over
    /// the page never shift it.
    func picture(_ view: Viewport, region: CGRect, width: Double) async throws -> Data {
        let data = try await page.picture(nil, width: view.pageWidth)
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
        let jpeg = NSMutableData()
        guard let scaled = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)
        else { throw BrowserCallError("The page could not be drawn.") }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BrowserCallError("The page could not be drawn.") }
        return jpeg as Data
    }
}

/// The first of several results to arrive.
@MainActor
private final class Race<T> {
    private var result: Result<T?, any Error>?
    private var waiter: CheckedContinuation<T?, any Error>?

    func finish(_ value: Result<T?, any Error>) {
        guard result == nil else { return }
        result = value
        // Both ends are on the main actor.
        nonisolated(unsafe) let value = value
        waiter?.resume(with: value)
        waiter = nil
    }

    func value() async throws -> T? {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}
