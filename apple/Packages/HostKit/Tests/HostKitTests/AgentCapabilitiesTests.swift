import Testing
@testable import HostKit

struct AgentCapabilitiesTests {
    /// An agent started by hand, which the first send restarts through the helper's launch,
    /// takes sends like any other; one without either stays read-only.
    @Test func theComposerSendsToAnAgentTheFirstSendTakesOver() {
        let takeover: AgentCapabilities = [.read, .sendAfterTakeover]
        #expect(takeover.forComposer.contains(.send))
        #expect(!takeover.forComposer.contains(.stop))
        let readOnly: AgentCapabilities = [.read]
        #expect(!readOnly.forComposer.contains(.send))
        #expect(AgentCapabilities.sendAfterTakeover.rawValue == 1 << 9)
    }
}
