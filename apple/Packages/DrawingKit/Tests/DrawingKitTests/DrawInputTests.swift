import Testing
@testable import DrawingKit

/// The draw overlay's input rules without UIKit: tools and routing, the PencilKit hand-off,
/// one pane at a time, the loose tray, and handwriting at the prompt.
@Suite struct DrawInputTests {
    // MARK: Tools

    @Test func toolsRoundTripThroughExcalidraw() {
        for tool in DrawTool.allCases {
            #expect(DrawTool(excalidrawType: tool.excalidrawType) == tool)
        }
        #expect(DrawTool(excalidrawType: "diamond") == .rectangle)
        #expect(DrawTool(excalidrawType: "line") == .arrow)
        #expect(DrawTool(excalidrawType: "laser") == nil)
        #expect(DrawTool(excalidrawType: "hand") == nil)
    }

    @Test func oneFingerAndThePencilDrawWithTheChosenTool() {
        for tool in [DrawTool.rectangle, .ellipse, .arrow, .text, .eraser] {
            #expect(DrawRouting.layer(for: tool, touch: .finger) == .editor)
            #expect(DrawRouting.layer(for: tool, touch: .pencil) == .editor)
            #expect(DrawRouting.inkLayer(for: tool).interactive == false)
        }
        #expect(DrawRouting.layer(for: .pen, touch: .finger) == .ink)
        #expect(DrawRouting.layer(for: .pen, touch: .pencil) == .ink)
        #expect(DrawRouting.inkLayer(for: .pen) == (true, false))
    }

    @Test func thePencilAlwaysDrawsEvenWithSelect() {
        #expect(DrawRouting.layer(for: .select, touch: .pencil) == .ink)
        #expect(DrawRouting.layer(for: .select, touch: .finger) == .editor)
        #expect(DrawRouting.inkLayer(for: .select) == (true, true))
    }

    // MARK: Hand-off

    @Test func strokesBeforeThePageLoadedWaitForIt() {
        var handoff = InkHandoff()
        #expect(handoff.converted("a", at: 0) == false)
        #expect(handoff.converted("b", at: 0.1) == false)
        #expect(handoff.loaded(at: 0.5) == ["a", "b"])
        #expect(handoff.converted("c", at: 0.6) == true)
        let result = handoff.applied(["a", "b", "c"], at: 0.62)
        #expect(result.drop == ["a", "b", "c"])
        #expect(abs((result.latency["c"] ?? 0) - 0.02) < 1e-9)
        #expect(handoff.isSettled)
    }

    @Test func confirmedStrokesStayWhileThePencilIsDown() {
        var handoff = InkHandoff()
        _ = handoff.loaded(at: 0)
        _ = handoff.converted("a", at: 1)
        handoff.strokeBegan()  // the next stroke starts before the page confirms "a"
        #expect(handoff.applied(["a"], at: 1.03).drop.isEmpty)
        #expect(handoff.strokeEnded() == ["a"])
        #expect(handoff.strokeEnded().isEmpty)
    }

    @Test func unconfirmedStrokesAreResentAFewTimes() {
        var handoff = InkHandoff()
        _ = handoff.loaded(at: 0)
        _ = handoff.converted("a", at: 0)
        #expect(handoff.overdue(at: 0.5, timeout: 1).isEmpty)
        #expect(handoff.overdue(at: 1.5, timeout: 1) == ["a"])
        #expect(handoff.overdue(at: 3, timeout: 1) == ["a"])
        #expect(handoff.overdue(at: 4.5, timeout: 1) == ["a"])
        #expect(handoff.overdue(at: 6, timeout: 1).isEmpty)  // gave up after 4 sends
        #expect(!handoff.isSettled)
    }

    @Test func aReloadHoldsStrokesAgain() {
        var handoff = InkHandoff()
        _ = handoff.loaded(at: 0)
        _ = handoff.converted("a", at: 0)
        handoff.reloading()
        #expect(handoff.converted("b", at: 1) == false)
        #expect(handoff.loaded(at: 2) == ["a", "b"])
    }

    @Test func unknownConfirmationsAreIgnored() {
        var handoff = InkHandoff()
        _ = handoff.loaded(at: 0)
        #expect(handoff.applied(["ghost"], at: 1).drop.isEmpty)
    }

    // MARK: One pane at a time

    @Test func onlyOnePaneDraws() {
        #expect(DrawExclusivity.decide(requester: 1, active: nil, activeHasContent: false) == .open)
        #expect(DrawExclusivity.decide(requester: 1, active: 1, activeHasContent: true) == .alreadyOpen)
        #expect(DrawExclusivity.decide(requester: 2, active: 1, activeHasContent: false) == .closeOtherAndOpen)
        #expect(DrawExclusivity.decide(requester: 2, active: 1, activeHasContent: true) == .ask)
    }

    // MARK: Loose tray

    @Test func placementsNeverVanishSilently() {
        #expect(PlacementPlace.classify(live: true, pinned: true, rowOnScreen: true, atSeq: 5, applied: 9) == .pinned)
        #expect(PlacementPlace.classify(live: true, pinned: false, rowOnScreen: false, atSeq: 12, applied: 9) == .pending)
        // The row was evicted from this device's scrollback ring.
        #expect(PlacementPlace.classify(live: true, pinned: false, rowOnScreen: false, atSeq: 5, applied: 9) == .loose)
        #expect(PlacementPlace.classify(live: true, pinned: true, rowOnScreen: false, atSeq: 5, applied: 9) == .loose)
        #expect(PlacementPlace.classify(live: false, pinned: false, rowOnScreen: false, atSeq: 5, applied: 9) == .loose)
    }

    // MARK: Handwriting

    @Test func handwritingIsOneLineAndOnlyLeavesOnCommit() {
        var draft = HandwritingDraft()
        draft.update("git status")
        draft.update("git status\n--short ")
        #expect(draft.preview == "git status --short")
        #expect(draft.commit() == "git status --short")
        #expect(draft.text.isEmpty)
        #expect(draft.commit() == nil)
    }

    @Test func blankHandwritingCommitsNothing() {
        var draft = HandwritingDraft(text: "  \n ")
        #expect(draft.isEmpty)
        #expect(draft.commit() == nil)
    }
}
