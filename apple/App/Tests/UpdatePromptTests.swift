#if os(macOS)
import Sparkle
import XCTest
@testable import App

/// The sidebar's update control: what the updater reports moves it on, and its choices reach the
/// updater as replies.
@MainActor
final class UpdatePromptTests: XCTestCase {
    private let suite = "update-prompt-tests"
    private var defaults: UserDefaults!
    private var replies: [UpdateChoice] = []

    private let offer = UpdateOffer(version: "815", displayVersion: "0.1.4", notes: "• Faster reconnects")

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        replies = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makePrompt(upToDateDuration: Duration = .seconds(60)) -> UpdatePrompt {
        UpdatePrompt(defaults: defaults, upToDateDuration: upToDateDuration)
    }

    private func reply(_ choice: UpdateChoice) {
        replies.append(choice)
    }

    func testAnUpdateMovesFromOfferToRestart() {
        let prompt = makePrompt()
        XCTAssertEqual(prompt.phase, .hidden)
        XCTAssertFalse(prompt.showsCard)

        prompt.found(offer, stage: .notDownloaded, userInitiated: false, reply: reply)
        XCTAssertEqual(prompt.phase, .available)
        XCTAssertTrue(prompt.showsCard)
        XCTAssertEqual(prompt.offer?.displayVersion, "0.1.4")

        prompt.accept()
        XCTAssertEqual(replies, [.install])
        XCTAssertEqual(prompt.phase, .downloading(nil), "progress before the updater reports any")

        var cancelled = false
        prompt.downloadStarted { cancelled = true }
        prompt.downloadExpects(1000)
        XCTAssertEqual(prompt.phase, .downloading(0))
        prompt.downloadReceived(425)
        XCTAssertEqual(prompt.phase, .downloading(0.42), "whole percents")
        prompt.downloadReceived(575)
        XCTAssertEqual(prompt.phase, .downloading(1))

        prompt.extractionStarted()
        XCTAssertEqual(prompt.phase, .preparing(nil))
        prompt.extractionProgressed(0.5)
        XCTAssertEqual(prompt.phase, .preparing(0.5))

        prompt.readyToInstall(reply: reply)
        XCTAssertEqual(prompt.phase, .ready)
        XCTAssertEqual(replies, [.install], "waits for Restart to Update")

        prompt.accept()
        XCTAssertEqual(replies, [.install, .install])
        XCTAssertEqual(prompt.phase, .installing)

        var retried = 0
        prompt.installing(applicationTerminated: false) { retried += 1 }
        XCTAssertFalse(prompt.canRetryRestart)
        prompt.restartStalled()
        XCTAssertTrue(prompt.canRetryRestart, "the app kept itself open")
        prompt.accept()
        XCTAssertEqual(retried, 1)
        XCTAssertFalse(cancelled)

        prompt.finished()
        XCTAssertEqual(prompt.phase, .hidden)
        XCTAssertNil(prompt.offer)
    }

    func testADownloadedUpdateRestartsInOneClick() {
        let prompt = makePrompt()
        prompt.found(offer, stage: .downloaded, userInitiated: false, reply: reply)
        XCTAssertEqual(prompt.phase, .ready)
        prompt.accept()
        XCTAssertEqual(replies, [.install])
        prompt.extractionStarted()
        prompt.readyToInstall(reply: reply)
        XCTAssertEqual(replies, [.install, .install], "already answered")
        XCTAssertEqual(prompt.phase, .installing)
    }

    func testDismissSkipsTheVersionUntilANewerOne() {
        let prompt = makePrompt()
        prompt.found(offer, stage: .notDownloaded, userInitiated: false, reply: reply)
        prompt.dismiss()
        XCTAssertEqual(replies, [.skip])
        XCTAssertEqual(prompt.phase, .hidden)
        XCTAssertEqual(prompt.dismissedVersion, "815")

        let later = makePrompt()
        later.found(offer, stage: .downloaded, userInitiated: false, reply: reply)
        XCTAssertEqual(replies, [.skip, .dismiss], "the same version stays out of sight")
        XCTAssertEqual(later.phase, .hidden)

        var newer = offer
        newer.version = "820"
        later.found(newer, stage: .notDownloaded, userInitiated: false, reply: reply)
        XCTAssertEqual(later.phase, .available)
    }

    func testACheckAskedForShowsADismissedVersionAgain() {
        let prompt = makePrompt()
        prompt.dismissedVersion = "815"
        prompt.isMinimized = true
        prompt.checkStarted {}
        prompt.found(offer, stage: .notDownloaded, userInitiated: true, reply: reply)
        XCTAssertEqual(prompt.phase, .available)
        XCTAssertNil(prompt.dismissedVersion)
        XCTAssertTrue(prompt.showsCard, "asked for: shown in full")
    }

    func testDismissingARestartInstallsOnQuit() {
        let prompt = makePrompt()
        prompt.found(offer, stage: .installing, userInitiated: false, reply: reply)
        XCTAssertEqual(prompt.phase, .ready)
        prompt.dismiss()
        XCTAssertEqual(replies, [.dismiss], "dismiss, not skip: the installer still runs at quit")
        XCTAssertEqual(prompt.dismissedVersion, "815")
    }

    func testClosingADownloadCancelsIt() {
        let prompt = makePrompt()
        prompt.found(offer, stage: .notDownloaded, userInitiated: false, reply: reply)
        prompt.accept()
        var cancelled = false
        prompt.downloadStarted { cancelled = true }
        prompt.dismiss()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(prompt.phase, .hidden)
        XCTAssertNil(prompt.dismissedVersion, "offered again next time")
    }

    func testMinimizedIsRemembered() {
        let prompt = makePrompt()
        prompt.found(offer, stage: .notDownloaded, userInitiated: false, reply: reply)
        prompt.toggleMinimized()
        XCTAssertTrue(prompt.showsIndicator)
        XCTAssertFalse(prompt.showsCard)
        XCTAssertTrue(defaults.bool(forKey: UpdatePrompt.minimizedKey))

        let relaunched = makePrompt()
        XCTAssertTrue(relaunched.isMinimized)
        XCTAssertFalse(relaunched.showsIndicator, "nothing on offer, nothing shown")
        relaunched.found(offer, stage: .notDownloaded, userInitiated: false, reply: reply)
        XCTAssertTrue(relaunched.showsIndicator)
        relaunched.focus()
        XCTAssertTrue(relaunched.showsCard, "brought to focus by Check for Updates")
    }

    func testACheckAskedForAnswersInTheCard() async throws {
        let prompt = makePrompt(upToDateDuration: .milliseconds(50))
        var cancelled = false
        prompt.checkStarted { cancelled = true }
        XCTAssertEqual(prompt.phase, .checking)
        XCTAssertTrue(prompt.showsCard)
        prompt.notFound(upToDate: true, message: "")
        XCTAssertEqual(prompt.phase, .upToDate)
        prompt.finished()
        XCTAssertEqual(prompt.phase, .upToDate, "outlives the session for a moment")
        for _ in 0..<40 where prompt.phase != .hidden { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(prompt.phase, .hidden)

        prompt.checkStarted { cancelled = true }
        prompt.dismiss()
        XCTAssertTrue(cancelled)

        prompt.checkStarted {}
        prompt.notFound(upToDate: false, message: "Needs a newer macOS.")
        XCTAssertEqual(prompt.phase, .failed("Needs a newer macOS."))
        prompt.dismiss()
        XCTAssertEqual(prompt.phase, .hidden)
    }

    func testAScheduledCheckThatFindsNothingStaysQuiet() {
        let prompt = makePrompt()
        prompt.notFound(upToDate: true, message: "")
        prompt.failed("offline")
        XCTAssertEqual(prompt.phase, .hidden)
    }

    func testAnErrorMidUpdateShows() {
        let prompt = makePrompt()
        prompt.found(offer, stage: .notDownloaded, userInitiated: false, reply: reply)
        prompt.accept()
        prompt.failed("The update is improperly signed.")
        XCTAssertEqual(prompt.phase, .failed("The update is improperly signed."))
        prompt.finished()
        XCTAssertEqual(prompt.phase, .failed("The update is improperly signed."))
    }

    func testAnInformationOnlyUpdateOpensItsPage() {
        let prompt = makePrompt()
        var opened: [URL] = []
        prompt.openURL = { opened.append($0) }
        let page = URL(string: "https://example.com/release")!
        prompt.found(UpdateOffer(version: "900", displayVersion: "1.0", isInformationOnly: true, infoURL: page), stage: .notDownloaded, userInitiated: false, reply: reply)
        prompt.accept()
        XCTAssertEqual(opened, [page])
        XCTAssertEqual(replies, [.dismiss], "never installed")
    }

    func testReleaseNotesBecomePlainText() {
        let html = "<h2>New</h2><ul><li>Faster&nbsp;reconnects</li><li>Fixes &amp; polish</li></ul><script>alert(1)</script><p>Thanks!</p>"
        XCTAssertEqual(ReleaseNotes.text(html, format: nil), "New\n\n• Faster reconnects\n• Fixes & polish\nThanks!")
        XCTAssertEqual(ReleaseNotes.text("**Bold** move", format: "markdown"), "Bold move")
        XCTAssertEqual(ReleaseNotes.text("  Line one  \n\n\n  Line two ", format: "plain-text"), "Line one\n\nLine two")
        XCTAssertNil(ReleaseNotes.text(" \n ", format: nil))
        XCTAssertNil(ReleaseNotes.text(data: Data(repeating: 0x41, count: ReleaseNotes.largestInlinePage + 1), mimeType: "text/html"), "a web page opens in the browser")
        XCTAssertEqual(ReleaseNotes.text(data: Data("Hello".utf8), mimeType: "text/plain"), "Hello")
    }

    func testTheFeedItemBecomesAnOffer() throws {
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "title": "Version 0.1.4",
            "sparkle:version": "815",
            "sparkle:shortVersionString": "0.1.4",
            "description": "<ul><li>Faster reconnects</li></ul>",
            "sparkle:releaseNotesLink": ["content": "https://example.com/notes"],
            "enclosure": ["url": "https://example.com/App.dmg", "length": "100", "type": "application/octet-stream", "sparkle:edSignature": "c2lnbmF0dXJl"],
        ]))
        let offer = UpdateOffer(item)
        XCTAssertEqual(offer.version, "815")
        XCTAssertEqual(offer.displayVersion, "0.1.4")
        XCTAssertEqual(offer.notes, "• Faster reconnects")
        XCTAssertEqual(offer.notesURL?.absoluteString, "https://example.com/notes")
        XCTAssertFalse(offer.isInformationOnly)
    }
}
#endif
