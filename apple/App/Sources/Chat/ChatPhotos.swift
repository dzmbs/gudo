#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ChatPhotos {
    enum Phase: Equatable { case idle, picking, loading, uploading, ready }
    typealias Source = @MainActor (ChatPhotoFile) async throws -> String
    private(set) var phase: Phase = .idle
    private(set) var message: String?
    private var reference: String?
    private var context: PaneChatState.ActionContext?
    private(set) var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .picking || phase == .loading || phase == .uploading }
    var status: String? {
        switch phase {
        case .picking: "Choose a photo to upload to this host's Downloads folder."
        case .loading: "Preparing photo…"
        case .uploading: "Uploading photo…"
        case .ready: "Photo uploaded. Finish or shorten your draft, then add its path."
        case .idle: message
        }
    }

    isolated deinit { task?.cancel() }

    func begin(in state: PaneChatState) {
        cancel()
        context = state.actionContext
        phase = .picking
    }

    func load(in state: PaneChatState, photo: @escaping @MainActor () async throws -> ChatPhotoFile, source: @escaping Source) {
        guard phase == .picking, context == state.actionContext else { return }
        let generation = generation
        phase = .loading
        task = Task { [weak self, weak state] in
            defer { if self?.generation == generation { self?.task = nil } }
            do {
                let file = try await photo()
                try Task.checkCancellation()
                guard let self, let state, self.generation == generation, self.context == state.actionContext else { return }
                phase = .uploading
                let path = try await source(file)
                try Task.checkCancellation()
                guard self.generation == generation, self.context == state.actionContext else { return }
                reference = try Self.reference(path)
                phase = .ready
                _ = append(to: state)
            } catch {
                guard let self, self.generation == generation else { return }
                phase = .idle
                message = "Couldn't add the photo. Try again."
            }
        }
    }

    @discardableResult
    func append(to state: PaneChatState) -> Bool {
        guard phase == .ready, context == state.actionContext, state.presentation == .chat,
              !state.composer.isBusy, !state.interrupt.isBusy, state.controller?.hasMarkedText != true, let reference else { return false }
        let combined = state.draft + (state.draft.isEmpty || state.draft.last?.isWhitespace == true ? "" : "\n") + reference
        guard combined.utf8.count <= ChatComposer.maximumDraftBytes else { return false }
        state.draft = combined
        self.reference = nil
        phase = .idle
        message = "Photo added to draft"
        return true
    }

    func cancelIfStale(in state: PaneChatState) { if context != nil, context != state.actionContext { cancel() } }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        context = nil
        reference = nil
        phase = .idle
        message = nil
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
