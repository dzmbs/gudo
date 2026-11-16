import GudoCore

enum PaneSizingSource: Equatable, Sendable {
    case peer(UInt64)
    case anotherWindow
    case fixed
    case shared

    /// Who decides the pane's size when it is not this view: nil while nobody else does. With no
    /// owner, only a fixed grid, or the smallest of several clients' grids, is someone else's.
    static func resolve(_ state: PaneSizing, myPeer: UInt64?, policy: SizePolicy, isLocalDriver: Bool, othersConnected: Bool) -> Self? {
        if let peer = state.peer {
            guard let myPeer else { return nil }
            if peer != myPeer { return .peer(peer) }
            return isLocalDriver ? nil : .anotherWindow
        }
        switch policy {
        case .fixed: return .fixed
        case .smallest: return othersConnected ? .shared : nil
        case .lastActive, .lastInput, .followLease: return nil
        }
    }
}
