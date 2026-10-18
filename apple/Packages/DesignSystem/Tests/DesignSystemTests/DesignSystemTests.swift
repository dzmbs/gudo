import Testing
@testable import DesignSystem

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
