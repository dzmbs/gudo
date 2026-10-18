import CoreGraphics

/// Identifies a pane (one terminal) within a session. Allocated by the layout store: locally by
/// `Session`, by the daemon once layouts live there.
public struct PaneId: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "pane-\(rawValue)" }
}

/// The direction a split lays out its children: `horizontal` puts `first` left of `second` (a
/// vertical divider, "split right"); `vertical` puts `first` above `second` ("split down").
public enum Axis: String, Hashable, Sendable, Codable {
    case horizontal, vertical
}

public enum Direction: String, Hashable, Sendable, Codable, CaseIterable {
    case left, right, up, down

    public var axis: Axis {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// Right and down point towards a split's `second` child.
    var isForward: Bool { self == .right || self == .down }
}

/// A tab's split tree.
public indirect enum Node: Hashable, Sendable, Codable {
    case leaf(PaneId)
    /// `ratio` is `first`'s share of the split's extent along `axis`, in (0, 1).
    case split(axis: Axis, ratio: Double, first: Node, second: Node)

    /// Ratios are clamped so that no divider drag or resize can collapse a child.
    public static let ratioRange = 0.1...0.9

    /// Every pane, in reading order (first before second).
    public var panes: [PaneId] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    public func contains(_ pane: PaneId) -> Bool {
        switch self {
        case .leaf(let leaf): leaf == pane
        case .split(_, _, let first, let second): first.contains(pane) || second.contains(pane)
        }
    }

    /// Each pane's rectangle when the tree fills `rect`.
    public func frames(in rect: CGRect) -> [PaneId: CGRect] {
        switch self {
        case .leaf(let pane):
            return [pane: rect]
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
        }
    }

    /// Splits `rect` along `axis`, giving `ratio` of it to the first part.
    public static func divide(_ rect: CGRect, axis: Axis, ratio: Double) -> (first: CGRect, second: CGRect) {
        let (slice, remainder) = switch axis {
        case .horizontal: rect.divided(atDistance: rect.width * ratio, from: .minXEdge)
        case .vertical: rect.divided(atDistance: rect.height * ratio, from: .minYEdge)
        }
        return (slice, remainder)
    }

    /// Replaces the leaf for `pane` with `node`.
    func replacing(_ pane: PaneId, with node: Node) -> Node {
        switch self {
        case .leaf(let leaf):
            leaf == pane ? node : self
        case .split(let axis, let ratio, let first, let second):
            .split(axis: axis, ratio: ratio, first: first.replacing(pane, with: node), second: second.replacing(pane, with: node))
        }
    }

    /// Removes `pane`; its sibling takes the parent split's place. Returns nil when this node is
    /// that pane, otherwise the new tree and the pane nearest to where the removed one was (the
    /// sibling's leaf on the side that faced it), which is where focus should go.
    func removing(_ pane: PaneId) -> (node: Node, nearest: PaneId)? {
        guard case .split(let axis, let ratio, let first, let second) = self else { return nil }
        if first == .leaf(pane) { return (second, second.panes.first!) }
        if second == .leaf(pane) { return (first, first.panes.last!) }
        if first.contains(pane), let (node, nearest) = first.removing(pane) {
            return (.split(axis: axis, ratio: ratio, first: node, second: second), nearest)
        }
        if second.contains(pane), let (node, nearest) = second.removing(pane) {
            return (.split(axis: axis, ratio: ratio, first: first, second: node), nearest)
        }
        return nil
    }

    /// One step from a split towards a pane.
    struct Step {
        var axis: Axis
        var inFirst: Bool
    }

    /// The splits from the root down to `pane`, or nil if it is not in this tree.
    func path(to pane: PaneId) -> [Step]? {
        switch self {
        case .leaf(let leaf):
            return leaf == pane ? [] : nil
        case .split(let axis, _, let first, let second):
            if let rest = first.path(to: pane) { return [Step(axis: axis, inFirst: true)] + rest }
            if let rest = second.path(to: pane) { return [Step(axis: axis, inFirst: false)] + rest }
            return nil
        }
    }

    /// Adds `delta` to the ratio of the split `depth` steps down the path to `pane`.
    func adjustingRatio(towards pane: PaneId, depth: Int, by delta: Double) -> Node {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard depth > 0 else {
            let clamped = min(max(ratio + delta, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            return .split(axis: axis, ratio: clamped, first: first, second: second)
        }
        return first.contains(pane)
            ? .split(axis: axis, ratio: ratio, first: first.adjustingRatio(towards: pane, depth: depth - 1, by: delta), second: second)
            : .split(axis: axis, ratio: ratio, first: first, second: second.adjustingRatio(towards: pane, depth: depth - 1, by: delta))
    }
}
