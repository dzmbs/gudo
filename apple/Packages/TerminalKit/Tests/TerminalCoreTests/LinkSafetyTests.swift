import Foundation
import Testing
@testable import TerminalCore

@Test func onlyWebPagesWhoseAddressWasSeenOpenWithoutAsking() {
    func action(_ string: String, shown: String?) -> LinkSafety.Action {
        LinkSafety.action(for: URL(string: string)!, shown: shown)
    }
    #expect(action("https://ghostty.org/docs", shown: "https://ghostty.org/docs") == .open)
    // An OSC 8 label that names another place, or no visible address at all.
    #expect(action("https://evil.example/", shown: "https://github.com/") == .confirm)
    #expect(action("https://evil.example/", shown: nil) == .confirm)
    #expect(action("https://github.com@evil.example/", shown: "https://github.com@evil.example/") == .confirm)
    // Other schemes start apps: this app's own pairing links, Shortcuts, editors.
    for other in ["unnamed://pair/abc", "shortcuts://run-shortcut?name=x", "vscode://file/etc/passwd", "mailto:a@b.c", "ssh://h"] {
        #expect(action(other, shown: other) == .confirm, "\(other)")
    }
    for bad in ["javascript:alert(1)", "data:text/html,<script>", "file:///Applications/Calculator.app"] {
        #expect(action(bad, shown: bad) == .refuse, "\(bad)")
    }
}

@Test func printedFileURLsArePaths() {
    let matches = LinkDetector.matches(in: "open file:///Applications/Calculator.app now")
    #expect(matches.map(\.kind) == [.path])
    #expect(matches.first?.target == "/Applications/Calculator.app")
}

@Test func localFilesThatWouldRunAreNotOpened() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func file(_ name: String, executable: Bool = false) throws -> URL {
        let url = dir.appending(path: name)
        try Data("echo hi\n".utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }
    #expect(LinkSafety.opensInDefaultApp(try file("notes.txt")))
    #expect(LinkSafety.opensInDefaultApp(try file("main.rs")))
    #expect(LinkSafety.opensInDefaultApp(dir))
    #expect(!LinkSafety.opensInDefaultApp(try file("run.command")))
    #expect(!LinkSafety.opensInDefaultApp(try file("install.sh")))
    #expect(!LinkSafety.opensInDefaultApp(try file("tool", executable: true)))
    #expect(!LinkSafety.opensInDefaultApp(try file("notes2.txt", executable: true)))
    #expect(!LinkSafety.opensInDefaultApp(try file("site.webloc")))
    #expect(!LinkSafety.opensInDefaultApp(try file("shell.terminal")))
    #expect(!LinkSafety.opensInDefaultApp(try file("tool.py")))
    #expect(!LinkSafety.opensInDefaultApp(try file("app.jar")))
    #expect(!LinkSafety.opensInDefaultApp(dir.appending(path: "missing.txt")))
    let app = dir.appending(path: "Evil.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(!LinkSafety.opensInDefaultApp(app))
    // A harmless-looking name that links to something that would run.
    let link = dir.appending(path: "README.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try file("payload.command"))
    #expect(!LinkSafety.opensInDefaultApp(link))
}

@Test func addressesShowEveryCharacter() {
    let url = URL(string: "https://example.com/%E2%80%AEtxt.exe")!
    #expect(!LinkSafety.display(url).unicodeScalars.contains { $0.properties.generalCategory == .format })
}
