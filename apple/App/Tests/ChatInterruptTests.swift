import HostKit
import XCTest
@testable import App

@MainActor
final class ChatInterruptTests: XCTestCase {
    func testOneInterruptRequestsDeliveryWithoutClaimingStoppedOrAutomaticallyRepeating() async {
        let action = ChatInterrupt()
        var commands: [ChatInterrupt.Command] = []
        let source: ChatInterrupt.Source = { command in
            commands.append(command)
            return command == .prepare ? .prepared(.init(ticket: 7, revision: 4, needsConfirmation: false)) : .interruptRequested
        }
        await action.begin(source: source)
        XCTAssertEqual(commands, [.prepare, .interrupt(ticket: 7, confirmation: nil)])
        XCTAssertEqual(action.message, "Interrupt requested")
        XCTAssertEqual(action.phase, .finished)
        XCTAssertFalse(action.canBegin)
        await action.begin(source: source)
        XCTAssertEqual(commands.count, 2)
    }

    func testDirtyDraftAndAChangedRevisionEachRequireAnExplicitConfirmation() async {
        let action = ChatInterrupt()
        var commands: [ChatInterrupt.Command] = []
        await action.begin { command in
            commands.append(command)
            switch command {
            case .prepare: return .prepared(.init(ticket: 7, revision: 4, needsConfirmation: true))
            case .interrupt(_, 4): return .confirmationRequired(5)
            case .interrupt(_, 5): return .interruptRequested
            default: XCTFail("Unexpected interrupt revision"); return .notConfirmed
            }
        }
        XCTAssertEqual(commands, [.prepare])
        XCTAssertTrue(action.needsConfirmation)
        await action.confirm()
        XCTAssertTrue(action.needsConfirmation)
        XCTAssertEqual(commands.count, 2)
        await action.confirm()
        XCTAssertEqual(commands, [.prepare, .interrupt(ticket: 7, confirmation: 4), .interrupt(ticket: 7, confirmation: 5)])
        XCTAssertEqual(action.message, "Interrupt requested")
    }

    func testCancellationBeforeLatePrepareNeverDispatchesEscape() async throws {
        let action = ChatInterrupt()
        var prepared: CheckedContinuation<ChatSendStatus, Never>?
        var commands: [ChatInterrupt.Command] = []
        let task = Task {
            await action.begin { command in
                commands.append(command)
                return await withCheckedContinuation { prepared = $0 }
            }
        }
        try await wait { prepared != nil }
        XCTAssertEqual(action.phase, .preparing)
        action.cancelBeforeSend()
        prepared?.resume(returning: .prepared(.init(ticket: 7, revision: 4, needsConfirmation: false)))
        await task.value
        XCTAssertEqual(commands, [.prepare])
        XCTAssertEqual(action.phase, .idle)
    }

    func testPromptReceiptsAndWrongStageResponsesDoNotProveAnInterruptOrStopped() async {
        for receipt: ChatSendStatus in [.confirmed, .notConfirmed, .sentNotConfirmed] {
            let action = ChatInterrupt()
            await action.begin { command in
                command == .prepare ? .prepared(.init(ticket: 7, revision: 4, needsConfirmation: false)) : receipt
            }
            XCTAssertEqual(action.message, "Interrupt not confirmed, check the terminal")
            XCTAssertFalse(action.canBegin)
        }
        let action = ChatInterrupt()
        await action.begin { _ in .interruptRequested }
        XCTAssertEqual(action.message, "Interrupt not confirmed, check the terminal")
    }

    func testNewIdleBoundaryIgnoresAnOlderInFlightCompletion() async throws {
        let action = ChatInterrupt()
        var completion: CheckedContinuation<ChatSendStatus, Never>?
        let old = Task {
            await action.begin { command in
                if command == .prepare { return .prepared(.init(ticket: 7, revision: 4, needsConfirmation: false)) }
                return await withCheckedContinuation { completion = $0 }
            }
        }
        try await wait { completion != nil }
        XCTAssertEqual(action.phase, .sending)
        action.reset()
        await action.begin { command in
            command == .prepare ? .prepared(.init(ticket: 8, revision: 5, needsConfirmation: false)) : .interruptRequested
        }
        completion?.resume(returning: .notConfirmed)
        await old.value
        XCTAssertEqual(action.message, "Interrupt requested")
        XCTAssertEqual(action.phase, .finished)
    }

    func testCancelledWarningAndTransportFailureNeverRetry() async {
        let action = ChatInterrupt()
        var preparations = 0
        await action.begin { _ in
            preparations += 1
            return .prepared(.init(ticket: 7, revision: 4, needsConfirmation: true))
        }
        action.cancelBeforeSend()
        await action.confirm()
        XCTAssertEqual(action.phase, .idle)
        await action.begin { _ in preparations += 1; throw CancellationError() }
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(action.message, "Interrupt not confirmed, check the terminal")
        await action.begin { _ in XCTFail("Failure must not automatically retry"); return .interruptRequested }
        XCTAssertEqual(preparations, 2)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Interrupt fixture did not reach its expected state")
        throw CancellationError()
    }

    func testInterruptReceiptDecoderNeverInventsAStoppedAcknowledgement() throws {
        XCTAssertEqual(try ChatSendStatus.decode(#""InterruptRequested""#), .interruptRequested)
        XCTAssertThrowsError(try ChatSendStatus.decode(#""Stopped""#))
    }
}
