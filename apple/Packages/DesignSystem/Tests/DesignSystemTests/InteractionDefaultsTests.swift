import Testing
@testable import DesignSystem

@Suite struct InteractionDefaultsTests {
    @Test func paneEmphasisIsOffByDefault() {
        #expect(TerminalPreferences.Default.paneActiveBorder == false)
        #expect(TerminalPreferences.Default.paneContentCard == false)
        #expect(TerminalPreferences.Default.paneInactiveFade == .dim)
        #expect(TerminalPreferences.InactivePaneFade.dim.dimsContent && TerminalPreferences.InactivePaneFade.dim.dimsHeader)
        #expect(!TerminalPreferences.InactivePaneFade.header.dimsContent && TerminalPreferences.InactivePaneFade.header.dimsHeader)
        #expect(!TerminalPreferences.InactivePaneFade.none.dimsContent && !TerminalPreferences.InactivePaneFade.none.dimsHeader)
    }

    @Test func storedValuesKeepTheirNames() {
        #expect(TerminalPreferences.Key.paneActiveBorder == "pane-active-border")
        #expect(TerminalPreferences.Key.paneInactiveFade == "pane-inactive-fade")
        #expect(TerminalPreferences.Key.paneContentCard == "pane-content-card")
        #expect(TerminalPreferences.Key.sidebarTextSize == "sidebar-text-size")
        #expect(ToastPosition.key == "toast-position")
        #expect(TerminalPreferences.InactivePaneFade.allCases.map(\.rawValue) == ["dim", "header", "none"])
        #expect(TerminalPreferences.SidebarTextSize.allCases.map(\.rawValue) == ["system", "small", "medium", "large"])
    }

    @Test func theSidebarFollowsTheSystemSizeUnlessChosen() {
        #expect(TerminalPreferences.Default.sidebarTextSize == .system)
        #expect(DS.Font.SidebarSize(.system, systemMode: 0) == .medium)
        #expect(DS.Font.SidebarSize(.system, systemMode: 1) == .small)
        #expect(DS.Font.SidebarSize(.system, systemMode: 3) == .large)
        #expect(DS.Font.SidebarSize(.small, systemMode: 3) == .small)
        #expect(DS.Font.SidebarSize(.large, systemMode: 1) == .large)
        #expect(DS.Font.sidebar(.small).icon < DS.Font.sidebar(.medium).icon)
        #expect(DS.Font.sidebar(.medium).icon < DS.Font.sidebar(.large).icon)
        #expect(DS.Font.sidebar(.medium).widthExtra == 0)
    }
}
