import Foundation
import Testing
import GudoCore
@testable import HostKit

@MainActor
struct AccountBookTests {
    static let me = AccountIdentity(email: "me@home.example", plan: "max", organization: nil, method: "claude.ai")

    static func account(_ id: String, _ label: String, _ agent: AgentKind = .claude, color: UInt8 = 0, signedIn: Bool = true) -> AgentAccount {
        AgentAccount(id: id, agent: agent, label: label, color: color, status: signedIn ? .signedIn(identity: me) : .signedOut)
    }

    static func window(_ permille: UInt16, limited: Bool = false, resets: Date = Date().addingTimeInterval(3600)) -> UsageWindow {
        UsageWindow(name: "5h", minutes: 300, usedPermille: permille, resetsAtMs: UInt64(resets.timeIntervalSince1970 * 1000), limited: limited)
    }

    static func usage(_ id: String, _ windows: [UsageWindow]) -> AccountUsage {
        AccountUsage(account: id, usage: AgentUsage(agent: .claude, plan: "max", windows: windows, source: .statusLine, asOfMs: nil, note: nil))
    }

    static func book(defaults: [AccountDefault] = [], usage: [AccountUsage] = []) -> AccountBook {
        AccountBook(
            report: AccountsReport(
                accounts: [
                    account(systemAccount, "System"),
                    account(systemAccount, "System", .codex),
                    account("work0001", "Work", color: 2),
                    account("pers0001", "Personal", color: 1),
                ],
                defaults: defaults,
                panes: [
                    PaneAccount(paneId: 3, agent: .claude, account: "work0001"),
                    PaneAccount(paneId: 4, agent: .codex, account: systemAccount),
                ]),
            usage: AccountUsageReport(accounts: usage))
    }

    @Test func aLaunchUsesTheTabsPickThenTheProjectThenTheHost() {
        let book = Self.book(defaults: [
            AccountDefault(agent: .claude, project: nil, account: "pers0001"),
            AccountDefault(agent: .claude, project: "app", account: "work0001"),
        ])
        #expect(book.resolve(.claude, project: nil, override: nil) == "pers0001")
        #expect(book.resolve(.claude, project: "app", override: nil) == "work0001")
        #expect(book.resolve(.claude, project: "blog", override: nil) == "pers0001")
        #expect(book.resolve(.claude, project: "app", override: systemAccount) == systemAccount)
        // An override for an account that is gone falls back to the defaults.
        #expect(book.resolve(.claude, project: "app", override: "gone0001") == "work0001")
        // Codex has its own defaults.
        #expect(book.resolve(.codex, project: "app", override: nil) == systemAccount)
    }

    @Test func aDefaultForARemovedAccountIsTheSystemAccount() {
        let book = Self.book(defaults: [AccountDefault(agent: .claude, project: nil, account: "gone0001")])
        #expect(book.defaultAccount(.claude, project: nil) == systemAccount)
    }

    /// Panes name their account only where there is a choice, so a host without accounts
    /// looks as before.
    @Test func panesNameTheirAccountOnlyWhereThereIsAChoice() {
        let book = Self.book()
        #expect(book.paneLabel(3)?.name == "Work")
        #expect(book.paneLabel(3)?.color == 2)
        #expect(book.paneLabel(4) == nil)
        #expect(book.paneLabel(99) == nil)
        #expect(book.hasChoice(.claude))
        #expect(!book.hasChoice(.codex))
    }

    @Test func aLimitSuggestsAnotherSignedInAccountNeverSwitches() {
        let limited = Self.book(usage: [Self.usage("work0001", [Self.window(1000, limited: true)])])
        let hint = limited.limitHint(forPane: 3)
        #expect(hint?.alternative.id == systemAccount)
        #expect(hint?.limited.label == "Work")
        #expect(hint?.message().hasPrefix("Work is at its 5h limit · resets") == true)
        #expect(hint?.action == "New Tab with System")
        // Under the limit: nothing.
        #expect(Self.book(usage: [Self.usage("work0001", [Self.window(700)])]).limitHint(forPane: 3) == nil)
        // The window already reset: nothing.
        let past = Self.window(1000, limited: true, resets: Date().addingTimeInterval(-60))
        #expect(Self.book(usage: [Self.usage("work0001", [past])]).limitHint(forPane: 3) == nil)
        // Every other account limited too: nothing to suggest.
        let all = Self.book(usage: [
            Self.usage("work0001", [Self.window(1000, limited: true)]),
            Self.usage(systemAccount, [Self.window(1000, limited: true)]),
            Self.usage("pers0001", [Self.window(1000, limited: true)]),
        ])
        #expect(all.limitHint(forPane: 3) == nil)
    }

    @Test func statusReadsAsWords() {
        #expect(AccountText.status(.signedIn(identity: Self.me)) == "me@home.example · Max")
        #expect(AccountText.status(.signedOut) == "Not signed in")
        #expect(AccountText.status(.signedIn(identity: AccountIdentity(email: nil, plan: nil, organization: nil, method: nil))) == "Signed in")
    }
}
