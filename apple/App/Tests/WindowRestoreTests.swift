import Foundation
import HostKit
import XCTest
@testable import App

final class WindowRestoreTests: XCTestCase {
    private func host(_ id: String, kind: HostRecord.Kind = .daemon, connected: TimeInterval?, guest: Bool = false) -> HostRecord {
        var record = HostRecord(id: id, name: id, kind: kind, daemonId: kind == .daemon ? id : nil)
        record.lastConnected = connected.map { Date(timeIntervalSince1970: $0) }
        record.guest = guest
        return record
    }

    func testAWindowWithNothingToRestoreOpensTheLastPairedHostWhereThereIsNoLocalShell() {
        let records = [host("old", connected: 10), host("recent", connected: 20), host("box", kind: .ssh, connected: 30),
                       host("friend", connected: 40, guest: true)]
        XCTAssertEqual(WindowModel.launchHost(restoring: [], saved: records, hasLocalShell: false), "recent")
        XCTAssertEqual(WindowModel.launchHost(restoring: [], saved: [host("never", connected: nil)], hasLocalShell: false), "never")
    }

    func testARestoredWindowOrALocalShellKeepsItsOwnChoice() {
        let records = [host("studio", connected: 10)]
        XCTAssertNil(WindowModel.launchHost(restoring: ["studio"], saved: records, hasLocalShell: false))
        XCTAssertNil(WindowModel.launchHost(restoring: [], saved: records, hasLocalShell: true))
        XCTAssertNil(WindowModel.launchHost(restoring: [], saved: [], hasLocalShell: false))
    }
}
