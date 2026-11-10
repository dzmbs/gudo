#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import App

@MainActor
final class FontSizeShortcutsTests: XCTestCase {
    private func keyDown(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)))
    }

    func testFontSizeItemsCarryTheirMenuShortcuts() {
        XCTAssertEqual(WorkspaceAction.fontActions, [.resetFontSize, .increaseFontSize, .decreaseFontSize])
        XCTAssertEqual(WorkspaceAction.fontActions.map(\.title), ["Reset Font Size", "Increase Font Size", "Decrease Font Size"])
        XCTAssertEqual(WorkspaceAction.increaseFontSize.shortcut.symbols, ["⌘", "+"])
        XCTAssertEqual(WorkspaceAction.decreaseFontSize.shortcut.symbols, ["⌘", "-"])
        XCTAssertEqual(WorkspaceAction.resetFontSize.shortcut.symbols, ["⌘", "0"])
        for action in WorkspaceAction.fontActions {
            XCTAssertTrue(WorkspaceAction.allShortcutActions.contains(action), "\(action.title) answers on iPad too")
        }
    }

    func testNoOtherActionTakesTheFontSizeKeys() {
        let fontKeys = WorkspaceAction.fontActions.flatMap(\.shortcuts)
        for action in WorkspaceAction.allShortcutActions where !WorkspaceAction.fontActions.contains(action) {
            for shortcut in action.shortcuts {
                XCTAssertFalse(fontKeys.contains { $0.key == shortcut.key && $0.modifiers == shortcut.modifiers }, action.title)
            }
        }
    }

    func testCommandEqualsAndCommandPlusBothIncrease() throws {
        let commandEquals = try keyDown("=", keyCode: kVK_ANSI_Equal)
        let commandShiftEquals = try keyDown("+", keyCode: kVK_ANSI_Equal, modifiers: [.command, .shift])
        XCTAssertEqual(WorkspaceShortcuts.action(for: commandEquals), .increaseFontSize)
        XCTAssertEqual(WorkspaceShortcuts.action(for: commandShiftEquals), .increaseFontSize)
    }

    func testCommandMinusDecreasesAndCommandZeroResets() throws {
        XCTAssertEqual(WorkspaceShortcuts.action(for: try keyDown("-", keyCode: kVK_ANSI_Minus)), .decreaseFontSize)
        XCTAssertEqual(WorkspaceShortcuts.action(for: try keyDown("0", keyCode: kVK_ANSI_0)), .resetFontSize)
    }

    func testShiftedLettersStillMeanTheirOwnShortcut() throws {
        let commandShiftD = try keyDown("D", keyCode: kVK_ANSI_D, modifiers: [.command, .shift])
        XCTAssertEqual(WorkspaceShortcuts.action(for: commandShiftD), .splitDown)
    }
}
#endif
