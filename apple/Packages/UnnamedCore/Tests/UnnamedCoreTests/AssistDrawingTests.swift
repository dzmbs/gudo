import Foundation
import Synchronization
import Testing
import UnnamedCore

/// Records input-assistance pushes.
final class AssistRecorder: AssistListener {
    private let events = Mutex<[AssistEvent]>([])

    func onAssistEvent(event: AssistEvent) {
        events.withLock { $0.append(event) }
    }

    var all: [AssistEvent] { events.withLock { $0 } }
}

/// Polls `match` until it returns something.
func poll<T>(_ what: String, timeout: Duration = .seconds(20), _ match: () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let found = try await match() { return found }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestError("timed out waiting for \(what)")
}

private func config() -> ClientConfig {
    ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: true)
}

private func line(_ state: PromptState?) -> String? {
    if case let .atPrompt(input) = state?.phase { input.text } else { nil }
}

/// The input-assistance and drawing surface against a local daemon.
@Suite(.serialized) struct AssistDrawingTests {
    /// zsh at a prompt: the typed line is read back, an atomic submit runs it once, and
    /// history has it.
    @Test func promptStateAndSubmit() async throws {
        let daemon = try LocalDaemon(
            shell: "/bin/zsh",
            environment: ["HOME": "{state}", "ZDOTDIR": "{state}"],
            setup: { try Data().write(to: $0.appending(path: ".zshrc")) }
        )
        let ticket = try await daemon.ticket()
        let events = Recorder()
        let client = try DaemonClient.connect(ticket: ticket, config: config(), listener: events)
        let assist = AssistRecorder()
        client.setAssistListener(listener: assist)
        let pane = try await attachFirstPane(client, events)

        _ = try await client.watchPrompt(paneId: pane, watch: true)
        let empty = try await poll("an empty prompt") {
            line(client.promptState(paneId: pane)) == "" ? client.promptState(paneId: pane) : nil
        }

        client.sendInput(paneId: pane, data: Data("echo hi".utf8))
        let typed = try await poll("the typed line") {
            line(client.promptState(paneId: pane)) == "echo hi" ? client.promptState(paneId: pane) : nil
        }
        #expect(typed.promptId == empty.promptId)
        #expect(assist.all.contains {
            if case let .prompt(state) = $0 { line(state) == "echo hi" } else { false }
        })
        let state = try await client.paneAssist(paneId: pane)
        #expect(state.foreground?.profile == .shell)
        #expect(line(state.prompt) == "echo hi")

        _ = try await client.submitLine(paneId: pane, promptId: typed.promptId, text: "echo hi", run: true)
        let next = try await poll("the next prompt") {
            let s = client.promptState(paneId: pane)
            return s.flatMap { $0.promptId != typed.promptId && line($0) == "" ? $0 : nil }
        }
        let text = client.paneText(paneId: pane) ?? ""
        #expect(text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces) == "hi" }.count == 1)

        // The old prompt is gone: refused with the state now, nothing written.
        do {
            _ = try await client.submitLine(paneId: pane, promptId: typed.promptId, text: "echo again", run: true)
            Issue.record("a stale prompt id was accepted")
        } catch let AssistError.NotAtPrompt(now) {
            #expect(now.promptId == next.promptId)
        }

        let entry = try await poll("history") {
            try await client.history(query: HistoryQuery(prefix: "echo", limit: 10))
                .first { $0.command == "echo hi" }
        }
        #expect(entry.count == 1)
        let completions = try await client.complete(paneId: pane, line: "ec", cursor: 2, limit: 50)
        #expect(completions.items.contains { $0.text.hasPrefix("echo") })
    }

    /// A drawing created with a rectangle, exported as SVG and ASCII.
    @Test func drawingCreateAndExport() async throws {
        let daemon = try LocalDaemon()
        let ticket = try await daemon.ticket()
        let events = Recorder()
        let client = try DaemonClient.connect(ticket: ticket, config: config(), listener: events)
        _ = try await attachFirstPane(client, events)
        let session = try await events.wait("attached") { all in
            all.lazy.compactMap { if case let .attached(sessionId, _, _) = $0 { sessionId } else { nil } }.first
        }

        let rect = DrawElement(
            id: 1, z: 0, style: DrawStyle(color: 0x0000_00ff, width: 2),
            kind: .shape(shape: .rect, from: Pt(x: 0, y: 0), to: Pt(x: 120, y: 60), filled: false)
        )
        let points = (0..<10).map { InkPoint(x: Float($0) * 4, y: 80, tMs: UInt32($0) * 4) }
        let ink = DrawElement(
            id: 2, z: 1, style: DrawStyle(color: 0xff00_00ff, width: 3),
            kind: .stroke(tool: .pen, points: packInkPoints(points: points))
        )
        let info = try await client.artifactCreate(create: ArtifactCreate(
            sessionId: session, kind: .drawing, title: "from swift", space: .canvas,
            ops: [.add(element: rect), .add(element: ink)]
        ))
        #expect(info.version == 1)
        #expect(info.title == "from swift")

        let svg = try await client.artifactExport(artifactId: info.artifactId, version: nil, format: .svg)
        #expect(String(decoding: svg.data, as: UTF8.self).contains("<svg"))
        let ascii = try await client.artifactExport(artifactId: info.artifactId, version: nil, format: .ascii)
        let text = String(decoding: ascii.data, as: UTF8.self)
        #expect(text.contains("┌") && text.contains("┘"))
        #expect(try renderAscii(elements: [rect], space: .canvas, maxCols: 80).contains("┌"))
        #expect(try unpackInkPoints(packed: packInkPoints(points: points)).count == 10)

        let listed = try await client.listArtifacts(sessionId: session)
        #expect(listed.map(\.artifactId) == [info.artifactId])
    }
}
