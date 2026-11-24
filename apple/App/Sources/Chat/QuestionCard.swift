import DesignSystem
import HostKit
import SwiftUI

/// The agent's questions, answered from Chat as in its terminal: pick an option (several where
/// it allows), or answer in your own words under Other.
struct QuestionCard: View {
    let questions: AgentQuestions
    let agent: String
    let canAnswer: Bool
    let answer: @MainActor ([QuestionAnswer]) async throws -> Void
    let skip: @MainActor () -> Void
    @State private var picks = QuestionPicks()
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(DS.Palette.attention)
                Text("\(agent) asks").font(DS.Font.banner)
                Spacer(minLength: 0)
            }
            ForEach(Array(questions.questions.enumerated()), id: \.offset) { index, question in
                questionView(index, question)
            }
            if let failure {
                Text(failure).font(DS.Font.caption).foregroundStyle(DS.Palette.error)
                    .accessibilityIdentifier("chat-question-failure")
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button { skip() } label: { Text("Skip").frame(minHeight: DS.Size.touchTarget) }
                    .buttonStyle(.quiet)
                    .disabled(!canAnswer || isSending)
                    .accessibilityIdentifier("chat-question-skip")
                Button(action: send) { Text("Answer").frame(minHeight: DS.Size.touchTarget) }
                    .buttonStyle(.primaryGlass)
                    .disabled(!canAnswer || isSending || picks.answers(for: questions.questions) == nil)
                    .accessibilityIdentifier("chat-question-answer")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 520)
        .chromeContent()
        .floatingPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-question")
    }

    private func questionView(_ index: Int, _ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if !question.header.isEmpty {
                Text(question.header).font(DS.Font.meta).foregroundStyle(DS.Palette.textSecondary)
            }
            Text(question.question).font(DS.Font.prose)
            ForEach(question.options, id: \.label) { option in
                optionRow(index, question, option)
            }
            TextField("Other", text: written(index), axis: .vertical)
                .font(DS.Font.prose).lineLimit(1...4)
                .padding(.horizontal, DS.Space.s)
                .frame(minHeight: DS.Size.touchTarget)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field, style: .continuous))
                .disabled(!canAnswer || isSending)
                .accessibilityIdentifier("chat-question-other-\(index)")
        }
    }

    private func optionRow(_ index: Int, _ question: AgentQuestion, _ option: AgentQuestionOption) -> some View {
        let isChosen = picks.isChosen(index, option.label)
        let mark = question.multiSelect ? (isChosen ? "checkmark.square.fill" : "square")
            : (isChosen ? "largecircle.fill.circle" : "circle")
        return Button {
            picks.toggle(index, option.label, multiSelect: question.multiSelect)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: mark).foregroundStyle(isChosen ? DS.Palette.accent : DS.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(DS.Font.prose).foregroundStyle(DS.Palette.text)
                    if !option.description.isEmpty {
                        Text(option.description).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: DS.Size.touchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canAnswer || isSending)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("chat-question-option-\(index)-\(option.label)")
    }

    private func written(_ index: Int) -> Binding<String> {
        Binding { picks.written[index] ?? "" } set: { picks.write(index, $0) }
    }

    private func send() {
        guard let answers = picks.answers(for: questions.questions) else { return }
        isSending = true
        failure = nil
        Task {
            do { try await answer(answers) } catch {
                failure = "The answer did not reach the agent. Try again or answer in Terminal."
            }
            isSending = false
        }
    }
}

/// What has been chosen and written for each question.
nonisolated struct QuestionPicks: Equatable {
    private(set) var chosen: [Int: [String]] = [:]
    private(set) var written: [Int: String] = [:]

    func isChosen(_ question: Int, _ label: String) -> Bool { chosen[question]?.contains(label) == true }

    mutating func toggle(_ question: Int, _ label: String, multiSelect: Bool) {
        var labels = chosen[question] ?? []
        if let index = labels.firstIndex(of: label) {
            labels.remove(at: index)
        } else if multiSelect {
            labels.append(label)
        } else {
            labels = [label]
            written[question] = nil
        }
        chosen[question] = labels
    }

    mutating func write(_ question: Int, _ text: String) {
        written[question] = text
    }

    /// One answer per question, in the order the options were offered, or nil while one is
    /// unanswered. Your own words replace a single choice and follow several.
    func answers(for questions: [AgentQuestion]) -> [QuestionAnswer]? {
        var answers: [QuestionAnswer] = []
        for (index, question) in questions.enumerated() {
            let picked = question.options.map(\.label).filter { isChosen(index, $0) }
            let own = (written[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = question.multiSelect ? picked + (own.isEmpty ? [] : [own]) : (own.isEmpty ? picked : [own])
            guard !parts.isEmpty else { return nil }
            answers.append(QuestionAnswer(question: question.question, answer: parts.joined(separator: ", ")))
        }
        return answers
    }
}
