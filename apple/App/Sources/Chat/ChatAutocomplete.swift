import Foundation
import GudoCore
import HostKit
import Observation

/// A file the host offered for an `@` mention, relative to the agent's folder.
nonisolated struct ChatFileSuggestion: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    /// Positions (Unicode scalars) of the characters the query matched, for emphasis.
    let positions: [UInt32]
}

/// What the composer offers for the word being typed: commands and skills after a leading `/`,
/// files after `@`. Files come from the host, a moment after typing stops.
@MainActor
@Observable
final class ChatAutocomplete {
    enum Kind: Equatable, Sendable { case command, file }

    /// The word the cursor is in, when it asks for suggestions.
    struct Trigger: Equatable {
        let kind: Kind
        let query: String
        /// Where the word, with its `/` or `@`, starts and ends in the draft.
        let range: Range<String.Index>
    }

    struct Suggestion: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        /// What replaces the word, ending with a space unless more can follow (a folder).
        let insertion: String
        /// Positions (Unicode scalars) in `title` to emphasise.
        let emphasis: Set<Int>
    }

    typealias FileSource = @MainActor (String) async throws -> [ChatFileSuggestion]

    nonisolated static let visibleLimit = 50
    nonisolated static let debounce = Duration.milliseconds(120)

    private(set) var trigger: Trigger?
    private(set) var suggestions: [Suggestion] = []
    private(set) var selection = 0
    /// Words for a list that has nothing to show yet, or cannot.
    private(set) var note: String?
    @ObservationIgnored private var dismissedStart: String.Index?
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var searchedQuery: String?

    var isPresented: Bool { trigger != nil && (!suggestions.isEmpty || note != nil) }

    isolated deinit { search?.cancel() }

    /// The word at `cursor` that asks for suggestions: `/name` as the draft's first word, or
    /// `@path` at the start of a word.
    nonisolated static func trigger(in draft: String, cursor: String.Index) -> Trigger? {
        guard cursor <= draft.endIndex else { return nil }
        var start = cursor
        while start > draft.startIndex {
            let previous = draft.index(before: start)
            if draft[previous].isWhitespace { break }
            start = previous
        }
        var end = cursor
        while end < draft.endIndex, !draft[end].isWhitespace { end = draft.index(after: end) }
        guard start < cursor, start < end, let first = draft[start...].first else { return nil }
        let query = String(draft[draft.index(after: start)..<cursor])
        switch first {
        case "/" where start == draft.startIndex && ChatCommands.isCommandName(query):
            return Trigger(kind: .command, query: query, range: start..<end)
        case "@" where !query.contains("@") && query.utf8.count <= 256:
            return Trigger(kind: .file, query: query, range: start..<end)
        default:
            return nil
        }
    }

    func update(draft: String, cursor: String.Index?, commands: [TimelineCommand], files: FileSource?) {
        let next = cursor.flatMap { Self.trigger(in: draft, cursor: $0) }
        guard let next, next.range.lowerBound != dismissedStart else {
            if next == nil { dismissedStart = nil }
            close()
            return
        }
        let kindChanged = trigger?.kind != next.kind
        trigger = next
        switch next.kind {
        case .command:
            search?.cancel()
            searchedQuery = nil
            suggestions = Self.commands(matching: next.query, in: commands)
            note = suggestions.isEmpty ? "No matching commands" : nil
            selection = min(selection, max(0, suggestions.count - 1))
        case .file:
            if kindChanged { suggestions = []; selection = 0 }
            guard let files else {
                suggestions = []
                note = "Update the helper to tag files"
                return
            }
            guard next.query != searchedQuery else { return }
            searchFiles(next.query, from: files)
        }
    }

    private func searchFiles(_ query: String, from files: @escaping FileSource) {
        search?.cancel()
        searchedQuery = query
        let feedback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.searchedQuery == query, self.suggestions.isEmpty else { return }
            self.note = "Searching…"
        }
        search = Task { [weak self] in
            defer { feedback.cancel() }
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            do {
                let found = try await files(query)
                guard let self, !Task.isCancelled, self.searchedQuery == query, self.trigger?.kind == .file else { return }
                self.suggestions = Array(found.prefix(Self.visibleLimit)).map(Self.suggestion)
                self.selection = 0
                self.note = self.suggestions.isEmpty ? "No files match" : nil
            } catch {
                guard let self, !Task.isCancelled, self.searchedQuery == query else { return }
                self.suggestions = []
                self.note = Self.message(for: error)
            }
        }
    }

    func moveSelection(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        selection = (selection + offset + suggestions.count) % suggestions.count
    }

    func select(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        selection = index
    }

    /// The draft with the selected suggestion in place of the word, and where the cursor goes.
    func accept(_ index: Int? = nil, in draft: String) -> (draft: String, cursor: String.Index)? {
        let chosen = index ?? selection
        guard let trigger, suggestions.indices.contains(chosen), trigger.range.upperBound <= draft.endIndex,
              draft[trigger.range.lowerBound...].first == (trigger.kind == .command ? "/" : "@") else { return nil }
        let insertion = suggestions[chosen].insertion
        var next = draft
        next.replaceSubrange(trigger.range, with: insertion)
        guard next.utf8.count <= ChatComposer.maximumDraftBytes else { return nil }
        let offset = draft.distance(from: draft.startIndex, to: trigger.range.lowerBound) + insertion.count
        let cursor = next.index(next.startIndex, offsetBy: offset)
        close()
        return (next, cursor)
    }

    /// Escape: this word asks no more until the cursor leaves it.
    func dismiss() {
        dismissedStart = trigger?.range.lowerBound
        close()
    }

    func close() {
        search?.cancel()
        search = nil
        searchedQuery = nil
        trigger = nil
        suggestions = []
        selection = 0
        note = nil
    }

    nonisolated static func commands(matching query: String, in commands: [TimelineCommand]) -> [Suggestion] {
        let lowered = query.lowercased()
        var seen: Set<String> = []
        let valid = commands.prefix(256).filter { command in
            ChatCommands.isCommandName(command.name) && !command.name.isEmpty && seen.insert(command.name).inserted
        }
        let ranked = valid.compactMap { command -> (rank: Int, command: TimelineCommand)? in
            let name = command.name.lowercased()
            if lowered.isEmpty || name.hasPrefix(lowered) { return (0, command) }
            if name.split(whereSeparator: { "-_:".contains($0) }).contains(where: { $0.hasPrefix(lowered) }) { return (1, command) }
            if name.contains(lowered) { return (2, command) }
            return nil
        }
        return ranked.sorted { ($0.rank, $0.command.name) < ($1.rank, $1.command.name) }
            .prefix(visibleLimit)
            .map { entry in
                let command = entry.command
                var emphasis: Set<Int> = []
                if !lowered.isEmpty, let match = command.name.lowercased().range(of: lowered) {
                    let start = command.name.lowercased().distance(from: command.name.lowercased().startIndex, to: match.lowerBound)
                    emphasis = Set((start + 1)...(start + lowered.count))
                }
                return Suggestion(id: "/" + command.name, title: "/" + command.name,
                                  detail: String(command.description.prefix(256)), symbol: symbol(command.source),
                                  insertion: "/" + command.name + " ", emphasis: emphasis)
            }
    }

    nonisolated private static func symbol(_ source: TimelineCommandSource) -> String {
        switch source {
        case .known(.builtIn): "command"
        case .known(.user), .known(.project), .unknown: "text.document"
        }
    }

    nonisolated static func suggestion(_ file: ChatFileSuggestion) -> Suggestion {
        let escaped = escape(file.path)
        return Suggestion(id: "@" + file.path, title: file.path, detail: "",
                          symbol: file.isDirectory ? "folder" : "doc",
                          insertion: "@" + escaped + (file.isDirectory ? "/" : " "),
                          emphasis: Set(file.positions.map(Int.init)))
    }

    /// A path as the agents read a mention: spaces and shell punctuation escaped.
    nonisolated static func escape(_ path: String) -> String {
        path.map { character in
            let plain = character.isLetter || character.isNumber || "_./@:-+".contains(character)
            return (plain ? "" : "\\") + String(character)
        }.joined()
    }

    nonisolated private static func message(for error: Error) -> String {
        if case WorkspaceError.Unavailable(let message) = error { return message }
        if case WorkspaceError.Denied = error { return "Only the host's owner can tag files" }
        return "Files could not be listed"
    }
}
