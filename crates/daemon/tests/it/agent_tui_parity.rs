//! Real Codex and Claude Code in a daemon pane, launched to their start screen only (nothing is
//! typed into them), with what they drew checked for the features they turn on in Ghostty.
//! Run by `scripts/agent-tui-parity.sh`, which finds the programs and names them in
//! `AGENT_TUI_CODEX` / `AGENT_TUI_CLAUDE`; a program not named is skipped. Evidence (screen
//! text, the program's raw output) goes to `AGENT_TUI_OUT`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use client_core::ClientConfig;
use client_core::proto::{PaneId, TerminalColors};

use crate::support::{TestClient, start, ticket};

/// How long a program gets to draw its start screen and finish its terminal probes.
const SETTLE: Duration = Duration::from_secs(12);

fn program(var: &str) -> Option<PathBuf> {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|path| path.exists())
}

fn out_dir() -> PathBuf {
    let dir = std::env::var_os("AGENT_TUI_OUT")
        .map_or_else(|| std::env::temp_dir().join("agent-tui"), PathBuf::from);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', r"'\''"))
}

/// What a program drew: the client's screen, the images placed on it, and its raw output.
struct Drawn {
    screen: String,
    images: usize,
    output: Vec<u8>,
}

/// Runs `command` in a fresh pane under `script`, which records everything it prints, until
/// it settles. The screen, each image a client shows and the output are saved as evidence.
async fn launch(name: &str, command: &str, workdir: &Path) -> Drawn {
    let state = tempfile::tempdir().unwrap();
    let daemon = start(state.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    // Ghostty's default theme, as the app announces it.
    client.client.set_terminal_colors(TerminalColors {
        foreground: [0xff, 0xff, 0xff],
        background: [0x28, 0x2c, 0x34],
        cursor: None,
        palette: Vec::new(),
    });
    let pane: PaneId = client.attach_and_follow().await;
    let raw = out_dir().join(format!("{name}.raw"));
    let _ = std::fs::remove_file(&raw);
    client.type_line(
        pane,
        &format!(
            "cd {} && exec script -q -t 0 {} {command}",
            quote(workdir),
            quote(&raw)
        ),
    );
    tokio::time::sleep(SETTLE).await;
    let screen = client.text(pane);
    std::fs::write(out_dir().join(format!("{name}.screen.txt")), &screen).unwrap();
    let placed = client.client.pane_images(pane).unwrap_or_default();
    for (index, (_, image)) in placed.iter().enumerate() {
        if let Some(image) = image
            && let Some(pixels) = &image.pixels
        {
            let png = client_core::drawing::encode_png(&client_core::drawing::Rgba {
                width: image.width,
                height: image.height,
                data: pixels.clone(),
            });
            std::fs::write(out_dir().join(format!("{name}.image{index}.png")), png).unwrap();
        }
    }
    // Leave without a prompt: interrupt twice, then hang up.
    client.client.send_input(pane, b"\x03".to_vec());
    tokio::time::sleep(Duration::from_millis(300)).await;
    client.client.send_input(pane, b"\x03".to_vec());
    tokio::time::sleep(Duration::from_millis(500)).await;
    drop(client);
    daemon.shutdown().await;
    Drawn {
        screen,
        images: placed.len(),
        output: std::fs::read(&raw).unwrap_or_default(),
    }
}

/// `CSI > <flags> u`: the program turned the kitty keyboard protocol on.
fn kitty_keyboard_pushed(output: &[u8]) -> bool {
    output.windows(3).enumerate().any(|(at, window)| {
        window == b"\x1b[>"
            && output[at + 3..]
                .iter()
                .position(|byte| !byte.is_ascii_digit())
                .is_some_and(|digits| digits > 0 && output.get(at + 3 + digits) == Some(&b'u'))
    })
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// Collects what is missing instead of stopping at the first, so one run reports everything.
#[derive(Default)]
struct Findings(Vec<String>);

impl Findings {
    fn expect(&mut self, ok: bool, what: &str) {
        println!("{} {what}", if ok { "ok  " } else { "MISS" });
        if !ok {
            self.0.push(what.to_owned());
        }
    }

    fn finish(self, name: &str) {
        assert!(self.0.is_empty(), "{name} is missing: {:?}", self.0);
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "launches the installed Codex; run through scripts/agent-tui-parity.sh"]
async fn codex_start_screen_matches_ghostty() {
    let Some(codex) = program("AGENT_TUI_CODEX") else {
        println!("skipped: AGENT_TUI_CODEX names no Codex");
        return;
    };
    let workdir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    // A throwaway home: the owner's sign-in and settings are never read, and an API key that
    // is not one gets past sign-in to the start screen; nothing is sent to a model.
    // The pet the owner picked with `/pets`, which Codex only shows where it can send images.
    let config = format!(
        "[tui]\npet = \"fireball\"\n\n[projects.{:?}]\ntrust_level = \"trusted\"\n",
        workdir.path().canonicalize().unwrap().display().to_string()
    );
    std::fs::write(home.path().join("config.toml"), config).unwrap();
    std::fs::write(
        home.path().join("auth.json"),
        r#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-start-screen-only"}"#,
    )
    .unwrap();
    let command = format!("env CODEX_HOME={} {}", quote(home.path()), quote(&codex));
    let drawn = launch("codex", &command, workdir.path()).await;
    let output = &drawn.output;

    let mut findings = Findings::default();
    findings.expect(
        contains(output, b"\x1b]11;?"),
        "asks for the background color (OSC 11)",
    );
    // The composer is drawn on a tint of the background it was told, in 24-bit color.
    findings.expect(
        contains(output, b"48;2;"),
        "composer drawn on a 24-bit background",
    );
    // The logo fades once the session settles, so it is looked for in what was drawn.
    findings.expect(
        String::from_utf8_lossy(output)
            .chars()
            .filter(|c| ('\u{2801}'..='\u{28ff}').contains(c))
            .count()
            > 50,
        "dotted logo drawn",
    );
    findings.expect(contains(output, b"38;2;"), "logo and text in 24-bit color");
    findings.expect(
        contains(output, b"\x1b_Ga=T") || contains(output, b"\x1b_Ga=t"),
        "pet sent as a kitty image",
    );
    findings.expect(drawn.images > 0, "pet shown by the client");
    findings.finish("codex");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "launches the installed Claude Code; run through scripts/agent-tui-parity.sh"]
async fn claude_start_screen_matches_ghostty() {
    let Some(claude) = program("AGENT_TUI_CLAUDE") else {
        println!("skipped: AGENT_TUI_CLAUDE names no Claude Code");
        return;
    };
    let workdir = tempfile::tempdir().unwrap();
    let drawn = launch("claude", &quote(&claude), workdir.path()).await;
    let (screen, output) = (&drawn.screen, &drawn.output);

    let mut findings = Findings::default();
    findings.expect(
        contains(output, b"\x1b[>q") || contains(output, b"\x1b[>0q"),
        "asks for XTVERSION",
    );
    // Asked only of terminals whose XTVERSION names Ghostty or kitty.
    findings.expect(
        contains(output, b"\x1b_Gi=31,s=1,v=1,a=q"),
        "probes kitty graphics (XTVERSION recognised)",
    );
    findings.expect(
        contains(output, b"\x1b[?2026h"),
        "synchronized output on (DECRQM 2026 answered)",
    );
    findings.expect(
        kitty_keyboard_pushed(output),
        "kitty keyboard protocol pushed (CSI ? u answered)",
    );
    findings.expect(
        contains(output, b"\x1b[?2031h"),
        "follows theme changes (mode 2031)",
    );
    findings.expect(
        contains(output, b"\x1b]9;4;"),
        "progress reports on (TERM_PROGRAM and version recognised)",
    );
    findings.expect(contains(output, b"\x1b]8;"), "hyperlinks (OSC 8)");
    findings.expect(
        screen.contains("Claude Code") || screen.contains("trust"),
        "start screen drawn",
    );
    findings.finish("claude");
}
