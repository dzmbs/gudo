import DesignSystem
import SwiftUI

/// Add a host: type user@host, paste a ticket, or scan a QR code (stub).
struct PairingSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case ssh, ticket, scan
        var id: String { rawValue }
    }

    let directory: any HostDirectory
    var initialMode: Mode = .ssh

    var body: some View { Text("Pairing") }
}
