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

// MARK: Attacks

/// What a pane does with a link target: one that does not parse opens nothing.
private func paneAction(_ string: String, shown: String?) -> LinkSafety.Action {
    URL(string: string).map { LinkSafety.action(for: $0, shown: shown) } ?? .refuse
}

@Test func disguisedScriptSchemesNeverOpen() {
    for bad in [
        "JaVaScRiPt:alert(1)", "DATA:text/html,<script>", "Blob:https://x/1", "VBScript:x", "About:blank", "FILE:///etc/passwd",
        " javascript:alert(1)", "\u{200B}javascript:alert(1)", "\tjavascript:alert(1)", "\u{1}javascript:alert(1)",
        "java\tscript:alert(1)", "java\nscript:alert(1)", "javascript%3Aalert(1)", "%6Aavascript:alert(1)",
    ] {
        #expect(paneAction(bad, shown: bad) == .refuse, "\(bad.debugDescription)")
    }
}

@Test func confirmationsNameTheRealHost() throws {
    for spoof in [
        "https://apple.com@evil.example/", "https://apple.com%2F@evil.example/", "https://apple.com\u{FF0F}@evil.example/",
        "https://apple.com:" + String(repeating: "a", count: 4000) + "@evil.example/",
    ] {
        let url = try #require(URL(string: spoof))
        #expect(LinkSafety.action(for: url, shown: spoof) == .confirm, "\(spoof.prefix(40))")
        #expect(LinkSafety.destination(url) == "evil.example", "\(spoof.prefix(40))")
    }
    // Look-alike letters: printed, they still ask, and the host shows as the browser sees it.
    let homograph = "https://\u{0430}pple.com/"
    #expect(paneAction(homograph, shown: homograph) == .confirm)
    #expect(LinkSafety.destination(try #require(URL(string: homograph))) == "xn--pple-43d.com")
    #expect(LinkSafety.destination(try #require(URL(string: "mailto:a@b.c"))) == nil)
}

@Test func filesThatInstallOrRunWebContentAreNotOpened() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func file(_ name: String) throws -> URL {
        let url = dir.appending(path: name)
        try Data("<?xml version=\"1.0\"?>\n".utf8).write(to: url)
        return url
    }
    func folder(_ name: String) throws -> URL {
        let url = dir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    // Profiles, Java Web Start, web pages (scripts run), and names only a bundle should have: a
    // plain file named so still goes to the app that installs those.
    for name in [
        "a.html", "a.svg", "a.mobileconfig", "a.configprofile", "a.jnlp", "a.prefPane", "a.saver", "a.workflow", "a.scptd",
        "X.COMMAND", "x.command.", "a.tool", "a.scpt", "a.applescript", "a.pkg", "a.mpkg", "a.dmg", "a.inetloc", "a.fileloc",
        "a.url", "a.terminal", "a.webloc", "a.jar", "a.zsh",
    ] {
        #expect(!LinkSafety.opensInDefaultApp(try file(name)), "\(name)")
    }
    for name in ["Evil.APP", "Evil.prefPane", "Evil.framework", "Evil.workflow", "Evil.kext", "Evil.xpc"] {
        let bundle = try folder(name)
        #expect(!LinkSafety.opensInDefaultApp(bundle), "\(name)")
        #expect(!LinkSafety.opensInDefaultApp(URL(fileURLWithPath: bundle.path + "/")), "\(name)/")
        let link = dir.appending(path: "docs-\(name)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        #expect(!LinkSafety.opensInDefaultApp(link), "link to \(name)")
    }
    // A chain of links ending at a script.
    let hop = dir.appending(path: "hop")
    try FileManager.default.createSymbolicLink(at: hop, withDestinationURL: try file("payload.command"))
    let start = dir.appending(path: "start.txt")
    try FileManager.default.createSymbolicLink(at: start, withDestinationURL: hop)
    #expect(!LinkSafety.opensInDefaultApp(start))
    // Documents and plain folders still open.
    for name in ["README.md", "data.json", "conf.yaml", "main.rs", "notes.txt"] {
        #expect(LinkSafety.opensInDefaultApp(try file(name)), "\(name)")
    }
    #expect(LinkSafety.opensInDefaultApp(try folder("release.v2")))
    // A link is judged by what it points at, both ways.
    let notes = dir.appending(path: "notes")
    try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: try file("notes.md"))
    #expect(LinkSafety.opensInDefaultApp(notes))
}
