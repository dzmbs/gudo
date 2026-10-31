import Testing
@testable import DesignSystem

/// A keyboard slide right after a resize (an app coming back to the front) hides the overlay
/// instead of leaving the first size on screen for good.
@Test func resizeOverlayHidesOnASuppressedChange() {
    var state = ResizeOverlayState(ready: true)
    let first = state.change(to: GridSize(cols: 51, rows: 25), mode: .afterFirst, suppressed: false)
    #expect(!first, "the first size")
    let resized = state.change(to: GridSize(cols: 51, rows: 24), mode: .afterFirst, suppressed: false)
    #expect(resized && state.visible)
    let keyboard = state.change(to: GridSize(cols: 51, rows: 20), mode: .afterFirst, suppressed: true)
    #expect(!keyboard && !state.visible)
    let never = state.change(to: GridSize(cols: 50, rows: 20), mode: .never, suppressed: false)
    #expect(!never)
    let always = state.change(to: GridSize(cols: 40, rows: 20), mode: .always, suppressed: false)
    #expect(always)
}

@Test func themeCatalogLoadsGhosttyThemes() {
    #expect(ThemeCatalog.all.count > 400)
    #expect(ThemeCatalog.all.allSatisfy { $0.palette.count == 16 })
    #expect(ThemeCatalog.theme(named: "Catppuccin Mocha").bg == "#1e1e2e")
    #expect(ThemeCatalog.theme(named: "no such theme") == .ghosttyDefault)
}

@Test func defaultThemeIsDark() {
    #expect(!TerminalTheme.ghosttyDefault.isLight)
    #expect(ThemeCatalog.theme(named: "iTerm2 Solarized Light").isLight)
}

@Test func fuzzyMatchPrefersPrefixes() {
    #expect(FuzzyMatch.indices("spr", in: "Split Right") == [0, 1, 6])
    #expect(FuzzyMatch.indices("xyz", in: "Split Right") == nil)
    #expect(FuzzyMatch.score("new", in: "New Tab")! > FuzzyMatch.score("new", in: "Rename Window")!)
}

@Test func agentStateUrgencyPutsBlockedFirst() {
    let sorted = AgentState.allCases.sorted { $0.urgency < $1.urgency }
    #expect(sorted.first == .blocked)
    #expect(sorted.last == .idle)
}
