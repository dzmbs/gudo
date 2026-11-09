#if os(iOS)
import DesignSystem
import HostKit
import GudoCore
import PaneLayout
import SwiftUI
import VoiceKit
import UIKit
import XCTest
@testable import App

@MainActor
final class PaneChatViewTests: XCTestCase {
    private struct Fixture {
        let pane: Pane
        let state: PaneChatState
        let backend: PanePresentationTests.Backend
        let events: WorkspaceEventHub
        let hub: DaemonWorkspace
        let client: TimelineFixtureClient
        let window: UIWindow
    }

    func testBothAgentsRenderColouredCodeWhileTheTimelineStreams() async throws {
        let suite = "chat-code-colours-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            preferences.removePersistentDomain(forName: suite)
            UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
        }
        let markdown = """
        # Native code colours

        Both agents keep the same readable code and full copy text.

        ```rust
        // Cache values, not native parser state.
        fn greet(name: &str) -> String {
            format!("Hello, {}", name)
        }
        ```

        ```swift
        func update(_ frame: Frame) {
            collection.apply(frame)
        }
        ```
        """
        for theme in ["Dracula", "Apple System Colors Light"] {
            var arguments = saved
            arguments[TerminalPreferences.Key.theme] = theme
            arguments[TerminalPreferences.Key.windowTheme] = TerminalPreferences.WindowTheme.auto.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for agent in ["Claude", "Codex"] {
                let base = try TimelineFixtureJSON.snapshot(0..<0, before: nil, agent: agent)
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
                var item = TimelineFixtureJSON.item(0)
                item["id"] = "code-colours"
                item["body"] = ["Assistant": ["text": markdown, "streaming": true]]
                value["items"] = [item]
                let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true,
                    nativeMessageReceipts: true, agent: agent, snapshot: TimelineFixtureJSON.json(value))
                defer {
                    fixture.state.deactivate()
                    fixture.window.isHidden = true
                    fixture.window.rootViewController = nil
                }
                try await wait { fixture.state.controller?.collection.visibleCells.isEmpty == false }
                let codes = fixture.state.model?.frame.rows.compactMap { row -> ChatCodeSnippet? in
                    guard case .markdown(let block) = row.content else { return nil }
                    return block.code
                } ?? []
                XCTAssertEqual(codes.count, 2)
                XCTAssertTrue(codes.allSatisfy { !$0.highlights.isEmpty })
                fixture.events.deliver(.timeline(paneId: 7, updateJson: try TimelineFixtureJSON.append("code-colours", text: "\n\nStreaming stays readable.", sequence: 1)))
                try await wait { fixture.state.model?.frame.rows.contains { row in
                    if case .markdown(let block) = row.content { return String(block.text.characters).contains("Streaming stays readable.") }
                    return false
                } == true }
                XCTAssertEqual(fixture.state.model?.frame.rows.compactMap { row -> ChatCodeSnippet? in
                    guard case .markdown(let block) = row.content else { return nil }
                    return block.code
                }, codes)
                try await Task.sleep(for: .milliseconds(180))
                try capture(fixture.window, name: "code-colours-\(agent.lowercased())-\(theme.contains("Light") ? "light" : "dark")")
            }
        }
    }

    func testCapabilitiesNotKindSelectNativeControls() async throws {
        let suite = "chat-agent-capabilities-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            preferences.removePersistentDomain(forName: suite)
            UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
        }
        for theme in ["Dracula", "Apple System Colors Light"] {
            var arguments = saved
            arguments[TerminalPreferences.Key.theme] = theme
            arguments[TerminalPreferences.Key.windowTheme] = TerminalPreferences.WindowTheme.auto.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            try await verifyCapabilities(preferences: preferences, theme: theme.contains("Light") ? "light" : "dark")
        }
    }

    private func verifyCapabilities(preferences: UserDefaults, theme: String) async throws {
        for (agent, capabilities) in [("Claude", UInt16(1)), ("Codex", UInt16(9))] {
            let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true,
                                          nativeMessageReceipts: true, capabilities: capabilities, agent: agent)
            defer {
                fixture.state.deactivate()
                fixture.window.isHidden = true
                fixture.window.rootViewController = nil
            }
            try await wait {
                fixture.state.model?.frame.rows.count == 60 && fixture.state.controller?.collection.visibleCells.isEmpty == false
            }
            XCTAssertEqual(fixture.state.capabilities.rawValue, capabilities)
            fixture.state.draft = "Keep this local draft"
            let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                     permitsSending: true, working: true) { _ in Color.clear }
            owner.send()
            owner.interrupt()
            await Task.yield()
            await Task.yield()
            if capabilities & 8 != 0 {
                try await wait { fixture.state.interrupt.phase == .finished }
                XCTAssertTrue(fixture.client.calls.contains("interrupt 7 7 none"))
            } else {
                XCTAssertEqual(fixture.state.interrupt.phase, .idle)
            }
            XCTAssertEqual(fixture.state.composer.phase, .idle)
            XCTAssertEqual(fixture.state.draft, "Keep this local draft")
            XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("send ") })
            try await wait { fixture.state.controller?.collection.visibleCells.isEmpty == false }
            let profile = capabilities == 1 ? "read-only" : "stop-only"
            try capture(fixture.window, name: "chat-capabilities-\(profile)-\(theme)")
        }
    }

    func testBothPresentationsRetainTheirNativeViewsWhileTheSharedTimelineAdvances() async throws {
        let suite = "chat-pane-view-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            preferences.removePersistentDomain(forName: suite)
            UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
        }
        for name in ["Dracula", "Apple System Colors Light"] {
            var arguments = saved
            arguments[TerminalPreferences.Key.theme] = name
            arguments[TerminalPreferences.Key.windowTheme] = TerminalPreferences.WindowTheme.auto.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let fixture = try makeFixture(preferences: preferences)
            defer {
                fixture.state.deactivate()
                fixture.window.isHidden = true
                fixture.window.rootViewController = nil
            }
            try await exercise(fixture, name: name.contains("Light") ? "light" : "dark")
        }
    }

    func testNativeSegmentSelectionVetoKeepsMarkedComposerAndChatSelected() async throws {
        let suite = "chat-pane-marked-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        let controller = try XCTUnwrap(fixture.state.controller)
        let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        controller.view.addSubview(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(fixture.state.showTerminal(commandMark: 42, terminal: fixture.pane))
        XCTAssertNil(fixture.state.terminalNotice)
        XCTAssertEqual(fixture.state.presentation, .chat)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertNotNil(editor.markedTextRange)
        fixture.state.draft = "Retain while composing"
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.send()
        owner.interrupt()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("interrupt") })
        let picker = try XCTUnwrap(presentationControl(in: fixture.window))
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(fixture.state.presentation, .chat)
        XCTAssertEqual(picker.selectedSegmentIndex, 0)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertNotNil(editor.markedTextRange)
        let update = try TimelineFixtureJSON.update([["Unavailable": ["message": "Fixture Chat stopped"]]])
        fixture.events.deliver(.timeline(paneId: 7, updateJson: update))
        try await wait { fixture.state.model?.error == "Fixture Chat stopped" }
        XCTAssertEqual(fixture.state.presentation, .chat)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertNotNil(editor.markedTextRange)
    }

    func testRetainedHiddenChatCannotBeginSendingFromAnActionOrHardwareShortcut() async throws {
        let suite = "chat-send-hidden-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Never send from the parked Chat view"
        XCTAssertTrue(fixture.state.show(.terminal, terminal: fixture.pane, persistence: .transient))
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.send()
        owner.interrupt()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("interrupt") })
        XCTAssertTrue(fixture.state.select(.chat, persistence: .transient) { true })
        PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub) { _ in Color.clear }.send()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.draft, "Never send from the parked Chat view")
        owner.send()
        owner.interrupt()
        XCTAssertTrue(fixture.state.show(.terminal, terminal: fixture.pane, persistence: .transient))
        XCTAssertTrue(fixture.state.select(.chat, persistence: .transient) { true })
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        owner.send()
        fixture.state.deactivate()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("interrupt") })
        fixture.state.activate(in: fixture.hub)
        try await wait { fixture.state.model?.frame.rows.count == 60 }
        owner.send()
        try await wait { fixture.state.composer.phase == .finished }
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
    }

    func testADeferredSendUsesTheTappedTextAndPreservesEditsMadeBeforeItsTaskRuns() async throws {
        let suite = "chat-send-tapped-draft-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, nativeMessageReceipts: true)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Tapped text"
        PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                     permitsSending: true) { _ in Color.clear }.send()
        fixture.state.draft = "New unsent text"
        try await wait { fixture.state.composer.confirmedText != nil }
        XCTAssertEqual(fixture.client.calls.filter { $0.hasPrefix("send ") }, ["send 7 Tapped text"])
        XCTAssertEqual(fixture.state.composer.confirmedText, "Tapped text")
        XCTAssertEqual(fixture.state.draft, "New unsent text")
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
    }

    func testQueuedActionsCannotReissueAfterTheirOriginalGenerationCompletesOrResets() async throws {
        let suite = "chat-action-generation-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true, nativeMessageReceipts: true)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        fixture.state.draft = "Queued text"
        owner.send()
        await fixture.state.composer.begin("A different explicit intent") { command in
            if case .prepare = command { return .prepared(.init(ticket: 9, revision: 1, needsConfirmation: false)) }
            return .confirmed
        }
        fixture.state.draft = ""
        fixture.state.composer.draftChanged("")
        owner.interrupt()
        fixture.state.interrupt.reset()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("send ") || $0.hasPrefix("interrupt") })
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
    }

    func testAQueuedConfirmationCannotApproveANewerWarningRevision() async throws {
        let suite = "chat-confirm-generation-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true) { _ in Color.clear }
        var writes = 0
        await fixture.state.composer.begin("Confirm this text") { command in
            if case .prepare = command { return .prepared(.init(ticket: 7, revision: 1, needsConfirmation: true)) }
            writes += 1
            return writes == 1 ? .confirmationRequired(2) : .confirmed
        }
        owner.confirmAction()
        owner.confirmAction()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(fixture.state.composer.needsConfirmation)
        XCTAssertEqual(fixture.state.composer.confirmationRevision, 2)
        owner.confirmAction()
        try await wait { fixture.state.composer.confirmedText != nil }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(fixture.state.composer.confirmedText, "Confirm this text")
    }

    func testTheActualComposerMarkedTextVetoesSendInterruptAndParking() async throws {
        let suite = "chat-composer-ime-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true, nativeMessageReceipts: true)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        func input(in view: UIView) -> (UIView & UITextInput)? {
            if let text = view as? UITextView, text.isEditable, text.text == "Draft in progress" { return text }
            if let field = view as? UITextField, field.isEnabled, field.text == "Draft in progress" { return field }
            return view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Draft in progress"
        fixture.window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(30))
        let editor = try XCTUnwrap(input(in: fixture.window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertNil(fixture.pane.view.markedTextRange)
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.send()
        owner.interrupt()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("send ") || $0.hasPrefix("interrupt") })
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertFalse(fixture.state.showTerminal(commandMark: nil, terminal: fixture.pane))
        XCTAssertEqual(fixture.state.presentation, .chat)
        editor.unmarkText()
        XCTAssertTrue(fixture.state.showTerminal(commandMark: nil, terminal: fixture.pane))
    }

    func testNativeInterruptUsesItsTicketAndWarningWithoutClearingDraftOrWritingRawKeys() async throws {
        let suite = "chat-interrupt-view-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true,
                                      interruptNeedsConfirmation: true)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Keep the phone draft while interrupting"
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.interrupt()
        try await wait { fixture.state.interrupt.needsConfirmation }
        XCTAssertEqual(fixture.client.calls.filter { $0.hasPrefix("interrupt") }, ["interrupt prepare 7"])
        try await wait { fixture.window.rootViewController?.presentedViewController != nil }
        try await Task.sleep(for: .milliseconds(250))
        try capture(fixture.window, name: "chat-stop-warning")
        await fixture.state.interrupt.confirm()
        try await wait { fixture.state.interrupt.message == "Interrupt requested" }
        owner.interrupt()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.client.calls.filter { $0.hasPrefix("interrupt") }, ["interrupt prepare 7", "interrupt 7 7 4"])
        XCTAssertEqual(fixture.state.draft, "Keep the phone draft while interrupting")
        XCTAssertEqual(fixture.backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(fixture.backend.state.withLock { $0.claims }, 0)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
        try await wait { fixture.window.rootViewController?.presentedViewController == nil }
        try capture(fixture.window, name: "chat-stop-requested")
    }

    func testNativeComposerClearsOnlyConfirmedUneditedTextAndShowsUnconfirmedAndDirtyStates() async throws {
        let suite = "chat-send-view-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        let state = fixture.state
        state.draft = "confirmed phone draft"
        await state.composer.begin(state.draft) { command in
            if case .prepare = command { return .prepared(.init(ticket: 1, revision: 0, needsConfirmation: false)) }
            return .confirmed
        }
        try await wait { state.draft.isEmpty }
        state.draft = "sent text"
        await state.composer.begin(state.draft) { command in
            if case .prepare = command { return .prepared(.init(ticket: 2, revision: 0, needsConfirmation: false)) }
            state.draft = "new phone draft while sending"
            return .confirmed
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.draft, "new phone draft while sending")
        await state.composer.begin(state.draft) { command in
            if case .prepare = command { return .prepared(.init(ticket: 3, revision: 0, needsConfirmation: false)) }
            return .notConfirmed
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.draft, "new phone draft while sending")
        XCTAssertEqual(state.composer.message, "Not confirmed, check the terminal")
        try capture(fixture.window, name: "chat-send-not-confirmed")
        state.draft = "another message"
        await state.composer.begin(state.draft) { command in
            if case .send = command { XCTFail("Dirty draft must wait for the user's choice") }
            return .prepared(.init(ticket: 4, revision: 1, needsConfirmation: true))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(state.composer.needsConfirmation)
        try capture(fixture.window, name: "chat-send-draft-warning")
        state.composer.cancelConfirmation()
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
    }

    func testDictationPermissionInactivityKeepsOnlyTheLocalDraftAndVetoesHostControls() async throws {
        let suite = "chat-dictation-pane-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recognizer = ChatSpeechFixture()
        let voice = PushToTalk(recognizer: { recognizer }, settings: { VoiceSettings(isEnabled: true) })
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true,
                                      dictation: ChatDictation(voice: voice))
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Draft in progress"
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.send()
        owner.interrupt()
        owner.dictate()
        fixture.state.dictation.cancel()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        owner.dictate()
        XCTAssertTrue(fixture.state.dictation.isStarting)
        let context = fixture.state.actionContext
        owner.sceneChanged(.inactive)
        XCTAssertEqual(fixture.state.actionContext, context)
        owner.send()
        owner.interrupt()
        try await wait { voice.phase == .listening }
        recognizer.emit(.volatile("add these words"))
        try await wait { fixture.state.dictation.preview == "add these words" }
        try capture(fixture.window, name: "voice-mock-listening")
        owner.send()
        owner.interrupt()
        owner.dictate()
        try await wait { !fixture.state.dictation.isActive }
        XCTAssertEqual(fixture.state.draft, "Draft in progress add these words")
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("send ") || $0.hasPrefix("interrupt") })
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
        try capture(fixture.window, name: "voice-mock-draft")
        owner.dictate()
        owner.sceneChanged(.background)
        XCTAssertFalse(voice.isActive)
        XCTAssertEqual(fixture.state.draft, "Draft in progress add these words")
    }

    func testReadOnlyDetailRoundTripCancelsAlreadyQueuedNativeControls() async throws {
        let suite = "chat-detail-action-scope-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true, nativeMessageReceipts: true)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Queued before reading a tool"
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.send()
        owner.interrupt()
        fixture.state.presentDetail { _ in .text(ChatSelectedText(title: "Select Text", text: "Read-only snapshot")) }
        fixture.state.detail = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.client.calls.contains { $0.hasPrefix("send ") || $0.hasPrefix("interrupt") })
        XCTAssertEqual(fixture.state.draft, "Queued before reading a tool")
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
    }

    func testPhotoUploadUsesTheExistingStreamAndDefersDraftInsertionWhileNativeTextIsMarked() async throws {
        let suite = "chat-photo-pane-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, permitsSending: true, working: true, photoUploads: true)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "photo.jpg")
        try Data(repeating: 1, count: 10).write(to: url)
        let file = ChatPhotoFile(url: url, bytes: 10)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        fixture.state.draft = "Review this photo"
        fixture.state.invalidateActions()
        fixture.state.photos.begin(in: fixture.state)
        let owner = PaneChatView(pane: fixture.pane, state: fixture.state, hub: fixture.hub,
                                 permitsSending: true, working: true) { _ in Color.clear }
        owner.send()
        owner.interrupt()
        let context = fixture.state.actionContext
        let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        try XCTUnwrap(fixture.state.controller).view.addSubview(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        fixture.state.photos.load(in: fixture.state, photo: { file }, source: { file in
            try await owner.uploadPhoto(file, context: context)
        })
        try await wait { fixture.state.photos.phase == .ready }
        XCTAssertEqual(fixture.state.draft, "Review this photo")
        XCTAssertNotNil(editor.markedTextRange)
        let uploads = fixture.client.state.withLock { $0.uploads }
        let target = try XCTUnwrap(uploads.first)
        XCTAssertEqual(uploads.count, 1)
        XCTAssertTrue(target.path.hasPrefix("/fixture/home/Downloads/Gudo-Attachments/"))
        XCTAssertTrue(target.createNew && target.mkdirs)
        XCTAssertEqual(target.mode, 0o600)
        editor.unmarkText()
        XCTAssertTrue(fixture.state.photos.append(to: fixture.state))
        editor.resignFirstResponder()
        editor.removeFromSuperview()
        XCTAssertEqual(fixture.state.draft, "Review this photo\n@" + target.path)
        XCTAssertFalse(fixture.state.photos.append(to: fixture.state))
        XCTAssertEqual(fixture.state.composer.phase, .idle)
        XCTAssertEqual(fixture.state.interrupt.phase, .idle)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
        func draftEditor(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.isEditable, text.text == fixture.state.draft { return text }
            return view.subviews.lazy.compactMap { draftEditor(in: $0) }.first
        }
        try await wait { draftEditor(in: fixture.window) != nil }
        let draftEditor = try XCTUnwrap(draftEditor(in: fixture.window))
        try await wait { draftEditor.bounds.height >= (draftEditor.font?.lineHeight ?? 1) * 1.9 }
        try await Task.sleep(for: .milliseconds(350))
        try capture(fixture.window, name: "photo-mock-added")
    }

    private func makeFixture(preferences: UserDefaults, permitsSending: Bool = false, working: Bool = false,
                             interruptNeedsConfirmation: Bool = false, nativeMessageReceipts: Bool = false,
                             dictation: ChatDictation = .init(), photoUploads: Bool = false,
                             capabilities: UInt16 = 447, agent: String = "Claude", snapshot: String? = nil) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let backend = PanePresentationTests.Backend()
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        pane.view.surface.terminal.write(Array("Private live terminal fixture\r\nOriginal terminal draft stays here".utf8))
        let state = PaneChatState(member: HostPane(hostId: "fixture", pane: pane.id), defaultPresentation: .chat,
                                  agent: agent == "Codex" ? .codex : .claude, inputPresentation: pane.inputPresentation,
                                  preferences: preferences, pool: ChatModelPool(capacity: 1), dictation: dictation)
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
        let client = TimelineFixtureClient(snapshot: try snapshot ?? TimelineFixtureJSON.snapshot(0..<60, before: nil, capabilities: capabilities, agent: agent),
                                           interruptNeedsConfirmation: interruptNeedsConfirmation,
                                           nativeMessageReceipts: nativeMessageReceipts, photoUploads: photoUploads)
        let events = WorkspaceEventHub()
        let hub = DaemonWorkspace(hostId: "fixture", events: events, resolve: { client })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            NavigationStack {
                PaneChatView(pane: pane, state: state, hub: hub, permitsSending: permitsSending, working: working) { active in
                    NativeTerminalFixture(pane: pane, active: active)
                }
                .navigationTitle("Review the change").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .principal) { PaneChatToggle(pane: pane, state: state) } }
            }
        })
        window.makeKeyAndVisible()
        return Fixture(pane: pane, state: state, backend: backend, events: events, hub: hub, client: client, window: window)
    }

    private func exercise(_ fixture: Fixture, name: String) async throws {
        let state = fixture.state
        try await wait { state.model?.frame.rows.count == 60 && state.controller?.collection.numberOfSections == 1 }
        try await Task.sleep(for: .milliseconds(180))
        let controller = try XCTUnwrap(state.controller)
        let original = fixture.pane.view
        let originalGrid = original.surface.terminal.size
        XCTAssertEqual(state.presentation, .chat)
        XCTAssertNil(original.superview)
        state.draft = "Unsent Chat draft"
        controller.scrollViewWillBeginDragging(controller.collection)
        controller.collection.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        XCTAssertFalse(try XCTUnwrap(state.model).followsBottom)
        try await Task.sleep(for: .milliseconds(180))
        let reading = try readingAnchor(in: controller.collection)
        try capture(fixture.window, name: "chat-" + name)
        let picker = try XCTUnwrap(presentationControl(in: fixture.window))
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        try await wait { state.presentation == .terminal && original.superview != nil }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(fixture.pane.view === original)
        XCTAssertTrue(state.controller === controller)
        XCTAssertEqual(state.draft, "Unsent Chat draft")
        try capture(fixture.window, name: "terminal-" + name)
        let update = try TimelineFixtureJSON.append("m59", text: "\n\nLive while Terminal is visible.", sequence: 1)
        fixture.events.deliver(.timeline(paneId: 7, updateJson: update))
        try await wait { state.model?.frame.cursor?.sequence == 1 }
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        try await wait { state.presentation == .chat && original.superview == nil }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(state.controller === controller)
        XCTAssertEqual(try position(of: reading.row, in: controller.collection), reading.position,
                       accuracy: 1, name + " reading anchor")
        XCTAssertEqual(state.draft, "Unsent Chat draft")
        XCTAssertEqual(original.surface.terminal.size.cols, originalGrid.cols)
        XCTAssertEqual(original.surface.terminal.size.rows, originalGrid.rows)
        XCTAssertEqual(fixture.backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(fixture.backend.state.withLock { $0.claims }, 0)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
        XCTAssertEqual(fixture.client.calls.filter { $0 == "watch 7" }.count, 1)
        XCTAssertFalse(fixture.client.calls.contains("unwatch 7"))
        XCTAssertTrue(fixture.client.state.withLock { $0.launches.isEmpty })
        try capture(fixture.window, name: "returned-chat-" + name)
        XCTAssertTrue(state.showTerminal(commandMark: 99, terminal: fixture.pane))
        try await wait { state.presentation == .terminal && original.superview != nil }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(state.terminalNotice, .unavailableCommand(99))
        XCTAssertEqual(fixture.backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(fixture.backend.state.withLock { $0.claims }, 0)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
        try capture(fixture.window, name: "missing-command-" + name)
        XCTAssertTrue(state.show(.chat, terminal: fixture.pane))
        XCTAssertNil(state.terminalNotice)
    }

    private func readingAnchor(in collection: UICollectionView) throws -> (row: ChatRowID, position: CGFloat) {
        let source = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<Int, ChatRowID>)
        let point = CGPoint(x: 1, y: collection.contentOffset.y + collection.adjustedContentInset.top)
        let path = try XCTUnwrap(collection.indexPathForItem(at: point))
        let identifier = try XCTUnwrap(source.itemIdentifier(for: path))
        return (identifier, try position(of: identifier, in: collection))
    }

    private func position(of identifier: ChatRowID, in collection: UICollectionView) throws -> CGFloat {
        let source = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<Int, ChatRowID>)
        let path = try XCTUnwrap(source.indexPath(for: identifier))
        return try XCTUnwrap(collection.layoutAttributesForItem(at: path)).frame.minY - collection.contentOffset.y
    }

    private func presentationControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.presentationControl(in: $0) }.first
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Chat pane did not reach its expected state", file: file, line: line)
        throw CancellationError()
    }

    private func capture(_ window: UIWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try image.pngData()?.write(to: root.appendingPathComponent("\(device)-pane-\(name).png"))
    }
}

private struct NativeTerminalFixture: UIViewRepresentable {
    let pane: Pane
    let active: Bool

    func makeUIView(context: Context) -> TerminalHost.Container {
        let host = TerminalHost.Container()
        host.pane = pane
        host.isActive = active
        pane.hosts.add(host)
        return host
    }

    func updateUIView(_ host: TerminalHost.Container, context: Context) { host.isActive = active }
}

nonisolated final class TimelineFixtureClient: FakeWorkspaceClient, DaemonTimelineAPI, @unchecked Sendable {
    private let snapshot: String
    private let interruptNeedsConfirmation: Bool
    private let nativeMessageReceipts: Bool
    private let photoUploads: Bool
    init(snapshot: String, interruptNeedsConfirmation: Bool = false, nativeMessageReceipts: Bool = false,
         photoUploads: Bool = false) {
        self.snapshot = snapshot
        self.interruptNeedsConfirmation = interruptNeedsConfirmation
        self.nativeMessageReceipts = nativeMessageReceipts
        self.photoUploads = photoUploads
        super.init()
    }
    func chatPrepare(paneId: UInt64) async throws -> String {
        guard nativeMessageReceipts else { throw CancellationError() }
        return try TimelineFixtureJSON.json(["Prepared": ["ticket": 1, "revision": 0, "needs_confirmation": false]])
    }
    func chatSend(paneId: UInt64, ticket: UInt64, text: String, confirmedRevision: UInt64?) async throws -> String {
        guard nativeMessageReceipts else { throw CancellationError() }
        record("send \(paneId) \(text)")
        return #""Confirmed""#
    }
    func chatInterruptPrepare(paneId: UInt64) async throws -> String {
        record("interrupt prepare \(paneId)")
        return try TimelineFixtureJSON.json(["Prepared": ["ticket": 7, "revision": 4,
                                                          "needs_confirmation": interruptNeedsConfirmation]])
    }
    func chatInterrupt(paneId: UInt64, ticket: UInt64, confirmedRevision: UInt64?) async throws -> String {
        record("interrupt \(paneId) \(ticket) \(confirmedRevision.map(String.init) ?? "none")")
        return #""InterruptRequested""#
    }
    override func fsStat(path: String) async throws -> FileStat {
        if photoUploads, path == "~" { return Self.stat("/fixture/home", size: 0, kind: .dir) }
        return try await super.fsStat(path: path)
    }
    override func uploadFile(localPath: String, target: WriteTarget, progress: (any TransferProgress)?) async throws -> FileStat {
        guard photoUploads else { return try await super.uploadFile(localPath: localPath, target: target, progress: progress) }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: localPath))
        state.withLock { $0.uploads.append(target) }
        return Self.stat(target.path, size: UInt64(bytes.count))
    }
    func timelineWatch(paneId: UInt64) async throws -> String { record("watch \(paneId)"); return snapshot }
    func timelineUnwatch(paneId: UInt64) async throws { record("unwatch \(paneId)") }
    func timelineItemsBefore(paneId: UInt64, before: UInt64, limit: UInt16) async throws -> String {
        try TimelineFixtureJSON.snapshot(0..<0, before: nil)
    }
    func timelineToolOutput(paneId: UInt64, handle: String, offset: UInt64, len: UInt32) async throws -> String {
        try TimelineFixtureJSON.json(["text": "Fixture output", "next_offset": NSNull(), "total_bytes": 14])
    }
}
#endif
