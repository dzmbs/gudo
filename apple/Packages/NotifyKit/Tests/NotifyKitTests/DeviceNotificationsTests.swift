import Foundation
import Testing
import UserNotifications

@testable import NotifyKit

@Suite struct DeviceNotificationsTests {
    private let note = DevicePairedNote(
        hostId: "h1", hostName: "studio", device: String(repeating: "c", count: 64),
        deviceName: "Mira’s iPhone", pairedAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func aPairingNamesTheDeviceTheHostAndTheWayOut() {
        let content = DeviceNotifications.content(for: note, now: note.pairedAt.addingTimeInterval(60))
        #expect(content.title == "New device paired: Mira’s iPhone")
        #expect(content.body.contains("studio"))
        #expect(content.body.contains(note.pairedAt.formatted(date: .omitted, time: .shortened)))
        #expect(content.body.contains("Settings › Devices"))
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.categoryIdentifier == DeviceNotifications.category)
        #expect(DeviceNotifications.hostId(from: content.userInfo) == "h1")
        // A local attention target must never be read out of it (it opens Devices, nothing else).
        #expect(NotificationTarget(userInfo: content.userInfo, remote: false) == nil)
    }

    @Test func anOlderPairingSaysWhichDay() {
        let content = DeviceNotifications.content(for: note, now: note.pairedAt.addingTimeInterval(3 * 86_400))
        #expect(content.body.contains(note.pairedAt.formatted(date: .abbreviated, time: .omitted)))
    }

    @Test func eachDeviceGetsItsOwnNotification() {
        var other = note
        other.device = String(repeating: "d", count: 64)
        #expect(DeviceNotifications.identifier(note) != DeviceNotifications.identifier(other))
        #expect(NotificationCategories.all.contains { $0.identifier == DeviceNotifications.category })
    }

    @Test func aHostAlertIsClaimedOncePerHostAcrossLaunches() throws {
        let suite = "ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(HostAlertLedger(defaults: defaults).claim(hostId: "h1", key: "grantStoreReset/1000"))
        #expect(!HostAlertLedger(defaults: defaults).claim(hostId: "h1", key: "grantStoreReset/1000"), "a new launch remembers")
        #expect(HostAlertLedger(defaults: defaults).claim(hostId: "h2", key: "grantStoreReset/1000"), "another host is told separately")
        #expect(HostAlertLedger(defaults: defaults).claim(hostId: "h1", key: "grantStoreReset/2000"), "a new occurrence is told again")
    }
}
