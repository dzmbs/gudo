import DesignSystem
import HostKit
import SwiftUI
import GudoCore

/// Settings › Devices: every host this device paired with, each opening its devices.
struct DevicesSettingsSection: View {
    private let hosts = AppModel.shared.hosts

    var body: some View {
        let owned = DeviceHosts.owned(hosts)
        Section {
            if owned.isEmpty {
                Text("No paired hosts. Hosts you pair with list their devices here.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(owned, id: \.id) { host in
                NavigationLink(value: SettingsPage.hostDevices(host.id)) {
                    LabeledContent {
                        Text(summary(host.id))
                    } label: {
                        Label(host.name, systemImage: "server.rack")
                    }
                }
                .accessibilityIdentifier("devices-host-\(host.id)")
            }
        } header: {
            Text("Paired Devices")
        } footer: {
            Text("Every device that can open a host as its owner, and every guest. Remove any you don't recognise.")
        }
        .settingAnchor("devices")
    }

    private func summary(_ id: String) -> String {
        guard let session = DeviceHosts.session(id, hosts: hosts), session.isOwner, !session.devices.isEmpty else {
            return DeviceHosts.session(id, hosts: hosts) == nil ? "Not connected" : ""
        }
        let owners = session.ownerDevices.filter { !$0.revoked }.count
        let guests = session.guestDevices.filter { !$0.revoked }.count
        let devices = owners == 1 ? "1 device" : "\(owners) devices"
        return guests == 0 ? devices : "\(devices) · \(guests == 1 ? "1 guest" : "\(guests) guests")"
    }
}

/// The hosts whose devices this device manages, and their live sessions.
enum DeviceHosts {
    struct Host {
        var id: String
        var name: String
    }

    @MainActor static func owned(_ hosts: HostsModel) -> [Host] {
        if LaunchOptions.mock { return [Host(id: "studio", name: "studio")] }
        return hosts.records
            .filter { $0.kind == .daemon && !$0.isGuest }
            .map { Host(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor static func session(_ id: String, hosts: HostsModel) -> MultiplayerSession? {
        if LaunchOptions.mock { return MockMultiplayer.session }
        return (hosts.connection(id) as? DaemonConnection)?.multiplayer
    }

    @MainActor static func name(_ id: String, hosts: HostsModel) -> String {
        LaunchOptions.mock ? "studio" : hosts.record(id)?.name ?? "this host"
    }
}

/// One host's devices: connects it if needed, then lists its owner devices and guests.
struct HostDevicesView: View {
    let hostId: String
    private let hosts = AppModel.shared.hosts
    @State private var removing: DeviceInfo?

    var body: some View {
        let name = DeviceHosts.name(hostId, hosts: hosts)
        Group {
            if let session = DeviceHosts.session(hostId, hosts: hosts), session.me != nil {
                if session.isOwner {
                    List {
                        HostAlertsSection(session: session)
                        DevicesSections(session: session, hostName: name, removing: $removing)
                    }
                    .chromeGrouped()
                    .modifier(RemoveDeviceDialog(session: session, hostName: name, device: $removing))
                    .refreshable { await session.refreshGrants() }
                    .task { await session.refreshGrants() }
                } else {
                    EmptyState("Owner Devices Only", systemImage: "lock", message: "You joined \(name) with an invite. Only its owner sees and removes devices.") {
                        EmptyView()
                    }
                }
            } else if DeviceHosts.session(hostId, hosts: hosts) != nil {
                ProgressView("Connecting to \(name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState("Not Connected", systemImage: "bolt.horizontal.circle", message: "Connect to \(name) to see the devices paired with it.") {
                    Button("Connect") { _ = try? hosts.open(hostId) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("devices-connect")
                }
            }
        }
        .navigationTitle("\(name) Devices")
        .accessibilityIdentifier("host-devices")
    }
}

/// Owner devices and guests with Remove, shared by Settings › Devices and Access & Grants.
struct DevicesSections: View {
    let session: MultiplayerSession
    let hostName: String
    @Binding var removing: DeviceInfo?

    var body: some View {
        Section {
            ForEach(session.ownerDevices, id: \.device) { row($0) }
            if session.ownerDevices.isEmpty {
                Text("Loading devices…").foregroundStyle(DS.Palette.textSecondary)
            }
        } header: {
            SectionTitle("Owner Devices", count: session.ownerDevices.filter { !$0.revoked }.count)
        } footer: {
            Text("Each paired with a pairing code and has full control of \(hostName).")
        }
        .chromeRows()

        if !session.guestDevices.isEmpty {
            Section {
                ForEach(session.guestDevices, id: \.device) { row($0) }
            } header: {
                SectionTitle("Guests", count: session.guestDevices.filter { !$0.revoked }.count)
            } footer: {
                Text("Joined with an invite link. Removing a guest keeps their device out; processes they started keep running.")
            }
            .chromeRows()
        }
    }

    private func row(_ device: DeviceInfo) -> some View {
        DeviceRow(
            device: device, name: session.displayName(of: device), deviceClass: deviceClass(device),
            isMe: session.isThisDevice(device), pairedNow: session.freshPairings[device.device],
            onRemove: session.canRemove(device) ? { removing = device } : nil)
            .swipeActions {
                if session.canRemove(device) {
                    // Red, not `.destructive`: the row stays until the removal is confirmed.
                    Button("Remove") { removing = device }
                        .tint(.red)
                }
            }
            .contextMenu {
                Button("Copy Device Key", systemImage: "doc.on.doc") { Pasteboard.copy(device.device) }
                if session.canRemove(device) {
                    Button("Remove…", systemImage: "minus.circle", role: .destructive) { removing = device }
                }
            }
    }

    private func deviceClass(_ device: DeviceInfo) -> DeviceClass? {
        session.peers.values.first { $0.actor.device == device.device }?.device
    }
}

/// What the host says the owner must act on, in its own words, above everything else.
struct HostAlertsSection: View {
    let session: MultiplayerSession

    var body: some View {
        if !session.hostAlerts.isEmpty {
            Section {
                ForEach(session.hostAlerts, id: \.key) { alert in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(DS.Palette.attention)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.title)
                                .font(DS.Font.rowTitleEmphasis)
                            Text(alert.body)
                                .font(DS.Font.rowSubtitle)
                                .foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Date(timeIntervalSince1970: Double(alert.atMs) / 1000), format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(DS.Font.meta)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("host-alert")
                }
            }
            .chromeRows()
        }
    }
}

/// Removing a device, confirmed: what it ends and that only a new pairing code undoes it.
struct RemoveDeviceDialog: ViewModifier {
    let session: MultiplayerSession
    let hostName: String
    @Binding var device: DeviceInfo?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(device.map(session.displayName(of:)) ?? "")?",
            isPresented: Binding(get: { device != nil }, set: { if !$0 { device = nil } }),
            titleVisibility: .visible, presenting: device
        ) { device in
            Button("Remove Device", role: .destructive) { remove(device) }
        } message: { device in
            Text(Self.message(device, name: session.displayName(of: device), hostName: hostName))
        }
    }

    private func remove(_ device: DeviceInfo) {
        let name = session.displayName(of: device)
        Task {
            if await session.removeDevice(device) != nil {
                ActiveWindow.model?.toasts.show(Toast("\(name) was removed", systemImage: "minus.circle", style: .success))
            }
        }
    }

    static func message(_ device: DeviceInfo, name: String, hostName: String) -> String {
        device.kind == .owner
            ? "\(name) is signed out of \(hostName) now and every invite it created stops working. It can only come back with a new pairing code."
            : "\(name) is disconnected now and can't rejoin from this device. Processes they started keep running."
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let name: String
    let deviceClass: DeviceClass?
    let isMe: Bool
    /// Set when it paired while this session ran.
    let pairedNow: Date?
    let onRemove: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the accessibility sizes the parts stack, so the name and date are never squeezed.
        let large = typeSize.isAccessibilitySize
        let row = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s)) : AnyLayout(HStackLayout(spacing: DS.Space.m))
        let title = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs)) : AnyLayout(HStackLayout(spacing: DS.Space.row))
        row {
            Image(systemName: symbol)
                .foregroundStyle(pairedNow != nil ? DS.Palette.attention : DS.Palette.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                title {
                    Text(name)
                        .font(pairedNow != nil ? DS.Font.rowTitleEmphasis : DS.Font.rowTitle)
                        .lineLimit(large ? 3 : 1)
                    HStack(spacing: DS.Space.row) {
                        if isMe { badge("This Device", tint: DS.Palette.textSecondary) }
                        if pairedNow != nil { badge("New", tint: DS.Palette.attention) }
                    }
                }
                Text(Self.when(device))
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                Text(groupedHex(device.device))
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !large { Spacer(minLength: DS.Space.s) }
            if device.revoked {
                Text("Removed").font(DS.Font.badge).foregroundStyle(DS.Palette.error)
            } else if device.connected > 0 {
                HStack(spacing: 4) {
                    Circle().fill(DS.Palette.done).frame(width: 7, height: 7)
                    Text("Connected").font(DS.Font.meta).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove…", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(QuietButtonStyle())
                .help("Remove…")
                .accessibilityIdentifier("remove-device-\(device.device.prefix(8))")
            }
        }
        .padding(.vertical, 2)
        .opacity(device.revoked ? 0.6 : 1)
        // One element in words (not the glyph and the hex key), Remove as its action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if let onRemove { Button("Remove…", action: onRemove) }
        }
        .accessibilityIdentifier("device-\(device.device.prefix(8))")
    }

    private var accessibilityLabel: String {
        var parts = [name]
        if isMe { parts.append("this device") }
        if pairedNow != nil { parts.append("new") }
        parts.append(Self.when(device))
        if device.revoked { parts.append("removed") } else if device.connected > 0 { parts.append("connected") }
        return parts.joined(separator: ", ")
    }

    private var symbol: String {
        guard device.kind == .owner else { return "person.crop.circle" }
        return switch deviceClass {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .desktop: "laptopcomputer"
        case .terminal: "terminal"
        case .unknown, nil: "laptopcomputer.and.iphone"
        }
    }

    private func badge(_ text: String, tint: ChromeStyle) -> some View {
        Text(text)
            .font(DS.Font.badge)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(DS.Palette.selectedFill, in: .capsule)
    }

    /// "Paired today at 14:32", "Joined 3 Oct 2026 at 09:10".
    static func when(_ device: DeviceInfo, now: Date = .now, calendar: Calendar = .current) -> String {
        let verb = device.kind == .owner ? "Paired" : "Joined"
        let date = device.pairedAt
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "\(verb) today at \(time)" }
        return "\(verb) \(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }
}
