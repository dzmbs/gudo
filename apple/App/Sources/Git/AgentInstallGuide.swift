import Foundation

nonisolated struct AgentInstallGuide: Equatable, Sendable {
    let command: String?
    let docs: URL
    let pathHelp: URL

    init?(agent: AgentKind, os: String) {
        switch agent {
        case .claude:
            command = switch os {
            case "macos", "linux": #"sh -c 'installer_script=$(curl -fsSL https://claude.ai/install.sh) && exec bash -c "$installer_script"'"#
            case "windows": "irm https://claude.ai/install.ps1 | iex"
            default: nil
            }
            docs = URL(string: "https://code.claude.com/docs/en/setup")!
            pathHelp = URL(string: "https://code.claude.com/docs/en/troubleshoot-install#command-not-found-claude-after-installation")!
        case .codex:
            command = switch os {
            case "macos", "linux": #"sh -c 'installer_script=$(curl -fsSL https://chatgpt.com/codex/install.sh) && exec sh -c "$installer_script"'"#
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
