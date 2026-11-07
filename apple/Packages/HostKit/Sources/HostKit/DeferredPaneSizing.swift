nonisolated public protocol DeferredPaneSizing: PaneBackend {
    var isSizeDeferred: Bool { get }
    func deferSize()
    /// Rolls back a failed presentation change without claiming or proposing a size.
    func cancelSizeDeferral()
    /// Returns false when the viewport was deferred rather than proposed.
    func layoutViewport(
        cols: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> Bool
}
