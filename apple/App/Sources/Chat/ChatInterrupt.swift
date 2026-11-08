import Foundation
import HostKit
import Observation

/// Independent of an in-flight prompt receipt: interrupting never confirms or resends that prompt.
@MainActor
@Observable
final class ChatInterrupt {
    enum Command: Equatable { case prepare, interrupt(ticket: UInt64, confirmation: UInt64?) }
    typealias Source = @MainActor (Command) async throws -> ChatSendStatus
    enum Phase: Equatable { case idle, preparing, confirming, sending, finished }

    private(set) var phase: Phase = .idle
    private(set) var message: String?
    private var offer: ChatSendOffer?
    private var generation = UUID()
    @ObservationIgnored private var source: Source?

    var canBegin: Bool { phase == .idle }
    var isBusy: Bool { phase == .preparing || phase == .confirming || phase == .sending }
    var needsConfirmation: Bool { phase == .confirming }
    var requestGeneration: UUID { generation }
    var confirmationRevision: UInt64? { needsConfirmation ? offer?.revision : nil }

    func begin(source: @escaping Source) async {
        guard canBegin else { return }
        generation = UUID()
        let request = generation
        phase = .preparing
        message = nil
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

    func cancelBeforeSend() {
        if phase == .preparing || phase == .confirming { reset() }
    }

    /// A new observed idle/agent boundary permits a fresh action; old completions cannot affect it.
    /// Already-admitted transport writes are not retracted, repeated or called acknowledged.
    func reset() {
        generation = UUID()
        phase = .idle
        message = nil
        offer = nil
        source = nil
    }

    private func send(confirmation: UInt64?) async {
        guard let offer, let source else { finish(.notConfirmed); return }
        let request = generation
        phase = .sending
        do {
            let receipt = try await source(.interrupt(ticket: offer.ticket, confirmation: confirmation))
            guard request == generation else { return }
            if case .confirmationRequired(let revision) = receipt {
                self.offer = ChatSendOffer(ticket: offer.ticket, revision: revision, needsConfirmation: true)
                phase = .confirming
            } else { finish(receipt) }
        } catch { if request == generation { finish(.notConfirmed) } }
    }

    private func finish(_ receipt: ChatSendStatus) {
        message = receipt == .interruptRequested ? "Interrupt requested" : "Interrupt not confirmed, check the terminal"
        phase = .finished
        offer = nil
        source = nil
    }
}
