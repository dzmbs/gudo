import GudoCore

enum PaneSizingSource: Equatable, Sendable {
    case peer(UInt64)
    case anotherWindow
    case fixed
    case shared

    /// Who decides the pane's size when it is not this view: nil while nobody else does. With no
    /// owner, only a fixed grid, or the smallest of several clients' grids, is someone else's.
    /// Another client or window that sized the pane to this view's own grid (`matchesOwnGrid`)
    /// changes nothing here, so it is not shown either.
    static func resolve(_ state: PaneSizing, myPeer: UInt64?, policy: SizePolicy, isLocalDriver: Bool,
                        othersConnected: Bool, matchesOwnGrid: Bool = false) -> Self? {
        if let peer = state.peer {
            guard let myPeer, !matchesOwnGrid else { return nil }
            if peer != myPeer { return .peer(peer) }
            return isLocalDriver ? nil : .anotherWindow
        }
        switch policy {
        case .fixed: return .fixed
        case .smallest: return othersConnected ? .shared : nil
        case .lastActive, .lastInput, .followLease: return nil
        }
    }

    /// The strip's words for a pane another device sized: that device as it named itself, else
    /// its kind, told apart from this device's own kind.
    static func peerLabel(name: String, device: DeviceClass, myDevice: DeviceClass?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The helper calls an owner device that never said its name "owner".
        if !trimmed.isEmpty, trimmed != "owner" { return "Sized for \(trimmed)" }
        let kind: String? = switch device {
        case .phone: "iPhone"
        case .tablet: "iPad"
        case .desktop: "Mac"
        case .terminal, .unknown: nil
        }
        guard let kind else { return "Sized for another device" }
        return device == myDevice ? "Sized for another \(kind)" : "Sized for \(kind)"
    }
}
