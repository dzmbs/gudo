import DesignSystem
import SwiftUI

/// Hosts: daemon and SSH hosts, "Needs you" first (stub; see docs/DESIGN.md "Hosts").
struct HostsView: View {
    let directory: any HostDirectory
    var onAdd: () -> Void = {}
    var onOpen: (HostSummary) -> Void = { _ in }

    var body: some View { Text("Hosts") }
}
