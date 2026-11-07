import GudoCore

enum PaneSizingSource: Equatable, Sendable {
    case peer(UInt64)
    case anotherWindow
    case fixed
    case shared

    static func resolve(_ state: PaneSizing, myPeer: UInt64?, policy: SizePolicy, isLocalDriver: Bool) -> Self? {
        if let peer = state.peer {
            if peer != myPeer { return .peer(peer) }
            return isLocalDriver ? nil : .anotherWindow
        }
        if case .fixed = policy { return .fixed }
        return .shared
    }
}
