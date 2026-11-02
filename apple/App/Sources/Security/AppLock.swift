import Foundation
import LocalAuthentication
import Observation

/// How this device proves its owner: its biometry, else its passcode (Mac: login password).
nonisolated enum AppLockMethod: Sendable, Equatable {
    case faceID, touchID, opticID, passcode

    var name: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode:
            #if os(macOS)
            "Password"
            #else
            "Passcode"
            #endif
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock.fill"
        }
    }
}

nonisolated enum AppLockAuthResult: Sendable, Equatable {
    case success
    /// The user or the system cancelled; nothing to say.
    case cancelled
    /// The device has no passcode (any more): there is no owner to check.
    case passcodeNotSet
    case failed(String)
}

/// Asks the device owner to prove it's them.
protocol AppLockAuthenticator: Sendable {
    /// What the system will ask for; nil when the device has no passcode.
    func method() -> AppLockMethod?
    func authenticate(reason: String) async -> AppLockAuthResult
}

/// LocalAuthentication's device owner check: biometrics with the passcode as fallback.
nonisolated struct SystemAppLockAuthenticator: AppLockAuthenticator {
    func method() -> AppLockMethod? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return nil }
        // Biometry that is not enrolled falls back to the passcode: name what will be asked.
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .passcode }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    func authenticate(reason: String) async -> AppLockAuthResult {
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .notInteractive, .userFallback: return .cancelled
            case .passcodeNotSet: return .passcodeNotSet
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// App Lock: with "Require Face ID" on, the app opens locked and locks again after it has been
/// in the background longer than the grace period. Only the windows are locked: connections,
/// agents and notifications carry on. Windows draw the lock with `AppLockCovers`.
@MainActor
@Observable
final class AppLock {
    static let shared: AppLock = {
        // The lock's own design fixture: locked, and stays so (`-screen app-lock`).
        if LaunchOptions.screen == "app-lock", let defaults = UserDefaults(suiteName: "app-lock.fixture") {
            defaults.set(true, forKey: enabledKey)
            return AppLock(defaults: defaults, authenticator: StaysLocked())
        }
        // Hosting unit tests and fixtures never lock.
        return AppLock(
            defaults: LaunchOptions.isTesting || LaunchOptions.mock ? UserDefaults(suiteName: "app-lock.unused") ?? .standard : .standard)
    }()

    nonisolated private struct StaysLocked: AppLockAuthenticator {
        func method() -> AppLockMethod? { .faceID }
        func authenticate(reason: String) async -> AppLockAuthResult { .cancelled }
    }

    nonisolated enum Grace: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .immediately: "Immediately"
            case .oneMinute: "After 1 Minute"
            case .fiveMinutes: "After 5 Minutes"
            case .fifteenMinutes: "After 15 Minutes"
            }
        }
    }

    nonisolated static let enabledKey = "app-lock.enabled"
    nonisolated static let graceKey = "app-lock.grace"

    private(set) var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            changed()
        }
    }

    var grace: Grace {
        didSet { defaults.set(grace.rawValue, forKey: Self.graceKey) }
    }

    private(set) var isLocked: Bool {
        didSet { if isLocked != oldValue { changed() } }
    }

    /// A system prompt is up.
    private(set) var isAuthenticating = false
    /// Why the last unlock failed, under the Unlock button.
    private(set) var failure: String?
    /// What the system will ask for (nil: the device has no passcode).
    private(set) var method: AppLockMethod?

    /// Called when the lock or the setting changes (the window covers follow).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: any AppLockAuthenticator
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    /// When the app left the foreground (nil: it is in front, or App Lock is off).
    @ObservationIgnored private var leftAt: ContinuousClock.Instant?
    /// The prompt was shown on its own since the app came forward; a cancel is not re-asked.
    @ObservationIgnored private var prompted = false

    /// `now`: a clock that keeps counting while the device sleeps.
    init(
        defaults: UserDefaults = .standard,
        authenticator: any AppLockAuthenticator = SystemAppLockAuthenticator(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        grace = (defaults.object(forKey: Self.graceKey) as? Int).flatMap(Grace.init(rawValue:)) ?? .oneMinute
        // A cold launch starts locked.
        isLocked = enabled
        method = authenticator.method()
    }

    /// The setting's name: "Require Face ID", "Require Touch ID", "Require Passcode".
    var settingTitle: String { "Require \((method ?? .passcode).name)" }

    // MARK: Foreground and background

    /// The app went to the background (iOS) or another app came to the front (Mac).
    func didEnterBackground() {
        // The system's own prompt takes the app out of the front on the Mac.
        guard isEnabled, !isAuthenticating, leftAt == nil else { return }
        leftAt = now()
        prompted = false
        if grace == .immediately { isLocked = true }
    }

    /// The app is coming back: locked when it was away for the grace period or longer.
    func willEnterForeground() {
        defer { leftAt = nil }
        guard isEnabled, let leftAt else { return }
        if now() - leftAt >= .seconds(grace.rawValue) { isLocked = true }
    }

    // MARK: Unlocking

    /// Shows the system prompt once per return to the foreground (the lock screen appearing);
    /// after a cancel the user taps Unlock.
    func promptIfNeeded() async {
        guard isLocked, !prompted else { return }
        prompted = true
        await unlock()
    }

    @discardableResult
    func unlock() async -> Bool {
        guard isLocked else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        failure = nil
        let result = await authenticator.authenticate(reason: Self.unlockReason)
        isAuthenticating = false
        switch result {
        case .success:
            leftAt = nil
            isLocked = false
        case .cancelled:
            break
        case .passcodeNotSet:
            // Without a passcode there is no owner to check (removing it took the passcode).
            isEnabled = false
            isLocked = false
        case .failed(let message):
            failure = message
        }
        refreshMethod()
        return !isLocked
    }

    /// Turns App Lock on or off once the owner confirms; false when they did not.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled != isEnabled else { return true }
        refreshMethod()
        failure = nil
        if enabled, method == nil {
            failure = Self.noPasscode
            return false
        }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        let result = await authenticator.authenticate(reason: enabled ? Self.enableReason : Self.disableReason)
        isAuthenticating = false
        switch result {
        case .success:
            isEnabled = enabled
            return true
        case .passcodeNotSet:
            failure = Self.noPasscode
            if !enabled { isEnabled = false }
            return !enabled
        case .cancelled:
            return false
        case .failed(let message):
            failure = message
            return false
        }
    }

    func refreshMethod() {
        method = authenticator.method()
    }

    private func changed() {
        onChange?()
    }

    #if os(macOS)
    // macOS: "<App> is trying to <reason>."
    static let unlockReason = "unlock your terminals"
    static let enableReason = "turn on App Lock"
    static let disableReason = "turn off App Lock"
    static let noPasscode = "Set a login password in System Settings to use this."
    #else
    static let unlockReason = "Unlock to see your terminals."
    static let enableReason = "Turn on App Lock."
    static let disableReason = "Turn off App Lock."
    static let noPasscode = "Set a passcode in Settings to use this."
    #endif
}
