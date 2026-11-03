import DesignSystem
import GudoCore
@testable import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// A pane zooming to fill its tab, and back, moves in one continuous motion: every edge of its
/// frame heads one way from start to end, sampled per display frame, however the host's
/// layouts arrive on the way.
@MainActor
final class ZoomMotionTests: XCTestCase {
    private static let size = CGSize(width: 1200, height: 800)
    private static let displayFrame = 1.0 / 120

    /// The frames SwiftUI draws for a pane whose target changes at the given times: the canvas's
    /// spring, retargeted from where the pane is with the speed it has, as SwiftUI does.
    private static func trajectory(_ targets: [(time: Double, frame: CGRect)], until end: Double = 0.8) -> [CGRect] {
        let spring = DS.Motion.splitSpring
        func components(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.maxX, rect.maxY] }
        var position = components(targets[0].frame)
        var velocity = [Double](repeating: 0, count: 4)
        var segmentStart = 0.0
        var origin = position
        var delta = [Double](repeating: 0, count: 4)
        var startVelocity = velocity
        var pending = targets.dropFirst()
        var frames: [CGRect] = []
        var time = 0.0
        while time <= end {
            if let next = pending.first, next.time <= time {
                pending.removeFirst()
                origin = position
                startVelocity = velocity
                delta = zip(components(next.frame), position).map { $0 - $1 }
                segmentStart = time
            }
            let elapsed = time - segmentStart
            for axis in 0..<4 {
                position[axis] = origin[axis] + spring.value(target: delta[axis], initialVelocity: startVelocity[axis], time: elapsed)
                velocity[axis] = spring.velocity(target: delta[axis], initialVelocity: startVelocity[axis], time: elapsed)
            }
            frames.append(CGRect(x: position[0], y: position[1], width: position[2] - position[0], height: position[3] - position[1]))
            time += displayFrame
        }
        return frames
    }

    /// The edges that turn back on the way (more than a hundredth of a point).
    private static func reversals(in frames: [CGRect]) -> [String] {
        let edges: [(String, (CGRect) -> CGFloat)] = [("left", \.minX), ("top", \.minY), ("right", \.maxX), ("bottom", \.maxY)]
        return edges.compactMap { name, edge in
            var direction: CGFloat = 0
            for (previous, next) in zip(frames, frames.dropFirst()) {
                let step = edge(next) - edge(previous)
                guard abs(step) > 0.01 else { continue }
                if direction != 0, step.sign != direction.sign { return name }
                direction = step
            }
            return nil
        }
    }

    private static func canvas(_ session: Session) -> CanvasLayout {
        let tab = session.activeTab!
        return CanvasLayout(
            node: tab.root, floats: .none, zoomed: tab.zoomed, focused: tab.focused, size: size, gap: 1,
            header: PaneHeader.height, cell: CGSize(width: 8, height: 17), padding: 4)
    }

    private static func layout(revision: UInt64, focused: UInt64, zoomed: UInt64? = nil) -> SessionLayout {
        SessionLayout(
            sessionId: 7, name: "main", revision: revision, activeTab: 10,
            tabs: [TabLayout(
                tabId: 10, name: "",
                nodes: [
                    .split(axis: .horizontal, ratio: 0.5, first: 1, second: 2),
                    .leaf(paneId: 1),
                    .split(axis: .vertical, ratio: 0.5, first: 3, second: 4),
                    .leaf(paneId: 2),
                    .leaf(paneId: 3),
                ],
                focused: focused, zoomed: zoomed)])
    }

    /// A click on an unfocused pane's Zoom button against a host: focus and zoom go out, the
    /// layout after the focus comes back first, then the one after the zoom. The pane's frame
    /// is sampled each time the store's session changes.
    private func hostZoom(from start: SessionLayout, events: (DaemonLayoutStore) -> [(Double, () -> Void)]) -> [(time: Double, frame: CGRect)] {
        var sent: UInt64 = 0
        let store = DaemonLayoutStore { _ in
            sent += 1
            return sent
        }
        store.floatsWait = .zero
        store.receive(start)
        var targets: [(time: Double, frame: CGRect)] = [(0, Self.canvas(store.session).leaf(PaneId(2))!.frame)]
        for (time, event) in events(store) {
            event()
            let frame = Self.canvas(store.session).leaf(PaneId(2))!.frame
            if frame != targets.last!.frame { targets.append((time, frame)) }
        }
        return targets
    }

    func testTheHarnessCatchesAZoomUndoneOnTheWay() {
        let tiled = Self.canvas(Session(tabs: [Tab(id: TabId(10), root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)), second: .split(axis: .vertical, ratio: 0.5, first: .leaf(PaneId(2)), second: .leaf(PaneId(3)))), focused: PaneId(2))], activeTabId: TabId(10)))
        let start = tiled.leaf(PaneId(2))!.frame
        let full = CGRect(origin: .zero, size: Self.size)
        // What the store showed before a zoom replayed: zoomed, undone by the focus's echo,
        // zoomed again by the host's own layout.
        let frames = Self.trajectory([(0, start), (0.02, full), (0.1, start), (0.16, full)])
        XCTAssertFalse(Self.reversals(in: frames).isEmpty)
    }

    func testZoomingInAgainstAHostIsOneMotion() {
        let targets = hostZoom(from: Self.layout(revision: 1, focused: 1)) { store in
            [
                (0.02, {
                    store.apply(.focus(PaneId(2)))
                    store.apply(.toggleZoom)
                }),
                (0.10, { store.receive(Self.layout(revision: 2, focused: 2)) }),
                (0.16, { store.receive(Self.layout(revision: 3, focused: 2, zoomed: 2)) }),
                (0.20, {
                    store.acknowledge(1, failed: false)
                    store.acknowledge(2, failed: false)
                }),
            ]
        }
        XCTAssertEqual(targets.count, 2, "one target: \(targets)")
        XCTAssertEqual(targets.last?.frame, CGRect(origin: .zero, size: Self.size))
        let frames = Self.trajectory(targets)
        XCTAssertEqual(Self.reversals(in: frames), [])
        XCTAssertEqual(frames.last!.width, Self.size.width, accuracy: 0.5, "arrives")
    }

    func testZoomingOutAgainstAHostIsOneMotion() {
        let targets = hostZoom(from: Self.layout(revision: 1, focused: 2, zoomed: 2)) { store in
            [
                (0.02, { store.apply(.toggleZoom) }),
                // The echo of an earlier op, still zoomed.
                (0.08, { store.receive(Self.layout(revision: 2, focused: 2, zoomed: 2)) }),
                (0.14, { store.receive(Self.layout(revision: 3, focused: 2)) }),
                (0.18, { store.acknowledge(1, failed: false) }),
            ]
        }
        XCTAssertEqual(targets.count, 2, "one target: \(targets)")
        let frames = Self.trajectory(targets)
        XCTAssertEqual(Self.reversals(in: frames), [])
    }

    /// Critically damped: no edge passes its target and comes back.
    func testTheCanvasSpringNeverOvershoots() {
        let start = CGRect(x: 600, y: 400, width: 600, height: 400)
        let full = CGRect(origin: .zero, size: Self.size)
        for (from, to) in [(start, full), (full, start)] {
            let frames = Self.trajectory([(0, from), (0, to)])
            XCTAssertEqual(Self.reversals(in: frames), [])
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, min(from.minX, to.minX) - 0.01)
                XCTAssertLessThanOrEqual(frame.minX, max(from.minX, to.minX) + 0.01)
                XCTAssertGreaterThanOrEqual(frame.minY, min(from.minY, to.minY) - 0.01)
                XCTAssertLessThanOrEqual(frame.minY, max(from.minY, to.minY) + 0.01)
            }
        }
    }

    /// A zoom interrupted half way turns back smoothly: the edges reverse once, where the
    /// hand asked, never twice.
    func testAnInterruptedZoomTurnsBackOnce() {
        let start = CGRect(x: 600, y: 400, width: 600, height: 400)
        let full = CGRect(origin: .zero, size: Self.size)
        let frames = Self.trajectory([(0, start), (0, full), (0.12, start)])
        XCTAssertEqual(Self.reversals(in: Array(frames.prefix(Int(0.12 / Self.displayFrame) + 1))), [])
        XCTAssertEqual(Self.reversals(in: Array(frames.dropFirst(Int(0.12 / Self.displayFrame) + 2))), [])
    }
}
