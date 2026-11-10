import Foundation
import Testing
@testable import TerminalRenderer

/// What a paste of item providers types (the iOS paste control hands the terminal providers, not
/// a pasteboard): text as it is, links as their address, files as shell-escaped paths.
@MainActor
struct ItemProviderPasteTests {
    @Test func textPastesAsItIs() async {
        let text = await TerminalView.pastedText(from: [NSItemProvider(object: "git status\nls" as NSString)])
        #expect(text == "git status\nls")
    }

    @Test func aLinkPastesItsAddress() async throws {
        let link = try #require(URL(string: "https://example.com/a?b=c"))
        let text = await TerminalView.pastedText(from: [NSItemProvider(object: link as NSURL)])
        #expect(text == "https://example.com/a?b=c")
    }

    @Test func filesPasteAsShellEscapedPathsJoinedBySpaces() async {
        let providers = [
            NSItemProvider(object: URL(fileURLWithPath: "/tmp/a b/it's.png") as NSURL),
            NSItemProvider(object: URL(fileURLWithPath: "/tmp/plain.txt") as NSURL),
        ]
        let text = await TerminalView.pastedText(from: providers)
        #expect(text == "'/tmp/a b/it'\\''s.png' /tmp/plain.txt")
    }

    @Test func nothingReadableTypesNothing() async {
        #expect(await TerminalView.pastedText(from: []) == nil)
        #expect(await TerminalView.pastedText(from: [NSItemProvider()]) == nil)
    }
}
