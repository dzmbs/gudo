import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Timeline items for the Chat scenes design reviews and long-session runs use, as the wire's JSON.
nonisolated enum ChatScenes {
    static let image = "/work/shots/dashboard.png"
    static let attachment = "/work/uploads/sketch.png"

    static func snapshot(_ items: [[String: Any]], nativeSession: String = "fixture", before: UInt64? = nil) throws -> String {
        try TimelineFixtureJSON.json([
            "capabilities": 447, "cursor": ["epoch": 1, "sequence": 0], "before": before.map { $0 as Any } ?? NSNull(),
            "items": items,
            "session": ["agent": "Claude", "native_session": nativeSession, "title": "Review the change",
                        "model": "claude-opus-4-5-20251101", "permission_mode": "auto", "commands": []],
        ])
    }

    static func longTurn(prefix: String = "", now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)) -> [[String: Any]] {
        [
            item(prefix + "prompt", at: now - 840_000, origin: "Terminal", body: ["User": [
                "text": "What clock do our 5090s run at? Check both boxes, and write up how the dashboard should change.",
                "attachments": [], "queued": false]]),
            item(prefix + "think", body: ["Thinking": ["text": NSNull(), "duration_ms": 4_000]]),
            item(prefix + "t1", body: tool("Shell", title: "Query nvidia-smi on box one", input: #"{"command":"ssh box-one nvidia-smi"}"#)),
            item(prefix + "t2", body: tool("Shell", title: "Query nvidia-smi on box two", status: "Failed", exit: 255)),
            item(prefix + "t3", body: tool("Read", title: "Read README.md", input: #"{"file_path":"/work/README.md"}"#)),
            item(prefix + "t4", body: tool("Shell", title: "Retry box two over the relay")),
            item(prefix + "t5", body: tool("Search", title: "Grep for clock settings")),
            item(prefix + "reply", body: ["Assistant": ["text": longReply, "streaming": false]]),
            item(prefix + "shot", body: tool("Read", title: "Read dashboard.png", input: #"{"file_path":"\#(image)"}"#)),
            item(prefix + "after", body: ["Assistant": ["text": "The starter page is close. I am fixing the link colour and the KPI label that wraps, then checking dark mode.",
                                                        "streaming": false]]),
            item(prefix + "e1", body: tool("Edit", title: "Edit dashboard.css", input: #"{"file_path":"/work/dashboard.css"}"#)),
            item(prefix + "e2", body: tool("Edit", title: "Edit kpi.html", input: #"{"file_path":"/work/kpi.html"}"#)),
            item(prefix + "end", body: ["TurnEnd": ["duration_ms": 94_000, "input_tokens": 61_000, "output_tokens": 3_100]]),
        ]
    }

    static func workingTurn(now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)) -> [[String: Any]] {
        [
            item("second-prompt", at: now - 19_000, body: ["User": [
                "text": "Read the guideline PDF in full and fix the dashboard. Gad is really checking this, so take care with every detail.",
                "attachments": [["path": attachment, "media_type": "image/png"]], "queued": false]]),
            item("r1", body: tool("Shell", title: "List the kit files")),
            item("r2", body: tool("Read", title: "Read guideline.pdf")),
            item("r3", body: tool("Read", title: "Read starter.html")),
            item("r4", body: tool("Shell", title: "Run the page checks", status: "Running")),
            item("note", body: ["Assistant": ["text": "I am reading the guideline and the starter page before touching any code.",
                                              "streaming": true]]),
        ]
    }

    static func failedTurn(now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)) -> [[String: Any]] {
        [
            item("prompt", at: now - 120_000, body: ["User": ["text": "Run the proto tests.", "attachments": [], "queued": false]]),
            item("failed", body: tool("Shell", title: "Run the proto tests", input: #"{"command":"cargo test -p proto"}"#,
                                      status: "Failed", exit: 101, output: """
                                      running 42 tests
                                      test golden::timeline_items ... ok
                                      test golden::tool_kinds ... FAILED

                                      failures:
                                          golden::tool_kinds: left: 9, right: 10
                                      test result: FAILED. 41 passed; 1 failed
                                      """)),
            item("reply", body: ["Assistant": ["text": "One golden test fails: a new tool kind was appended without its byte. I will add it.",
                                               "streaming": false]]),
        ]
    }

    /// A long session of `turns` finished turns, seven items each: a prompt, thinking, three
    /// tools, a reply with Markdown and code, and the turn's end.
    static func session(turns: Int) -> [[String: Any]] {
        (0..<turns).flatMap { turn -> [[String: Any]] in
            let id = "s\(turn)-"
            let at = UInt64(turn) * 60_000
            let reply = turn.isMultiple(of: 3)
                ? "Turn \(turn): the change is in.\n\n- `Pane.swift` keeps its size.\n- The tests pass.\n\n```swift\nlet turn = \(turn)\nprint(turn)\n```"
                : "Turn \(turn): I read the files and updated the layout. The build passes and nothing else moved."
            return [
                item(id + "prompt", turn: "turn-\(turn)", at: at, body: ["User": [
                    "text": "Step \(turn): update the layout and run the checks.", "attachments": [], "queued": false]]),
                item(id + "think", turn: "turn-\(turn)", at: at, body: ["Thinking": ["text": NSNull(), "duration_ms": 2_000]]),
                item(id + "read", turn: "turn-\(turn)", at: at, body: tool("Read", title: "Read Layout.swift",
                                                                             input: #"{"file_path":"/work/Layout.swift"}"#)),
                item(id + "edit", turn: "turn-\(turn)", at: at, body: tool("Edit", title: "Edit Layout.swift",
                                                                             input: #"{"file_path":"/work/Layout.swift"}"#)),
                item(id + "test", turn: "turn-\(turn)", at: at, body: tool("Shell", title: "Run the tests",
                                                                             input: #"{"command":"swift test"}"#)),
                item(id + "reply", turn: "turn-\(turn)", at: at, body: ["Assistant": ["text": reply, "streaming": false]]),
                item(id + "end", turn: "turn-\(turn)", at: at, body: ["TurnEnd": ["duration_ms": 30_000, "input_tokens": 12_000,
                                                                                    "output_tokens": 900]]),
            ]
        }
    }

    static let longReply = """
    ## Clocks on both boxes

    Measured live on both boxes. The cards boost well past their base clock and stay under the power limit, so nothing is throttling. Readings come from `nvidia-smi --query-gpu=clocks.sm,clocks.mem --format=csv` on each box.

    | | Now | Card maximum |
    |---|---|---|
    | GPU core (SM) clock | **2,570 to 2,595 MHz** | 3,090 MHz |
    | Memory clock | 13,801 MHz | 14,001 MHz |
    | Power draw under load | 545 to 575 W | 575 W |

    ### What to change

    1. Show the **live clock** next to each card, not the base clock.
    2. Mark a card amber when it sits under `2,400 MHz` for a minute.
    3. Keep the power column, and add the limit as a faint rule.

    - The same reading drives the sparkline.
    - Nothing else on the page moves.

    > Both boxes run the same driver, 580.82, so the numbers compare directly.

    The card model reads its clock like this:

    ```swift
    struct GPUClock: Decodable {
        let core: Measurement<UnitFrequency>
        let memory: Measurement<UnitFrequency>

        var isBoosting: Bool { core.value > 2_400 }
    }
    ```

    Here is the dashboard before the change:
    """

    static func tool(_ kind: String, title: String, input: String = "{}", status: String = "Done", exit: Int? = nil,
                     output: String? = nil) -> [String: Any] {
        let reference: Any = output.map { ["handle": "fixture", "preview": $0, "bytes": $0.utf8.count] } ?? NSNull()
        return ["Tool": ["kind": kind, "name": kind, "title": title, "input": input, "status": status, "output": reference,
                         "diff": [], "exit": exit.map { $0 as Any } ?? NSNull(), "duration_ms": 1_200, "command_mark": NSNull()]]
    }

    static func item(_ id: String, turn: String = "turn", at: UInt64 = 0, origin: String = "Agent", body: [String: Any]) -> [String: Any] {
        ["id": id, "revision": 1, "turn": turn, "parent": NSNull(), "at": at, "origin": origin, "body": body]
    }

    /// A small dashboard picture for inline images and attachments.
    static func dashboardPNG() -> Data {
        let width = 1_200, height = 700
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        func fill(_ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            // CoreGraphics counts from the bottom; the layout reads from the top.
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0.96, 0.96, 0.96)
        fill(CGRect(x: 0, y: 0, width: width, height: 56), 0.12, 0.12, 0.12)
        for column in 0..<6 { fill(CGRect(x: 40 + column * 190, y: 90, width: 170, height: 90), 0.86, 0.86, 0.86) }
        for (column, bar) in [60, 90, 130, 170, 210, 250, 290, 330, 80, 140].enumerated() {
            fill(CGRect(x: 60 + column * 110, y: height - 40 - bar, width: 70, height: bar), 0.29, 0.62, 0.64)
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
