import XCTest
@testable import App

/// The Inbox's keys as an iPad or Mac keyboard sends them: ↑ ↓ move, ↩ approves, ⇧↩ approves
/// all like this, Esc and ⌘. deny, E edits. The simulator never delivers a synthesized Esc to key
/// commands, so the UI tests drive ⌘. and these drive every key through the catcher itself.
@MainActor
final class InboxKeysTests: XCTestCase {
    #if os(iOS)
    func testEveryKeyCommandReachesItsInboxKey() throws {
        let catcher = InboxKeyCatcher.CatcherView()
        var received: [InboxKey] = []
        catcher.handle = { received.append($0) }
        let expected: [(String, UIKeyModifierFlags, InboxKey)] = [
            (UIKeyCommand.inputUpArrow, [], .previous),
            (UIKeyCommand.inputDownArrow, [], .next),
            ("\r", [], .approve),
            ("\r", .shift, .approveAll),
            (UIKeyCommand.inputEscape, [], .deny),
            (".", .command, .deny),
            ("e", [], .edit),
        ]
        let commands = try XCTUnwrap(catcher.keyCommands)
        for (input, modifiers, key) in expected {
            received = []
            let command = try XCTUnwrap(
                commands.first { $0.input == input && $0.modifierFlags == modifiers }, "\(input) \(modifiers)")
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior, "\(input): ahead of the system's own use")
            let action = try XCTUnwrap(command.action)
            catcher.perform(action, with: command)
            XCTAssertEqual(received, [key], "\(input) \(modifiers)")
        }
    }
    #elseif os(macOS)
    func testEveryKeyEventReachesItsInboxKey() throws {
        let expected: [(UInt16, String, NSEvent.ModifierFlags, InboxKey)] = [
            (126, "\u{F700}", [], .previous),
            (125, "\u{F701}", [], .next),
            (36, "\r", [], .approve),
            (76, "\u{3}", [], .approve),
            (36, "\r", .shift, .approveAll),
            (53, "\u{1B}", [], .deny),
            (47, ".", .command, .deny),
            (14, "e", [], .edit),
        ]
        for (keyCode, characters, modifiers, key) in expected {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            XCTAssertEqual(InboxKeyCatcher.CatcherView.key(for: event), key, "key code \(keyCode) \(modifiers)")
        }
    }
    #endif
}
