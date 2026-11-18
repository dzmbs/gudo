#if os(macOS)
import Foundation
import HostKit
import Observation
import os
import ServiceManagement

/// This Mac's own helper: the daemon bundled in the app (`Contents/MacOS/<name>-hostd`), run for
/// this user and paired with the app as its owner, so This Mac has everything a remote host has:
/// files, changes, ports, the editor, agents, sharing. The app copies it out of the bundle
/// (`HelperInstall`) and starts the copy as a launchd job that runs until logout
/// (`hostd service start`), so sessions outlive the app; or as the app's child when that is
/// turned off or launchd refuses the job. Starting at login is `hostd service install`.
/// iPhone and iPad have no helper of their own.
@MainActor
@Observable
final class LocalHelper {
    enum State: Equatable {
        /// Turned off, or not part of this build.
        case off
        case starting
        case running
        case failed(String)
    }

    /// Whether This Mac runs the helper the app carries.
    enum Update: Equatable {
        /// An older helper serves This Mac that cannot hand its sessions over: replacing it
        /// restarts running commands, so it waits for the user (`replaceOlderHelper`).
        case needsRestart(failure: String?)
        case updating
        /// This start moved This Mac onto the app's helper.
        case updated
    }

    private(set) var state = State.off
    private(set) var update: Update?
    /// Goes up each time This Mac moves onto a newer helper.
    private(set) var updatedCount = 0
    /// The build the app carries, once read from its installed copy.
    private(set) var appBuild: HelperBuild?
    @ObservationIgnored private var isReplacing = false
    @ObservationIgnored let hosts: HostsModel
    @ObservationIgnored let binary: URL?
    /// The copy of `binary` the helper runs from, once installed.
    @ObservationIgnored private(set) var installed: URL?
    /// The helper's state folder (keys, paired devices, layout).
    @ObservationIgnored let stateDirectory: URL
    /// Test launches: their own folder, a child unless asked otherwise, never a login service,
    /// never on unless asked.
    @ObservationIgnored let isIsolated: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var child: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// When this app last started the helper (a dial from before then found nothing to reach).
    @ObservationIgnored private(set) var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var pairsAgainAfterTask = false
    @ObservationIgnored private var isPairingAgain = false
    @ObservationIgnored private var pairingAgainFailed: ContinuousClock.Instant?
    @ObservationIgnored private var exitWatch: DispatchSourceProcess?
    @ObservationIgnored private var watchedSince: ContinuousClock.Instant?
    @ObservationIgnored private var respawn = HelperRespawn()
    @ObservationIgnored private var respawnTask: Task<Void, Never>?
    @ObservationIgnored private var timeline = StartTimeline()
    /// A daemon the user runs on the folder serves This Mac: they (or launchd) start it again.
    @ObservationIgnored private var servesForeign = false
    /// The host became ready (each window opens it).
    @ObservationIgnored var onReady: ((String) -> Void)?
    /// The helper stopped or failed to start.
    @ObservationIgnored var onUnavailable: (() -> Void)?

    static let enabledKey = "localHelper"
    static let keepsRunningKey = "localHelperKeepsRunning"
    static let startsAtLoginKey = "localHelperStartsAtLogin"
    private static let registeredKey = "localHelperRegistered"
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "helper")

    init(hosts: HostsModel, binary: URL?, stateDirectory: URL, isIsolated: Bool, defaults: UserDefaults = .standard) {
        self.hosts = hosts
        self.binary = binary
        self.stateDirectory = stateDirectory
        self.isIsolated = isIsolated
        self.defaults = defaults
        hosts.thisDeviceEndpointFile = stateDirectory.appending(path: "endpoint.json")
    }

    /// The app's helper: the bundled build in the daemon's default folder (where the `gudo` CLI
    /// and agent hooks look), or a test folder.
    static func app(hosts: HostsModel) -> LocalHelper {
        let binary = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(Brand.daemonBinary)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let state = AppData.isolatedDirectory.map { $0.appending(path: "helper", directoryHint: .isDirectory) }
            ?? home.appending(path: "Library/Application Support/\(Brand.name)", directoryHint: .isDirectory)
        return LocalHelper(
            hosts: hosts, binary: FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil,
            stateDirectory: state, isIsolated: AppData.isIsolated)
    }

    /// On unless turned off (Settings ▸ This Mac); test launches only with `-localHelper YES`.
    var isEnabled: Bool {
        guard binary != nil else { return false }
        return flag(Self.enabledKey) ?? !isIsolated
    }

    /// Sessions keep running after the app quits, until logout (a launchd job). On by default,
    /// except in test launches.
    var keepsRunning: Bool {
        flag(Self.keepsRunningKey) ?? !isIsolated
    }

    /// The helper also starts at login (`hostd service install`), so phones reach This Mac after
    /// a restart. On by default, except in test launches.
    var startsAtLogin: Bool {
        keepsRunning && !isIsolated && (flag(Self.startsAtLoginKey) ?? true)
    }

    /// Where the helper's installed builds live.
    var versionsDirectory: URL { install(of: binary ?? stateDirectory).versions }

    /// A saved switch, or a launch argument (`-localHelper YES`); nil when unset.
    private func flag(_ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    /// Whether This Mac is served by the helper: its plain local shells give way to it.
    var isActive: Bool { isEnabled && state != .off && !isFailed }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    private var isOutOfDate: Bool { if case .needsRestart = update { true } else { false } }

    /// Whether This Mac's link reads as the helper starting rather than a lost link: it is
    /// starting, or it runs and this launch has not reached it yet (`connectionCount`).
    static func readsAsStarting(_ state: State, connectionCount: Int) -> Bool {
        switch state {
        case .starting: true
        case .running: connectionCount == 0
        case .off, .failed: false
        }
    }

    // MARK: Starting and stopping

    /// Starts the helper if needed and pairs with it once.
    func start() {
        guard isEnabled, task == nil else { return }
        guard state != .running || hosts.thisDeviceId == nil else { return }
        state = .starting
        begin()
    }

    /// Update Helper: the older helper saves its sessions and stops, and the app's starts on
    /// them (shells start again in their folders, agents resume).
    func replaceOlderHelper() {
        guard isEnabled, task == nil, case .needsRestart = update else { return }
        isReplacing = true
        update = .updating
        stopWatchingExit()
        state = .starting
        begin()
    }

    private func begin() {
        task = Task {
            defer {
                isReplacing = false
                finishTask()
            }
            do {
                let id = try await run()
                state = .running
                if update == .updated { updatedCount += 1 }
                watchExit()
                onReady?(id)
            } catch {
                if Task.isCancelled { return }
                Self.log.error("helper: \(String(describing: error), privacy: .public)")
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                if isReplacing {
                    update = .needsRestart(failure: reason)
                    if Self.runningEndpoint(in: stateDirectory) != nil {
                        state = .running
                        watchExit()
                        return
                    }
                }
                state = .failed(reason)
                onUnavailable?()
            }
        }
    }

    /// The helper no longer knows this app's device (removed from its devices, or the pairing
    /// was lost): pairs again with a fresh ticket from the helper, without asking. Anyone who
    /// can run the helper on its folder can mint one, as this user on this Mac can. False when
    /// it won't (turned off, or it just failed): the host then asks the user.
    @discardableResult
    func pairAgain() -> Bool {
        // A refusal of the pairing itself must not start another.
        guard isEnabled, !isPairingAgain, let binary else { return false }
        if let failed = pairingAgainFailed, ContinuousClock.now - failed < .seconds(10) { return false }
        guard task == nil else {
            pairsAgainAfterTask = true
            return true
        }
        Self.log.info("helper: this Mac's device was removed; pairing again")
        isPairingAgain = true
        task = Task {
            defer {
                isPairingAgain = false
                finishTask()
            }
            do {
                let ticket = try await Self.mintTicket(binary: binary, stateDirectory: stateDirectory)
                let id = try await hosts.pairThisDevice(try PairingTicket(ticket), name: WindowModel.deviceName)
                pairingAgainFailed = nil
                state = .running
                watchExit()
                onReady?(id)
            } catch {
                Self.log.error("helper: pairing again failed: \(String(describing: error), privacy: .public)")
                pairingAgainFailed = .now
                showRefusal()
            }
        }
        return true
    }

    private func finishTask() {
        task = nil
        guard pairsAgainAfterTask else { return }
        pairsAgainAfterTask = false
        guard let id = hosts.thisDeviceId, let connection = hosts.connection(id) as? DaemonConnection,
              connection.refusal.map(DaemonConnection.meansDeviceRemoved) == true
        else { return }
        if !pairAgain() { showRefusal() }
    }

    /// A connection left waiting for a pairing that did not happen dials again, and this time
    /// shows the refusal.
    private func showRefusal() {
        guard let id = hosts.thisDeviceId, let connection = hosts.connection(id), connection.status.isConnecting else { return }
        connection.retry()
    }

    /// Stops the helper (its sessions end) and leaves it off until started again.
    func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        task?.cancel()
        stopWatchingExit()
        if let id = hosts.thisDeviceId { hosts.disconnect(id) }
        if loginItem != .none { retireLoginItemLater() }
        child?.terminate()
        child = nil
        if let executable = installed ?? binary {
            let directory = stateDirectory, uninstalls = startsAtLogin
            Task { await Self.stopJob(executable: executable, stateDirectory: directory, uninstallsLoginService: uninstalls) }
        }
        state = .off
        onUnavailable?()
    }

    func enable() {
        defaults.set(true, forKey: Self.enabledKey)
        start()
    }

    /// Switches between a launchd job and a child of the app. The running sessions end.
    func setKeepsRunning(_ keep: Bool) {
        let uninstallsLoginService = startsAtLogin
        defaults.set(keep, forKey: Self.keepsRunningKey)
        restart { executable, directory in
            if !keep {
                await Self.stopJob(executable: executable, stateDirectory: directory, uninstallsLoginService: uninstallsLoginService)
            }
        }
    }

    /// Installs or removes the login service (`hostd service install`), which runs the helper
    /// from login on. The running sessions end: one helper runs on the folder at a time.
    func setStartsAtLogin(_ starts: Bool) {
        defaults.set(starts, forKey: Self.startsAtLoginKey)
        guard keepsRunning, !isIsolated else { return }
        restart { executable, directory in
            if starts {
                await Self.stopJob(executable: executable, stateDirectory: directory, uninstallsLoginService: false)
            } else {
                _ = try? await Self.output(executable, ["service", "uninstall"])
            }
        }
    }

    /// Stops the helper with `stopping`, waits for it to let go of the state folder, and
    /// starts it again the way the settings now say.
    private func restart(stopping: @escaping (URL, URL) async -> Void) {
        guard isEnabled else { return }
        task?.cancel()
        task = nil
        stopWatchingExit()
        child?.terminate()
        child = nil
        state = .starting
        let executable = installed ?? binary, directory = stateDirectory
        Task {
            if let executable { await stopping(executable, directory) }
            // The old process lets go of the state folder before the new one takes it.
            let deadline = ContinuousClock.now + .seconds(5)
            while Self.runningEndpoint(in: directory) != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.pollInterval)
            }
            start()
        }
    }

    /// The app is quitting: a child helper goes with it (a launchd job stays).
    func appWillTerminate() {
        stopWatchingExit()
        child?.terminate()
    }

    // MARK: When the helper ends on its own

    /// Notices the helper ending while it serves This Mac (killed, crashed, or stopped from a
    /// terminal), whoever started it: the app, launchd or the user.
    private func watchExit() {
        stopWatchingExit()
        guard let endpoint = Self.runningEndpoint(in: stateDirectory) else { return }
        let pid = endpoint.pid
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.helperExited(pid: pid) }
        }
        source.resume()
        exitWatch = source
        watchedSince = .now
        // A process that ended before the watch began never reports it.
        if kill(pid, 0) != 0 { helperExited(pid: pid) }
    }

    private func stopWatchingExit() {
        exitWatch?.cancel()
        exitWatch = nil
        respawnTask?.cancel()
        respawnTask = nil
    }

    /// Starts the helper once more after a pause, so This Mac reconnects to it by itself. Its
    /// layout and saved screens bring the sessions back.
    private func helperExited(pid: Int32) {
        exitWatch?.cancel()
        exitWatch = nil
        guard isEnabled, state == .running, task == nil, respawnTask == nil else { return }
        // Its link looks up until the idle timeout; dialling now shows "Connecting" at once
        // and reaches the helper as soon as one listens again.
        if let id = hosts.thisDeviceId { hosts.connection(id)?.retry() }
        // An older helper the user ran gives way to the app's once it ends.
        guard !servesForeign || isOutOfDate else { return }
        if child?.processIdentifier == pid { child = nil }
        let ranFor = watchedSince.map { ContinuousClock.now - $0 } ?? .zero
        guard let delay = respawn.delay(afterRunning: ranFor, jitter: .random(in: 0..<1)) else {
            Self.log.error("helper: pid \(pid) ended right after starting again; leaving it stopped")
            state = .failed(HelperError.keepsStopping.errorDescription ?? "")
            onUnavailable?()
            return
        }
        Self.log.info("helper: pid \(pid) ended; starting it again in \(delay, privacy: .public)")
        state = .starting
        respawnTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            respawnTask = nil
            start()
        }
    }

    private func run() async throws -> String {
        guard let binary else { throw HelperError.notBundled }
        timeline = StartTimeline()
        if !isIsolated && !Brand.isDev {
            await retireLegacyHelper()
            timeline.mark("legacy helper check")
        }
        let executable = await installHelper(binary)
        timeline.mark("helper installed")
        let appBuild = await HelperBuild.read(executable)
        self.appBuild = appBuild
        timeline.mark("build \(appBuild?.summary ?? "unknown")")
        let wasOutOfDate = isOutOfDate || update == .updating
        var outcome: Update?
        var launched = true
        servesForeign = false
        let runningEndpoint = Self.runningEndpoint(in: stateDirectory)
        var running: Running?
        if let runningEndpoint {
            running = await Self.running(pid: runningEndpoint.pid, versions: versionsDirectory, app: appBuild)
        }
        let plan = Self.plan(running: running, loginItem: loginItem)
        timeline.mark("plan \(plan)")
        switch plan {
        case .launch(let earlier):
            if earlier == .retire {
                await stopLoginItem()
                timeline.mark("login item removed")
            }
            try await launch(executable)
            if wasOutOfDate { outcome = .updated }
        case .keep(let earlier):
            launched = false
            // A helper the user runs (`service install` of a build folder, `run`) is theirs to
            // start again.
            servesForeign = running?.location == .foreign
            await apply(earlier)
            Self.log.info("helper: keeping the running helper (pid \(runningEndpoint?.pid ?? 0))")
        case .restart(let target, let earlier):
            guard let runningEndpoint else { break }
            if isReplacing {
                try await replace(pid: runningEndpoint.pid, with: executable)
                outcome = .updated
                break
            }
            launched = false
            await apply(earlier)
            let into = target == .installed ? executable : nil
            // A build that cannot hand over is restarted cold by `restart` itself: its
            // commands end, its agents resume.
            _ = await Self.restartInPlace(binary: executable, stateDirectory: stateDirectory, into: into)
            timeline.mark("restart")
            let after = Self.runningEndpoint(in: stateDirectory)
            var now: Running?
            if let after { now = await Self.running(pid: after.pid, versions: versionsDirectory, app: appBuild) }
            switch Self.afterRestart(before: runningEndpoint, after: after, build: now?.build) {
            case .updated:
                servesForeign = now?.location == .foreign
                outcome = .updated
                if into != nil { await pointLoginServiceAtInstalled(executable) }
            case .replace:
                if let after { try await replace(pid: after.pid, with: executable) } else { try await launch(executable) }
                launched = true
                outcome = .updated
            case .ask:
                servesForeign = now?.location == .foreign
                outcome = .needsRestart(failure: nil)
            }
        case .replace:
            if let runningEndpoint {
                try await replace(pid: runningEndpoint.pid, with: executable)
            } else {
                try await launch(executable)
            }
            outcome = .updated
        }
        update = outcome
        let endpoint = try await waitForEndpoint()
        timeline.mark("helper listening")
        if launched { startedAt = .now }
        if let id = hosts.thisDeviceId, hosts.record(id)?.daemonId == endpoint.daemonId { return id }
        let ticket = try await Self.mintTicket(binary: executable, stateDirectory: stateDirectory)
        let id = try await hosts.pairThisDevice(try PairingTicket(ticket), name: WindowModel.deviceName)
        timeline.mark("paired")
        return id
    }

    private func apply(_ earlier: EarlierLoginItem) async {
        switch earlier {
        case .leave: break
        case .retire: retireLoginItemLater()
        case .keepFromStartingAtLogin: await stopLoginStart()
        }
    }

    /// After a hand-off into `Versions/Current`, the login service starts that build at the
    /// next login too (`service install --no-start`: the plist alone).
    private func pointLoginServiceAtInstalled(_ executable: URL) async {
        guard startsAtLogin, executable == installed else { return }
        _ = await Self.installLoginService(executable, stateDirectory: stateDirectory, startsNow: false)
        timeline.mark("login service points at the installed build")
    }

    /// Replaces an older helper that cannot hand over: it saves its sessions and stops
    /// (SIGTERM, on which every released build saves its screens and layout), then the
    /// installed build starts on the same folder, keys and pairings, as the login service when
    /// it starts at login, so that points at `Versions/Current` from then on.
    private func replace(pid: Int32, with executable: URL) async throws {
        Self.log.info("helper: replacing the older helper (pid \(pid))")
        // Its own launchd job, when it is the app's, goes with it rather than starting it again.
        await Self.stopJob(executable: executable, stateDirectory: stateDirectory, uninstallsLoginService: false)
        if Self.isAlive(pid), loginItem != .none { await stopLoginItem() }
        if Self.isAlive(pid) { kill(pid, SIGTERM) }
        // Saving a long scrollback takes a while; launchd allows a job 20 s.
        let deadline = ContinuousClock.now + .seconds(30)
        while Self.isAlive(pid), ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.pollInterval)
        }
        guard !Self.isAlive(pid) else { throw HelperError.olderHelperKeepsRunning }
        timeline.mark("older helper stopped")
        try await launch(executable)
    }

    nonisolated private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// What runs as `pid`: where from, and its build against the app's, read from the file it
    /// runs while that is still at its path. When the app's build cannot be told, what runs is
    /// kept, as before builds were compared. A process whose file the system no longer names
    /// (removed, or swapped out of `Current`) hands over to the installed build.
    nonisolated static func running(pid: Int32, versions: URL, app: HelperBuild?) async -> Running {
        guard let app else {
            return Running(location: runningHelper(pid: pid, versions: versions), build: .same, buildAtItsPath: .same)
        }
        guard let executable = RunningExecutable.of(pid: pid) else {
            return Running(location: .installed, build: .older, buildAtItsPath: .older)
        }
        let atItsPath = BuildAge(await HelperBuild.read(URL(fileURLWithPath: executable.path)), against: app)
        return Running(
            location: runningHelper(executable: executable.path, versions: versions),
            build: executable.isOnDisk ? atItsPath : .older, buildAtItsPath: atItsPath)
    }

    private func install(of binary: URL) -> HelperInstall {
        HelperInstall(
            bundled: binary, stateDirectory: stateDirectory,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    /// The installed copy of the bundled build; the bundled build itself when it cannot be
    /// installed (it then only runs as a child).
    private func installHelper(_ binary: URL) async -> URL {
        do {
            let current = try await install(of: binary).install()
            installed = current
            return current
        } catch {
            Self.log.error("helper: installing: \(String(describing: error), privacy: .public)")
            installed = nil
            return binary
        }
    }

    /// Each step of starting the helper in the log (info, category `helper`): how long it took
    /// and how long since the start began.
    struct StartTimeline {
        private let began = ContinuousClock.now
        private var last = ContinuousClock.now
        private(set) var steps: [(name: String, took: Duration)] = []

        mutating func mark(_ step: String) {
            let now = ContinuousClock.now
            let took = Self.milliseconds(now - last), sinceStart = Self.milliseconds(now - began)
            steps.append((step, now - last))
            LocalHelper.log.info("helper start: \(step, privacy: .public) took \(took) ms, \(sinceStart) ms in")
            last = now
        }

        private static func milliseconds(_ duration: Duration) -> Int { Int((duration / .milliseconds(1)).rounded()) }
    }

    /// What runs on the state folder.
    nonisolated enum RunningHelper: Equatable {
        /// A build the app installed (`Helper/Versions`): its launchd job, the login service or
        /// a child.
        case installed
        /// A build inside an app bundle: an earlier version's login item or child.
        case bundled
        /// A daemon the user runs on the folder (another build's `service install`, `run`).
        case foreign
    }

    /// The login item earlier versions registered (`SMAppService`, a LaunchAgent in the bundle).
    nonisolated enum LoginItem: Equatable {
        case none
        /// launchd starts it at login.
        case enabled
        /// Registered but switched off: in Login Items, or by this app so it no longer starts.
        case disabled
    }

    /// What runs on the state folder: where from, and its build against the app's.
    nonisolated struct Running: Equatable {
        var location: RunningHelper
        var build: BuildAge
        /// The build now at the path it runs from.
        var buildAtItsPath: BuildAge
    }

    /// What becomes of the login item earlier versions registered.
    nonisolated enum EarlierLoginItem: Equatable {
        case leave
        /// Unregistered: it runs nothing.
        case retire
        /// Its helper may be the one running: kept from starting at the next login only.
        case keepFromStartingAtLogin
    }

    /// How starting goes, given what runs on the state folder.
    nonisolated enum StartPlan: Equatable {
        /// Nothing runs there: start the installed build.
        case launch(EarlierLoginItem)
        /// The app's build or a newer one runs, from wherever it runs: kept.
        case keep(EarlierLoginItem)
        /// An older build runs: it hands its sessions over in the same process (`restart`),
        /// or, a build that cannot, is restarted cold on the new build.
        case restart(into: RestartTarget, EarlierLoginItem)
        /// An older app's login item runs an older build: launchd would start that build
        /// again, so the login item goes first and the installed build starts in its place.
        case replace
    }

    nonisolated enum RestartTarget: Equatable {
        case installed
        /// The app's build or a newer one now at the path the helper runs from (`Current`
        /// swapped, an app replaced in place, a rebuilt build folder).
        case itsOwnPath
    }

    nonisolated static func plan(running: Running?, loginItem: LoginItem) -> StartPlan {
        guard let running else { return .launch(loginItem == .none ? .leave : .retire) }
        let earlier: EarlierLoginItem = switch (running.location, loginItem) {
        case (_, .none): .leave
        case (.bundled, .enabled): .keepFromStartingAtLogin
        case (.bundled, .disabled): .leave
        case (.installed, _), (.foreign, _): .retire
        }
        if running.build != .older { return .keep(earlier) }
        // Released builds hand over only to the file at their own path.
        if running.buildAtItsPath != .older { return .restart(into: .itsOwnPath, earlier) }
        if running.location == .bundled, loginItem != .none { return .replace }
        return .restart(into: .installed, earlier)
    }

    nonisolated enum AfterRestart: Equatable {
        case updated
        /// Still older, but its commands ended already (it restarted cold, onto the old path
        /// launchd knows): replaced at once.
        case replace
        /// Still older and untouched: replacing it would end running commands.
        case ask
    }

    nonisolated static func afterRestart(before: Endpoint?, after: Endpoint?, build: BuildAge?) -> AfterRestart {
        guard let after, let build else { return .replace }
        if build != .older { return .updated }
        return after.pid == before?.pid && after.startedAt == before?.startedAt ? .ask : .replace
    }

    /// Stops the helper of a build from before the product's rename and keeps its login items
    /// from starting again, so this build's helper can take over its state folder (keys, paired
    /// devices, grants, layout), which the helper moves into its own when it starts.
    private func retireLegacyHelper() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appending(path: "Library/Application Support/\(Brand.Legacy.name)", directoryHint: .isDirectory)
        guard Self.legacyHelperNeedsRetiring(legacy: legacy, current: stateDirectory) else { return }
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        // The old app's login item, and a helper installed with `service install`.
        for label in ["\(Brand.Legacy.bundleIdPrefix).app.hostd", "\(Brand.Legacy.bundleIdPrefix).hostd"] {
            let target = "gui/\(getuid())/\(label)"
            _ = try? await Self.output(launchctl, ["bootout", target])
            _ = try? await Self.output(launchctl, ["disable", target])
        }
        if let old = Self.runningEndpoint(in: legacy) { kill(old.pid, SIGTERM) }
        let deadline = ContinuousClock.now + .seconds(5)
        while Self.runningEndpoint(in: legacy) != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
        Self.log.info("helper: retired the helper from before the rename")
    }

    /// Whether the helper from before the rename still has to be stopped: its folder holds a
    /// key, and either it runs or this build's folder has none yet (the helper only moves the
    /// old folder into one without a key, so an old key next to a new one stays for good).
    nonisolated static func legacyHelperNeedsRetiring(legacy: URL, current: URL) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.appending(path: "daemon.key").path) else { return false }
        return runningEndpoint(in: legacy) != nil || !files.fileExists(atPath: current.appending(path: "daemon.key").path)
    }

    /// Starts the installed build as a launchd job (or the login service), or as a child when
    /// sessions end with the app, launchd refuses the job, or nothing is installed.
    private func launch(_ executable: URL) async throws {
        if keepsRunning, let installed {
            if startsAtLogin, await Self.installLoginService(installed, stateDirectory: stateDirectory) {
                timeline.mark("login service installed")
                return
            }
            do {
                let started = try await Self.startJob(executable: installed, stateDirectory: stateDirectory)
                timeline.mark(started ? "job started" : "job found running")
                return
            } catch HelperError.launchdRefused {
                Self.log.error("helper: launchd refused its job: running it as a child")
            }
        }
        try startChild(executable)
        timeline.mark("child started")
    }

    /// `hostd service start`: the helper as a launchd job that runs until logout, unless one
    /// already runs on the folder. True when it started one.
    nonisolated static func startJob(executable: URL, stateDirectory: URL) async throws -> Bool {
        do {
            let printed = try await output(executable, ["--state-dir", stateDirectory.path, "service", "start", "--json"])
            let started = (try? JSONSerialization.jsonObject(with: printed) as? [String: Any])?["started"] as? Bool
            return started ?? false
        } catch HelperError.exited(launchdRefusedStatus) {
            throw HelperError.launchdRefused
        }
    }

    /// `hostd service start` exits with this when launchd refused the job.
    nonisolated static let launchdRefusedStatus: Int32 = 3

    /// Stops the helper's launchd job (`hostd service stop`; it saves its sessions first), and
    /// the login service with it when asked.
    nonisolated static func stopJob(executable: URL, stateDirectory: URL, uninstallsLoginService: Bool) async {
        do {
            _ = try await output(executable, ["--state-dir", stateDirectory.path, "service", "stop"])
        } catch {
            log.info("helper: stopping its job: \(String(describing: error), privacy: .public)")
        }
        if uninstallsLoginService { _ = try? await output(executable, ["service", "uninstall"]) }
    }

    /// `hostd service install`; `startsNow` false writes the plist alone, for the next login.
    nonisolated static func installLoginService(_ executable: URL, stateDirectory: URL, startsNow: Bool = true) async -> Bool {
        do {
            _ = try await output(
                executable, ["--state-dir", stateDirectory.path, "service", "install"] + (startsNow ? [] : ["--no-start"]))
            return true
        } catch {
            log.error("helper: installing the login service: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private var loginItem: LoginItem {
        guard !isIsolated else { return .none }
        switch agent.status {
        case .enabled: return .enabled
        case .requiresApproval: return .disabled
        default: return .none
        }
    }

    /// Unregisters an earlier version's login item that runs nothing, without waiting for it.
    private func retireLoginItemLater() {
        Task { await stopLoginItem() }
    }

    /// Keeps an earlier version's login item from starting at the next login, leaving its
    /// running helper (and launchd's restart of it after a crash) alone.
    private func stopLoginStart() async {
        _ = try? await Self.output(Self.launchctl, ["disable", Self.loginItemTarget])
        timeline.mark("login item kept from starting at login")
    }

    /// How often a start looks for the helper's endpoint.
    static let pollInterval = Duration.milliseconds(25)

    /// Unregisters an earlier version's login item and waits for its helper to let go of the
    /// state folder. A label this app switched off is switched on again, so the next
    /// registration (an older version run again) starts as usual.
    private func stopLoginItem() async {
        do {
            try await agent.unregister()
        } catch {
            Self.log.info("login item: unregistering: \(String(describing: error), privacy: .public)")
        }
        _ = try? await Self.output(Self.launchctl, ["enable", Self.loginItemTarget])
        defaults.removeObject(forKey: Self.registeredKey)
        let deadline = ContinuousClock.now + .seconds(5)
        while Self.runningEndpoint(in: stateDirectory) != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func startChild(_ executable: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--state-dir", stateDirectory.path, "run"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
    }

    private static var label: String { (Bundle.main.bundleIdentifier ?? "app") + ".hostd" }
    private static var loginItemTarget: String { "gui/\(getuid())/\(label)" }
    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    /// The login item earlier versions registered; kept in the bundle so it can be unregistered.
    private var agent: SMAppService { .agent(plistName: Self.label + ".plist") }

    // MARK: The helper's state folder

    /// What a running helper recorded about itself.
    nonisolated struct Endpoint: Equatable, Decodable {
        var daemonId: String
        var pid: Int32
        /// Unix ms; a hand-off keeps the pid and records a new start.
        var startedAt: UInt64?

        enum CodingKeys: String, CodingKey {
            case daemonId = "daemon_id"
            case pid
            case startedAt = "started_at"
        }
    }

    /// The helper running on `directory`, if its process is alive.
    nonisolated static func runningEndpoint(in directory: URL) -> Endpoint? {
        guard let data = try? Data(contentsOf: directory.appending(path: "endpoint.json")),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
              endpoint.pid > 0, kill(endpoint.pid, 0) == 0
        else { return nil }
        return endpoint
    }

    /// What `pid` runs: a build the app installed, one inside an app bundle, or a daemon the
    /// user installed or started from a terminal.
    nonisolated static func runningHelper(pid: Int32, versions: URL) -> RunningHelper {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return .installed }
        return runningHelper(executable: String(cString: buffer), versions: versions)
    }

    nonisolated static func runningHelper(executable: String, versions: URL) -> RunningHelper {
        // The kernel reports the real path; `resolvingSymlinksInPath` would keep `/var` for
        // `/private/var`.
        let versionsPath = realpath(versions.path, nil).map { real in
            defer { free(real) }
            return String(cString: real)
        } ?? versions.path
        if executable.hasPrefix(versionsPath.hasSuffix("/") ? versionsPath : versionsPath + "/") { return .installed }
        return executable.contains(".app/Contents/") ? .bundled : .foreign
    }

    private func waitForEndpoint(timeout: Duration = .seconds(30)) async throws -> Endpoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let endpoint = Self.runningEndpoint(in: stateDirectory) { return endpoint }
            if let child, !child.isRunning { throw HelperError.exited(child.terminationStatus) }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw HelperError.didNotStart
    }

    /// Asks the running helper to hand its sessions to the build now in the app and become it
    /// (`restart`): false when it cannot (a build from before this, or the new build cannot
    /// take the sessions over), which leaves it running as it was.
    static func restartInPlace(binary: URL, stateDirectory: URL, into target: URL? = nil) async -> Bool {
        do {
            let into = target.map { ["--into", $0.path] } ?? []
            let output = try await Self.output(binary, ["--state-dir", stateDirectory.path, "restart"] + into)
            let said = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("helper: \(said, privacy: .public)")
            return true
        } catch {
            Self.log.info("helper: no restart in place (\(String(describing: error), privacy: .public))")
            return false
        }
    }

    /// A one-time ticket from the helper itself, with loopback addresses (works offline).
    nonisolated static func mintTicket(binary: URL, stateDirectory: URL) async throws -> String {
        let output = try await Self.output(binary, ["--state-dir", stateDirectory.path, "pair", "--json", "--local", "--minutes", "5"])
        guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              let ticket = object["ticket"] as? String
        else { throw HelperError.noTicket }
        return ticket
    }

    nonisolated static func output(_ binary: URL, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HelperError.exited(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// When a helper that ended on its own starts again: soon after a long run, then further
/// apart (with jitter) while it keeps ending right after it starts, and not again after
/// `maxQuickEnds` of those in a row.
nonisolated struct HelperRespawn: Equatable {
    /// launchd starts a crashed job again by itself; waiting a little first lets the app find
    /// that one rather than start another.
    static let firstDelay = Duration.milliseconds(500)
    static let maxDelay = Duration.seconds(30)
    static let stableAfter = Duration.seconds(30)
    static let maxQuickEnds = 5
    private(set) var endsInARow = 0

    /// The pause before starting again, or nil to leave it stopped. `jitter` in 0..<1 adds up
    /// to half the pause again.
    mutating func delay(afterRunning ranFor: Duration, jitter: Double) -> Duration? {
        if ranFor >= Self.stableAfter { endsInARow = 0 }
        endsInARow += 1
        guard endsInARow <= Self.maxQuickEnds else { return nil }
        let base = min(Self.firstDelay * (1 << (endsInARow - 1)), Self.maxDelay)
        return base + base * (min(max(jitter, 0), 1) / 2)
    }
}

nonisolated enum HelperError: Error, Equatable, LocalizedError {
    case notBundled
    case didNotStart
    case exited(Int32)
    case noTicket
    case keepsStopping
    case launchdRefused
    case olderHelperKeepsRunning

    var errorDescription: String? {
        switch self {
        case .notBundled: "This build doesn't include the helper."
        case .didNotStart: "The helper didn't start."
        case .exited(let status): "The helper stopped (status \(status))."
        case .noTicket: "The helper didn't hand out a pairing ticket."
        case .keepsStopping: "The helper keeps stopping right after it starts."
        case .launchdRefused: "launchd didn't start the helper."
        case .olderHelperKeepsRunning: "The older helper didn't stop. Quit it from a terminal and try again."
        }
    }
}
#endif
