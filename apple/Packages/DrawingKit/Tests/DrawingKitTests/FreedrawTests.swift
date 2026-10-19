import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import DrawingKit

/// PencilKit strokes → Excalidraw `freedraw` elements.
@Suite struct FreedrawTests {
    let geometry = OverlayGeometry(cell: CGSize(width: 8, height: 16), origin: CGPoint(x: 100, y: 50))

    @Test func elementHasExcalidrawFields() throws {
        let stroke = InkStroke(samples: [
            InkSample(x: 10, y: 20, width: 4),
            InkSample(x: 15, y: 18, width: 6),
            InkSample(x: 15, y: 18, width: 6),  // duplicate, dropped
            InkSample(x: 30, y: 25, width: 2),
        ], color: "#e03131")
        let element = try #require(Freedraw.element(stroke, id: "ink-1", seed: 7, versionNonce: 9, updatedMs: 1000))
        #expect(element["type"] as? String == "freedraw")
        #expect(element["x"] as? Double == 10 && element["y"] as? Double == 20)
        let points = try #require(element["points"] as? [[Double]])
        #expect(points == [[0, 0], [5, -2], [20, 5]])
        #expect(element["width"] as? Double == 20 && element["height"] as? Double == 7)
        // Pressures: width relative to the median (4) → 0.5 at the median.
        #expect(element["pressures"] as? [Double] == [0.5, 0.75, 0.25])
        #expect(element["simulatePressure"] as? Bool == false)
        #expect(element["strokeColor"] as? String == "#e03131")
        #expect(abs((element["strokeWidth"] as? Double ?? 0) - 0.94) < 0.001)  // 4 / 4.25
        #expect(element["version"] as? Int == 1 && element["versionNonce"] as? Int == 9 && element["isDeleted"] as? Bool == false)
        // Valid JSON for the bridge.
        _ = try JSONSerialization.data(withJSONObject: element)
    }

    @Test func emptyStrokeHasNoElement() {
        #expect(Freedraw.element(InkStroke(samples: [], color: "#000000"), id: "x", seed: 1, versionNonce: 1, updatedMs: 0) == nil)
    }

    @Test func pencilKitStrokeConvertsToScenePx() throws {
        // A horizontal pen stroke over three columns of the anchor row, in view points.
        let points = (0...20).map { i in
            PKStrokePoint(
                location: CGPoint(x: 100 + Double(i) * 1.2, y: 58), timeOffset: Double(i) / 120,
                size: CGSize(width: 3.2, height: 3.2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let pk = PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let stroke = InkStroke(pk, geometry: geometry)
        let first = try #require(stroke.samples.first), last = try #require(stroke.samples.last)
        // (100, 58) is the origin + half a row: scene (0, 10). 24 pt → 30 scene px at zoom 0.8.
        #expect(abs(first.x) < 0.5 && abs(first.y - 10) < 0.5)
        #expect(abs(last.x - 30) < 1 && abs(last.y - 10) < 0.5)
        // 3.2 pt wide → 4 scene px.
        #expect(abs(first.width - 4) < 0.1)
        #expect(stroke.color == "#ff0000")
        let element = try #require(Freedraw.element(stroke, id: "a", seed: 1, versionNonce: 1, updatedMs: 0))
        let cells = geometry.cells(
            covering: CGRect(x: element["x"] as! Double, y: element["y"] as! Double, width: element["width"] as! Double, height: 1),
            maxCols: 80)
        #expect(cells == CellBox(col: 0, row: 0, cols: 3, rows: 1))
    }
}
