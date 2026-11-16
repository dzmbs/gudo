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
    ("pi-rpc", "pi"), ("kimi", "kimi"), ("aider", "aider"), ("yarn", "yarn"), ("pnpm", "node"), ("zig", "zig"),
    ("sqlite3", "sqlite"), ("mongosh", "mongosh"), ("less", "less"), ("man", "man"), ("gmake", "make"),
    ("iex", "elixir"), ("zellij", "zellij"), ("yazi", "yazi"), ("jj", "jj"),
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
    #expect(ProgramCatalog.normalize("time", arguments: words("time make test")) == "make")
    #expect(ProgramCatalog.normalize("caffeinate", arguments: words("caffeinate -i cargo build")) == "cargo")
    #expect(ProgramCatalog.normalize("sudo", arguments: words("sudo -E env PATH=/x nvim")) == "neovim")
    #expect(ProgramCatalog.normalize("") == nil)
    #expect(ProgramCatalog.normalize("sudo") == "sudo")
}

/// Package runners name the package they run; interpreters name a script or module that is a
/// program of its own.
@Test func runnersAndInterpretersNameWhatTheyRun() {
    let words = ProgramCatalog.words(of:)
    #expect(ProgramCatalog.normalize("npx", arguments: words("npx @earendil-works/pi-coding-agent")) == "pi")
    #expect(ProgramCatalog.normalize("npx", arguments: words("npx -y @anthropic-ai/claude-code@latest")) == "claude")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /usr/local/bin/npx --yes @openai/codex")) == "codex")
    #expect(ProgramCatalog.normalize("bun", arguments: words("bun x cowsay hello")) == "cowsay")
    #expect(ProgramCatalog.normalize("bunx", arguments: words("bunx --bun vite")) == "vite")
    #expect(ProgramCatalog.normalize("npm", arguments: words("npm exec -- prettier --write .")) == "prettier")
    #expect(ProgramCatalog.normalize("pnpm", arguments: words("pnpm dlx create-vite@5 app")) == "create-vite")
    #expect(ProgramCatalog.normalize("uvx", arguments: words("uvx ruff check")) == "ruff")
    #expect(ProgramCatalog.normalize("pipx", arguments: words("pipx run black .")) == "black")
    #expect(ProgramCatalog.normalize("npm exec cowsay", arguments: ["npm exec cowsay"]) == "cowsay")
    #expect(ProgramCatalog.normalize("npm", arguments: words("npm run dev")) == "node")
    #expect(ProgramCatalog.normalize("npx", arguments: words("npx")) == "node")
    #expect(ProgramCatalog.normalize("python3", arguments: words("python3 -m http.server 8000")) == "python")
    #expect(ProgramCatalog.normalize("python3", arguments: words("python3 -m aider --model sonnet")) == "aider")
    #expect(ProgramCatalog.normalize("python3", arguments: words("python3 /usr/local/bin/aider")) == "aider")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /opt/homebrew/bin/yarn install")) == "yarn")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /home/me/.pi/agent/install/releases/1.4.0/node_modules/.bin/pi")) == "pi")
    #expect(ProgramCatalog.normalize("ruby", arguments: words("ruby bin/rails server")) == "ruby")
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
    for id in ["claude", "codex", "gemini", "copilot", "pi", "vim", "emacs", "htop", "docker", "kubectl", "python", "node",
               "bun", "deno", "go", "rustc", "cargo", "psql", "zig", "yarn"] {
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
    // pi titles its terminal "π - <folder>".
    #expect(ProgramCatalog.identity(title: "π - gudo")?.id == "pi")
    #expect(ProgramCatalog.identity(title: "π")?.id == "pi")
}

@Test func commonProgramsHaveAKindOfTheirOwn() {
    #expect(ProgramCatalog.identity(process: "less").symbol == "doc.plaintext")
    #expect(ProgramCatalog.identity(process: "man").symbol == "book.closed")
    #expect(ProgramCatalog.identity(process: "make").symbol == "hammer")
    #expect(ProgramCatalog.identity(process: "yazi").symbol == "folder")
    #expect(ProgramCatalog.identity(process: "sqlite3").displayName == "SQLite")
    #expect(ProgramCatalog.identity(process: "sqlite3").symbol == "cylinder")
    #expect(ProgramCatalog.identity(process: "aider").kind == .agent)
    #expect(ProgramCatalog.identity(process: "kimi").displayName == "Kimi Code")
    #expect(ProgramCatalog.identity(process: "zellij").kind == .multiplexer)
}

@Test func agentsRunAsScriptsOrBinariesAreNamed() {
    let words = ProgramCatalog.words(of:)
    #expect(ProgramCatalog.identity(process: "pi").id == "pi")
    #expect(ProgramCatalog.identity(process: "opencode").id == "opencode")
    #expect(ProgramCatalog.identity(process: "amp").id == "amp")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /usr/local/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js")) == "pi")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /usr/local/bin/pi --continue")) == "pi")
    #expect(ProgramCatalog.normalize("node", arguments: words("node /usr/local/lib/node_modules/opencode-ai/bin/opencode")) == "opencode")
    #expect(ProgramCatalog.normalize("bun", arguments: words("bun /opt/opencode/packages/opencode/src/index.ts")) == "opencode")
    #expect(ProgramCatalog.normalize("node", arguments: words("node --no-warnings /usr/local/lib/node_modules/@sourcegraph/amp/dist/main.js")) == "amp")
    // Their names inside other words are not them.
    #expect(ProgramCatalog.normalize("node", arguments: words("node scripts/api-server.js")) == "node")
    #expect(ProgramCatalog.normalize("node", arguments: words("node examples/sample/main.js")) == "node")
    #expect(ProgramCatalog.normalize("python", arguments: words("python -m pip install pipx")) == "python")
    for id in ["opencode", "amp"] {
        let identity = ProgramCatalog.identity(process: id)
        #expect(identity.kind == .agent, "\(id) is an agent")
        #expect(identity.logo?.template == true, "\(id) draws its glyph in the ink")
        #expect(identity.logo?.clearance == .original, "\(id)'s glyph is our own drawing")
    }
    // pi's own mark, from its MIT repository, in its own colours as pi draws it in the terminal.
    let pi = ProgramCatalog.identity(process: "pi")
    #expect(pi.kind == .agent)
    #expect(pi.logo?.asset == "PiLogo" && pi.logo?.template == false && pi.logo?.clearance == .licensed)
    #expect(ProgramCatalog.identity(title: "pi")?.id == "pi")
}

/// Our own glyphs are not official artwork: they carry no download record, are drawn in the
/// ink, and ship in the bundle.
@Test func ownGlyphsAreTemplatesInTheBundle() {
    #expect(!ProgramCatalog.glyphs.isEmpty)
    for (id, glyph) in ProgramCatalog.glyphs {
        #expect(ProgramCatalog.logos[id] == nil, "\(id) has one mark")
        #expect(glyph.template && glyph.clearance == .original && glyph.sources.isEmpty, "\(id)")
        #expect(ProgramLogoImage.exists(glyph.asset), "\(glyph.asset) in ProgramLogos.xcassets")
        #expect(ProgramCatalog.entry(id: id)?.logo == glyph, "\(id) carries its glyph")
    }
}
