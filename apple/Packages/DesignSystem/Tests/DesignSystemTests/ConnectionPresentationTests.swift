import Foundation
import Testing
@testable import DesignSystem

/// What the connection overlay shows over a host's panes, by state and by how long it lasted.
@MainActor
@Suite struct ConnectionPresentationTests {
    private func presentation(
        _ state: ConnectionState, savedState: Bool = false, thisDevice: Bool = false, downFor: TimeInterval
    ) -> ConnectionPresentation {
        ConnectionPresentation(
            state: state, hostName: "This Mac", showsSavedState: savedState, isThisDevice: thisDevice,
            downFor: downFor, now: Date(timeIntervalSinceReferenceDate: 1000))
    }

    @Test func aHelperStartingSaysStartingWithoutALastContact() {
        let state = ConnectionState.starting
        #expect(state.title == "Starting…")
        #expect(!state.isLive && !state.isQuiet && !state.isFailure)
        let shown = presentation(state, thisDevice: true, downFor: 10)
        #expect(shown.notice?.text == "Starting…")
        #expect(shown.card == nil)
        #expect(presentation(state, thisDevice: true, downFor: 120).card == nil, "starting never turns into a lost-connection card")
    }

    @Test func nothingShowsForAQuickStart() {
        for downFor in [0, 0.15, 0.5] as [TimeInterval] {
            let shown = presentation(.starting, thisDevice: true, downFor: downFor)
            #expect(shown == ConnectionPresentation(), "\(downFor) s")
        }
    }

    @Test func aStartingHelpersLastFramesStayReadable() {
        let shown = presentation(.starting, thisDevice: true, downFor: 10)
        #expect(shown.fade <= ChromePalette.waitingLevel)
        #expect(presentation(.starting, savedState: true, thisDevice: true, downFor: 10).fade == 0,
                "saved screens carry their own light wash")
    }

    @Test func savedScreensAreNeverDimmedFurther() {
        let since = Date(timeIntervalSinceReferenceDate: 990)
        #expect(presentation(.reconnecting(attempt: 2, since: since), savedState: true, downFor: 10).fade == 0)
        #expect(presentation(.connecting(phase: nil), savedState: true, downFor: 10).fade == 0)
        #expect(presentation(.reconnecting(attempt: 2, since: since), downFor: 10).fade > 0, "a live pane's last frame dims")
    }

    @Test func thisMacsLostHelperDoesNotPromiseRunningSessions() throws {
        let since = Date(timeIntervalSinceReferenceDate: 900)
        let mac = try #require(presentation(.reconnecting(attempt: 5, since: since), thisDevice: true, downFor: 100).card)
        #expect(!mac.detail.contains("keep running"), "the helper itself may have stopped: \(mac.detail)")
        #expect(mac.detail.contains("helper"))
        let remote = try #require(presentation(.reconnecting(attempt: 5, since: since), downFor: 100).card)
        #expect(remote.detail.contains("Sessions keep running"))
    }
}
