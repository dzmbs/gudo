import Foundation
import HostKit
import Observation

@MainActor
@Observable
final class ChatComposer {
    static let maximumDraftBytes = 16 * 1_024

    enum Command { case prepare, send(ticket: UInt64, text: String, confirmation: UInt64?) }
    typealias Source = @MainActor (Command) async throws -> ChatSendStatus
    enum Phase: Equatable { case idle, preparing, confirming, sending, finished }
    enum PrimaryAction: Equatable { case send, queue, stop }

    /// The disc at the composer's trailing edge: Send (or Queue while the agent works, as the
    /// setting says) with a message written, else Stop while the agent works.
    static func primaryAction(hasMessage: Bool, isWorking: Bool, canStop: Bool, canSend: Bool,
                              whileWorking: ChatPreferences.SendWhileWorking) -> PrimaryAction? {
        if canSend, hasMessage { return isWorking && whileWorking == .queue ? .queue : .send }
        if canStop { return .stop }
        return canSend ? .send : nil
    }

    enum Outcome: Equatable { case confirmed, sentNotConfirmed, notConfirmed }

    private(set) var phase: Phase = .idle
    private(set) var message: String?
    /// How the last send ended; nil while one is under way or none has finished.
    private(set) var outcome: Outcome?
    private(set) var confirmedText: String?
    private var text = ""
    private var offer: ChatSendOffer?
    private var generation = UUID()
    @ObservationIgnored private var source: Source?

    var needsConfirmation: Bool { phase == .confirming }
    var requestGeneration: UUID { generation }
    var confirmationRevision: UInt64? { needsConfirmation ? offer?.revision : nil }
    var isBusy: Bool { phase == .preparing || phase == .sending || phase == .confirming }

    func canSend(_ draft: String) -> Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf8.count <= Self.maximumDraftBytes && !(phase == .finished && draft == text)
    }

    func draftChanged(_ draft: String) {
        if phase == .finished, confirmedText != nil, draft != text { phase = .idle }
    }

    func begin(_ draft: String, source: @escaping Source) async {
        guard canSend(draft) else { return }
        phase = .preparing
        generation = UUID()
        let request = generation
        message = nil
        outcome = nil
        confirmedText = nil
        text = draft
        self.source = source
        do {
            let receipt = try await source(.prepare)
            guard request == generation, phase == .preparing else { return }
            guard case .prepared(let offer) = receipt else { finish(.notConfirmed); return }
            self.offer = offer
            if offer.needsConfirmation { phase = .confirming } else { await send(confirmation: nil) }
        } catch { if request == generation { finish(.notConfirmed) } }
    }

    func confirm() async {
        guard phase == .confirming, let offer else { return }
        await send(confirmation: offer.revision)
    }

    func cancelConfirmation() {
        guard phase == .confirming else { return }
        cancelBeforeSend()
    }

    func cancelBeforeSend() {
        guard phase == .confirming || phase == .preparing else { return }
        generation = UUID()
        phase = .idle
        offer = nil
        source = nil
    }

    private func send(confirmation: UInt64?) async {
        guard let offer, let source else { finish(.notConfirmed); return }
        phase = .sending
        do {
            let receipt = try await source(.send(ticket: offer.ticket, text: text, confirmation: confirmation))
            if case .confirmationRequired(let revision) = receipt {
                self.offer = ChatSendOffer(ticket: offer.ticket, revision: revision, needsConfirmation: true)
                phase = .confirming
            } else { finish(receipt) }
        } catch { finish(.notConfirmed) }
    }

    private func finish(_ receipt: ChatSendStatus) {
        switch receipt {
        case .confirmed:
            message = "Confirmed"
            confirmedText = text
            outcome = .confirmed
        case .sentNotConfirmed:
            message = "Sent, not confirmed"
            outcome = .sentNotConfirmed
        default:
            message = "Not confirmed, check the terminal"
            outcome = .notConfirmed
        }
        phase = .finished
        offer = nil
        source = nil
    }
}
