import HostKit
import GudoCore
import XCTest
@testable import App

/// Pair a Device: who may make a code, the code's countdown and expiry, and the device that
/// paired with it.
@MainActor
final class PairDeviceTests: XCTestCase {
    private let owner = Actor(principal: "aa", device: String(repeating: "a", count: 64))

    private func session(grant: String? = nil, roles: [Role] = [.owner], client: (any MultiplayerClientAPI)? = MockMultiplayerClient()) -> MultiplayerSession {
        MultiplayerSession.preview(
            me: JoinInfo(actor: owner, name: "Alex’s iPad", roles: roles, scope: .daemon, grantId: grant, expiresMs: nil),
            participants: [], client: client)
    }

    private func code(expiresIn seconds: TimeInterval, from now: Date = .now) -> PairingCode {
        PairingCode(link: "gudo://pair/abc", qrPayload: "GUDO://PAIR/ABC", expiresMs: UInt64((now.timeIntervalSince1970 + seconds) * 1000))
    }

    func testOwnerDevicesGetACode() async {
        let model = PairDeviceModel(hostName: "studio")
        await model.makeCode(session())
        guard case .showing(let code) = model.stage else { return XCTFail("\(model.stage)") }
        XCTAssertTrue(code.qrPayload.hasPrefix("GUDO://PAIR/"))
        XCTAssertEqual(code.qrPayload, code.link.uppercased())
    }

    func testGuestsAndOlderHostsAndDisconnectedHostsSayWhy() async {
        let guest = PairDeviceModel(hostName: "studio")
        await guest.makeCode(session(grant: "g1", roles: [.owner, .driver]))
        XCTAssertEqual(guest.stage, .unavailable("You joined studio with an invite. Only its owner's devices can pair another one.", canConnect: false))

        let older = PairDeviceModel(hostName: "studio")
        await older.makeCode(session(client: nil))
        guard case .unavailable(let message, canConnect: false) = older.stage else { return XCTFail("\(older.stage)") }
        XCTAssertTrue(message.contains("too old"), message)

        let offline = PairDeviceModel(hostName: "studio")
        await offline.makeCode(nil)
        XCTAssertEqual(offline.stage, .unavailable("Connect to studio to pair a device with it.", canConnect: true))
    }

    func testTheCodeCountsDownAndExpires() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let code = code(expiresIn: 581, from: now)
        XCTAssertEqual(PairDeviceModel.remaining(code, now: now), "9:41")
        XCTAssertEqual(PairDeviceModel.remaining(code, now: now.addingTimeInterval(600)), "0:00")

        let model = PairDeviceModel(hostName: "studio")
        let owner = session()
        await model.makeCode(owner)
        guard case .showing(let shown) = model.stage else { return XCTFail("\(model.stage)") }
        model.refresh(owner, now: PairDeviceModel.expiry(shown).addingTimeInterval(-1))
        XCTAssertEqual(model.stage, .showing(shown))
        model.refresh(owner, now: PairDeviceModel.expiry(shown).addingTimeInterval(1))
        XCTAssertEqual(model.stage, .expired)
    }

    func testTheDeviceThatPairsIsNamed() async {
        let opened = Date.now
        let model = PairDeviceModel(hostName: "studio", openedAt: opened)
        let owner = session()
        await model.makeCode(owner)
        let earlier = DeviceInfo(device: String(repeating: "b", count: 64), principal: "aa", kind: .owner, name: "Old iPad",
                                 firstSeenMs: UInt64((opened.timeIntervalSince1970 - 3600) * 1000), grantId: nil, revoked: false, connected: 1)
        owner.seed(devices: [earlier], freshPairings: [earlier.device: earlier.pairedAt])
        model.refresh(owner)
        XCTAssertNotEqual(model.stage, .paired("Old iPad"), "a pairing from before the sheet opened is not this one")

        let phone = DeviceInfo(device: String(repeating: "c", count: 64), principal: "aa", kind: .owner, name: "Alex’s iPhone",
                               firstSeenMs: UInt64((opened.timeIntervalSince1970 + 2) * 1000), grantId: nil, revoked: false, connected: 1)
        owner.apply(.devicePaired(device: phone))
        model.refresh(owner)
        XCTAssertEqual(model.stage, .paired("Alex’s iPhone"))
        XCTAssertEqual(owner.notice?.message, "Alex’s iPhone paired with this host.")
    }

    #if os(macOS)
    func testTheCommandLineToolLinksToTheBundledHelperAndLeavesOthersAlone() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let bundle = home.appending(path: "Gudo.app/Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let helper = bundle.appending(path: Brand.daemonBinary)
        FileManager.default.createFile(atPath: helper.path, contents: Data())
        let link = CommandLineTool.link(home: home)

        XCTAssertEqual(CommandLineTool.status(helper: nil, link: link), .unavailable)
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .notInstalled)
        try CommandLineTool.install(helper: helper, link: link)
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helper.path)

        let moved = home.appending(path: "Applications/Gudo.app/Contents/MacOS/\(Brand.daemonBinary)")
        XCTAssertEqual(CommandLineTool.status(helper: moved, link: link), .notInstalled, "a link to an earlier copy of the app is replaced")

        try FileManager.default.removeItem(at: link)
        FileManager.default.createFile(atPath: link.path, contents: Data("#!/bin/sh\n".utf8))
        XCTAssertEqual(CommandLineTool.status(helper: helper, link: link), .taken(link.path))
        XCTAssertThrowsError(try CommandLineTool.install(helper: helper, link: link))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "#!/bin/sh\n", "someone else's command stays")
    }
    #endif

    func testFirstRunExplainsHowToPairInOneLine() {
        XCTAssertFalse(PairingHint.message.contains("\n"))
        #if os(iOS)
        XCTAssertTrue(PairingHint.message.contains("Pair a Phone or iPad"))
        XCTAssertTrue(PairingHint.message.contains("\(Brand.commandLineTool) pair"))
        #endif
    }
}
