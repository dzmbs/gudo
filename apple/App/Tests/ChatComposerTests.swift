import HostKit
import XCTest
@testable import App

@MainActor
final class ChatComposerTests: XCTestCase {
    func testCleanSendUsesOneTicketAndExactText() async {
        let composer = ChatComposer()
        var writes = 0
        await composer.begin("hello\nworld") { command in
            switch command {
            case .prepare: return .prepared(.init(ticket: 7, revision: 4, needsConfirmation: false))
            case .send(let ticket, let text, let revision):
                writes += 1
                XCTAssertEqual(ticket, 7)
                XCTAssertEqual(text, "hello\nworld")
                XCTAssertNil(revision)
                return .confirmed
            }
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(composer.confirmedText, "hello\nworld")
        XCTAssertEqual(composer.message, "Confirmed")
    }

    func testAQueuedSecondTapCannotResendAnAlreadyConfirmedUnclearedDraft() async {
        let composer = ChatComposer()
        var writes = 0
        let source: ChatComposer.Source = { command in
            if case .prepare = command { return .prepared(.init(ticket: 1, revision: 0, needsConfirmation: false)) }
            writes += 1
            return .confirmed
        }
        await composer.begin("hello", source: source)
        await composer.begin("hello", source: source)
        XCTAssertEqual(writes, 1)
        composer.draftChanged("")
        XCTAssertTrue(composer.canSend("hello"))
    }

    func testDirtyDraftRequiresExplicitConfirmationAndNewTypingRequiresAnother() async {
        let composer = ChatComposer()
        var writes = 0
        await composer.begin("hello") { command in
            switch command {
            case .prepare: return .prepared(.init(ticket: 8, revision: 1, needsConfirmation: true))
            case .send(_, _, let revision):
                writes += 1
                if writes == 1 { XCTAssertEqual(revision, 1); return .confirmationRequired(2) }
                XCTAssertEqual(revision, 2)
                return .confirmed
            }
        }
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(composer.needsConfirmation)
        await composer.confirm()
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(composer.needsConfirmation)
        await composer.confirm()
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(composer.needsConfirmation)
    }

    func testCancellingDirtyDraftNeverSends() async {
        let composer = ChatComposer()
        await composer.begin("hello") { command in
            if case .send = command { XCTFail("Cancel must never write") }
            return .prepared(.init(ticket: 1, revision: 0, needsConfirmation: true))
        }
        composer.cancelConfirmation()
        await composer.confirm()
        XCTAssertEqual(composer.phase, .idle)
        XCTAssertTrue(composer.canSend("hello"))
    }

    func testMismatchTimeoutExitAndTransportFailureNeverAutomaticallyResend() async {
        for receipt in [ChatSendStatus.notConfirmed, .sentNotConfirmed] {
            let composer = ChatComposer()
            var writes = 0
            let source: ChatComposer.Source = { command in
                if case .prepare = command { return .prepared(.init(ticket: 1, revision: 0, needsConfirmation: false)) }
                writes += 1
                return receipt
            }
            await composer.begin("hello", source: source)
            await composer.begin("hello", source: source)
            XCTAssertEqual(writes, 1)
            XCTAssertNil(composer.confirmedText)
            XCTAssertFalse(composer.canSend("hello"))
            XCTAssertTrue(composer.canSend("different message"))
            XCTAssertEqual(composer.message, receipt == .notConfirmed ? "Not confirmed, check the terminal" : "Sent, not confirmed")
        }
        let composer = ChatComposer()
        var writes = 0
        await composer.begin("hello") { command in
            if case .prepare = command { return .prepared(.init(ticket: 1, revision: 0, needsConfirmation: false)) }
            writes += 1
            throw CancellationError()
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(composer.message, "Not confirmed, check the terminal")
        XCTAssertNil(composer.confirmedText)
    }

    func testLeavingDuringPreparationCannotStartALateWrite() async {
        let composer = ChatComposer()
        var resume: CheckedContinuation<ChatSendStatus, Never>?
        let task = Task {
            await composer.begin("hello") { command in
                if case .send = command { XCTFail("Cancelled preparation must never send") }
                return await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        composer.cancelBeforeSend()
        resume?.resume(returning: .prepared(.init(ticket: 1, revision: 0, needsConfirmation: false)))
        await task.value
        XCTAssertEqual(composer.phase, .idle)
        XCTAssertNil(composer.confirmedText)
    }

    func testReceiptDecoderPreservesIntegerRevisionAndRejectsUnknowns() throws {
        let prepared = try ChatSendStatus.decode(#"{"Prepared":{"ticket":18446744073709551615,"revision":42,"needs_confirmation":true}}"#)
        XCTAssertEqual(prepared, .prepared(.init(ticket: .max, revision: 42, needsConfirmation: true)))
        XCTAssertEqual(try ChatSendStatus.decode(#"{"ConfirmationRequired":{"revision":43}}"#), .confirmationRequired(43))
        XCTAssertEqual(try ChatSendStatus.decode(#""Confirmed""#), .confirmed)
        XCTAssertThrowsError(try ChatSendStatus.decode(#""FutureSuccess""#))
        XCTAssertThrowsError(try ChatSendStatus.decode(String(repeating: "x", count: 1_025)))
    }
}
