import Foundation
import GudoCore

/// Chat's controls for a pane's agent (`proto::agent_control`): its model, permission mode and
/// reasoning effort, and the question or plan it waits on. Values arrive as JSON from the FFI.
nonisolated public protocol DaemonAgentControlsAPI: AnyObject, Sendable {
    func offersAgentControls() -> Bool
    func agentControlsWatch(paneId: UInt64) async throws -> String
    func agentControlsUnwatch(paneId: UInt64) async throws
    func setAgentConfig(paneId: UInt64, model: String?, mode: String?, effort: String?) async throws -> String
    func answerQuestion(requestId: UInt64, optionId: UInt32, answersJson: String) async throws
    func refuseRequest(requestId: UInt64, optionId: UInt32, message: String) async throws
}

extension DaemonClient: DaemonAgentControlsAPI {}

nonisolated public struct AgentChoice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String

    public init(id: String, label: String, detail: String = "") {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

/// How much a mode lets the agent do without asking. A future risk reads as unknown, never safe.
nonisolated public enum AgentModeRisk: Codable, Equatable, Sendable {
    case asks, plans, edits, automatic, bypass, unknown

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "Asks": self = .asks
        case "Plans": self = .plans
        case "Edits": self = .edits
        case "Automatic": self = .automatic
        case "Bypass": self = .bypass
        default: self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let names: [Self: String] = [.asks: "Asks", .plans: "Plans", .edits: "Edits", .automatic: "Automatic", .bypass: "Bypass"]
        try container.encode(names[self] ?? "Unknown")
    }
}

extension AgentModeRisk: Hashable {}

nonisolated public struct AgentModeChoice: Codable, Equatable, Sendable, Identifiable {
    public var choice: AgentChoice
    public var risk: AgentModeRisk
    public var id: String { choice.id }

    public init(choice: AgentChoice, risk: AgentModeRisk) {
        self.choice = choice
        self.risk = risk
    }
}

/// When a change reaches the agent: Claude Code restarts on the same conversation once its
/// turn ends; Codex takes it with the next turn Chat starts.
nonisolated public enum AgentConfigTiming: String, Codable, Equatable, Sendable {
    case restart = "Restart"
    case nextTurn = "NextTurn"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .nextTurn
    }
}

nonisolated public struct AgentConfigValues: Codable, Equatable, Sendable {
    public var model: String?
    public var mode: String?
    public var effort: String?

    public init(model: String? = nil, mode: String? = nil, effort: String? = nil) {
        self.model = model
        self.mode = mode
        self.effort = effort
    }
}

nonisolated public enum AgentConfigSupport: Codable, Equatable, Sendable {
    case supported
    case unsupported(String)

    private enum Keys: String, CodingKey { case unsupported = "Unsupported" }

    public init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = text == "Supported" ? .supported : .unsupported("Update the app to change this agent.")
        } else {
            self = .unsupported(try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .unsupported))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .supported: var container = encoder.singleValueContainer(); try container.encode("Supported")
        case .unsupported(let reason): var container = encoder.container(keyedBy: Keys.self); try container.encode(reason, forKey: .unsupported)
        }
    }
}

nonisolated public struct AgentConfig: Codable, Equatable, Sendable {
    public var support: AgentConfigSupport
    public var current: AgentConfigValues
    public var pending: AgentConfigValues?
    public var models: [AgentChoice]
    public var modes: [AgentModeChoice]
    public var efforts: [AgentChoice]
    public var timing: AgentConfigTiming

    public init(support: AgentConfigSupport, current: AgentConfigValues, pending: AgentConfigValues? = nil,
                models: [AgentChoice], modes: [AgentModeChoice], efforts: [AgentChoice], timing: AgentConfigTiming) {
        self.support = support
        self.current = current
        self.pending = pending
        self.models = models
        self.modes = modes
        self.efforts = efforts
        self.timing = timing
    }

    public var isSupported: Bool { support == .supported }
}

nonisolated public struct AgentQuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String

    public init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}

nonisolated public struct AgentQuestion: Codable, Equatable, Sendable {
    public var header: String
    public var question: String
    public var options: [AgentQuestionOption]
    public var multiSelect: Bool

    public init(header: String = "", question: String, options: [AgentQuestionOption], multiSelect: Bool = false) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    private enum CodingKeys: String, CodingKey { case header, question, options; case multiSelect = "multi_select" }
}

nonisolated public struct AgentQuestions: Codable, Equatable, Sendable {
    public var requestId: UInt64
    public var questions: [AgentQuestion]
    public var answer: UInt32
    public var skip: UInt32

    public init(requestId: UInt64, questions: [AgentQuestion], answer: UInt32, skip: UInt32) {
        self.requestId = requestId
        self.questions = questions
        self.answer = answer
        self.skip = skip
    }

    private enum CodingKeys: String, CodingKey { case questions, answer, skip; case requestId = "request_id" }
}

nonisolated public struct AgentPlan: Codable, Equatable, Sendable {
    public var requestId: UInt64
    public var plan: String
    public var approve: UInt32
    public var keepPlanning: UInt32

    public init(requestId: UInt64, plan: String, approve: UInt32, keepPlanning: UInt32) {
        self.requestId = requestId
        self.plan = plan
        self.approve = approve
        self.keepPlanning = keepPlanning
    }

    private enum CodingKeys: String, CodingKey {
        case plan, approve
        case requestId = "request_id", keepPlanning = "keep_planning"
    }
}

nonisolated public enum AgentPrompt: Codable, Equatable, Sendable {
    case questions(AgentQuestions)
    case plan(AgentPlan)

    private enum Keys: String, CodingKey { case questions = "Questions", plan = "Plan" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let questions = try container.decodeIfPresent(AgentQuestions.self, forKey: .questions) {
            self = .questions(questions)
        } else {
            self = .plan(try container.decode(AgentPlan.self, forKey: .plan))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .questions(let questions): try container.encode(questions, forKey: .questions)
        case .plan(let plan): try container.encode(plan, forKey: .plan)
        }
    }

    public var requestId: UInt64 {
        switch self {
        case .questions(let questions): questions.requestId
        case .plan(let plan): plan.requestId
        }
    }
}

nonisolated public struct AgentControls: Codable, Equatable, Sendable {
    public var paneId: UInt64
    public var config: AgentConfig
    public var prompt: AgentPrompt?

    public init(paneId: UInt64, config: AgentConfig, prompt: AgentPrompt? = nil) {
        self.paneId = paneId
        self.config = config
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case config, prompt; case paneId = "pane_id" }
}

/// The answer to one question: the chosen labels joined by ", ", or the user's own words.
nonisolated public struct QuestionAnswer: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

extension DaemonWorkspace {
    /// Whether the connected helper offers agent controls; older ones keep Chat's read-only chips.
    public var offersAgentControls: Bool { (try? agentControlsClient())?.offersAgentControls() ?? false }

    func agentControlsClient() throws -> any DaemonAgentControlsAPI {
        guard let client = try client() as? any DaemonAgentControlsAPI else { throw HostError.notConnected }
        return client
    }

    /// Starts showing `pane`'s controls in `agentControls` (counted: every view that watches
    /// stops once).
    public func watchAgentControls(pane: UInt64) {
        agentControlsViewers[pane, default: 0] += 1
        guard agentControlsViewers[pane] == 1 else { return }
        requestAgentControls(pane: pane)
    }

    public func unwatchAgentControls(pane: UInt64) {
        guard let viewers = agentControlsViewers[pane] else { return }
        guard viewers <= 1 else { agentControlsViewers[pane] = viewers - 1; return }
        agentControlsViewers[pane] = nil
        agentControls[pane] = nil
        guard let client = try? agentControlsClient(), client.offersAgentControls() else { return }
        Task { try? await client.agentControlsUnwatch(paneId: pane) }
    }

    func requestAgentControls(pane: UInt64) {
        guard let client = try? agentControlsClient(), client.offersAgentControls() else { return }
        Task { [weak self] in
            guard let json = try? await client.agentControlsWatch(paneId: pane) else { return }
            self?.receiveAgentControls(pane: pane, json: json)
        }
    }

    func receiveAgentControls(pane: UInt64, json: String) {
        guard agentControlsViewers[pane] != nil,
              let controls = try? TimelineJSON.decode(AgentControls.self, from: json) else { return }
        agentControls[pane] = controls
    }

    /// Changes the agent's model, mode or effort (the ones given).
    public func setAgentConfig(pane: UInt64, change: AgentConfigValues) async throws {
        let client = try agentControlsClient()
        let json = try await client.setAgentConfig(paneId: pane, model: change.model, mode: change.mode, effort: change.effort)
        receiveAgentControls(pane: pane, json: json)
    }

    public func answer(_ questions: AgentQuestions, with answers: [QuestionAnswer]) async throws {
        let client = try agentControlsClient()
        let json = String(decoding: try TimelineJSON.encode(answers), as: UTF8.self)
        try await client.answerQuestion(requestId: questions.requestId, optionId: questions.answer, answersJson: json)
    }

    /// Declines to answer: the agent goes on without the answers.
    public func skip(_ questions: AgentQuestions) {
        api?.decide(requestId: questions.requestId, optionId: questions.skip)
    }

    public func approve(_ plan: AgentPlan) {
        api?.decide(requestId: plan.requestId, optionId: plan.approve)
    }

    /// Sends the plan back with what to change (none: just keep planning).
    public func keepPlanning(_ plan: AgentPlan, feedback: String) async throws {
        let feedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { api?.decide(requestId: plan.requestId, optionId: plan.keepPlanning); return }
        try await agentControlsClient().refuseRequest(requestId: plan.requestId, optionId: plan.keepPlanning, message: feedback)
    }
}
