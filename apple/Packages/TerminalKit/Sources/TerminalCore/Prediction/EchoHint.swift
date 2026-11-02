/// What the backend knows about how the pane's program treats input, pushed whenever it
/// changes. The daemon reads `echo`/`canonical` from the PTY master with `tcgetattr`, `atPrompt`
/// from OSC 133 marks, and `altScreen` from the terminal state.
public struct EchoHint: Sendable, Equatable {
    /// termios `ECHO`.
    public var echo: Bool
    /// termios `ICANON` (cooked mode).
    public var canonical: Bool
    /// The shell is editing a command line: after OSC 133;B (prompt end) and before OSC 133;C
    /// (command start).
    public var atPrompt: Bool
    /// The alternate screen is active (full-screen TUI).
    public var altScreen: Bool
    /// The foreground program's name, if the backend knows it (key-bar profiles; not used here).
    public var foreground: String?

    public init(echo: Bool, canonical: Bool, atPrompt: Bool, altScreen: Bool, foreground: String? = nil) {
        self.echo = echo
        self.canonical = canonical
        self.atPrompt = atPrompt
        self.altScreen = altScreen
        self.foreground = foreground
    }

    /// `-echo icanon`: `read -s`, `getpass`, `sudo`, `ssh` passphrases. Never predicted.
    public var isHiddenInput: Bool { !echo && canonical }

    /// When to predict:
    /// - hidden input (`-echo icanon`): never;
    /// - alt screen: never (TUIs get no prediction in v1);
    /// - raw mode (`-icanon`, which is how zsh ZLE, readline and fish run): only at a prompt being
    ///   edited (OSC 133 B..C), never inside a running command;
    /// - cooked with echo (`echo icanon`, e.g. `cat`): safe.
    public var allowsPrediction: Bool {
        if isHiddenInput || altScreen { return false }
        if !canonical { return atPrompt }
        return echo
    }
}
