import CoreGraphics

public struct FloatId: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "float-\(rawValue)" }
}

/// Where a floating window sits, in fractions of its tab's area (`0,0` top left), so it keeps
/// its place across window sizes and on devices of different sizes (the daemon's `FloatFrame`).
public struct FloatFrame: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// Smallest side, as a fraction of the tab.
    public static let minimumSide = 0.1
    /// A new window with nothing else to go by: centred, three fifths of the tab.
    public static let standard = FloatFrame(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// `rect` (in `bounds`) as fractions of `bounds`.
    public init(_ rect: CGRect, in bounds: CGRect) {
        let boundsWidth = max(bounds.width, 1)
        let boundsHeight = max(bounds.height, 1)
        self.init(
            x: (rect.minX - bounds.minX) / boundsWidth, y: (rect.minY - bounds.minY) / boundsHeight,
            width: rect.width / boundsWidth, height: rect.height / boundsHeight)
    }

    public func rect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height,
            width: width * bounds.width, height: height * bounds.height)
    }

    /// Moved and sized to lie wholly inside the tab; nil when a value is not finite.
    public var clamped: FloatFrame? {
        guard [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        let clampedWidth = min(max(width, Self.minimumSide), 1)
        let clampedHeight = min(max(height, Self.minimumSide), 1)
        return FloatFrame(
            x: min(max(x, 0), 1 - clampedWidth), y: min(max(y, 0), 1 - clampedHeight),
            width: clampedWidth, height: clampedHeight)
    }
}

/// A floating window: a card over a tab holding one or more panes, split like a tab. Its panes
/// are one subtree of the tab's tree (where it docks back to, and how older clients show it).
public struct FloatWindow: Identifiable, Hashable, Sendable, Codable {
    public let id: FloatId
    /// Its panes in the tree's reading order.
    public var panes: [PaneId]
    public var frame: FloatFrame
    /// Stacking order within the session: higher is in front.
    public var z: UInt32
    /// In the tab's tray as a chip, instead of a card.
    public var minimized: Bool
    /// Shown over every tab of its session.
    public var pinned: Bool
    /// The host closes it once its run is done.
    public var closesWhenDone: Bool

    public init(
        id: FloatId, panes: [PaneId], frame: FloatFrame, z: UInt32,
        minimized: Bool = false, pinned: Bool = false, closesWhenDone: Bool = false
    ) {
        self.id = id
        self.panes = panes
        self.frame = frame
        self.z = z
        self.minimized = minimized
        self.pinned = pinned
        self.closesWhenDone = closesWhenDone
    }
}

extension Node {
    func isExactly(_ panes: [PaneId]) -> Bool {
        let leaves = self.panes
        return leaves.count == panes.count && Set(leaves) == Set(panes)
    }

    public func subtree(of panes: [PaneId]) -> Node? {
        if isExactly(panes) { return self }
        guard case .split(_, _, let first, let second) = self else { return nil }
        return first.subtree(of: panes) ?? second.subtree(of: panes)
    }

    /// The tree without the leaves `floating` names; nil when every leaf floats.
    public func removing(where floating: (PaneId) -> Bool) -> Node? {
        switch self {
        case .leaf(let pane):
            return floating(pane) ? nil : self
        case .split(let axis, let ratio, let first, let second):
            switch (first.removing(where: floating), second.removing(where: floating)) {
            case (let keptFirst?, let keptSecond?): return .split(axis: axis, ratio: ratio, first: keptFirst, second: keptSecond)
            case (let keptFirst, let keptSecond): return keptFirst ?? keptSecond
            }
        }
    }

    /// Takes out the subtree (never the root) whose leaves are exactly `panes`; its parent
    /// collapses into the sibling. Nil when there is none.
    func takingSubtree(_ panes: [PaneId]) -> (rest: Node, taken: Node)? {
        guard case .split(let axis, let ratio, let first, let second) = self else { return nil }
        if first.isExactly(panes) { return (second, first) }
        if second.isExactly(panes) { return (first, second) }
        if let (rest, taken) = first.takingSubtree(panes) {
            return (.split(axis: axis, ratio: ratio, first: rest, second: second), taken)
        }
        if let (rest, taken) = second.takingSubtree(panes) {
            return (.split(axis: axis, ratio: ratio, first: first, second: rest), taken)
        }
        return nil
    }

    /// The leaves of the largest subtree around `pane` whose leaves all lie in `within`.
    func contiguous(around pane: PaneId, within: Set<PaneId>) -> [PaneId] {
        let leaves = panes
        guard leaves.contains(pane) else { return [] }
        if leaves.allSatisfy(within.contains) { return leaves }
        guard case .split(_, _, let first, let second) = self else { return [] }
        let inFirst = first.contiguous(around: pane, within: within)
        return inFirst.isEmpty ? second.contiguous(around: pane, within: within) : inFirst
    }
}
