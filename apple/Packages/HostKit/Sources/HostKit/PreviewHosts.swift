import Foundation
import Observation
import PaneLayout

/// A host over an in-memory layout, for design fixtures and snapshots: no network, no panes.
@MainActor
@Observable
public final class PreviewConnection: HostConnection {
    public var status: ConnectionStatus
    public let layout: LocalLayoutStore
    public var isReady = true
    public var layoutStore: any LayoutStore { layout }

    /// A host with one tab per name.
    public init(tabs: [String], status: ConnectionStatus = .connected(rtt: nil)) {
        self.status = status
        layout = LocalLayoutStore()
        for (index, name) in tabs.enumerated() {
            if index > 0 { layout.apply(.newTab) }
            if let id = layout.session.activeTabId { layout.apply(.rename(id, name)) }
        }
    }

    public func makeBackend(for pane: PaneId) throws -> any PaneBackend { throw HostError.notConnected }
    public func retry() {}
    public func foreground() {}
    public func background() {}
    public func networkChanged() {}
    public func close() {}
}
