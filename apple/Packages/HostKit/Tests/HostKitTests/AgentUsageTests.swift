import Foundation
import Testing
@testable import HostKit
import GudoCore

/// Agent plan usage: the meter's words and colours, the detail rows, and watching only while
/// something shows it.
@MainActor
struct AgentUsageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-19 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_411_200)

    private func ms(_ offset: TimeInterval) -> UInt64 { UInt64((now.timeIntervalSince1970 + offset) * 1000) }

    private func window(_ name: String, _ minutes: UInt32, _ permille: UInt16, resetIn: TimeInterval?, limited: Bool = false) -> UsageWindow {
        UsageWindow(name: name, minutes: minutes, usedPermille: permille, resetsAtMs: resetIn.map(ms), limited: limited)
    }

    private func usage(_ windows: [UsageWindow], agent: AgentKind = .claude, plan: String? = nil, source: UsageSource = .statusLine, asOf: TimeInterval? = -180, note: String? = nil) -> AgentUsage {
        AgentUsage(agent: agent, plan: plan, windows: windows, source: source, asOfMs: asOf.map(ms), note: note)
    }

    @Test func compactMeterReadsLikeTheSpec() throws {
        let agentUsage = usage([window("5h", 300, 620, resetIn: 2 * 3600 + 20 * 60), window("weekly", 10_080, 410, resetIn: 3 * 86_400)])
        let meter = try #require(UsageMeter.compact(agentUsage, now: now, calendar: calendar, locale: locale))
        #expect(meter.text == "Claude · 62% of 5h · resets 14:20")
        #expect(meter.tone == .quiet)
    }

    @Test func theFullestWindowWinsAndColourOnlyAbove80() throws {
        let agentUsage = usage([window("5h", 300, 300, resetIn: 3600), window("weekly", 10_080, 920, resetIn: 2 * 86_400)], agent: .codex)
        let meter = try #require(UsageMeter.compact(agentUsage, now: now, calendar: calendar, locale: locale))
        #expect(meter.text == "Codex · 92% of weekly · resets Wed")
        #expect(meter.tone == .attention)
        let edge = usage([window("5h", 300, 800, resetIn: 60)])
        #expect(UsageMeter.compact(edge, now: now, calendar: calendar, locale: locale)?.tone == .quiet, "80 % exactly stays quiet")
    }

    @Test func limitedIsRedAndComesFirst() throws {
        let agentUsage = usage([window("5h", 300, 1000, resetIn: 600, limited: true), window("weekly", 10_080, 990, resetIn: 86_400 * 9)])
        let meter = try #require(UsageMeter.compact(agentUsage, now: now, calendar: calendar, locale: locale))
        #expect(meter.text == "Claude · 100% of 5h · resets 12:10")
        #expect(meter.tone == .limited)
    }

    @Test func absentWhenUnknownOrEveryWindowReset() {
        #expect(UsageMeter.compact(usage([], source: .unknown, asOf: nil, note: "why"), now: now) == nil)
        let stale = usage([window("5h", 300, 900, resetIn: -60)])
        #expect(UsageMeter.compact(stale, now: now) == nil, "a window that reset since the report says nothing now")
        #expect(UsageMeter.compact(nil, now: now).isEmpty)
    }

    @Test func detailListsEveryWindowWithItsSourceAndReason() {
        let agentUsage = usage(
            [window("5h", 300, 850, resetIn: -60), window("weekly", 10_080, 410, resetIn: 9 * 86_400), window("weekly Opus", 10_080, 4, resetIn: 9 * 86_400)],
            plan: "max", source: .cli, asOf: -30)
        let detail = UsageDetail(agentUsage, now: now, calendar: calendar, locale: locale)
        #expect(detail.title == "Claude Code · Max")
        #expect(detail.rows.map(\.name) == ["5h", "weekly", "weekly Opus"])
        #expect(detail.rows[0].isPast)
        #expect(detail.rows[0].tone == .quiet, "an old window is not an alarm")
        #expect(detail.rows[0].reset == "reset at 11:59")
        #expect(detail.rows[1].reset == "resets 28 Oct")
        #expect(detail.rows[2].percent == "0.4%")
        #expect(detail.source == "From claude /usage on the host · just now")

        let unknown = UsageDetail(usage([], agent: .codex, source: .unknown, asOf: nil, note: "Codex reports its limits when signed in with ChatGPT."), now: now)
        #expect(unknown.title == "Codex")
        #expect(unknown.rows.isEmpty)
        #expect(unknown.source == nil)
        #expect(unknown.note == "Codex reports its limits when signed in with ChatGPT.")
        let api = UsageDetail(usage([window("5h", 300, 10, resetIn: 60)], agent: .codex, source: .api, asOf: -600), now: now, locale: locale)
        #expect(api.source?.hasPrefix("From your ChatGPT sign-in (unofficial) · ") == true)
    }

    @Test func watchesOnlyWhileShownAndOnlyDaemonsThatOfferIt() async throws {
        let client = FakeWorkspaceAPI()
        client.state.withLock {
            $0.usage = AgentUsageReport(agents: [usage([window("5h", 300, 620, resetIn: 3600)])])
        }
        let connection = DaemonConnection(hostId: "h", ticket: "t") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        let hub = connection.workspace

        // An old daemon: never asked (it would drop the connection).
        connection.handle(.daemonInfo(info: daemonInfo(agentUsage: false)))
        hub.beginWatchingUsage()
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.state.withLock { $0.usageWatches } == 0)
        hub.endWatchingUsage()

        connection.handle(.daemonInfo(info: daemonInfo(agentUsage: true)))
        hub.beginWatchingUsage()
        hub.beginWatchingUsage()
        try await eventually("watched") { hub.usage != nil }
        #expect(client.state.withLock { $0.usageWatches } == 1, "two viewers, one watch")
        #expect(hub.usage?.agents.first?.windows.first?.usedPermille == 620)

        client.push(.agentUsage(report: AgentUsageReport(agents: [usage([window("5h", 300, 700, resetIn: 3600)])])))
        try await eventually("pushed") { hub.usage?.agents.first?.windows.first?.usedPermille == 700 }

        hub.endWatchingUsage()
        #expect(client.state.withLock { $0.usageUnwatches } == 0, "one viewer left")
        hub.endWatchingUsage()
        try await eventually("unwatched") { client.state.withLock { $0.usageUnwatches } == 1 }
        // Not watched: pushes are ignored.
        client.push(.agentUsage(report: AgentUsageReport(agents: [])))
        try await Task.sleep(for: .milliseconds(100))
        #expect(hub.usage?.agents.count == 1)
    }
}
