#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit
import XCTest
@testable import App

/// Renders Chat states to PNGs for comparing against the reference screenshots:
/// `TEST_RUNNER_GUDO_CHAT_RENDER_DIR=<dir>`.
@MainActor
final class ChatRenderGalleryTests: XCTestCase {
    private var directory: URL!
    private static let width: CGFloat = 393

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["GUDO_CHAT_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipIf(path == nil, "set TEST_RUNNER_GUDO_CHAT_RENDER_DIR to render Chat states")
        directory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testRenderChatStates() async throws {
        let loader = ChatImageLoader { _ in Self.samplePNG() }
        _ = try await loader.image("/work/shots/dashboard.png")
        let builder = RowBuilder()
        let items = try conversation()
        let rows = items.flatMap { builder.rows(for: $0) }
        let folded = ChatToolGroups.fold(rows, expanded: [])
        let groupID = try XCTUnwrap(folded.first { ChatToolGroups.isGroup($0.id) }?.id)
        let expanded = ChatToolGroups.fold(rows, expanded: [groupID])
        let running = ChatToolGroups.fold(try runningTurn().flatMap { builder.rows(for: $0) }, expanded: [])
        var actions = ChatRowActions()
        actions.resend = { _ in }
        actions.loadImage = loader
        let session = try session()
        for (appearance, themeName) in [("dark", TerminalPreferences.Default.theme), ("light", ThemePair.resolvedDefaultLight)] {
            let theme = ThemeCatalog.theme(named: themeName)
            try render(sheet(folded, expanded: [], actions: actions, theme: theme), named: "chat-folded-\(appearance)")
            try render(sheet(expanded, expanded: [groupID], actions: actions, theme: theme), named: "chat-expanded-\(appearance)")
            try render(sheet(running, expanded: [], actions: actions, theme: theme, working: true, session: session),
                       named: "chat-working-\(appearance)")
        }
    }

    private func sheet(_ rows: [ChatRow], expanded: Set<ChatRowID>, actions: ChatRowActions, theme: TerminalTheme,
                       working: Bool = false, session: TimelineSession? = nil) -> some View {
        let chrome = ChromePalette(theme: theme)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ChatRowView(row: row, isExpanded: expanded.contains(row.id), toggle: {}, actions: actions,
                            topSpacing: ChatRowSpacing.top(of: row, below: index > 0 ? rows[index - 1] : nil))
            }
            if working || session != nil {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if working { ChatWorkingIndicator().padding(.leading, DS.Space.xl) }
                    ChatSessionChips(session: session, canChooseModel: true, chooseModel: { _ in })
                        .padding(.horizontal, DS.Space.m)
                }
                .padding(.top, DS.Space.l)
            }
        }
        .padding(.vertical, DS.Space.l)
        .frame(width: Self.width)
        .background(chrome.baseColor)
        .chromeContent()
        .environment(\.terminalTheme, theme)
        .environment(\.chrome, chrome)
        .environment(\.colorScheme, chrome.scheme)
    }

    private func render(_ content: some View, named name: String) throws {
        let host = UIHostingController(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private static func samplePNG() -> Data {
        let size = CGSize(width: 1_200, height: 700)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.withAlphaComponent(0.35).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemIndigo.withAlphaComponent(0.5).setFill()
            for column in 0..<6 {
                let height = CGFloat(120 + column * 70)
                context.fill(CGRect(x: 80 + CGFloat(column) * 180, y: size.height - 60 - height, width: 120, height: height))
            }
        }
        return image.pngData() ?? Data()
    }

    private func conversation() throws -> [TimelineItem] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return try [
            item("prompt", at: now - 600_000, origin: "Terminal", body: ["User": [
                "text": "What clock do our 5090s run at? Check both boxes.", "attachments": [], "queued": false]]),
            item("think", body: ["Thinking": ["text": NSNull(), "duration_ms": NSNull()]]),
            item("t1", body: tool("Shell", title: "Query nvidia-smi on box one")),
            item("t2", body: tool("Shell", title: "Query nvidia-smi on box two", status: "Failed")),
            item("t3", body: tool("Read", title: "Read README.md")),
            item("t4", body: tool("Shell", title: "Retry box two over the relay")),
            item("t5", body: tool("Search", title: "Grep for clock settings")),
            item("reply", body: ["Assistant": ["text": """
            Measured live on both boxes. The cards boost well past their base clock and stay under the power limit:

            | | Now | Card maximum |
            |---|---|---|
            | GPU core (SM) clock | **2,570 to 2,595 MHz** | 3,090 MHz |
            | Memory clock | 13,801 MHz | 14,001 MHz |
            | Power draw under load | 545 to 575 W | 575 W |

            Here is the dashboard after the change:
            """, "streaming": false]]),
            item("shot", body: tool("Read", title: "Read dashboard.png", input: #"{"file_path":"/work/shots/dashboard.png"}"#)),
            item("end", body: ["TurnEnd": ["duration_ms": 94_000, "input_tokens": NSNull(), "output_tokens": 3_100]]),
        ]
    }

    private func runningTurn() throws -> [TimelineItem] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return try [
            item("second-prompt", at: now - 60_000, origin: "Agent", body: ["User": [
                "text": "Read the guideline PDF in full and fix the dashboard.", "attachments": [], "queued": false]]),
            item("timed", body: ["Thinking": ["text": NSNull(), "duration_ms": 4_000]]),
            item("r1", body: tool("Shell", title: "List the kit files")),
            item("r2", body: tool("Read", title: "Read guideline.pdf")),
            item("r3", body: tool("Read", title: "Read starter.html")),
            item("r4", body: tool("Shell", title: "Run the page checks", status: "Running")),
            item("note", body: ["Assistant": ["text": "I am reading the guideline and the starter page before touching any code.",
                                              "streaming": true]]),
        ]
    }

    private func tool(_ kind: String, title: String, status: String = "Done", input: String = "{}") -> [String: Any] {
        ["Tool": ["kind": kind, "name": kind, "title": title, "input": input, "status": status, "output": NSNull(),
                  "diff": [], "exit": NSNull(), "duration_ms": 1_200, "command_mark": NSNull()]]
    }

    private func item(_ id: String, at: UInt64 = 0, origin: String = "Agent", body: [String: Any]) throws -> TimelineItem {
        let value: [String: Any] = ["id": id, "revision": 1, "turn": "turn", "parent": NSNull(), "at": at,
                                    "origin": origin, "body": body]
        let encoded = try JSONSerialization.data(withJSONObject: value)
        return try TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
    }

    private func session() throws -> TimelineSession {
        let value: [String: Any] = ["agent": "Claude", "native_session": "session", "title": NSNull(),
                                    "model": "claude-opus-4-5-20251101", "permission_mode": "auto", "commands": []]
        return try JSONDecoder().decode(TimelineSession.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
#endif
