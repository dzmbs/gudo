import Foundation
import GudoCore
import HostKit
import XCTest
@testable import App

@MainActor
final class ChatAgentControlsTests: XCTestCase {
    /// The JSON the helper's FFI sends for a Claude pane with a question waiting.
    static let controlsJSON = """
    {"pane_id":7,"config":{"support":"Supported","current":{"model":"opus","mode":"default","effort":null},
     "pending":null,
     "models":[{"id":"opus","label":"Opus","detail":"The latest Opus"},{"id":"sonnet","label":"Sonnet","detail":""}],
     "modes":[{"choice":{"id":"default","label":"Ask","detail":""},"risk":"Asks"},
              {"choice":{"id":"bypassPermissions","label":"Bypass permissions","detail":""},"risk":"Bypass"},
              {"choice":{"id":"later","label":"Later","detail":""},"risk":"Future"}],
     "efforts":[{"id":"high","label":"High","detail":""}],"timing":"Restart",
     "context":{"used":50000,"window":200000}},
     "prompt":{"Questions":{"request_id":42,"answer":0,"skip":1,"questions":[
       {"header":"Framework","question":"Which framework?","multi_select":false,
        "options":[{"label":"React","description":"Components"},{"label":"Vue","description":""}]}]}}}
    """

    func testControlsDecodeFromTheHelpersJSONAndAFutureRiskIsNeverSafe() throws {
        let controls = try TimelineJSON.decode(AgentControls.self, from: Self.controlsJSON)
        XCTAssertEqual(controls.paneId, 7)
        XCTAssertTrue(controls.config.isSupported)
        XCTAssertEqual(controls.config.current.model, "opus")
        XCTAssertEqual(controls.config.modes.map(\.risk), [.asks, .bypass, .unknown])
        XCTAssertEqual(controls.config.timing, .restart)
        XCTAssertEqual(controls.config.context?.fraction, 0.25)
        guard case .questions(let questions)? = controls.prompt else { return XCTFail("no questions") }
        XCTAssertEqual(questions.requestId, 42)
        XCTAssertEqual(questions.questions[0].options.map(\.label), ["React", "Vue"])
        let unsupported = try TimelineJSON.decode(AgentConfigSupport.self, from: #"{"Unsupported":"Start it from Gudo."}"#)
        XCTAssertEqual(unsupported, .unsupported("Start it from Gudo."))
    }

    func testCodexAndPiAreNotOfferedClaudeAliases() {
        XCTAssertTrue(ChatSessionControls.offersModelAliases(.known(.claude)))
        XCTAssertFalse(ChatSessionControls.offersModelAliases(.known(.codex)))
        XCTAssertFalse(ChatSessionControls.offersModelAliases(.known(.pi)))
        XCTAssertFalse(ChatSessionControls.offersModelAliases(nil))
    }

    func testAWaitingChangeSaysWhenItApplies() throws {
        var config = try TimelineJSON.decode(AgentControls.self, from: Self.controlsJSON).config
        XCTAssertNil(ChatAgentControlsText.note(config, isWorking: true))
        config.pending = AgentConfigValues(model: "sonnet")
        XCTAssertEqual(ChatAgentControlsText.note(config, isWorking: true), "Applies after this turn")
        XCTAssertEqual(ChatAgentControlsText.note(config, isWorking: false), "Restarting with the change")
        config.timing = .nextTurn
        XCTAssertEqual(ChatAgentControlsText.note(config, isWorking: true), "Applies next turn")
        XCTAssertEqual(ChatAgentControlsText.modelLabel("sonnet", in: config.models), "Sonnet")
        XCTAssertEqual(ChatAgentControlsText.modelLabel("claude-opus-4-5-20251101", in: []), "Opus 4.5")
        XCTAssertEqual(ChatAgentControlsText.shield(.bypass), "exclamationmark.shield.fill")
    }

    func testAClaudeStartedByHandAsksBeforeItRestartsInItsPane() throws {
        let json = Self.controlsJSON.replacingOccurrences(of: #""timing":"Restart""#, with: #""timing":"RestartInPane""#)
        var config = try TimelineJSON.decode(AgentControls.self, from: json).config
        XCTAssertEqual(config.timing, .restartInPane)
        XCTAssertTrue(ChatAgentControlsText.confirmsChange(config))
        let confirmation = ChatAgentControlsText.restartInPaneConfirmation(AgentConfigValues(model: "sonnet"), in: config)
        XCTAssertEqual(confirmation.title, "Restart Claude Code with Sonnet?")
        XCTAssertTrue(confirmation.message.contains("claude --resume"), confirmation.message)
        config.pending = AgentConfigValues(model: "sonnet")
        XCTAssertEqual(ChatAgentControlsText.note(config, isWorking: true), "Applies after this turn")
        config.timing = .restart
        XCTAssertFalse(ChatAgentControlsText.confirmsChange(config))
    }

    func testAnswersFollowTheOptionsOrderAndYourOwnWords() {
        let single = AgentQuestion(question: "Which framework?", options: [.init(label: "React"), .init(label: "Vue")])
        let several = AgentQuestion(question: "Which tests?", options: [.init(label: "Unit"), .init(label: "UI")], multiSelect: true)
        var picks = QuestionPicks()
        XCTAssertNil(picks.answers(for: [single, several]), "every question needs an answer")
        picks.toggle(0, "Vue", multiSelect: false)
        picks.toggle(0, "React", multiSelect: false)
        picks.toggle(1, "UI", multiSelect: true)
        picks.toggle(1, "Unit", multiSelect: true)
        XCTAssertEqual(picks.answers(for: [single, several]), [
            QuestionAnswer(question: "Which framework?", answer: "React"),
            QuestionAnswer(question: "Which tests?", answer: "Unit, UI"),
        ])
        picks.write(0, "  Svelte ")
        picks.write(1, "snapshot")
        XCTAssertEqual(picks.answers(for: [single, several])?.map(\.answer), ["Svelte", "Unit, UI, snapshot"])
    }

    func testAPlanReadsAsHeadingsItemsAndText() {
        let lines = PlanMarkdown.lines("# Plan\n\n1. Add **tests**\n- Fix it\n\n```\ncargo test\n```\nDone.")
        XCTAssertEqual(lines, [
            .heading("Plan", level: 1), .gap,
            .item(marker: "1.", text: "Add **tests**"), .item(marker: "•", text: "Fix it"), .gap,
            .code("cargo test"), .text("Done."),
        ])
        XCTAssertNil(PlanMarkdown.inline("[site](https://example.com)").runs.first?.link)
    }

    func testTheHubWatchesChangesAndAnswersThroughTheHelper() async throws {
        let client = AgentControlsFixtureClient(json: Self.controlsJSON)
        let events = WorkspaceEventHub()
        let hub = DaemonWorkspace(hostId: "fixture", events: events, resolve: { client })
        hub.watchAgentControls(pane: 7)
        hub.watchAgentControls(pane: 7)
        try await waitUntil { hub.agentControls[7] != nil }
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("watch") }, ["watch 7"], "one watch for two viewers")

        try await hub.setAgentConfig(pane: 7, change: AgentConfigValues(model: "sonnet"))
        XCTAssertTrue(client.calls.contains("set 7 sonnet - -"))
        let pushed = Self.controlsJSON.replacingOccurrences(of: #""pending":null"#, with: #""pending":{"model":"sonnet","mode":null,"effort":null}"#)
        events.deliver(.agentControls(paneId: 7, controlsJson: pushed))
        XCTAssertEqual(hub.agentControls[7]?.config.pending?.model, "sonnet")

        guard case .questions(let questions)? = hub.agentControls[7]?.prompt else { return XCTFail("no questions") }
        try await hub.answer(questions, with: [QuestionAnswer(question: "Which framework?", answer: "React")])
        XCTAssertTrue(client.calls.contains("answer 42 0 Which framework?=React"), "\(client.calls)")
        hub.skip(questions)
        XCTAssertTrue(client.calls.contains("decide 42 1"))

        hub.unwatchAgentControls(pane: 7)
        XCTAssertNotNil(hub.agentControls[7], "another viewer still shows it")
        hub.unwatchAgentControls(pane: 7)
        XCTAssertNil(hub.agentControls[7])
        try await waitUntil { client.calls.contains("unwatch 7") }
    }

    func testAnOlderHelperKeepsTheReadOnlyChips() {
        let client = AgentControlsFixtureClient(json: Self.controlsJSON, offers: false)
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: { client })
        XCTAssertFalse(hub.offersAgentControls)
        hub.watchAgentControls(pane: 7)
        XCTAssertTrue(client.calls.isEmpty, "nothing is sent to a helper that cannot read it")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

nonisolated final class AgentControlsFixtureClient: FakeWorkspaceClient, DaemonAgentControlsAPI, @unchecked Sendable {
    private let json: String
    private let offers: Bool

    init(json: String, offers: Bool = true) {
        self.json = json
        self.offers = offers
        super.init()
    }

    func offersAgentControls() -> Bool { offers }

    func agentControlsWatch(paneId: UInt64) async throws -> String {
        record("watch \(paneId)")
        return json
    }

    func agentControlsUnwatch(paneId: UInt64) async throws { record("unwatch \(paneId)") }

    func setAgentConfig(paneId: UInt64, model: String?, mode: String?, effort: String?) async throws -> String {
        record("set \(paneId) \(model ?? "-") \(mode ?? "-") \(effort ?? "-")")
        return json
    }

    func answerQuestion(requestId: UInt64, optionId: UInt32, answersJson: String) async throws {
        let answers = try TimelineJSON.decode([QuestionAnswer].self, from: answersJson)
        record("answer \(requestId) \(optionId) " + answers.map { "\($0.question)=\($0.answer)" }.joined(separator: ";"))
    }

    func refuseRequest(requestId: UInt64, optionId: UInt32, message: String) async throws {
        record("refuse \(requestId) \(optionId) \(message)")
    }
}
