import Foundation
import UnnamedCore

// The daemon gathers the numbers on the host (`DaemonWorkspace.usage`); this turns them into a
// compact meter ("Claude · 62% of 5h · resets 14:20") and a detail list. Quiet by design
// unknown (the reason is in the detail).

/// The app's usage setting (Settings › Agents).
public enum AgentUsageSettings {
    /// Let the host ask Anthropic's and OpenAI's usage endpoints with its own Claude / Codex
    /// sign-in when the tools' own data says nothing. Off by default: the endpoints are
    /// undocumented.
    public static let apiFallbackKey = "agents.checkUsageWithSignIn"

    public static var apiFallback: Bool { UserDefaults.standard.bool(forKey: apiFallbackKey) }
}

/// How loud a meter is.
public enum UsageTone: Sendable, Equatable {
    /// Monochrome.
    case quiet
    /// Above 80 %: amber.
    case attention
    /// Requests refused until the reset: red.
    case limited

    static func of(_ window: UsageWindow) -> UsageTone {
        if window.limited || window.usedPermille >= 1000 { return .limited }
        if window.usedPermille > 800 { return .attention }
        return .quiet
    }
}

/// One agent's compact meter for the sidebar and the Inbox.
public struct UsageMeter: Equatable, Sendable, Identifiable {
    public var agent: AgentKind
    /// "Claude · 62% of 5h · resets 14:20".
    public var text: String
    public var tone: UsageTone
    public var id: String { UsageText.name(agent) }

    /// The window that matters most right now (limited, else the fullest; the shorter on a
    /// tie), or nil when nothing is known or every window has reset since the report.
    public static func compact(_ usage: AgentUsage, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> UsageMeter? {
        let current = usage.windows.filter { window in
            window.resetsAtMs.map { UsageText.date($0) > now } ?? true
        }
        guard let window = current.min(by: { a, b in
            if a.limited != b.limited { return a.limited }
            if a.usedPermille != b.usedPermille { return a.usedPermille > b.usedPermille }
            return (a.minutes == 0 ? .max : a.minutes) < (b.minutes == 0 ? .max : b.minutes)
        }) else { return nil }
        var parts = [UsageText.name(usage.agent), "\(UsageText.percent(window.usedPermille)) of \(window.name)"]
        if let reset = window.resetsAtMs {
            parts.append("resets \(UsageText.reset(UsageText.date(reset), now: now, calendar: calendar, locale: locale, compact: true))")
        }
        return UsageMeter(agent: usage.agent, text: parts.joined(separator: " · "), tone: .of(window))
    }

    /// Meters for every agent that has one, in the report's order.
    public static func compact(_ report: AgentUsageReport?, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> [UsageMeter] {
        (report?.agents ?? []).compactMap { compact($0, now: now, calendar: calendar, locale: locale) }
    }
}

/// One agent in the detail popover: every window, where the numbers come from, and why there
/// are none.
public struct UsageDetail: Equatable, Sendable, Identifiable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var name: String
        /// "62%".
        public var percent: String
        /// 0…1 for the bar.
        public var fraction: Double
        /// "resets Thu 14:20", "reset at 14:20" once past, or nil.
        public var reset: String?
        public var tone: UsageTone
        /// The window reset since the report: the numbers are old.
        public var isPast: Bool
        public var id: String { name }
    }

    public var agent: AgentKind
    /// "Claude Code · Max".
    public var title: String
    public var rows: [Row]
    /// "From Claude Code's status line · 3 min ago".
    public var source: String?
    /// Why nothing is known, or a caveat.
    public var note: String?
    public var id: String { title }

    public init(_ usage: AgentUsage, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) {
        agent = usage.agent
        let product = usage.agent == .claude ? "Claude Code" : "Codex"
        title = usage.plan.map { "\(product) · \(UsageText.plan($0))" } ?? product
        rows = usage.windows.map { window in
            let reset = window.resetsAtMs.map(UsageText.date)
            let past = reset.map { $0 <= now } ?? false
            let when = reset.map { UsageText.reset($0, now: now, calendar: calendar, locale: locale) }
            return Row(
                name: window.name, percent: UsageText.percent(window.usedPermille),
                fraction: min(1, Double(window.usedPermille) / 1000), reset: when.map { past ? "reset at \($0)" : "resets \($0)" },
                tone: past ? .quiet : .of(window), isPast: past)
        }
        source = UsageText.source(usage, now: now, locale: locale)
        note = usage.note
    }
}

/// The words.
public enum UsageText {
    public static func name(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// "62%" (whole percents; "0.4%" below one).
    public static func percent(_ permille: UInt16) -> String {
        if permille > 0, permille < 10 { return "0.\(permille)%" }
        return "\(Int((Double(permille) / 10).rounded()))%"
    }

    /// `max` → "Max", `prolite` → "Prolite", `plus` → "Plus".
    public static func plan(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func date(_ ms: UInt64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// "14:20" today, "Thu 14:20" within a week (`compact`: "Thu"), else "Oct 28".
    public static func reset(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current, compact: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
            formatter.setLocalizedDateFormatFromTemplate(compact ? "EEE" : "EEEjmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }

    /// Where the numbers come from, and how old they are.
    static func source(_ usage: AgentUsage, now: Date, locale: Locale) -> String? {
        let from: String
        switch (usage.source, usage.agent) {
        case (.unknown, _): return nil
        case (.localLog, _): from = "From Codex's session logs on the host"
        case (.statusLine, _): from = "From Claude Code's status line"
        case (.cli, .claude): from = "From claude /usage on the host"
        case (.cli, .codex): from = "From codex app-server on the host"
        case (.api, .claude): from = "From your Claude sign-in (unofficial)"
        case (.api, .codex): from = "From your ChatGPT sign-in (unofficial)"
        }
        guard let asOf = usage.asOfMs.map(date) else { return from }
        if now.timeIntervalSince(asOf) < 60 { return "\(from) · just now" }
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .short
        return "\(from) · \(relative.localizedString(for: asOf, relativeTo: now))"
    }
}
