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
#elseif canImport(AppKit)
import AppKit
#endif

/// Notifications while the app is alive: every daemon's attention feed (agent blocked or done,
/// a long command finished unseen) becomes a local notification, except for the pane on screen
/// and, in the background, hosts that push to this device; with Approve / Deny / Open wired to
/// the signed `decide` (local) or `sendPushAction` (push). Remote push registration runs only
/// in builds with the push entitlement (`PUSH_YES`).
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "notify")

    /// Whether a window of the app is active (set from the scene phase).
    var appIsActive = true
    var prefs = NotificationPrefs.load() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            prefsChanged()
        }
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
    /// Items some device saw, per host, so a finished turn held back for a moment is dropped.
    private var seenItems: [String: Set<UInt64>] = [:]
    /// Finished-turn notes, at most one per pane per interval (the newest).
    private var pacer = PaneNotePacer()
    private var newestFinished: [String: UInt64] = [:]
    /// When a note was last posted per pane, so a push for the same moment does not show twice.
    private var postedAt: [String: ContinuousClock.Instant] = [:]
    /// Hosts that push to this device.
    private var pushingHosts: Set<String> = []
    private var reregistration: Task<Void, Never>?
    /// How long a finished turn waits for the agent to go straight on.
    static let finishedSettle: Duration = .seconds(2)

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
            daemon.multiplayer.onGuestAnswered = { [weak self] answer in
                Task { await self?.postGuestAnswer(answer, hostId: id) }
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
            // Another device showing the pane does not count: only this device's own screen.
            guard !item.seen else { return }
            Task {
                // The pane's agent state comes on another stream and can land just after the
                // item: an approval waits for its options, or it would lose Approve / Deny.
                if case .agentBlocked(_, let request?) = item.kind {
                    await Self.settle { Self.blockedOptions(daemon.meta[PaneId(item.paneId)]?.agent, request: request) != nil }
                }
                guard let note = note(for: item, hostId: hostId, daemon: daemon) else { return }
                if note.isFinished, await !finishedStillDue(note, daemon: daemon) { return }
                notes.enqueue(note, key: LocalNotifications.identifier(hostId: note.hostId, paneId: note.paneId))
            }
        case .seen(let ids, let count):
            unseen[hostId] = count
            seenItems[hostId, default: []].formUnion(ids)
            if seenItems[hostId, default: []].count > 2000 { seenItems[hostId] = Set(ids) }
            updateBadge()
            if count == 0 { clearDelivered(hostId: hostId) }
        }
    }

    /// A finished turn waits a moment and goes only if nobody saw it and the agent did not go
    /// straight on (working again, or asking: its own note, with Approve and Deny, stands); one
    /// per pane per interval, the newest.
    private func finishedStillDue(_ note: AttentionNote, daemon: DaemonConnection) async -> Bool {
        let key = LocalNotifications.identifier(hostId: note.hostId, paneId: note.paneId)
        newestFinished[key] = note.itemId
        try? await Task.sleep(for: Self.finishedSettle)
        let wait = pacer.wait(for: key, now: .now)
        if wait > .zero { try? await Task.sleep(for: wait) }
        guard newestFinished[key] == note.itemId,
              !(seenItems[note.hostId]?.contains(note.itemId) ?? false),
              !Self.hasMovedOn(daemon.meta[PaneId(note.paneId)]?.agent)
        else { return false }
        newestFinished[key] = nil
        pacer.posted(key, at: .now)
        return true
    }

    static func hasMovedOn(_ agent: AgentStatus?) -> Bool {
        switch agent?.state {
        case .running?, .blocked?: true
        default: false
        }
    }

    /// The daemon's item as a note: approval options come from the pane's agent state.
    func note(for item: AttentionItem, hostId: String, daemon: DaemonConnection) -> AttentionNote? {
        let drive: DriveRequestInfo? = if case .agentBlocked(_, let request?) = item.kind {
            daemon.approvals.drives[request]
        } else {
            nil
        }
        var note = Self.note(for: item, hostId: hostId, hostName: hosts.record(hostId)?.name ?? "Host",
                             agentState: daemon.meta[PaneId(item.paneId)]?.agent, drive: drive)
        note.place = Self.place(
            tabTitle: daemon.layout.session.tab(containing: PaneId(item.paneId))?.title,
            directory: daemon.meta[PaneId(item.paneId)]?.cwd)
        return note
    }

    /// The tab's own name, else the pane's directory's.
    static func place(tabTitle: String?, directory: String?) -> String? {
        if let tabTitle = tabTitle?.trimmingCharacters(in: .whitespaces), !tabTitle.isEmpty { return tabTitle }
        guard let directory, !directory.isEmpty else { return nil }
        let path = directory.hasPrefix("file://") ? URL(string: directory)?.path ?? directory : directory
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// The note for `item`. A drive request (an agent asking to drive one of the user's panes)
    /// is titled with what it wants and answers with its fixed options: Approve allows once,
    /// never "for this pane". Pure, for tests.
    static func note(
        for item: AttentionItem, hostId: String, hostName: String, agentState: AgentStatus?, drive: DriveRequestInfo?
    ) -> AttentionNote {
        let kind: AttentionNote.Kind
        var agent: String?
        var agentId: String?
        switch item.kind {
        case .agentBlocked(let name, let request?) where drive?.id == request:
            agent = AgentKind(name).title
            agentId = name
            if let drive {
                kind = .approval(requestId: request, approve: .init(id: drive.allowOnce, label: "Allow once"),
                                 deny: .init(id: drive.deny, label: "Deny"))
                return AttentionNote(hostId: hostId, hostName: hostName, itemId: item.id, paneId: item.paneId,
                                     kind: kind, title: drive.title, body: drive.action, agent: agent, agentId: agentId)
            }
            kind = .blocked
        case .agentBlocked(let name, let request):
            agent = AgentKind(name).title
            agentId = name
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
            agentId = name
            kind = .done
        case .agentFailed(let name):
            agent = AgentKind(name).title
            agentId = name
            kind = .failed
        case .commandFinished:
            kind = .command
        }
        // An agent's item is titled with its product name ("Claude Code finished"), not the
        // daemon's lowercased one ("claude finished").
        return AttentionNote(hostId: hostId, hostName: hostName, itemId: item.id, paneId: item.paneId, kind: kind,
                             title: agent == nil ? item.title : "", body: item.body, agent: agent, agentId: agentId)
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

    /// The user is in the app: in front, and on a Mac the active app (a window left visible
    /// behind another app is not being looked at).
    var isFrontmost: Bool {
        #if os(macOS)
        appIsActive && NSApplication.shared.isActive
        #else
        appIsActive
        #endif
    }

    /// Whether this device shows `pane` of the host to the user right now.
    func isOnScreen(hostId: String, pane: UInt64) -> Bool {
        guard isFrontmost, let daemon = hosts.connection(hostId) as? DaemonConnection else { return false }
        return daemon.reportedView?.visible.contains(pane) ?? false
    }

    /// A host pushes to this device and, with no window of it on screen, will push this note.
    func pushCovers(hostId: String) -> Bool {
        guard pushingHosts.contains(hostId), let daemon = hosts.connection(hostId) as? DaemonConnection else { return false }
        return daemon.reportedView?.visible.isEmpty ?? true
    }

    /// Posts a note if the preferences and the permission allow it, its pane is not on screen,
    /// and in the background no push brings it already.
    func post(_ note: AttentionNote) async {
        let allowed = LocalNotifications.shouldPost(
            note, prefs: prefs, appIsActive: isFrontmost,
            paneOnScreen: isOnScreen(hostId: note.hostId, pane: note.paneId),
            pushCoversBackground: pushCovers(hostId: note.hostId))
        guard allowed, await isAuthorized() else { return }
        postedAt[LocalNotifications.identifier(hostId: note.hostId, paneId: note.paneId)] = .now
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

    /// Someone else answered an agent's request on a host this device owns. Posted whatever the
    /// notification preferences or what was seen say, so no guest answers unnoticed; in front,
    /// the toast says it.
    func postGuestAnswer(_ answer: GuestAnswer, hostId: String) async {
        guard !appIsActive, await isAuthorized() else { return }
        let note = AttentionNote(
            hostId: hostId, hostName: hosts.record(hostId)?.name ?? "Host", itemId: 0, paneId: answer.paneId,
            kind: .blocked, title: MultiplayerSession.guestAnswerTitle(answer), body: answer.summary)
        let content = LocalNotifications.content(for: note)
        let request = UNNotificationRequest(
            identifier: "answer-\(hostId)-\(answer.paneId)-\(answer.atMs)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        Self.log.info("posted guest answer host=\(hostId, privacy: .public) pane=\(answer.paneId)")
    }

    private func clearDelivered(hostId: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == hostId || $0.request.content.threadIdentifier.hasPrefix("\(hostId).pane.") }
                .map(\.request.identifier)
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

    /// In front: nothing for the pane on screen, a banner for the rest. A push for a pane this
    /// app just alerted about locally shows once.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let remote = notification.request.trigger is UNPushNotificationTrigger
        let target = NotificationTarget(userInfo: content.userInfo, remote: remote)
        return await MainActor.run { AppNotifications.shared.presentation(for: target) }
    }

    func presentation(for target: NotificationTarget?) -> UNNotificationPresentationOptions {
        switch target {
        case .local(let hostId, let paneId, _, _, _, _):
            return LocalNotifications.presentation(paneOnScreen: isOnScreen(hostId: hostId, pane: paneId))
        case .push(let push):
            guard let hostId = hosts.records.first(where: { $0.daemonId?.lowercased() == push.daemon.lowercased() })?.id else {
                return [.banner, .list, .sound]
            }
            let key = LocalNotifications.identifier(hostId: hostId, paneId: push.pane)
            if let posted = postedAt[key], ContinuousClock.now - posted < .seconds(60) { return [] }
            return LocalNotifications.presentation(paneOnScreen: isOnScreen(hostId: hostId, pane: push.pane))
        case nil:
            return [.list]
        }
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
        let agentRules = Self.agentRules(prefs)
        #if os(iOS)
        let activityStart = AgentsLiveActivity.shared.startToken
        #else
        let activityStart: Data? = nil
        #endif
        for (id, connection) in hosts.connections where connection is DaemonConnection && hosts.record(id)?.isGuest == false {
            do {
                _ = try await hosts.registerPush(
                    hostId: id, apnsToken: token, environment: Self.apnsEnvironment, prefs: pushPrefs,
                    agentRules: agentRules, activityStartToken: activityStart)
                pushingHosts.insert(id)
            } catch {
                Self.log.error("push registration host=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        #if os(iOS)
        // A running agents activity's token, for daemons that connected since it started.
        if AgentsLiveActivity.shared.updateToken != nil { await AgentsLiveActivity.shared.sendUpdateToken() }
        #endif
    }

    /// The per-agent choices as the daemons take them.
    static func agentRules(_ prefs: NotificationPrefs) -> [PushAgentRule] {
        prefs.agents.keys.sorted().compactMap { name in
            prefs.agents[name].map { PushAgentRule(agent: name, needsYou: $0.needsYou, finished: $0.finished) }
        }
    }

    /// Pushes follow the new choices: registered again a moment after the last change.
    private func prefsChanged() {
        guard apnsToken != nil else { return }
        reregistration?.cancel()
        reregistration = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await registerPush()
        }
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
