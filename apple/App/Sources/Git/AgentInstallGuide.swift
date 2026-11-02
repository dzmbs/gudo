import Foundation

/// How to install an agent on a host, only as its vendor documents it: Claude Code from
/// code.claude.com/docs/en/setup, Codex from the github.com/openai/codex README.
nonisolated struct AgentInstallGuide: Equatable, Sendable {
    /// `nil` where the vendor has no one-line installer for the host's system.
    let command: String?
    let docs: URL
    /// What to do when the command is installed but the shell can't find it.
    let pathHelp: URL

    /// `os` is the helper's `std::env::consts::OS`: `macos`, `linux`, `windows`, …
    init?(agent: AgentKind, os: String) {
        switch agent {
        case .claude:
            command = switch os {
            case "macos", "linux": "curl -fsSL https://claude.ai/install.sh | bash"
            case "windows": "irm https://claude.ai/install.ps1 | iex"
            default: nil
            }
            docs = URL(string: "https://code.claude.com/docs/en/setup")!
            pathHelp = URL(string: "https://code.claude.com/docs/en/troubleshoot-install#command-not-found-claude-after-installation")!
        case .codex:
            command = switch os {
            case "macos", "linux": "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
            case "windows": #"powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex""#
            default: nil
            }
            docs = URL(string: "https://github.com/openai/codex#installing-and-running-codex-cli")!
            pathHelp = docs
        case .other:
            return nil
        }
    }
}
