import Testing
@testable import DesignSystem

@Test func mostUrgentStateLeadsWhatNeedsYou() {
    #expect(AgentState.mostUrgent([.idle, .done, .working, .blocked]) == .blocked)
    #expect(AgentState.mostUrgent([.idle, .error, .working]) == .error)
    #expect(AgentState.mostUrgent([.done, .working, .idle]) == .working)
    #expect(AgentState.mostUrgent([.idle, .done]) == .done)
    #expect(AgentState.mostUrgent([.idle, .unknown]) == .unknown)
    #expect(AgentState.mostUrgent([.idle]) == .idle)
    #expect(AgentState.mostUrgent([]) == nil)
    // Waiting for you comes before a failure: one can be answered now.
    #expect(AgentState.mostUrgent([.error, .blocked]) == .blocked)
}

@Test func urgencyOrdersEveryState() {
    let ordered: [AgentState] = [.blocked, .error, .working, .done, .unknown, .idle]
    #expect(AgentState.allCases.sorted { $0.urgency < $1.urgency } == ordered)
}

@Test func quietStatesAreDotsAndTheOnesThatNeedYouArePills() {
    #expect(AgentState.idle.statusMark == .dot)
    #expect(AgentState.working.statusMark == .dot)
    #expect(AgentState.done.statusMark == .dot)
    #expect(AgentState.blocked.statusMark == .pill)
    #expect(AgentState.error.statusMark == .pill)
    #expect(AgentState.unknown.statusMark == nil)
    #expect(AgentState.blocked.pillTitle == "Needs you")
    #expect(AgentState.error.pillTitle == "Failed")
}

@Test func onlyATabTurningBlockedOutOfSightCallsForAttention() {
    #expect(AgentState.callsForAttention(from: .working, to: .blocked, isVisible: false))
    #expect(AgentState.callsForAttention(from: nil, to: .blocked, isVisible: false))
    #expect(!AgentState.callsForAttention(from: .working, to: .blocked, isVisible: true))
    #expect(!AgentState.callsForAttention(from: .blocked, to: .blocked, isVisible: false))
    #expect(!AgentState.callsForAttention(from: .working, to: .error, isVisible: false))
    #expect(!AgentState.callsForAttention(from: .working, to: .done, isVisible: false))
}
