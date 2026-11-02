import Synchronization
import XCTest
@testable import App

/// App Lock's state machine: cold launch, the grace period, and what unlocking needs.
@MainActor
final class AppLockTests: XCTestCase {
    private final class FakeAuthenticator: AppLockAuthenticator, @unchecked Sendable {
        let results = Mutex<[AppLockAuthResult]>([])
        let reasons = Mutex<[String]>([])
        let available = Mutex<AppLockMethod?>(.faceID)

        func method() -> AppLockMethod? { available.withLock { $0 } }

        func authenticate(reason: String) async -> AppLockAuthResult {
            reasons.withLock { $0.append(reason) }
            return results.withLock { $0.isEmpty ? .success : $0.removeFirst() }
        }

        func answer(_ result: AppLockAuthResult) { results.withLock { $0.append(result) } }
        var asked: Int { reasons.withLock { $0.count } }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private let authenticator = FakeAuthenticator()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero

    override func setUp() async throws {
        suite = "app-lock-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeLock() -> AppLock {
        AppLock(defaults: defaults, authenticator: authenticator, now: { [unowned self] in start + elapsed })
    }

    /// App Lock on, as a previous launch left it.
    private func enabledLock(grace: AppLock.Grace = .oneMinute) -> AppLock {
        defaults.set(true, forKey: AppLock.enabledKey)
        defaults.set(grace.rawValue, forKey: AppLock.graceKey)
        return makeLock()
    }

    func testOffByDefaultAndNeverLocks() {
        let lock = makeLock()
        XCTAssertFalse(lock.isEnabled)
        XCTAssertEqual(lock.grace, .oneMinute, "the default grace period")
        lock.didEnterBackground()
        elapsed = .seconds(3600)
        lock.willEnterForeground()
        XCTAssertFalse(lock.isLocked)
    }

    func testColdLaunchStartsLocked() async {
        let lock = enabledLock()
        XCTAssertTrue(lock.isLocked)
        authenticator.answer(.cancelled)
        let unlocked = await lock.unlock()
        XCTAssertFalse(unlocked)
        XCTAssertTrue(lock.isLocked, "a cancel keeps it locked")
        let again = await lock.unlock()
        XCTAssertTrue(again)
        XCTAssertFalse(lock.isLocked)
    }

    func testLocksOnlyAfterTheGracePeriod() async {
        let lock = enabledLock(grace: .fiveMinutes)
        await lock.unlock()

        lock.didEnterBackground()
        elapsed += .seconds(299)
        lock.willEnterForeground()
        XCTAssertFalse(lock.isLocked, "back within the grace period")

        lock.didEnterBackground()
        elapsed += .seconds(300)
        lock.willEnterForeground()
        XCTAssertTrue(lock.isLocked, "away for the whole grace period")
    }

    func testGraceCountsFromWhenTheAppLeftNotFromTheLastReturn() async {
        let lock = enabledLock(grace: .oneMinute)
        await lock.unlock()
        lock.didEnterBackground()
        elapsed += .seconds(50)
        // A second "left" (another scene, a repeated notification) does not restart the clock.
        lock.didEnterBackground()
        elapsed += .seconds(20)
        lock.willEnterForeground()
        XCTAssertTrue(lock.isLocked)
    }

    func testImmediatelyLocksAsTheAppLeaves() async {
        let lock = enabledLock(grace: .immediately)
        await lock.unlock()
        lock.didEnterBackground()
        XCTAssertTrue(lock.isLocked, "locked before the app switcher's snapshot")
    }

    /// The Mac's Touch ID panel takes the app out of the front; with "Immediately" that must
    /// not lock it again right after the unlock.
    func testTheSystemPromptDoesNotRelock() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        defaults.set(AppLock.Grace.immediately.rawValue, forKey: AppLock.graceKey)
        let gate = AsyncStream<Void>.makeStream()
        let blocking = BlockingAuthenticator(release: gate.stream)
        let mac = AppLock(defaults: defaults, authenticator: blocking, now: { [unowned self] in start + elapsed })
        XCTAssertTrue(mac.isLocked)
        let unlocking = Task { await mac.unlock() }
        while !mac.isAuthenticating { await Task.yield() }
        mac.didEnterBackground()
        gate.continuation.yield()
        let unlocked = await unlocking.value
        XCTAssertTrue(unlocked)
        mac.willEnterForeground()
        XCTAssertFalse(mac.isLocked)
    }

    private final class BlockingAuthenticator: AppLockAuthenticator, @unchecked Sendable {
        let release: AsyncStream<Void>
        init(release: AsyncStream<Void>) { self.release = release }
        func method() -> AppLockMethod? { .touchID }
        func authenticate(reason: String) async -> AppLockAuthResult {
            for await _ in release { break }
            return .success
        }
    }

    func testPromptsOnItsOwnOncePerReturn() async {
        let lock = enabledLock(grace: .immediately)
        authenticator.answer(.cancelled)
        await lock.promptIfNeeded()
        await lock.promptIfNeeded()
        XCTAssertEqual(authenticator.asked, 1, "a cancelled prompt is not shown again by itself")
        XCTAssertTrue(lock.isLocked)
        // The next time the app comes back it asks again.
        lock.didEnterBackground()
        lock.willEnterForeground()
        await lock.promptIfNeeded()
        XCTAssertEqual(authenticator.asked, 2)
        XCTAssertFalse(lock.isLocked)
    }

    func testFailureIsShownAndUnlockingStillWorks() async {
        let lock = enabledLock()
        authenticator.answer(.failed("Face ID did not match."))
        await lock.unlock()
        XCTAssertEqual(lock.failure, "Face ID did not match.")
        XCTAssertTrue(lock.isLocked)
        await lock.unlock()
        XCTAssertNil(lock.failure)
        XCTAssertFalse(lock.isLocked)
    }

    func testTurningOnAndOffNeedsTheOwner() async {
        let lock = makeLock()
        authenticator.answer(.cancelled)
        let cancelled = await lock.setEnabled(true)
        XCTAssertFalse(cancelled)
        XCTAssertFalse(lock.isEnabled)
        let on = await lock.setEnabled(true)
        XCTAssertTrue(on)
        XCTAssertTrue(lock.isEnabled)
        XCTAssertFalse(lock.isLocked, "turning it on does not lock the app in use")
        XCTAssertTrue(defaults.bool(forKey: AppLock.enabledKey))
        XCTAssertTrue(makeLock().isLocked, "the next launch starts locked")

        authenticator.answer(.failed("No"))
        let refused = await lock.setEnabled(false)
        XCTAssertFalse(refused)
        XCTAssertTrue(lock.isEnabled, "someone holding the unlocked app cannot quietly turn it off")
    }

    func testCannotTurnOnWithoutAPasscode() async {
        authenticator.available.withLock { $0 = nil }
        let lock = makeLock()
        let on = await lock.setEnabled(true)
        XCTAssertFalse(on)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertEqual(authenticator.asked, 0)
        XCTAssertNotNil(lock.failure)
    }

    /// The passcode was removed after App Lock was turned on: there is no owner left to check,
    /// so the app opens instead of locking its owner out.
    func testPasscodeRemovedTurnsItOff() async {
        let lock = enabledLock()
        authenticator.answer(.passcodeNotSet)
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isEnabled)
    }

    func testSettingNamesTheDevicesBiometry() {
        XCTAssertEqual(makeLock().settingTitle, "Require Face ID")
        authenticator.available.withLock { $0 = .touchID }
        XCTAssertEqual(makeLock().settingTitle, "Require Touch ID")
        authenticator.available.withLock { $0 = .passcode }
        #if os(macOS)
        XCTAssertEqual(makeLock().settingTitle, "Require Password")
        #else
        XCTAssertEqual(makeLock().settingTitle, "Require Passcode")
        #endif
    }

    func testChangesReachTheWindowCovers() async {
        let lock = makeLock()
        var calls = 0
        lock.onChange = { calls += 1 }
        await lock.setEnabled(true)
        lock.didEnterBackground()
        elapsed += .seconds(61)
        lock.willEnterForeground()
        XCTAssertEqual(calls, 2, "on, then locked")
    }

    func testHostedTestsNeverLock() {
        XCTAssertFalse(AppLock.shared.isEnabled)
        XCTAssertFalse(AppLock.shared.isLocked)
    }
}
