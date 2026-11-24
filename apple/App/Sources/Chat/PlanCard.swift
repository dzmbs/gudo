import DesignSystem
import HostKit
import SwiftUI

/// The plan the agent asks to carry out, rendered, with Approve and Keep planning (with what
/// to change).
struct PlanCard: View {
    let plan: AgentPlan
    let agent: String
    let canAnswer: Bool
    let approve: @MainActor () -> Void
    let keepPlanning: @MainActor (String) async throws -> Void
    @State private var isRevising = false
    @State private var feedback = ""
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(DS.Palette.attention)
                Text("\(agent) has a plan").font(DS.Font.banner)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(Array(PlanMarkdown.lines(plan.plan).enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 280)
            .accessibilityIdentifier("chat-plan-text")
            if isRevising {
                TextField("What should change?", text: $feedback, axis: .vertical)
                    .font(DS.Font.prose).lineLimit(1...5)
                    .padding(.horizontal, DS.Space.s)
                    .frame(minHeight: DS.Size.touchTarget)
                    .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field, style: .continuous))
                    .disabled(isSending)
                    .accessibilityIdentifier("chat-plan-feedback")
            }
            if let failure {
                Text(failure).font(DS.Font.caption).foregroundStyle(DS.Palette.error)
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button(action: sendBack) {
                    Text(isRevising ? "Send back" : "Keep planning").frame(minHeight: DS.Size.touchTarget)
                }
                .buttonStyle(.quiet)
                .disabled(!canAnswer || isSending)
                .accessibilityIdentifier("chat-plan-keep-planning")
                Button(action: approve) { Text("Approve").frame(minHeight: DS.Size.touchTarget) }
                    .buttonStyle(.primaryGlass)
                    .disabled(!canAnswer || isSending || isRevising)
                    .accessibilityIdentifier("chat-plan-approve")
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 520)
        .chromeContent()
        .floatingPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-plan")
    }

    @ViewBuilder private func lineView(_ line: PlanMarkdown.Line) -> some View {
        switch line {
        case .heading(let text, let level):
            Text(PlanMarkdown.inline(text)).font(level <= 2 ? DS.Font.banner : DS.Font.prose.weight(.semibold))
                .padding(.top, DS.Space.xs)
        case .item(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(marker).foregroundStyle(DS.Palette.textSecondary)
                Text(PlanMarkdown.inline(text))
            }
            .font(DS.Font.prose)
        case .code(let text):
            Text(text).font(DS.Font.literal)
        case .text(let text):
            Text(PlanMarkdown.inline(text)).font(DS.Font.prose)
        case .gap:
            Spacer().frame(height: DS.Space.xs)
        }
    }

    private func sendBack() {
        guard isRevising else { isRevising = true; return }
        isSending = true
        failure = nil
        let feedback = feedback
        Task {
            do { try await keepPlanning(feedback) } catch {
                failure = "The answer did not reach the agent. Try again or answer in Terminal."
            }
            isSending = false
        }
    }
}

/// A plan's Markdown as lines to show: headings, list items, code and paragraphs.
nonisolated enum PlanMarkdown {
    enum Line: Equatable {
        case heading(String, level: Int)
        case item(marker: String, text: String)
        case code(String)
        case text(String)
        case gap
    }

    static func lines(_ markdown: String) -> [Line] {
        var lines: [Line] = []
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { lines.append(.code(line)); continue }
            if trimmed.isEmpty {
                if lines.last != .gap, !lines.isEmpty { lines.append(.gap) }
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                lines.append(.heading(String(trimmed.dropFirst(hashes + 1)), level: hashes))
            } else if let rest = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix).map({ String(trimmed.dropFirst($0.count)) }) {
                lines.append(.item(marker: "•", text: rest))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed[trimmed.index(after: dot)...].first == " " {
                lines.append(.item(marker: String(trimmed[...dot]), text: String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
            } else {
                lines.append(.text(trimmed))
            }
        }
        if lines.last == .gap { lines.removeLast() }
        return lines
    }

    /// Bold, italics, code and links within a line; links stay text.
    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let links = attributed.runs.filter { $0.link != nil }.map(\.range)
        for range in links { attributed[range].link = nil }
        return attributed
    }
}
