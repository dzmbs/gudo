import Foundation

/// A known wire tag or a future value retained without granting it known semantics.
nonisolated public enum TimelineValue<Known: RawRepresentable & Hashable & Sendable>: Codable, Hashable, Sendable
where Known.RawValue == String {
    case known(Known)
    case unknown(String)

    public init(wireValue: String) {
        if let known = Known(rawValue: wireValue) { self = .known(known) }
        else { self = .unknown(wireValue) }
    }

    public var wireValue: String {
        switch self {
        case .known(let value): value.rawValue
        case .unknown(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

nonisolated public enum TimelineAgentTag: String, Hashable, Sendable, CaseIterable {
    case claude = "Claude", codex = "Codex"
}
public typealias TimelineAgent = TimelineValue<TimelineAgentTag>

nonisolated public enum TimelineCommandSourceTag: String, Hashable, Sendable, CaseIterable {
    case builtIn = "Built-in", user = "User", project = "Project"
}
public typealias TimelineCommandSource = TimelineValue<TimelineCommandSourceTag>

nonisolated public enum TimelinePermissionModeTag: String, Hashable, Sendable, CaseIterable {
    case `default` = "default", acceptEdits = "acceptEdits", plan = "plan", dontAsk = "dontAsk"
    case bypassPermissions = "bypassPermissions", auto = "auto"
}
public typealias TimelinePermissionMode = TimelineValue<TimelinePermissionModeTag>

nonisolated public enum TimelinePlanStatusTag: String, Hashable, Sendable, CaseIterable {
    case pending = "Pending", inProgress = "InProgress", completed = "Completed"
}
public typealias TimelinePlanStatus = TimelineValue<TimelinePlanStatusTag>

nonisolated public enum TimelineNoticeKindTag: String, Hashable, Sendable, CaseIterable {
    case compacted = "Compacted", cleared = "Cleared", modelChanged = "ModelChanged", modeChanged = "ModeChanged"
    case error = "Error", retry = "Retry", interrupted = "Interrupted"
}
public typealias TimelineNoticeKind = TimelineValue<TimelineNoticeKindTag>

nonisolated public enum TimelineToolKindTag: String, Hashable, Sendable, CaseIterable {
    case shell = "Shell", read = "Read", search = "Search", edit = "Edit", write = "Write", fetch = "Fetch"
    case webSearch = "WebSearch", mcp = "Mcp", task = "Task", other = "Other"
}
public typealias TimelineToolKind = TimelineValue<TimelineToolKindTag>

nonisolated public enum TimelineToolStatusTag: String, Hashable, Sendable, CaseIterable {
    case running = "Running", done = "Done", failed = "Failed", denied = "Denied", interrupted = "Interrupted"
}
public typealias TimelineToolStatus = TimelineValue<TimelineToolStatusTag>

nonisolated public enum TimelineFileChangeTag: String, Hashable, Sendable, CaseIterable {
    case unmodified = "Unmodified", modified = "Modified", added = "Added", deleted = "Deleted"
    case renamed = "Renamed", copied = "Copied", typeChanged = "TypeChanged", unmerged = "Unmerged", untracked = "Untracked"
}
public typealias TimelineFileChange = TimelineValue<TimelineFileChangeTag>

nonisolated public enum TimelineDiffLineKindTag: String, Hashable, Sendable, CaseIterable {
    case context = "Context", added = "Added", removed = "Removed", noNewline = "NoNewline"
}
public typealias TimelineDiffLineKind = TimelineValue<TimelineDiffLineKindTag>

nonisolated public enum TimelineFieldTag: String, Hashable, Sendable, CaseIterable {
    case text = "Text", output = "Output", thinking = "Thinking"
}
public typealias TimelineField = TimelineValue<TimelineFieldTag>
