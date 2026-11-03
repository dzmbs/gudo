#if os(macOS)
import Foundation
import Observation
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
@MainActor
@Observable
final class AppUpdater {
    static var shared = AppUpdater()

    static let checkTitle = "Check for Updates…"

    private(set) var canCheckForUpdates = false
    @ObservationIgnored private let updater: UpdateChecking?
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(updater: UpdateChecking) {
        self.updater = updater
        controller = nil
        canCheckForUpdates = updater.canCheckForUpdates
    }

    private init() {
        guard Self.startsUpdater else {
            updater = nil
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        updater = controller.updater
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
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

    /// Checks now and shows Sparkle's standard window with the result.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }
}
#endif
