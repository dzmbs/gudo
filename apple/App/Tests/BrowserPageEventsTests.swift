import Network
import WebKit
import XCTest
@testable import App

/// A page's frames, popups, dialogs and file inputs as agents meet them, on fixture pages
/// served from two local origins (`127.0.0.1` and `localhost` on one port).
@MainActor
final class BrowserPageEventsTests: XCTestCase {
    private var server: FixtureServer!

    override func setUp() async throws {
        server = try await FixtureServer(pages: [
            "/frames": """
            <!doctype html><title>Frames</title><h1>Top</h1><button>Top button</button>
            <iframe id="same" src="/same" style="width:300px;height:120px;border:4px solid #ccc"></iframe>
            <iframe id="cross" src="{B}/cross" style="width:300px;height:160px;border:0;margin-left:40px"></iframe>
            """,
            "/same": """
            <!doctype html><button onclick="this.textContent='Same clicked'">Same</button>
            """,
            "/cross": """
            <!doctype html><input id="q" placeholder="Cross field">
            <button id="go" style="margin:30px" onclick="this.textContent='Cross clicked'">Cross</button>
            <input id="f" type="file" multiple onchange="document.title=[...this.files].map(f=>f.name+':'+f.type+':'+f.size).join(',')">
            """,
            "/popups": """
            <!doctype html><title>Popups</title>
            <a href="/popped" target="_blank">New tab link</a>
            <button onclick="window.open('/opened')">Open window</button>
            """,
            "/popped": "<!doctype html><title>Popped</title><button onclick=\"window.close()\">Close me</button>",
            "/opened": "<!doctype html><title>Opened</title>",
            "/opener": """
            <!doctype html><title>Opener</title><p id="out"></p>
            <button onclick="window.open('/signin', 'signin', 'width=400,height=500')">Sign in with Example</button>
            <script>addEventListener('message', e => { out.textContent += (out.textContent ? ' ' : '') + e.data })</script>
            """,
            "/signin": """
            <!doctype html><title>Sign in</title>
            <button onclick="window.opener.postMessage('token-42', '*'); window.close()">Continue</button>
            <script>window.opener && window.opener.postMessage('ready', '*')</script>
            """,
            "/dialogs": """
            <!doctype html><title>Dialogs</title><p id="out"></p>
            <button id="alert" onclick="alert('Hello'); out.textContent='after alert'">Alert</button>
            <button id="confirm" onclick="out.textContent='confirm ' + confirm('Delete it?')">Confirm</button>
            <button id="prompt" onclick="out.textContent='prompt ' + prompt('Your name?', 'Ada')">Prompt</button>
            <input id="draft" placeholder="Draft" oninput="window.dirty = true">
            <script>addEventListener('beforeunload', e => { if (window.dirty) { e.preventDefault(); e.returnValue = ''; } })</script>
            """,
            "/upload": """
            <!doctype html><title>Upload</title><p id="out"></p>
            <input id="f" type="file" multiple onchange="out.textContent=[...this.files].map(f=>f.name+':'+f.type+':'+f.size).join(',')">
            <label>Avatar <input id="one" type="file" onchange="out.textContent='one '+this.files[0].name"></label>
                        <input id="hidden" type="file" hidden onchange="out.textContent='picked '+[...this.files].map(f=>f.name).join(',')">
            """,
        ])
    }

    override func tearDown() async throws {
        server.stop()
    }

    // MARK: Frames

    func testFramesOfBothOriginsShowInTheSnapshotAndTakeActions() async throws {
        let pane = try await open("/frames", frames: 3)
        let text = try await pane.snapshot(["full": true, "filter": "all"])
        XCTAssertTrue(text.contains(#"button "Top button" [ref_"#), text)
        XCTAssertTrue(text.contains("frame f1:") && text.contains("frame f2:"), text)
        let same = try ref(#"button "Same""#, in: text)
        let cross = try ref(#"button "Cross""#, in: text)
        XCTAssertTrue(same.hasPrefix("ref_f") && cross.hasPrefix("ref_f"), text)
        XCTAssertNotEqual(same.prefix(6), cross.prefix(6), "each frame has its own prefix")

        // Refs route to their frame, the cross-origin one too.
        _ = try await act(pane, ["kind": "click", "target": ["type": "ref", "ref": cross]])
        _ = try await act(pane, ["kind": "fill", "value": "hi", "target": ["type": "ref", "ref": try ref("Cross field", in: text)]])
        _ = try await act(pane, ["kind": "click", "target": ["type": "ref", "ref": same]])
        let crossFrame = try await pane.locate(["type": "ref", "ref": cross]).frame
        let sameFrame = try await pane.locate(["type": "ref", "ref": same]).frame
        let crossText = try await pane.js("return go.textContent + '|' + q.value", [:], frame: crossFrame)
        XCTAssertEqual(crossText, "Cross clicked|hi")
        let sameText = try await pane.js("return document.querySelector('button').textContent", [:], frame: sameFrame)
        XCTAssertEqual(sameText, "Same clicked")
        let after = try await pane.snapshot(["full": true, "filter": "all"])
        XCTAssertTrue(after.contains(#"button "Cross clicked" [\#(cross)]"#), after)

        // A screenshot point over a frame lands in it, in its own pixels.
        let box = try await pane.js(
            "const r = cross.getBoundingClientRect(); return [r.left, r.top].join(',')", [:], as: String.self)
        let inner = try await pane.js(
            "const r = go.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2].join(',')", [:], frame: crossFrame, as: String.self)
        let (frameX, frameY) = try pair(box), (buttonX, buttonY) = try pair(inner)
        pane.shotScale = 1
        let located = try await pane.locate(["type": "coordinate", "x": frameX + buttonX, "y": frameY + buttonY])
        XCTAssertEqual(located.frame, crossFrame)
        XCTAssertEqual((located.target?["x"] as? Double) ?? 0, buttonX, accuracy: 1)
        XCTAssertEqual((located.target?["y"] as? Double) ?? 0, buttonY, accuracy: 1)

        // Annotated screenshots label refs inside frames with the frame's prefix.
        await pane.label(true)
        let labels = try await pane.js(
            "return [...document.querySelectorAll('#__un-overlay [data-label]')].map(l => l.textContent).join(' ')", [:], frame: crossFrame)
        XCTAssertTrue(labels.contains(String(cross.dropFirst(4))), "\(labels) has \(cross)")
        await pane.label(false)
    }

    func testUploadsReachAFileInputInACrossOriginFrame() async throws {
        let pane = try await open("/frames", frames: 3)
        let text = try await pane.snapshot(["full": true, "filter": "all"])
        let field = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("ref_f") && $0.contains("button") && !$0.contains("Cross") && !$0.contains("Same") })
        let files = BrowserAgent.payloads(["files": [["name": "a.txt", "mime_type": "text/plain", "data": "aGk="]]])
        let target = ["type": "ref", "ref": try ref("", in: String(field))]
        let frame = try await pane.locate(target).frame

        // Approved for the page's origin, the files do not go to the frame's other origin.
        let top = "http://127.0.0.1:\(server.port)"
        let refused = try await act(pane, ["kind": "upload", "files": files, "target": target, "approved": true, "approved_origin": top])
        let need = try XCTUnwrap(refused["needsUser"] as? [String: Any])
        XCTAssertEqual(need["origin"] as? String, "http://localhost:\(server.port)")
        let untouched = try await pane.js("return document.title", [:], frame: frame)
        XCTAssertEqual(untouched, "")

        _ = try await act(pane, ["kind": "upload", "files": files, "target": target, "approved": true, "approved_origin": "http://localhost:\(server.port)"])
        let title = try await pane.js("return document.title", [:], frame: frame)
        XCTAssertEqual(title, "a.txt:text/plain:2")
    }

    // MARK: Popups

    func testLinksToNewWindowsAndWindowOpenBecomeTabs() async throws {
        let pane = try await open("/popups")
        var opened: [String] = []
        pane.onPopup = { opened.append($0.path()) }
        pane.agentActing = true
        let text = try await pane.snapshot(["full": true])
        _ = try await act(pane, ["kind": "click", "target": ["type": "ref", "ref": try ref("New tab link", in: text)]])
        _ = try await act(pane, ["kind": "click", "target": ["type": "ref", "ref": try ref("Open window", in: text)]])
        try await until("both popups") { opened.count == 2 }
        XCTAssertEqual(Set(opened), ["/popped", "/opened"])
        XCTAssertEqual(pane.page.url?.path(), "/popups", "the opener stays where it was")

        // A page opened that way may close itself.
        let popped = BrowserPane(url: server.url("/popped"), popup: true)
        var closed = false
        popped.onClose = { closed = true }
        popped.start()
        try await until("the popup loads") { !popped.page.isLoading && !popped.frames.tokens.isEmpty }
        let close = try await popped.snapshot(["full": true])
        _ = try await act(popped, ["kind": "click", "target": ["type": "ref", "ref": try ref("Close me", in: close)]])
        try await until("the popup closes") { closed }
    }

    /// A "Sign in with…" popup: it has `window.opener`, messages it, and closes itself.
    func testPopupTalksToItsOpenerAndClosesItself() async throws {
        let pane = try await open("/opener")
        var popups: [BrowserPane] = []
        pane.onPopupPane = { popups.append($0) }
        pane.agentActing = true
        let text = try await pane.snapshot(["full": true])
        _ = try await act(pane, ["kind": "click", "target": ["type": "ref", "ref": try ref("Sign in with Example", in: text)]])
        try await until("the popup opens") { popups.count == 1 }
        let popup = popups[0]
        XCTAssertNotNil(popup.popupPage, "WebKit's own web view, with the opener")
        try await until("the popup loads") { !popup.page.isLoading && !popup.frames.tokens.isEmpty }
        XCTAssertEqual(popup.page.url?.path(), "/signin")
        try await until("the opener hears it") { try await out(pane) == "ready" }

        // Agents' tools work on it as on any page.
        var closed = false
        popup.onClose = { closed = true }
        popup.agentActing = true
        let signin = try await popup.snapshot(["full": true])
        // The page goes away under the action, which may not get to answer.
        _ = try? await act(popup, ["kind": "click", "target": ["type": "ref", "ref": try ref("Continue", in: signin)]])
        try await until("the token reaches the opener") { try await out(pane) == "ready token-42" }
        try await until("the popup closes") { closed }
    }

    // MARK: Dialogs

    func testEachDialogWaitsForItsAnswer() async throws {
        let pane = try await open("/dialogs")
        let text = try await pane.snapshot(["full": true])

        let alert = try await blocked(pane, ["kind": "click", "target": ["type": "ref", "ref": try ref(#"button "Alert""#, in: text)]])
        XCTAssertEqual(alert.kind, .alert)
        XCTAssertEqual(alert.message, "Hello")
        XCTAssertTrue(BrowserAgent.dialogNote(alert).contains("alert dialog: “Hello”"), BrowserAgent.dialogNote(alert))
        alert.answer(true, nil)
        try await until("the alert closes") { try await self.out(pane) == "after alert" }

        let confirm = try await blocked(pane, ["kind": "click", "target": ["type": "ref", "ref": try ref(#"button "Confirm""#, in: text)]])
        XCTAssertEqual(confirm.kind, .confirm)
        confirm.answer(false, nil)
        try await until("the confirm is dismissed") { try await self.out(pane) == "confirm false" }

        let prompt = try await blocked(pane, ["kind": "click", "target": ["type": "ref", "ref": try ref(#"button "Prompt""#, in: text)]])
        XCTAssertEqual(prompt.kind, .prompt)
        XCTAssertEqual(prompt.defaultText, "Ada")
        prompt.answer(true, "Grace")
        try await until("the prompt answers") { try await self.out(pane) == "prompt Grace" }
    }

    func testLeavingAPageWithUnsavedChangesAsksFirst() async throws {
        let pane = try await open("/dialogs")
        let clean = await pane.leavingAllowed()
        XCTAssertTrue(clean, "a page without a beforeunload objection leaves at once")

        let text = try await pane.snapshot(["full": true])
        _ = try await act(pane, ["kind": "type", "text": "unsaved", "target": ["type": "ref", "ref": try ref("Draft", in: text)]])
        let asking = Task { await pane.leavingAllowed() }
        try await until("the leave check shows") { pane.dialog != nil }
        XCTAssertEqual(pane.dialog?.kind, .beforeunload)
        pane.dialog?.answer(false, nil)
        let stayed = await asking.value
        XCTAssertFalse(stayed)

        let again = Task { await pane.leavingAllowed() }
        try await until("the leave check shows again") { pane.dialog != nil }
        pane.dialog?.answer(true, nil)
        let left = await again.value
        XCTAssertTrue(left)
    }

    // MARK: Uploads

    func testUploadsSetFilesAndAnswerTheFilePicker() async throws {
        let pane = try await open("/upload")
        let text = try await pane.snapshot(["full": true, "filter": "all"])
        let files = BrowserAgent.payloads(["files": [
            ["name": "a.txt", "mime_type": "text/plain", "data": "aGk="],
            ["name": "b.png", "mime_type": "image/png", "data": "AAEC"],
        ]])
        let field = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("button") && !$0.contains("Avatar") })
        let target = ["type": "ref", "ref": try ref("", in: String(field))]
        let origin = "http://127.0.0.1:\(server.port)"

        // Without the user's approval for this origin, no file is set.
        for approval: [String: Any] in [[:], ["approved": true], ["approved": true, "approved_origin": "https://elsewhere.example"]] {
            let refused = try await act(pane, (["kind": "upload", "files": files, "target": target] as [String: Any]).merging(approval) { $1 })
            let need = try XCTUnwrap(refused["needsUser"] as? [String: Any], "\(approval)")
            XCTAssertEqual(need["upload"] as? Bool, true)
            XCTAssertEqual(need["origin"] as? String, origin)
            let empty = try await out(pane)
            XCTAssertEqual(empty, "")
        }

        _ = try await act(pane, ["kind": "upload", "files": files, "target": target, "approved": true, "approved_origin": origin])
        let out = try await out(pane)
        XCTAssertEqual(out, "a.txt:text/plain:2,b.png:image/png:3")
        // The label stands for its input.
        _ = try await act(pane, ["kind": "upload", "files": Array(files.prefix(1)), "target": ["type": "ref", "ref": try ref("Avatar", in: text)], "approved": true, "approved_origin": origin])
        let one = try await self.out(pane)
        XCTAssertEqual(one, "one a.txt")

        // A file picker opened while the agent acts waits for its files. Script input carries
        // no user gesture, so the picker is opened from the app here (WebKit counts that as one).
        pane.agentActing = true
        defer { pane.agentActing = false }
        _ = try await pane.page.run("document.getElementById('hidden').click()", in: .page)
        try await until("the picker opens") { pane.fileChooser != nil }
        let chooser = try XCTUnwrap(pane.fileChooser)
        XCTAssertFalse(chooser.multiple)
        XCTAssertEqual(chooser.origin, origin, "the picker names the origin that receives the files")
        let file = FileManager.default.temporaryDirectory.appending(path: "picked.txt")
        try Data("x".utf8).write(to: file)
        chooser.answer([file])
        try await until("the picked file arrives") { try await self.out(pane) == "picked picked.txt" }
    }

    func testTheUploadApprovalNamesEveryFileItsSizeAndTheOrigin() {
        let one = BrowserAgent.uploadRequest(
            [.init(name: "notes.txt", size: 2048, path: "~/app/notes.txt")], origin: "https://forms.example")
        XCTAssertTrue(one.hasPrefix("Upload this file to https://forms.example?\n"), one)
        XCTAssertTrue(one.contains("~/app/notes.txt, 2 KB"), one)
        let inline = BrowserAgent.listing([["name": "a.txt", "data": "aGk="], ["name": "b.png", "data": "AAEC"]])
        XCTAssertEqual(inline, [.init(name: "a.txt", size: 2), .init(name: "b.png", size: 3)])
        let two = BrowserAgent.uploadRequest(inline, origin: "http://localhost:3000")
        XCTAssertTrue(two.hasPrefix("Upload these 2 files to http://localhost:3000?\n"), two)
        XCTAssertTrue(two.contains("a.txt, 2 bytes") && two.contains("b.png, 3 bytes"), two)
    }

    // MARK: Plumbing

    private func open(_ path: String, frames: Int = 1) async throws -> BrowserPane {
        let pane = BrowserPane(url: server.url(path))
        pane.start()
        try await until("\(path) loads") { !pane.page.isLoading && pane.frames.tokens.count >= frames }
        return pane
    }

    /// Runs an action where its target lives, as `BrowserAgent` does.
    @discardableResult
    private func act(_ pane: BrowserPane, _ args: [String: Any]) async throws -> [String: Any] {
        let (target, frame) = try await pane.locate(args["target"] as? [String: Any])
        var input = args
        input["phase"] = "do"
        input["target"] = target
        return try await pane.js("return window.__un.act(args)", input, frame: frame, as: [String: Any].self)
    }

    /// The dialog an action opens.
    private func blocked(_ pane: BrowserPane, _ args: [String: Any]) async throws -> BrowserPane.PageDialog {
        _ = try await pane.untilBlocked { try await self.act(pane, args) }
        return try XCTUnwrap(pane.dialog)
    }

    private func out(_ pane: BrowserPane) async throws -> String {
        try await pane.js("return document.getElementById('out').textContent", [:])
    }

    private func ref(_ needle: String, in text: String) throws -> String {
        let line = try XCTUnwrap(text.split(separator: "\n").first { (needle.isEmpty || $0.contains(needle)) && $0.contains("[ref_") }, "\(needle) in \(text)")
        return String(try XCTUnwrap(line.firstMatch(of: /\[(ref_[\w]+)\]/)?.output.1))
    }

    private func pair(_ text: String) throws -> (Double, Double) {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(parts.count, 2)
        return (parts[0], parts[1])
    }

    private func until(_ what: String, seconds: Double = 10, _ check: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }
}

/// Serves fixed pages over HTTP on a free port of this device. `{A}` and `{B}` in a page
/// become this server's two origins.
final class FixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let pages: [String: String]

    init(pages: [String: String]) async throws {
        self.pages = pages
        listener = try NWListener(using: .tcp, on: .any)
        let ready = AsyncStream<Void> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.finish() } }
        }
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        listener.start(queue: .global())
        for await _ in ready {}
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func url(_ path: String, origin: String = "127.0.0.1") -> URL {
        URL(string: "http://\(origin):\(port)\(path)")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map { String($0.split(separator: "?")[0]) } ?? "/"
            let page = pages[path]
            let body = Data((page ?? "not found")
                .replacingOccurrences(of: "{A}", with: "http://127.0.0.1:\(port)")
                .replacingOccurrences(of: "{B}", with: "http://localhost:\(port)").utf8)
            let head = "HTTP/1.1 \(page == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
