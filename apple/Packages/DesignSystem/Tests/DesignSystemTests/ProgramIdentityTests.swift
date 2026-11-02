import Foundation
import Testing
@testable import DesignSystem

@Test(arguments: [
    ("nvim", "neovim"), ("vim", "vim"), ("vi", "vim"), ("/usr/bin/vim", "vim"), ("hx", "helix"),
    ("emacs-30.1", "emacs"), ("emacsclient", "emacs"), ("python3.12", "python"), ("python3", "python"),
    ("Python", "python"), ("ipython", "python"), ("ruby3.3", "ruby"), ("irb", "ruby"), ("node", "node"),
    ("npx", "node"), ("bunx", "bun"), ("-zsh", "zsh"), ("--bash", "bash"), ("/opt/homebrew/bin/fish", "fish"),
    ("k9s", "k9s"), ("redis-cli", "redis-cli"), ("rustup", "rustc"), ("claude", "claude"), ("CLAUDE", "claude"),
    ("htop", "htop"), ("mosh-client", "mosh"), ("pwsh.exe", "pwsh"), ("lazygit", "lazygit"),
])
func programNamesNormalize(name: String, id: String) {
    #expect(ProgramCatalog.normalize(name) == id)
}

@Test func programNormalisationUnwrapsLaunchersAndScripts() {
    let words = ProgramCatalog.words(of:)
    #expect(ProgramCatalog.normalize("sudo", arguments: words("sudo -u root htop")) == "htop")
    #expect(ProgramCatalog.normalize("env", arguments: words("env FOO=1 nvim README.md")) == "neovim")
    #expect(ProgramCatalog.normalize("nice", arguments: words("nice -n 10 btop")) == "btop")
    #expect(ProgramCatalog.normalize("x", arguments: words("RUST_LOG=debug cargo test")) == "cargo")
    #expect(ProgramCatalog.normalize("command", arguments: words("command -v vim")) == "command")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js")) == "claude")
    #expect(ProgramCatalog.normalize("node", arguments: words("node --max-old-space-size=4096 /x/@openai/codex/bin/codex.js")) == "codex")
    #expect(ProgramCatalog.normalize("node", arguments: words("node server.js")) == "node")
    #expect(ProgramCatalog.normalize("") == nil)
    #expect(ProgramCatalog.normalize("sudo") == "sudo")
}

@Test func programCatalogNamesAndKinds() {
    #expect(ProgramCatalog.identity(process: "nvim").displayName == "Neovim")
    #expect(ProgramCatalog.identity(process: "python3.12").displayName == "Python")
    #expect(ProgramCatalog.identity(process: "claude").kind == .agent)
    #expect(ProgramCatalog.identity(process: "-zsh").isShell)
    #expect(ProgramCatalog.identity(process: "htop").kind.symbol == "chart.bar")
    #expect(ProgramCatalog.identity(process: "nano").kind.symbol == "doc.text")
    #expect(ProgramCatalog.identity(process: "claude").kind.symbol == "sparkle")
    // Unknown programs keep their name with the neutral glyph.
    let unknown = ProgramCatalog.identity(process: "/usr/local/bin/frobnicate")
    #expect(unknown.displayName == "frobnicate")
    #expect(unknown.kind == .other && unknown.symbol == "terminal" && unknown.logo == nil)
    #expect(ProgramCatalog.identity(process: "") == .shell)
}

@Test func programCatalogIsConsistent() {
    #expect(Set(ProgramCatalog.entries.map(\.id)).count == ProgramCatalog.entries.count)
    for (alias, id) in ProgramCatalog.aliases {
        #expect(ProgramCatalog.entry(id: id) != nil, "alias \(alias) → \(id)")
    }
    // Every shipped logo belongs to an entry, and every entry carries its logo.
    for (id, logo) in ProgramCatalog.logos {
        #expect(ProgramCatalog.entry(id: id)?.logo == logo, "logo for \(id)")
    }
    // The agents' and runtimes' official marks ship.
    for id in ["claude", "codex", "gemini", "copilot", "vim", "emacs", "htop", "docker", "kubectl", "python", "node",
               "bun", "deno", "go", "rustc", "cargo", "psql"] {
        #expect(ProgramCatalog.entry(id: id)?.logo != nil, "\(id) ships its logo")
    }
    // No official artwork could be sourced (redis-cli: brand kit unreachable; bash: not published
    // by GNU), or none exists (nano, lazygit, K9s), or no licence (zsh, fish, OpenSSH): a symbol.
    for id in ["redis-cli", "bash", "nano", "lazygit", "k9s", "zsh", "fish", "ssh"] {
        #expect(ProgramCatalog.entry(id: id)?.logo == nil, "\(id) ships no logo")
    }
    #expect(ProgramCatalog.identity(process: "ipython").logo?.asset == "PythonLogo")
    #expect(ProgramCatalog.identity(process: "rustup").logo?.asset == "RustLogo")
}

/// Every shipped logo records where each of its files came from and when, so the legal switch
/// (`ProgramCatalog.logos`) doubles as the provenance list.
@Test func shippedLogosRecordTheirSource() throws {
    let date = try Regex(#"^20\d\d-[01]\d-[0-3]\d$"#)
    for (id, logo) in ProgramCatalog.logos {
        #expect(!logo.sources.isEmpty, "\(id) records its source")
        #expect(logo.sources.count <= 2, "\(id): one file, or light and dark")
        for source in logo.sources {
            let url = URL(string: source.replacingOccurrences(of: " ", with: "%20"))
            #expect(url?.scheme == "https" && url?.host?.isEmpty == false, "\(id) source \(source) is an https URL")
        }
        #expect(logo.retrieved.wholeMatch(of: date) != nil, "\(id) records its retrieval date: \(logo.retrieved)")
    }
    // Shipped while permission is requested.
    let risky = ProgramCatalog.logos.filter { $0.value.clearance == .ownerApprovedRisk }.keys
    #expect(Set(risky) == ["claude", "codex", "gemini", "copilot", "docker", "kubectl", "python", "node", "go", "rustc", "cargo", "psql"])
}

@Test func shippedLogosAreInTheBundle() {
    for logo in Set(ProgramCatalog.logos.values) {
        #expect(ProgramLogoImage.exists(logo.asset), "\(logo.asset) in ProgramLogos.xcassets")
    }
}

@Test func programFromTitle() {
    #expect(ProgramCatalog.identity(title: "✳ Fix the flaky test")?.id == "claude")
    #expect(ProgramCatalog.identity(title: "nvim README.md")?.id == "neovim")
    #expect(ProgramCatalog.identity(title: "htop")?.id == "htop")
    #expect(ProgramCatalog.identity(title: "~/projects/gudo") == nil)
    #expect(ProgramCatalog.identity(title: "zsh") == nil)
    #expect(ProgramCatalog.identity(title: "") == nil)
    #expect(ProgramCatalog.identity(title: "make: building") == nil)
}
