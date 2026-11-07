import Foundation
import HostKit
import Observation

@MainActor
@Observable
final class ChatDiffReader {
    typealias Source = @MainActor (String) async throws -> String
    private(set) var snapshot: ChatDiffSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isRecorded = false
    @ObservationIgnored private let groups: [ChatToolDiff]
    @ObservationIgnored private let source: Source?
    @ObservationIgnored private var request = UUID()

    var canLoadRecorded: Bool {
        source != nil && !isRecorded && !groups.isEmpty && groups.allSatisfy { $0.resultHandle != nil }
    }

    init(groups: [ChatToolDiff], source: Source? = nil) {
        self.groups = groups.filter { !$0.files.isEmpty }
        self.source = source
    }

    func cancel() {
        request = UUID()
        isLoading = false
    }

    func preview() async {
        await load(recorded: false) { [groups] _ in
            try await Task.detached(priority: .userInitiated) { try ChatDiffSnapshot(groups: groups) }.value
        }
    }

    func loadRecorded() async {
        await load(recorded: true) { ticket in
            guard let source, canLoadRecorded else { throw ChatDiffReadError.unavailable }
            var builder = ChatDiffSnapshot.Builder()
            for group in groups {
                guard let handle = group.resultHandle else { throw ChatDiffReadError.unavailable }
                try check(ticket)
                let json = try await source(handle)
                try check(ticket)
                builder = try await Task.detached(priority: .userInitiated) { [builder] in
                    var staged = builder
                    try staged.append(ChatDiffReadPage.decode(json, for: group))
                    return staged
                }.value
                try check(ticket)
            }
            return builder.snapshot
        }
    }

    private func check(_ ticket: UUID) throws {
        guard request == ticket, !Task.isCancelled else { throw CancellationError() }
    }

    private func load(recorded: Bool, operation: (UUID) async throws -> ChatDiffSnapshot) async {
        let ticket = UUID()
        request = ticket
        isLoading = true
        error = nil
        defer { if request == ticket { isLoading = false } }
        do {
            let snapshot = try await operation(ticket)
            try check(ticket)
            self.snapshot = snapshot
            isRecorded = recorded
        } catch {
            guard request == ticket, !Task.isCancelled else { return }
            self.error = (error as? ChatDiffReadError)?.errorDescription ?? (error as? ChatDiffError)?.errorDescription
                ?? "Recorded changes could not load. Try again or open Terminal."
        }
    }
}

nonisolated enum ChatDiffReadPage {
    static func decode(_ json: String, for group: ChatToolDiff) throws -> ChatToolDiff {
        guard json.utf8.count <= ChatDiffLimits.jsonBytes else { throw ChatDiffError.tooLarge }
        let reply = try TimelineJSON.decode([TimelineFileDiff].self, from: json)
        guard reply.count <= ChatDiffLimits.files else { throw ChatDiffError.tooLarge }
        let expected = Dictionary(grouping: group.files, by: \.path).mapValues(\.count)
        let files = reply.filter { expected[$0.path] != nil }
        guard Dictionary(grouping: files, by: \.path).mapValues(\.count) == expected else {
            throw ChatDiffReadError.changed
        }
        guard files.allSatisfy({ !$0.hunksOmitted }) else { throw ChatDiffReadError.incomplete }
        return ChatToolDiff(item: group.item, files: files, resultHandle: group.resultHandle)
    }
}

nonisolated enum ChatDiffReadError: Error, LocalizedError {
    case unavailable, changed, incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable: "Complete recorded changes are unavailable for this selection. Open Terminal."
        case .changed: "The recorded change no longer matches this selection. Open Terminal."
        case .incomplete: "The helper returned an incomplete diff. Open Terminal to read it."
        }
    }
}
