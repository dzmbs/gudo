#if DEBUG
import DrawingKit
import Foundation
import TerminalCore
#if os(iOS)
import PencilKit
import UIKit
#endif

/// `-drawingDemo overlay|done|canvas` (Debug): scripted drawing on the first daemon pane, for
/// overlay over it, circles the failure with Pencil ink (synthesized PencilKit strokes that go
/// through the real conversion path), adds an Excalidraw rectangle and arrow, and with `done`
/// places it; `canvas` splits a canvas pane instead.
@MainActor
enum DrawingDemo {
    private static var started = false

    static func run(on drawing: PaneDrawing) {
        guard let mode = UserDefaults.standard.string(forKey: "drawingDemo"), !mode.isEmpty, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if mode == "blank" || mode == "keyboard" {
                #if os(iOS)
                if mode == "keyboard" {
                    _ = drawing.pane?.view.becomeFirstResponder()
                    try? await Task.sleep(for: .seconds(1.5))
                }
                #endif
                drawing.beginDrawing()
                return
            }
            let script = """
            clear; printf '\\033[1m$ cargo test -p drawing\\033[0m\\n   Compiling drawing v0.1.0\\n    Finished test profile in 2.31s\\n     Running tests/scene.rs\\n\\nrunning 4 tests\\ntest packs_points ... \\033[32mok\\033[0m\\ntest converges ... \\033[32mok\\033[0m\\ntest simplify_keeps_swells ... \\033[31mFAILED\\033[0m\\ntest svg_golden ... \\033[32mok\\033[0m\\n\\nfailures:\\n  assertion failed: kept.len() == 41 (got 37)\\n  at crates/drawing/src/simplify.rs:88\\n\\ntest result: \\033[31mFAILED\\033[0m. 3 passed; 1 failed\\n'
            """
            Array((script + "\r").utf8).withUnsafeBytes { drawing.backend.write($0) }
            try? await Task.sleep(for: .seconds(1.5))
            if mode == "canvas" {
                if let workspace = drawing.workspace { DrawingCommands.newCanvas(in: workspace) }
                try? await Task.sleep(for: .seconds(4))
                guard let canvas = drawing.workspace?.panes.keys.compactMap(PaneDrawing.of).compactMap(\.canvas).first else { return }
                func box(_ id: String, _ x: Int, _ y: Int, _ text: String, _ color: String) -> [String: Any] {
                    ["type": "rectangle", "id": id, "x": x, "y": y, "width": 220, "height": 90, "strokeColor": color, "backgroundColor": "transparent",
                     "roundness": ["type": 3], "label": ["text": text, "fontSize": 22]]
                }
                func arrow(_ from: String, _ to: String, _ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> [String: Any] {
                    ["type": "arrow", "x": x, "y": y, "width": dx, "height": dy, "points": [[0, 0], [dx, dy]],
                     "start": ["id": from], "end": ["id": to], "strokeColor": "#1e1e1e"]
                }
                canvas.call("debugSkeleton", ["elements": [
                    box("pencil", 0, 0, "Pencil / Excalidraw", "#1971c2"),
                    box("daemon", 320, 0, "daemon scene", "#2f9e44"),
                    box("pane", 320, 180, "pane placement", "#e8590c"),
                    box("agent", 0, 180, "Claude [Image #1]", "#c92a2a"),
                    arrow("pencil", "daemon", 225, 45, 90, 0),
                    arrow("daemon", "pane", 430, 95, 0, 80),
                    arrow("pane", "agent", 315, 225, -90, 0),
                ]])
                return
            }
            guard let surface = drawing.surface, let grid = surface.grid else { return }
            // The FAILED line: 9 rows above the prompt.
            let row = max(0, surface.terminal.cursorPosition.y - 9)
            drawing.beginDrawing(at: surface.rect(for: GridPoint(x: 0, y: row)).origin)
            try? await Task.sleep(for: .seconds(2.5))
            guard let overlay = drawing.overlay, let g = overlay.currentGeometry else { return }
            _ = grid
            // Shapes: a box around the assertion and an arrow to it.
            let col = g.sceneColumnWidth
            overlay.addShapes(rect: CGRect(x: col * 1, y: 20 * 3.85, width: col * 46, height: 20 * 2.3), arrowFrom: CGPoint(x: col * 60, y: 20 * 1.2), arrowTo: CGPoint(x: col * 47.5, y: 20 * 4.6))
            // Ink: a loop around FAILED and a handwritten-ish underline.
            let center = CGPoint(x: col * 34, y: 10)
            let loop = (0...64).map { i -> InkSample in
                let t = Double(i) / 64 * 2 * .pi * 1.08
                return InkSample(x: center.x + cos(t) * col * 8.5, y: center.y + sin(t) * 16, width: 3.2 + 1.2 * sin(t * 3), time: Double(i) / 120)
            }
            let underline = (0...30).map { i -> InkSample in
                InkSample(x: col * (2 + Double(i) * 1.3), y: 20 * 7.75 + sin(Double(i) / 3) * 1.5, width: 2.5 + Double(i % 5) * 0.3, time: Double(i) / 120)
            }
            overlay.injectInk([InkStroke(samples: loop, color: "#c92a2a"), InkStroke(samples: underline, color: "#e8590c")])
            if mode == "done" {
                try? await Task.sleep(for: .seconds(2.5))
                overlay.commit()
            }
            if mode == "scroll" || mode == "done" {
                if mode == "scroll" {
                    try? await Task.sleep(for: .seconds(2.5))
                    overlay.commit()
                }
                // More output: the placement scrolls with its rows.
                try? await Task.sleep(for: .seconds(mode == "scroll" ? 3 : 1_000_000))
                Array("seq 1 57\r".utf8).withUnsafeBytes { drawing.backend.write($0) }
            }
        }
    }
}

extension DrawOverlay {
    /// Debug: Excalidraw shapes as if drawn with the editor's tools.
    func addShapes(rect: CGRect, arrowFrom: CGPoint, arrowTo: CGPoint) {
        webEval("""
        (() => {
          const api = window.canvas;
          api.debugRect({x: \(rect.minX), y: \(rect.minY), width: \(rect.width), height: \(rect.height)});
          api.debugArrow && api.debugArrow({x1: \(arrowFrom.x), y1: \(arrowFrom.y), x2: \(arrowTo.x), y2: \(arrowTo.y)});
        })()
        """)
    }

    /// Debug: Pencil strokes converted like real ones (`Freedraw.element`).
    func injectInk(_ strokes: [InkStroke]) {
        #if os(iOS)
        // Through PencilKit, as a Pencil stroke would arrive (conversion, hand-off timing).
        if let ink, let g = currentGeometry {
            let pk = strokes.map { stroke -> PKStroke in
                let points = stroke.samples.map { s in
                    PKStrokePoint(
                        location: g.view(fromScene: CGPoint(x: s.x, y: s.y)), timeOffset: s.time,
                        size: CGSize(width: s.width * g.zoom, height: s.width * g.zoom), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let rgb = stroke.color.dropFirst()
                let value = Int(rgb, radix: 16) ?? 0
                let color = UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
                return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
            }
            ink.canvas.drawing = PKDrawing(strokes: ink.canvas.drawing.strokes + pk)
            return
        }
        #endif
        let elements = strokes.enumerated().compactMap { i, stroke in
            Freedraw.element(stroke, id: "demo-ink-\(i)-\(UUID().uuidString.prefix(6))", seed: 100 + i, versionNonce: 200 + i, updatedMs: Int64(Date().timeIntervalSince1970 * 1000))
        }
        addInk(elements)
    }
}
#endif
