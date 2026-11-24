#if os(iOS)
import Foundation
import Observation

/// A file uploaded to the host for the next message, shown as a pill above the field until the
/// message goes or the pill is removed.
nonisolated struct ChatAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    /// The `@path` mention the message carries.
    let reference: String
    /// A small JPEG of an image, for its pill.
    let thumbnail: Data?
}

/// Attaching files to a message: each is prepared on the device, uploaded to the host's
/// attachments folder, then held as a pill; Send adds their mentions to the message. Nothing is
/// typed into the agent and nothing is sent until Send.
@MainActor
@Observable
final class ChatPhotos {
    enum Phase: Equatable { case idle, picking, loading, uploading }
    typealias Source = @MainActor (ChatPhotoFile) async throws -> String
    static let attachmentLimit = 8

    private(set) var phase: Phase = .idle
    private(set) var message: String?
    private(set) var attachments: [ChatAttachment] = []
    /// The file being uploaded, for its pill.
    private(set) var pendingName: String?
    private var context: PaneChatState.ActionContext?
    /// The session the pills were made for; another session's message never carries them.
    private var session: String?
    private(set) var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .picking || phase == .loading || phase == .uploading }
    var isFull: Bool { attachments.count >= Self.attachmentLimit }
    var status: String? {
        switch phase {
        case .loading: "Preparing…"
        case .uploading: "Uploading…"
        case .picking, .idle: message
        }
    }

    /// The mentions Send adds after the text, one per pill.
    var references: String { attachments.map(\.reference).joined(separator: " ") }

    isolated deinit { task?.cancel() }

    func begin(in state: PaneChatState) {
        cancel()
        message = nil
        context = state.actionContext
        phase = .picking
    }

    func load(in state: PaneChatState, photo: @escaping @MainActor () async throws -> ChatPhotoFile, source: @escaping Source) {
        guard phase == .picking, context == state.actionContext, !isFull else { return }
        let generation = generation
        phase = .loading
        task = Task { [weak self, weak state] in
            defer { if self?.generation == generation { self?.task = nil } }
            do {
                let file = try await photo()
                try Task.checkCancellation()
                guard let self, let state, self.generation == generation, self.context == state.actionContext else { return }
                pendingName = file.name
                phase = .uploading
                let path = try await source(file)
                try Task.checkCancellation()
                guard self.generation == generation, self.context == state.actionContext else { return }
                let reference = try Self.reference(path)
                if session != state.actionContext.session { attachments.removeAll() }
                session = state.actionContext.session
                attachments.append(ChatAttachment(id: UUID(), name: file.name, reference: reference, thumbnail: file.thumbnail))
                pendingName = nil
                phase = .idle
                context = nil
            } catch {
                guard let self, self.generation == generation else { return }
                pendingName = nil
                phase = .idle
                message = "Couldn't attach the file. Try again."
            }
        }
    }

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// The message Send would send: the text, then the attachments' mentions on their own line.
    func message(with draft: String, session: String?) -> String {
        guard !attachments.isEmpty, self.session == session else { return draft }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? references : text + "\n" + references
    }

    /// The pills belong to one session: a new one in this pane drops them.
    func discardIfStale(session: String?) {
        if self.session != session { attachments.removeAll() }
    }

    func discardAttachments() {
        attachments.removeAll()
    }

    func cancelIfStale(in state: PaneChatState) { if context != nil, context != state.actionContext { cancel() } }

    /// Stops a file still being picked, prepared or uploaded; pills already made stay.
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        context = nil
        pendingName = nil
        phase = .idle
    }

    static func reference(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 8_192,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ChatPhotoError.invalidPath
        }
        return "@" + path.map { character in
            let plain = character.isLetter || character.isNumber || "_./@:-".contains(character)
            return (plain ? "" : "\\") + String(character)
        }.joined()
    }
}
#endif
