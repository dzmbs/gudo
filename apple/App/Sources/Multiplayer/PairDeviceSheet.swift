import DesignSystem
import HostKit
import SwiftUI
import GudoCore

/// What Pair a Device shows for a host: a one-time code to scan, why it can't, or the device
/// that just paired.
@MainActor
@Observable
final class PairDeviceModel {
    enum Stage: Equatable {
        case loading
        /// Not connected (`canConnect`), or this device can't pair others on that host.
        case unavailable(String, canConnect: Bool)
        case showing(PairingCode)
        case expired
        case paired(String)
    }

    let hostName: String
    private(set) var stage = Stage.loading
    /// Pairings announced after this moment are the one the code was shown for.
    private let openedAt: Date

    init(hostName: String, openedAt: Date = .now) {
        self.hostName = hostName
        self.openedAt = openedAt
    }

    /// Why `session` can't make a code, if it can't.
    static func unavailableReason(_ session: MultiplayerSession?, hostName: String) -> Stage? {
        guard let session, let me = session.me else {
            return .unavailable("Connect to \(hostName) to pair a device with it.", canConnect: true)
        }
        if me.grantId != nil || !session.isOwner {
            return .unavailable("You joined \(hostName) with an invite. Only its owner's devices can pair another one.", canConnect: false)
        }
        if !session.canManageDevices {
            return .unavailable(
                "The helper on \(hostName) is too old to pair from here. Update it, or run \(Brand.daemonBinary) pair on \(hostName).",
                canConnect: false)
        }
        return nil
    }

    /// Makes a fresh code, unless the session can't.
    func makeCode(_ session: MultiplayerSession?) async {
        if let reason = Self.unavailableReason(session, hostName: hostName) {
            stage = reason
            return
        }
        stage = .loading
        guard let code = await session?.makePairingCode() else {
            stage = .unavailable("\(hostName) couldn't make a pairing code. Try again.", canConnect: false)
            return
        }
        stage = .showing(code)
    }

    /// Notices a device that paired since the code was shown, and a code that ran out.
    func refresh(_ session: MultiplayerSession?, now: Date = .now) {
        if case .paired = stage { return }
        if let session,
           let (key, _) = session.freshPairings.filter({ $0.value >= openedAt.addingTimeInterval(-5) }).max(by: { $0.value < $1.value }) {
            let device = session.devices.first { $0.device == key }
            stage = .paired(device.map(session.displayName(of:)) ?? "A new device")
            return
        }
        if case .showing(let code) = stage, Self.expiry(code) <= now {
            stage = .expired
        }
    }

    static func expiry(_ code: PairingCode) -> Date {
        Date(timeIntervalSince1970: Double(code.expiresMs) / 1000)
    }

    /// "9:41" until it expires.
    static func remaining(_ code: PairingCode, now: Date = .now) -> String {
        let seconds = max(0, Int(expiry(code).timeIntervalSince(now).rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    #if os(macOS)
    static var instruction: String { "On your iPhone or iPad, open \(Brand.name), tap Add Host, then Scan." }
    #else
    static var instruction: String { "On your other iPhone or iPad, open \(Brand.name), tap Add Host, then Scan." }
    #endif
}

/// Pair a Device: a QR code this host's daemon made for one more device of its owner. It turns
/// into the new device's name once it pairs.
struct PairDeviceSheet: View {
    let hostId: String
    private let hosts = AppModel.shared.hosts
    @Environment(\.dismiss) private var dismiss
    @State private var model: PairDeviceModel
    @State private var copied = false

    init(hostId: String) {
        self.hostId = hostId
        _model = State(initialValue: PairDeviceModel(hostName: DeviceHosts.name(hostId, hosts: AppModel.shared.hosts)))
    }

    private var session: MultiplayerSession? { DeviceHosts.session(hostId, hosts: hosts) }

    var body: some View {
        SheetScaffold(
            "Pair a Device", subtitle: model.hostName,
            primary: SheetAction("Done", identifier: "pair-device-done") { dismiss() }
        ) {
            VStack(spacing: DS.Space.l) {
                content
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .animation(DS.Motion.snappy, value: model.stage)
        }
        #if os(iOS)
        .phoneDetents([.large])
        #else
        .frame(width: 420, height: 520)
        #endif
        .task(id: session?.me?.actor.device) { await model.makeCode(session) }
        .task {
            while !Task.isCancelled {
                model.refresh(session)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: session?.freshPairings) { model.refresh(session) }
        .sensoryFeedback(DS.Haptic.success, trigger: model.stage.isPaired)
        .accessibilityIdentifier("pair-device")
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .loading:
            ProgressView()
                .frame(width: 220, height: 220)
        case .showing(let code):
            QRCodeView(text: code.qrPayload, label: "QR code to pair a device with \(model.hostName)")
                .frame(width: 220, height: 220)
                .accessibilityIdentifier("pair-device-qr")
            Text(PairDeviceModel.instruction)
                .font(DS.Font.rowTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label("Works once, for \(PairDeviceModel.remaining(code, now: context.date))", systemImage: "clock")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .monospacedDigit()
            }
            Button(action: { copy(code) }) {
                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("pair-device-copy")
            Text("A Mac pastes the link in Add Host › Ticket. Anyone with this code can control \(model.hostName), so show it only to your own devices.")
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .expired:
            status("clock.badge.xmark", tint: DS.Palette.textSecondary, title: "This code expired", message: "Codes work for 10 minutes. Make a new one when the other device is ready.")
            Button("New Code") { Task { await model.makeCode(session) } }
                .buttonStyle(.primaryGlass)
                .accessibilityIdentifier("pair-device-new-code")
        case .paired(let name):
            status("checkmark.circle.fill", tint: DS.Palette.done, title: "\(name) is paired", message: "It can open \(model.hostName) now. Rename or remove it in Devices.")
        case .unavailable(let message, let canConnect):
            status("lock", tint: DS.Palette.textSecondary, title: canConnect ? "Not Connected" : "Can't Pair from Here", message: message)
            if canConnect {
                Button("Connect") { _ = try? hosts.open(hostId) }
                    .buttonStyle(.primaryGlass)
                    .accessibilityIdentifier("pair-device-connect")
            }
        }
    }

    private func status(_ systemImage: String, tint: ChromeStyle, title: String, message: String) -> some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(tint)
                .padding(.bottom, DS.Space.xs)
            Text(title)
                .font(DS.Font.rowTitleEmphasis)
            Text(message)
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DS.Space.xl)
        .accessibilityElement(children: .combine)
    }

    private func copy(_ code: PairingCode) {
        Pasteboard.copySecret(code.link)
        withAnimation(DS.Motion.indicator) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(DS.Motion.indicator) { copied = false }
        }
    }
}

private extension PairDeviceModel.Stage {
    var isPaired: Bool { if case .paired = self { true } else { false } }
}

/// How to pair this device with a computer, in one line, for the first-run screens.
enum PairingHint {
    #if os(iOS)
    static var message: String {
        "Open \(Brand.name) on your Mac and choose Pair a Phone or iPad, or run \(Brand.commandLineTool) pair on Linux. Then scan the code."
    }
    #else
    static var message: String {
        "Run \(Brand.commandLineTool) pair on the other computer and paste the link here, or connect to any SSH host."
    }
    #endif
}

/// The host a "Pair a Device" command means: the one asked for, else the window's host, else
/// This Mac, else the first host this device owns.
enum PairDeviceTarget {
    @MainActor static func host(preferring hostId: String?, window: WindowModel?) -> String? {
        let owned = DeviceHosts.owned(AppModel.shared.hosts).map(\.id)
        if let hostId, owned.contains(hostId) { return hostId }
        if let current = window?.workspace?.hostId, owned.contains(current) { return current }
        if let mine = AppModel.shared.hosts.thisDeviceId, owned.contains(mine) { return mine }
        return owned.first
    }

    /// Whether this device owns `hostId`, so it may pair others with it.
    @MainActor static func owns(_ hostId: String) -> Bool {
        DeviceHosts.owned(AppModel.shared.hosts).contains { $0.id == hostId }
    }
}
