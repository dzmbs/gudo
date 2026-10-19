import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Handoff (docs/APP-ARCHITECTURE.md "Windows"): every window advertises what it shows (host,
/// tab, pane) as an `NSUserActivity`, and continues activities from the owner's other devices
/// and from tabs dragged out of another window. A host this device has not paired is named,
/// with Add Host offered.
struct HandoffActivity: ViewModifier {
    let model: WindowModel
    let onContinue: (HandoffPayload) -> Void

    func body(content: Content) -> some View {
        content
            .userActivity(HandoffPayload.activityType, element: HandoffPayload.current(in: model)) { payload, activity in
                activity.title = payload.title
                activity.isEligibleForHandoff = payload.isContinuable
                activity.isEligibleForSearch = false
                #if os(iOS)
                activity.isEligibleForPrediction = false
                #endif
                activity.addUserInfoEntries(from: payload.userInfo())
                activity.requiredUserInfoKeys = [HandoffPayload.userInfoKey]
            }
            .onContinueUserActivity(HandoffPayload.activityType) { activity in
                guard let payload = HandoffPayload(userInfo: activity.userInfo) else { return }
                onContinue(payload)
            }
            .alert(
                missingTitle,
                isPresented: Binding(get: { model.handoffMissing != nil }, set: { if !$0 { model.handoffMissing = nil } })
            ) {
                Button("Add Host…") { model.addMissingHost() }
                    .accessibilityIdentifier("handoff-add-host")
                Button("Not Now", role: .cancel) { model.handoffMissing = nil }
            } message: {
                Text(missingMessage)
            }
    }

    private var missingTitle: String {
        guard let payload = model.handoffMissing else { return "" }
        return "\(payload.hostName) isn't set up on \(WindowModel.deviceName.replacingOccurrences(of: "This ", with: "this "))"
    }

    private var missingMessage: String {
        guard let payload = model.handoffMissing else { return "" }
        if let ssh = payload.ssh {
            return "You were working on \(payload.hostName) (\(ssh)) on \(payload.device). Add it here to pick up where you left off."
        }
        return "You were working on \(payload.hostName) on \(payload.device). Pair this device with it (a pairing ticket from the host, or its QR code) to pick up where you left off."
    }
}

#if os(iOS)
import UIKit

/// Tells the window model which scene it is in.
struct SceneReader: UIViewRepresentable {
    let model: WindowModel

    final class Probe: UIView {
        weak var model: WindowModel?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { model?.scene = scene }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}
}

/// A tab row or chip as a drag: its reference as text (reordering within the host) and, on
/// iPad, the window activity, so dropping it outside the window opens it in a new window.
enum TabDrag {
    @MainActor
    static func provider(for ref: TabRef, in model: WindowModel) -> NSItemProvider {
        let provider = NSItemProvider(object: ref.description as NSString)
        if let workspace = model.workspace(ofGroup: ref.hostId), let tab = workspace.session.tabs.first(where: { $0.id == ref.tab }) {
            let record = ref.hostId == HostGroups.localId ? nil : model.app.hosts.record(ref.hostId)
            let payload = HandoffPayload(
                kind: record == nil ? .local : record?.kind == .ssh ? .ssh : .daemon,
                hostId: record?.id, hostName: record?.name ?? WindowModel.deviceName,
                daemonId: record?.daemonId, ssh: record?.ssh?.display,
                tab: tab.id.rawValue, pane: tab.focused.rawValue,
                origin: HandoffPayload.installation, device: WindowModel.deviceName)
            let activity = NSUserActivity(activityType: HandoffPayload.activityType)
            activity.title = workspace.title(of: tab)
            activity.addUserInfoEntries(from: payload.userInfo())
            provider.registerObject(activity, visibility: .all)
        }
        return provider
    }
}
#endif

extension View {
    /// Drag a tab: reorder within its host; on iPad, drop it outside the window for a new one.
    @ViewBuilder
    func tabDrag(_ ref: TabRef, model: WindowModel) -> some View {
        #if os(iOS)
        onDrag { TabDrag.provider(for: ref, in: model) }
        #else
        draggable(ref.description)
        #endif
    }
}

/// UI tests only (`-windowProbe YES`): what the window shows and advertises, as JSON in an
/// accessibility value: its width bucket, host, tab and focused pane, the Handoff payload, the
/// last continued payload, and how many cols × rows overlays a layout change showed.
struct WindowProbe: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        if WindowProbe.isEnabled {
            HStack(spacing: 0) {
                #if DEBUG
                // Test controls: narrow / restore the window's content, bring window 1 forward.
                Button("narrow") { model.debugWidth = 420 }
                    .accessibilityIdentifier("debug-narrow")
                Button("wide") { model.debugWidth = nil }
                    .accessibilityIdentifier("debug-wide")
                #if os(iOS)
                Button("front") { model.bringWindowForward(0) }
                    .accessibilityIdentifier("debug-front-0")
                #endif
                #endif
                Text(value)
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .accessibilityElement()
                    .accessibilityLabel("window")
                    .accessibilityValue(value)
                    .accessibilityIdentifier("window-probe")
            }
            .font(.system(size: 8))
            .frame(height: 24)
            .opacity(0.05)
        }
    }

    static let isEnabled = UserDefaults.standard.bool(forKey: "windowProbe")

    private var value: String {
        let workspace = model.workspace
        var fields: [String: String] = [
            "bucket": model.widthBucket?.rawValue ?? "",
            "host": model.currentGroupId,
            "tab": workspace?.session.activeTabId.map { String($0.rawValue) } ?? "",
            "pane": workspace?.focusedPane.map { String($0.rawValue) } ?? "",
            "overlays": String(model.resizeOverlayShows),
            "windows": String(model.app.openWindows.count),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let payload = HandoffPayload.current(in: model), let data = try? encoder.encode(payload) {
            fields["handoff"] = String(decoding: data, as: UTF8.self)
        }
        if let missing = model.handoffMissing { fields["missing"] = missing.hostName }
        if let result = model.continuedResult { fields["continued"] = result }
        let data = (try? encoder.encode(fields)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
