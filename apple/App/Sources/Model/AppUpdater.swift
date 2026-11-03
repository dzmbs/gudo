#if os(macOS)
import AppKit
import Observation
import OSLog
import Sparkle

/// What the Mac app's update controls need from Sparkle's updater.
@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    func checkForUpdates()
}

extension SPUUpdater: UpdateChecking {}

/// Updates for the Mac app, downloaded outside the App Store (Sparkle): the feed is `SUFeedURL`
/// and every update must carry an EdDSA signature from the key whose public half is
/// `SUPublicEDKey` (both in the Info.plist). Checks run on Sparkle's daily schedule unless
/// turned off in Settings ▸ About. Only release builds start the updater: a local build would
/// offer to replace itself with the published app.
///
/// An update found on the schedule is offered in the sidebar (`UpdatePrompt`, `UpdateCard`),
/// not in windows of its own; `UpdateUserDriver` decides where each session plays out.
@MainActor
@Observable
final class AppUpdater {
    static var shared = AppUpdater()

    static let checkTitle = "Check for Updates…"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "updates")

    private(set) var canCheckForUpdates = false
    let prompt: UpdatePrompt
    @ObservationIgnored private let updater: UpdateChecking?
    @ObservationIgnored private var userDriver: UpdateUserDriver?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var sidebars: [SidebarWindow] = []

    /// A window whose sidebar shows the update control.
    private struct SidebarWindow {
        let window: Weak<NSWindow>
        let model: Weak<WindowModel>

        var showsSidebar: Bool {
            guard window.value != nil, let model = model.value else { return false }
            return model.isSidebarShown && !model.isEditorFullScreen
        }
    }

    init(updater: UpdateChecking, prompt: UpdatePrompt = UpdatePrompt()) {
        self.updater = updater
        self.prompt = prompt
        canCheckForUpdates = updater.canCheckForUpdates
    }

    private init() {
        prompt = UpdatePrompt()
        guard Self.startsUpdater else {
            updater = nil
            return
        }
        let userDriver = UpdateUserDriver(prompt: prompt) { AppUpdater.shared.sidebarIsFrontmost }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: nil)
        self.userDriver = userDriver
        self.updater = updater
        prompt.openURL = { NSWorkspace.shared.open($0) }
        prompt.reveal = { AppUpdater.shared.revealSidebar() }
        do {
            try updater.start()
        } catch {
            Self.log.error("updater did not start: \(error.localizedDescription, privacy: .public)")
        }
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    private static var startsUpdater: Bool {
        #if DEBUG
        false
        #else
        !LaunchOptions.isTesting && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        #endif
    }

    /// Whether this build updates itself at all (release builds).
    var isAvailable: Bool { updater != nil }

    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    var downloadsAutomatically: Bool {
        get {
            access(keyPath: \.downloadsAutomatically)
            return updater?.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.downloadsAutomatically) { updater?.automaticallyDownloadsUpdates = newValue }
        }
    }

    /// Automatic downloads can be turned on (they need automatic checks).
    var allowsAutomaticDownloads: Bool {
        access(keyPath: \.checksAutomatically)
        return updater?.allowsAutomaticUpdates ?? false
    }

    /// Checks now. The answer shows in the sidebar when the key window shows one, else in the
    /// updater's standard window.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    func registerSidebar(in window: NSWindow, model: WindowModel) {
        sidebars.removeAll { $0.window.value == nil || $0.window.value === window }
        sidebars.append(SidebarWindow(window: Weak(window), model: Weak(model)))
    }

    var sidebarIsFrontmost: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return sidebars.contains { $0.window.value === key && $0.showsSidebar }
    }

    /// The key window's sidebar, else the front-most window's, shown and brought forward.
    func revealSidebar() {
        let ordered = NSApp.orderedWindows
        func depth(_ entry: SidebarWindow) -> Int {
            ordered.firstIndex { $0 === entry.window.value } ?? .max
        }
        guard let entry = sidebars.filter({ $0.window.value != nil && $0.model.value != nil }).min(by: { depth($0) < depth($1) }),
              let window = entry.window.value, let model = entry.model.value
        else { return }
        if !model.isSidebarShown { model.isSidebarShown = true }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
#endif
