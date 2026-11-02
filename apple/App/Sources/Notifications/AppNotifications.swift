import DesignSystem
import Foundation
import HostKit
import NotifyKit
import os
import PaneLayout
import PushCrypto
import GudoCore
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Notifications while the app is alive: every daemon's attention feed (agent blocked or done,
/// a long command finished unseen) becomes a local notification when the app is not in front,
/// with Approve / Deny / Open wired to the signed `decide` (local) or `sendPushAction` (push).
/// Remote push registration runs only in builds with the push entitlement (`PUSH_YES`).
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "notify")

    /// Whether a window of the app is active (set from the scene phase).
    var appIsActive = true
    var prefs = NotificationPrefs.load() {
        didSet { prefs.save() }
    }
    /// The APNs token, once registered (push builds only).
    private(set) var apnsToken: Data?

    private var hosts: HostsModel { AppModel.shared.hosts }
    private var subscriptions: [String: (connection: ObjectIdentifier, token: UUID)] = [:]
    private(set) var unseen: [String: UInt32] = [:]
    private var installed = false
    /// Where permission is read and asked for (a fake in tests).
    var authorizer: any NotificationAuthorizing = SystemNotificationAuthorizer()
    /// Attention notes, posted one at a time, newest per pane (a burst is not a task per item).
    private lazy var notes = NoteQueue<AttentionNote> { [weak self] note in await self?.post(note) }
    private lazy var security = HostSecurityNotifier { [weak self] in await self?.isAuthorized() ?? false }

    /// Registers categories and the delegate (before launch finishes, so actions on a cold
    /// start reach the handler) and starts following the hosts' attention feeds.
    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationCategories.all)
        hosts.onFirstPairing = { [weak self] _ in
            Task { await self?.askAfterPairing() }
        }
        follow()
    }

    /// Whether notes may be posted. Never asks: a note fires while the app is away, where a
    /// permission prompt would come out of nowhere.
    private func isAuthorized() async -> Bool {
        switch await authorizer.status() {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// Asks for permission right after the first host is paired, Apple's "ask in context": the
    /// user has just set up the thing that will notify them. Asked once (only while undecided);
    /// `-notificationPrompt NO` (and the UI tests' own pairing hooks) skip it.
    func askAfterPairing(allowed: Bool = LaunchOptions.asksNotificationPermission) async {
        guard allowed, await authorizer.status() == .notDetermined else { return }
        let granted = await authorizer.request()
        Self.log.info("notification permission asked after pairing: \(granted ? "granted" : "not granted", privacy: .public)")
    }

    // MARK: Following the attention feeds

    /// Subscribes to every daemon connection's workspace pushes, now and as hosts connect.
    private func follow() {
        var connectedIds: Set<String> = []
        for (id, connection) in hosts.connections {
            guard let daemon = connection as? DaemonConnection else { continue }
            connectedIds.insert(id)
            let identity = ObjectIdentifier(daemon)
            if subscriptions[id]?.connection == identity { continue }
            let token = daemon.workspaceEvents.observe { [weak self, weak daemon] event in
                guard let self, let daemon else { return }
                self.handle(event, hostId: id, daemon: daemon)
            }
            daemon.multiplayer.onKnockArrived = { [weak self] knock in
                Task { await self?.postKnock(knock, hostId: id) }
            }
            daemon.multiplayer.onDevicePaired = { [weak self, weak daemon] device in
                guard let self, let daemon else { return }
                let hostName = hosts.record(id)?.name ?? "your host"
                Task { await self.security.post(device, hostId: id, hostName: hostName, session: daemon.multiplayer) }
            }
            daemon.multiplayer.onHostAlert = { [weak self] alert in
                guard let self else { return }
                let hostName = hosts.record(id)?.name ?? "Your host"
                Task { await self.security.post(alert, hostId: id, hostName: hostName) }
            }
            subscriptions[id] = (identity, token)
        }
        for id in subscriptions.keys where !connectedIds.contains(id) { subscriptions[id] = nil }
        withObservationTracking {
            _ = hosts.connections.keys.sorted()
        } onChange: {
            Task { @MainActor in AppNotifications.shared.follow() }
        }
    }

    private func handle(_ event: WorkspaceEvent, hostId: String, daemon: DaemonConnection) {
        guard case .attention(let update) = event else { return }
        switch update {
        case .added(let item, let count):
            unseen[hostId] = count
            updateBadge()
            guard !item.seen, !item.whileViewed else { return }
            Task {
                // The pane's agent state comes on another stream and can land just after the
                // item: an approval waits for its options, or it would lose Approve / Deny.
                if case .agentBlocked(_, let request?) = item.kind {
                    await Self.settle { Self.blockedOptions(daemon.meta[PaneId(item.paneId)]?.agent, request: request) != nil }
                }
                guard let note = note(for: item, hostId: hostId, daemon: daemon) else { return }
                notes.enqueue(note, key: LocalNotifications.identifier(hostId: note.hostId, paneId: note.paneId))
            }
        case .seen(_, let count):
            unseen[hostId] = count
            updateBadge()
            if count == 0 { clearDelivered(hostId: hostId) }
        }
    }

    /// The daemon's item as a note: approval options come from the pane's agent state.
    func note(for item: AttentionItem, hostId: String, daemon: DaemonConnection) -> AttentionNote? {
        let drive: DriveRequestInfo? = if case .agentBlocked(_, let request?) = item.kind {
            daemon.approvals.drives[request]
        } else {
            nil
        }
        return Self.note(for: item, hostId: hostId, hostName: hosts.record(hostId)?.name ?? "Host",
                         agentState: daemon.meta[PaneId(item.paneId)]?.agent, drive: drive)
    }

    /// The note for `item`. A drive request (an agent asking to drive one of the user's panes)
    /// is titled with what it wants and answers with its fixed options: Approve allows once,
    /// never "for this pane". Pure, for tests.
    static func note(
        for item: AttentionItem, hostId: String, hostName: String, agentState: AgentStatus?, drive: DriveRequestInfo?
    ) -> AttentionNote {
        let kind: AttentionNote.Kind
        var agent: String?
        switch item.kind {
        case .agentBlocked(let name, let request?) where drive?.id == request:
            agent = AgentKind(name).title
            if let drive {
                kind = .approval(requestId: request, approve: .init(id: drive.allowOnce, label: "Allow once"),
                                 deny: .init(id: drive.deny, label: "Deny"))
                return AttentionNote(hostId: hostId, hostName: hostName, itemId: item.id, paneId: item.paneId,
                                     kind: kind, title: drive.title, body: drive.action, agent: agent)
            }
            kind = .blocked
        case .agentBlocked(let name, let request):
            agent = AgentKind(name).title
            if let request, case .blocked(_, _, let options) = agentState?.state, !options.isEmpty {
                let approve = options.first { Self.isAllow($0.label) } ?? options.first
                let deny = options.first { Self.isDeny($0.label) } ?? options.last
                kind = .approval(
                    requestId: request,
                    approve: approve.map { .init(id: $0.id, label: $0.label) },
                    deny: deny.flatMap { $0.id == approve?.id ? nil : .init(id: $0.id, label: $0.label) })
            } else {
                kind = .blocked
            }
        case .agentDone(let name):
            agent = AgentKind(name).title
            kind = .done
        case .agentFailed(let name):
            agent = AgentKind(name).title
            kind = .failed
        case .commandFinished:
            kind = .command
        }
        // An agent's item is titled by its kind ("Approval needed"); the agent's name is in the
        // subtitle already, where the daemon's title would repeat it lowercased ("claude needs you").
        return AttentionNote(hostId: hostId, hostName: hostName, itemId: item.id, paneId: item.paneId, kind: kind,
                             title: agent == nil ? item.title : "", body: item.body, agent: agent)
    }

    /// The options of the request an agent is blocked on, once its state says so.
    static func blockedOptions(_ agent: AgentStatus?, request: UInt64) -> [DecisionOption]? {
        guard case .blocked(request, _, let options)? = agent?.state, !options.isEmpty else { return nil }
        return options
    }

    /// Waits until `ready` holds, checking every 50 ms for at most `limit`.
    static func settle(limit: Duration = .seconds(2), _ ready: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func isAllow(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["allow", "yes", "approve", "accept", "proceed"].contains { lower.contains($0) }
    }

    static func isDeny(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["deny", "no", "reject", "decline", "cancel"].contains { lower.hasPrefix($0) || lower.contains(" \($0)") }
    }

    /// Posts a note if the preferences and the permission allow it and the app is not in front.
    func post(_ note: AttentionNote) async {
        guard LocalNotifications.shouldPost(note, prefs: prefs, appIsActive: appIsActive), await isAuthorized() else { return }
        let request = UNNotificationRequest(
            identifier: LocalNotifications.identifier(hostId: note.hostId, paneId: note.paneId),
            content: LocalNotifications.content(for: note), trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            Self.log.info("posted \(note.pushKind.rawValue, privacy: .public) host=\(note.hostId, privacy: .public) pane=\(note.paneId)")
        } catch {
            Self.log.error("posting failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Someone knocks on a host this device owns: a time-sensitive note that opens the Inbox,
    /// where they are let in or turned away. In front, the banner over the terminal says it.
    func postKnock(_ knock: Knock, hostId: String) async {
        guard !appIsActive, await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(knock.name) wants to join"
        content.body = "\(hosts.record(hostId)?.name ?? "Your host") · their link offers \(roleWords(knock.roles)). Open to let them in or turn them away."
        content.threadIdentifier = hostId
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.userInfo = [Self.knockHostKey: hostId]
        let request = UNNotificationRequest(identifier: "knock-\(hostId)-\(knock.knockId)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        Self.log.info("posted knock host=\(hostId, privacy: .public)")
    }

    nonisolated static let knockHostKey = "knockHost"

    private func clearDelivered(hostId: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == hostId }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private func updateBadge() {
        let total = unseen.values.reduce(0) { $0 + Int($1) }
        UNUserNotificationCenter.current().setBadgeCount(total)
    }

    /// An item answered from its notification is seen on every device, and the badge takes the
    /// daemon's new count. A push's host is found by its daemon id; without a live connection
    /// the feed catches up when it is back.
    func markAnswered(hostId: String?, daemonId: String?, itemId: UInt64) async {
        let id = hostId ?? hosts.records.first { $0.daemonId?.lowercased() == daemonId?.lowercased() }?.id
        guard let id, let daemon = hosts.connection(id) as? DaemonConnection, daemon.status.isLive else { return }
        await daemon.workspace.markSeen([itemId])
        setUnseen(UInt32(max(0, daemon.workspace.unseen)), hostId: id)
    }

    /// A host's unseen count from the daemon's own answer (after marking items seen).
    func setUnseen(_ count: UInt32, hostId: String) {
        unseen[hostId] = count
        updateBadge()
        if count == 0 { clearDelivered(hostId: hostId) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // In front, the terminal and the Inbox show it already; keep it in the list only.
        [.list]
    }

    /// The completion handler goes back on the main thread: UIKit asserts it there (it updates
    /// the app switcher snapshot), and the `async` form of this method would call it from the
    /// concurrency pool once the action's work is done, aborting the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let isKnock = content.userInfo[Self.knockHostKey] is String
        let deviceHost = DeviceNotifications.hostId(from: content.userInfo)
        let thread = content.threadIdentifier
        let remote = response.notification.request.trigger is UNPushNotificationTrigger
        let target = NotificationTarget(userInfo: content.userInfo, remote: remote)
        Task { @MainActor in
            defer { completionHandler() }
            if isKnock {
                ActiveWindow.model?.destination = .inbox
                return
            }
            if let deviceHost {
                if action != UNNotificationDismissActionIdentifier { SettingsLink.shared.open(.hostDevices(deviceHost)) }
                return
            }
            let result = await NotificationActionHandler(client: AppActionClient()).handle(actionIdentifier: action, target: target)
            Self.log.info("action \(action, privacy: .public): \(String(describing: result), privacy: .public)")
            if case .failed(let message) = result {
                let failure = NotificationActionHandler.failureContent(message, threadIdentifier: thread)
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: failure, trigger: nil))
            }
        }
    }

    // MARK: Push (entitlement builds)

    /// The token from `didRegisterForRemoteNotificationsWithDeviceToken`: register with every
    /// paired daemon, and share the sealing key and the paired hosts with the extension.
    func didRegister(apnsToken token: Data) {
        apnsToken = token
        Task { await registerPush() }
    }

    func registerPush() async {
        guard let token = apnsToken else { return }
        let store = SharedPushStore(bundle: .main)
        if let key = try? hosts.pushSealKey() { store.setSealKey(key.secret) }
        store.setPairedDaemons(hosts.pairedDaemonIds)
        let pushPrefs = PushPrefs(approvals: prefs.approvals, blocked: prefs.blocked, done: prefs.done, failed: prefs.failed, commands: prefs.commands)
        #if os(iOS)
        let activityStart = AgentsLiveActivity.shared.startToken
        #else
        let activityStart: Data? = nil
        #endif
        for (id, connection) in hosts.connections where connection is DaemonConnection && hosts.record(id)?.isGuest == false {
            do {
                _ = try await hosts.registerPush(
                    hostId: id, apnsToken: token, environment: Self.apnsEnvironment, prefs: pushPrefs, activityStartToken: activityStart)
            } catch {
                Self.log.error("push registration host=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        #if os(iOS)
        // A running agents activity's token, for daemons that connected since it started.
        if AgentsLiveActivity.shared.updateToken != nil { await AgentsLiveActivity.shared.sendUpdateToken() }
        #endif
    }

    /// Development builds get sandbox tokens; TestFlight and the App Store production ones.
    static var apnsEnvironment: ApnsEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    /// Whether this build can receive remote pushes (entitlement + team).
    static var pushEnabled: Bool {
        #if PUSH_YES
        true
        #else
        false
        #endif
    }
}

/// The action handler's way into the app: the host's live connection, a one-shot signed
/// connection for pushes, and showing a pane.
struct AppActionClient: NotificationActionClient {
    struct NotConnected: LocalizedError {
        var errorDescription: String? { "The host is not connected. Open the app to answer." }
    }

    func decide(hostId: String, paneId: UInt64, requestId: UInt64, optionId: UInt32) async throws {
        let daemon = try await MainActor.run {
            let hosts = AppModel.shared.hosts
            guard let daemon = (hosts.connection(hostId) ?? (try? hosts.open(hostId))) as? DaemonConnection else { throw NotConnected() }
            return daemon
        }
        try await daemon.decideWhenReady(requestId: requestId, optionId: optionId)
    }

    func sendPushAction(daemonId: String, token: Data, approve: Bool) async throws {
        _ = try await AppModel.shared.hosts.sendPushDecision(daemonId: daemonId, token: token, approve: approve)
    }

    func markSeen(hostId: String?, daemonId: String?, itemId: UInt64) async {
        await AppNotifications.shared.markAnswered(hostId: hostId, daemonId: daemonId, itemId: itemId)
    }

    func open(hostId: String?, daemonId: String?, paneId: UInt64) async {
        await MainActor.run {
            let hosts = AppModel.shared.hosts
            let id = hostId ?? hosts.records.first { $0.daemonId?.lowercased() == daemonId?.lowercased() }?.id
            guard let id else { return }
            AppNotifications.openPane(hostId: id, pane: paneId)
        }
    }
}

/// Notification permission: read it, and ask for it.
protocol NotificationAuthorizing: Sendable {
    func status() async -> UNAuthorizationStatus
    func request() async -> Bool
}

struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])) ?? false
    }
}

extension AppNotifications {
    /// Shows a host's pane in the frontmost window (notification tap, Live Activity link).
    static func openPane(hostId: String, pane: UInt64) {
        guard let model = ActiveWindow.model else { return }
        model.destination = .terminal
        // Opens the host in the window's sidebar if needed (a host already open just shows: no
        // reconnect), then focuses the pane's tab and the pane once the host's layout has it.
        model.show(.host(hostId))
        Task {
            for _ in 0..<40 {
                if model.workspace(ofGroup: hostId)?.session.panes.contains(PaneId(pane)) == true {
                    model.focus(pane: PaneId(pane), onGroup: hostId)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

extension DaemonConnection {
    /// Decides once the connection is live (a notification action may wake a dropped one).
    func decideWhenReady(requestId: UInt64, optionId: UInt32, timeout: Duration = .seconds(8)) async throws {
        let deadline = ContinuousClock.now + timeout
        if !status.isLive { foreground() }
        while !status.isLive {
            guard ContinuousClock.now < deadline else { throw AppActionClient.NotConnected() }
            try await Task.sleep(for: .milliseconds(50))
        }
        decide(requestId: requestId, optionId: optionId)
    }
}
