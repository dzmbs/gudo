import Foundation

/// What a pane runs, as the chrome shows it: a display name ("Neovim") and a mark, either the
/// program's official logo (where one ships, `ProgramCatalog.logos`) or a neutral SF Symbol for
/// its kind.
nonisolated public struct ProgramIdentity: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case shell, agent, editor, monitor, vcs, container, language, database, multiplexer, remote, other

        /// The neutral glyph for programs of this kind without a shipped logo.
        public var symbol: String {
            switch self {
            case .shell, .other: "terminal"
            case .agent: "sparkle"
            case .editor: "doc.text"
            case .monitor: "chart.bar"
            case .vcs: "arrow.triangle.branch"
            case .container: "shippingbox"
            case .language: "chevron.left.forwardslash.chevron.right"
            case .database: "cylinder"
            case .multiplexer: "rectangle.split.3x1"
            case .remote: "network"
            }
        }
    }

    /// An official logo in the package's asset catalog.
    public struct Logo: Hashable, Sendable {
        /// Why the logo may ship.
        public enum Clearance: String, Hashable, Sendable {
            /// The artwork's licence or the owner's trademark terms allow this use.
            case licensed
            /// The owner publishes the artwork without terms for this use; permission requested.
            case termsSilent
            /// The owner's terms ask for permission first. Shipped as nominative use while
            /// permission is requested (docs/legal/logo-permission-requests.md).
            case ownerApprovedRisk
        }

        /// The image set's name in `ProgramLogos.xcassets`.
        public var asset: String
        /// Drawn in the text colour (the owner publishes a monochrome version or allows one);
        /// otherwise drawn unaltered in its own colours. A set may carry the owner's dark-background
        /// variant as its dark appearance.
        public var template: Bool
        /// The exact URL each file in the image set was downloaded from (a file inside a zip is
        /// named after `#`), light first.
        public var sources: [String]
        /// When the files were downloaded, yyyy-MM-dd.
        public var retrieved: String
        public var clearance: Clearance

        public init(_ asset: String, template: Bool = false, sources: [String], retrieved: String, clearance: Clearance) {
            self.asset = asset
            self.template = template
            self.sources = sources
            self.retrieved = retrieved
            self.clearance = clearance
        }
    }

    /// Catalog id ("neovim"), stable across process names (`nvim`, `nvim-0.11`).
    public var id: String
    /// What the user calls it ("Neovim"); also the mark's accessibility label.
    public var displayName: String
    public var kind: Kind
    /// The official logo, nil where none ships (the kind's symbol shows).
    public var logo: Logo?

    public init(id: String, displayName: String, kind: Kind, logo: Logo? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.logo = logo
    }

    public var isShell: Bool { kind == .shell }
    /// The SF Symbol shown when there is no logo.
    public var symbol: String { kind.symbol }

    /// A shell at its prompt whose name is not known.
    public static let shell = ProgramIdentity(id: "shell", displayName: "Shell", kind: .shell)
}

/// Process name or terminal title → `ProgramIdentity`. Code rather than data so an unknown name
/// degrades to a neutral glyph, never to a missing image.
nonisolated public enum ProgramCatalog {
    // MARK: Entries

    /// Every known program. Logos come from `logos`; `logo: nil` means the kind's neutral symbol.
    public static let entries: [ProgramIdentity] = [
        // Agents
        entry("claude", "Claude Code", .agent),
        entry("codex", "Codex", .agent),
        entry("gemini", "Gemini CLI", .agent),
        entry("copilot", "GitHub Copilot CLI", .agent),
        // Editors
        entry("vim", "Vim", .editor),
        entry("neovim", "Neovim", .editor),
        entry("emacs", "Emacs", .editor),
        entry("helix", "Helix", .editor),
        entry("nano", "nano", .editor),
        // Monitors
        entry("htop", "htop", .monitor),
        entry("btop", "btop", .monitor),
        entry("top", "top", .monitor),
        // Version control
        entry("git", "Git", .vcs),
        entry("lazygit", "lazygit", .vcs),
        // Containers
        entry("docker", "Docker", .container),
        entry("kubectl", "kubectl", .container),
        entry("k9s", "K9s", .container),
        // Languages and runtimes
        entry("python", "Python", .language),
        entry("node", "Node.js", .language),
        entry("bun", "Bun", .language),
        entry("deno", "Deno", .language),
        entry("ruby", "Ruby", .language),
        entry("go", "Go", .language),
        entry("cargo", "Cargo", .language),
        entry("rustc", "Rust", .language),
        // Databases
        entry("psql", "psql", .database),
        entry("redis-cli", "redis-cli", .database),
        // Multiplexers, remote
        entry("tmux", "tmux", .multiplexer),
        entry("ssh", "SSH", .remote),
        entry("mosh", "Mosh", .remote),
        // Shells
        entry("bash", "bash", .shell),
        entry("zsh", "zsh", .shell),
        entry("fish", "fish", .shell),
        entry("sh", "sh", .shell),
        entry("dash", "dash", .shell),
        entry("nu", "Nushell", .shell),
        entry("elvish", "Elvish", .shell),
        entry("xonsh", "xonsh", .shell),
        entry("pwsh", "PowerShell", .shell),
    ]

    /// Official logos this build ships, by catalog id: the legal switch. One line per logo, so
    /// any one is turned off by deleting its line if its owner objects (the kind's symbol shows
    /// again). Each file is the owner's own artwork, byte-identical to its download (ruby: the
    /// kit's PDF page cropped to the gem), in its own colours; a dark variant only where the owner
    /// publishes one. `template` only where the licence allows recolouring and the artwork needs
    /// it (tmux's dark-grey screen). Terms and notices: apple/THIRD_PARTY_NOTICES.md.
    public static let logos: [String: ProgramIdentity.Logo] = [
        // CC BY 3.0 (Jason Long); the Git trademark policy allows identifying Git without
        // permission. Not lazygit: the Git mark on another project would suggest it is Git.
        "git": .init("GitLogo", sources: ["https://git-scm.com/images/logos/downloads/Git-Icon-1788C.svg"], retrieved: "2026-10-19", clearance: .licensed),
        // CC BY 3.0 (Jason Long).
        "neovim": .init("NeovimLogo", sources: ["https://neovim.io/logos/neovim-logos.zip#neovim-mark.svg"], retrieved: "2026-10-19", clearance: .licensed),
        // MPL-2.0 (logo by @jakenvac).
        "helix": .init("HelixLogo", sources: ["https://raw.githubusercontent.com/helix-editor/helix/master/logo.svg"], retrieved: "2026-10-19", clearance: .licensed),
        // ISC (© 2015 Jason Long).
        "tmux": .init("TmuxLogo", template: true, sources: ["https://raw.githubusercontent.com/tmux/tmux/master/logo/tmux-logomark.svg"], retrieved: "2026-10-19", clearance: .licensed),
        // Apache-2.0.
        "btop": .init("BtopLogo", sources: ["https://raw.githubusercontent.com/aristocratos/btop/main/Img/icon.svg"], retrieved: "2026-10-19", clearance: .licensed),
        // CC BY-SA 2.5 (© 2006 Yukihiro Matsumoto).
        "ruby": .init("RubyLogo", sources: ["https://cache.ruby-lang.org/pub/misc/logo/ruby-logo-kit.zip#ruby.pdf"], retrieved: "2026-10-19", clearance: .licensed),
        // GPL-3.0-or-later (© FSF, Nicolas Petton); the SVG is its own source form.
        "emacs": .init("EmacsLogo", sources: ["https://git.savannah.gnu.org/cgit/emacs.git/plain/etc/images/icons/hicolor/scalable/apps/emacs.svg"], retrieved: "2026-10-21", clearance: .licensed),
        // GPL-2.0-or-later (htop repository).
        "htop": .init("HtopLogo", sources: ["https://raw.githubusercontent.com/htop-dev/htop/main/htop.svg"], retrieved: "2026-10-21", clearance: .licensed),
        // No terms published; permission requested.
        "vim": .init("VimLogo", sources: ["https://www.vim.org/images/vimlogo.svg"], retrieved: "2026-10-21", clearance: .termsSilent),
        "bun": .init("BunLogo", sources: ["https://bun.com/logo.svg"], retrieved: "2026-10-21", clearance: .termsSilent),
        // Deno's guidelines: light mark on light, outlined dark mark on dark.
        "deno": .init("DenoLogo", sources: ["https://deno.com/logos/icon-light.svg", "https://deno.com/logos/icon-dark.svg"], retrieved: "2026-10-21", clearance: .termsSilent),
        // Each owner's terms ask for permission first; permission requested.
        "claude": .init("ClaudeLogo", sources: ["https://www.anthropic.com/press-kit#Anthropic media resources/Anthropic logos/Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        // OpenAI publishes no Codex mark; the Blossom, black on light and white on dark.
        "codex": .init("CodexLogo", sources: ["https://cdn.openai.com/brand/OpenAI-Logos-2025.zip#OpenAI-logos(new)/SVGs/OpenAI-black-monoblossom.svg", "https://cdn.openai.com/brand/OpenAI-Logos-2025.zip#OpenAI-logos(new)/SVGs/OpenAI-white-monoblossom.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "gemini": .init("GeminiCLILogo", sources: ["https://geminicli.com/brandassets/gemini-cli-icon_full-color.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "copilot": .init("CopilotLogo", sources: ["https://brand.github.com/GitHub_Logos.zip#GitHub Logos/SVG/Copilot_Icon_Black.svg", "https://brand.github.com/GitHub_Logos.zip#GitHub Logos/SVG/Copilot_Icon_White.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "docker": .init("DockerLogo", sources: ["https://www.docker.com/static/Docker-Logos-1.zip#docker-logos/SVG/docker-mark-ocean-blue.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        // The Kubernetes icon (CNCF publishes no kubectl mark).
        "kubectl": .init("KubernetesLogo", sources: ["https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "python": .init("PythonLogo", sources: ["https://s3.dualstack.us-east-2.amazonaws.com/pythondotorg-assets/media/files/python-logo-only.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "node": .init("NodeLogo", sources: ["https://nodejs.org/static/logos/nodejsHex.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "go": .init("GoLogo", sources: ["https://go.dev/images/go-logo-blue.svg", "https://go.dev/images/go-logo-white.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        // CC BY 4.0 artwork, also Rust Foundation trademarks; the white-outline file is the
        // project's version for dark backgrounds.
        "rustc": .init("RustLogo", sources: ["https://raw.githubusercontent.com/rust-lang/rust-artwork/main/logo/rust-logo.svg", "https://raw.githubusercontent.com/rust-lang/rust-artwork/main/logo/rust-logo-white-outline.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "cargo": .init("CargoLogo", sources: ["https://raw.githubusercontent.com/rust-lang/cargo/master/doc/book/src/images/Cargo-Logo-Small.png"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
        "psql": .init("PostgreSQLLogo", sources: ["https://wiki.postgresql.org/images/a/a4/PostgreSQL_logo.3colors.svg"], retrieved: "2026-10-21", clearance: .ownerApprovedRisk),
    ]

    /// Process names that differ from the catalog id.
    static let aliases: [String: String] = [
        "claude-code": "claude",
        "codex-cli": "codex",
        "gemini-cli": "gemini",
        "github-copilot-cli": "copilot",
        "vi": "vim", "view": "vim", "vimdiff": "vim", "gvim": "vim", "mvim": "vim",
        "nvim": "neovim",
        "emacsclient": "emacs",
        "hx": "helix",
        "rnano": "nano",
        "ipython": "python", "bpython": "python", "ptpython": "python", "pypy": "python",
        "nodejs": "node", "npm": "node", "npx": "node", "pnpm": "node", "yarn": "node",
        "bunx": "bun",
        "irb": "ruby", "bundle": "ruby", "rake": "ruby", "rails": "ruby",
        "rustup": "rustc", "rust-analyzer": "rustc",
        "docker-compose": "docker", "com.docker.cli": "docker",
        "kubecolor": "kubectl",
        "postgres": "psql", "pgcli": "psql",
        "valkey-cli": "redis-cli",
        "mosh-client": "mosh",
        "nushell": "nu",
        "powershell": "pwsh",
    ]

    /// Launchers that run the program named after their options (`sudo -u root htop` is htop).
    /// The value lists the options that take the next word as their argument.
    static let wrappers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-S", "-P"],
        "nice": ["-n"],
        "nohup": [],
        "time": ["-o", "-f"],
        "exec": ["-a"],
        "command": [],
        "caffeinate": ["-t", "-w"],
    ]

    /// Interpreters whose versioned binaries (`python3.12`, `ruby3.3`) share one identity.
    static let versioned = ["python", "ruby", "node", "perl", "php", "lua", "pip"]

    /// Interpreters that run an agent as a script (`node …/claude-code/cli.js`).
    static let scriptHosts: Set<String> = ["node", "bun", "deno", "python"]

    private static let byId: [String: ProgramIdentity] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    private static func entry(_ id: String, _ name: String, _ kind: ProgramIdentity.Kind) -> ProgramIdentity {
        ProgramIdentity(id: id, displayName: name, kind: kind, logo: logos[id])
    }

    // MARK: Lookup

    public static func entry(id: String) -> ProgramIdentity? { byId[id] }

    /// The identity of a process: its name (`nvim`, `/usr/bin/python3.12`, `-zsh`) and, when the
    /// source has them, its arguments including argv0 (`sudo htop`, `node …/claude/cli.js`).
    /// Unknown programs keep their own name with the neutral glyph.
    public static func identity(process name: String, arguments: [String] = []) -> ProgramIdentity {
        guard let normalized = normalize(name, arguments: arguments) else { return .shell }
        if let known = byId[normalized] { return known }
        return ProgramIdentity(id: normalized, displayName: normalized, kind: .other)
    }

    /// A known program named by a terminal title (OSC 0/2), nil when the title names none:
    /// Claude Code's "✳ task" titles, and titles that start with a program ("vim README.md").
    /// Shells are never inferred from a title (a prompt's title is usually the directory).
    public static func identity(title: String) -> ProgramIdentity? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard let firstScalar = trimmedTitle.unicodeScalars.first else { return nil }
        // Claude Code titles its terminal "✳ <task>" (a spinner glyph while working).
        if "✳✻✽✶✢".unicodeScalars.contains(firstScalar) { return byId["claude"] }
        let word = trimmedTitle.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first.map(String.init) ?? trimmedTitle
        guard let name = normalize(word), let known = byId[name], !known.isShell else { return nil }
        return known
    }

    // MARK: Normalisation

    /// Reduces a process name and its argv to the catalog id the user would name: `-zsh` → zsh,
    /// `/usr/bin/htop` → htop, `sudo -u root htop` → htop, `python3.12` → python, `nvim` → neovim,
    /// `node /…/@anthropic-ai/claude-code/cli.js` → claude. Nil for an empty name.
    public static func normalize(_ name: String, arguments: [String] = []) -> String? {
        var words = arguments.isEmpty ? [name] : arguments
        // `FOO=1 make` from a command line.
        if let commandStart = words.firstIndex(where: { !isAssignment($0) }), commandStart > 0 { words = Array(words[commandStart...]) }
        words = unwrapped(words)
        guard let head = words.first else { return nil }
        let base = canonical(head)
        guard !base.isEmpty else { return nil }
        // An agent run as a script by its interpreter: name it, not the interpreter.
        if scriptHosts.contains(base), let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            let lowered = script.lowercased()
            for agent in ["claude", "codex", "gemini", "copilot"] where lowered.contains(agent) { return agent }
        }
        return base
    }

    /// Splits a command line into words for `normalize` (quoting ignored: only the leading words
    /// matter and they are rarely quoted).
    public static func words(of commandLine: String) -> [String] {
        commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Drops launchers (`sudo`, `env`, `nice` …) and their options.
    static func unwrapped(_ input: [String]) -> [String] {
        var words = input
        while let head = words.first, let options = wrappers[basename(head)], words.count > 1 {
            // `command -v x` prints rather than runs.
            if basename(head) == "command", words[1].hasPrefix("-v") || words[1].hasPrefix("-V") { break }
            var next = 1
            while next < words.count {
                let word = words[next]
                if word == "--" { next += 1; break }
                if options.contains(word) { next += 2; continue }
                if word.hasPrefix("-") || (basename(head) == "env" && isAssignment(word)) { next += 1; continue }
                break
            }
            guard next < words.count else { break }
            words = Array(words[next...])
        }
        return words
    }

    /// A single process name → catalog id or plain lowercased name.
    static func canonical(_ word: String) -> String {
        var name = basename(word).lowercased()
        if name.hasSuffix(".exe") { name.removeLast(4) }
        if let alias = aliases[name] { return alias }
        name = withoutVersion(name)
        return aliases[name] ?? name
    }

    static func basename(_ word: String) -> String {
        var name = word.trimmingCharacters(in: .whitespacesAndNewlines)
        // Login shells run as `-zsh`.
        while name.hasPrefix("-") { name.removeFirst() }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return name
    }

    /// `emacs-30.1` → emacs, `python3.12` → python, `ruby3` → ruby; other digits stay (`k9s`).
    static func withoutVersion(_ name: String) -> String {
        if let dash = name.lastIndex(of: "-"), dash != name.startIndex {
            let version = name[name.index(after: dash)...]
            if version.first?.isNumber == true, version.allSatisfy({ $0.isNumber || $0 == "." }) {
                return String(name[..<dash])
            }
        }
        for interpreter in versioned where name.hasPrefix(interpreter) {
            let suffix = name.dropFirst(interpreter.count)
            if suffix.allSatisfy({ $0.isNumber || $0 == "." }) { return interpreter }
        }
        return name
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let key = word[..<equals]
        return key.first.map { $0.isLetter || $0 == "_" } == true && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
