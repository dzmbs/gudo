import XCTest

/// The Hosts screen without a daemon: Tailscale hosts are tagged, Add Host recognises a tailnet
/// destination and, when the dial fails, says that Tailscale must be connected on this device;
/// an ssh_config pasted in is offered for import (tailnet entries tagged) and saved.
@MainActor
final class HostsUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A hosts folder with saved SSH hosts (`hosts.json`, as `HostRepository` writes it).
    private func hostsDirectory(_ hosts: [(id: String, name: String, host: String)]) throws -> String {
        let directory = NSTemporaryDirectory() + "hosts-ui-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let records = hosts.map { host in
            """
            {"id":"\(host.id)","name":"\(host.name)","kind":"ssh","pinned":false,"created":"2026-10-21T00:00:00Z",
             "nameSource":"user","ssh":{"user":"me","host":"\(host.host)","port":22,"identity":{"password":{}}}}
            """
        }
        try "[\(records.joined(separator: ","))]".write(toFile: directory + "/hosts.json", atomically: true, encoding: .utf8)
        return directory
    }

    private func launch(hostsDirectory: String, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += [
            "-hostsDirectory", hostsDirectory, "-destination", "hosts", "-restoreLastTarget", "NO",
            "-ApplePersistenceIgnoreState", "YES", "-resetWindows", "YES",
        ] + extra
        app.launch()
    }

    private func hostRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "host-\(name)").firstMatch
    }

    func testTailscaleHostsAreTaggedAndAFailedDialSaysToConnectTailscale() throws {
        launch(hostsDirectory: try hostsDirectory([
            ("t1", "tailbox", "100.101.7.3"), ("t2", "nas", "nas.tail3f2c.ts.net"), ("p1", "pi", "192.168.1.40"),
        ]))
        let tailbox = hostRow("tailbox")
        XCTAssertTrue(tailbox.waitForExistence(timeout: 20), "the saved hosts are listed")
        XCTAssertTrue(tailbox.label.contains("Tailscale"), "a 100.64/10 host is tagged: \(tailbox.label)")
        XCTAssertTrue(hostRow("nas").label.contains("Tailscale"), "a MagicDNS host is tagged")
        XCTAssertFalse(hostRow("pi").label.contains("Tailscale"), "a LAN host is not")
        shot("hosts-tailscale")

        // Add Host: the destination is recognised as a tailnet name while typing.
        press(element("hosts-add"))
        let field = element("pairing-destination")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        press(field)
        // An unresolvable MagicDNS name: the dial fails at once (no real tailnet needed).
        field.typeText("me@no-such-machine.tail0000.ts.net")
        XCTAssertTrue(element("pairing-tailscale").waitForExistence(timeout: 5), "Add Host says it needs Tailscale")
        let password = element("ssh-password")
        if password.exists {
            press(password)
            password.typeText("x")
        }
        press(element("pairing-confirm"))
        XCTAssertTrue(element("pairing-error").waitForExistence(timeout: 40), "the failed dial is reported, not a spinner forever")
        XCTAssertTrue(element("tailscale-hint").waitForExistence(timeout: 5), "and explains that Tailscale must be connected")
        shot("add-host-tailscale-failed")
    }

    func testSSHConfigImportListsTagsAndSavesHosts() throws {
        // The file is read as Hosts → Import reads one (`-testSSHConfig`: the simulator's
        // pasteboard prompt and file picker cannot be driven reliably); the sheet is the real one.
        let file = NSTemporaryDirectory() + "ssh-config-\(UUID().uuidString)"
        try Self.config.write(toFile: file, atomically: true, encoding: .utf8)
        launch(hostsDirectory: try hostsDirectory([]), extra: ["-testSSHConfig", file])
        XCTAssertTrue(app.buttons["Import"].firstMatch.waitForExistence(timeout: 20), "the Import menu is on the Hosts screen")
        let importButton = app.buttons["Import 3"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "the three aliases are offered, all selected")
        XCTAssertTrue(app.staticTexts["builder"].exists)
        let tags = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tailscale'"))
        XCTAssertGreaterThanOrEqual(tags.count, 2, "the tailnet entries are tagged")
        shot("ssh-config-import")
        press(importButton)
        XCTAssertTrue(hostRow("builder").waitForExistence(timeout: 10), "the imported hosts are saved and listed")
        XCTAssertTrue(hostRow("tailpi").label.contains("Tailscale"))
        XCTAssertTrue(hostRow("magic").label.contains("Tailscale"))
        XCTAssertFalse(hostRow("builder").label.contains("Tailscale"))
    }

    private static let config = """
        Host builder
          HostName build.example.com
          User ci
          Port 2222
        Host tailpi
          HostName 100.88.1.2
          User pi
        Host magic
          HostName magic.tail3f2c.ts.net
          User me
        Host *
          ServerAliveInterval 30
        """
}
