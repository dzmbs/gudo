//! The terminal coding-agent TUIs (Claude Code, Codex) see in a pane: the environment they read
//! to pick features, and the replies to the queries they and their libraries send, which must
//! be Ghostty's for the same theme (`ghostty-vt`'s `tests/it/queries.rs` pins each one against
//! libghostty-vt directly; this checks them end to end through a daemon pane).

use client_core::proto::{LayoutOp, OpOutcome, PaneLaunch, TerminalColors};
use client_core::{ClientConfig, proto::PaneId};

use crate::support::{TestClient, start, ticket};

/// A shell line that puts the tty in raw mode, sends `queries`, prints READY (split so the
/// echoed command line does not contain it) and then shows every byte the terminal answered
/// as `<hex>`.
fn probe(queries: &str) -> String {
    format!(
        "stty raw -echo -icrnl; printf '{queries}%s%s\\r\\n' REA DY; \
         while :; do b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); printf '<%s>' $b; done"
    )
}

fn hex(bytes: &str) -> String {
    bytes.bytes().map(|byte| format!("<{byte:02x}>")).collect()
}

async fn split(client: &mut TestClient, pane: PaneId) -> PaneId {
    let OpOutcome::PaneCreated { pane_id } = client
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: client_core::proto::Axis::Horizontal,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed");
    };
    client.follow(pane_id).await;
    pane_id
}

#[tokio::test(flavor = "multi_thread")]
async fn panes_advertise_truecolor_and_ghostty_features() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    client.type_line(
        pane,
        r#"printf '%s|' "$TERM" "$COLORTERM" "$TERM_PROGRAM" "$TERM_PROGRAM_VERSION" "$LC_TERMINAL" "${TMUX-no tmux}"; echo"#,
    );
    let want = format!(
        "xterm-256color|truecolor|ghostty|{}|Gudo|no tmux|",
        ghostty_vt::GHOSTTY_VERSION
    );
    client.wait_text(pane, &want).await;

    drop(client);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn identity_and_mode_queries_are_answered_like_ghostty() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    client.type_line(
        pane,
        &probe(r"\033[c\033[>c\033[>q\033[?2026$p\033[?2027$p\033[?2004$p\033[?1004$p\033[?1006$p"),
    );
    client.wait_text(pane, "READY").await;
    let want = format!(
        "\x1b[?62;22;52c\x1b[>1;10;0c\x1bP>|ghostty {} (Gudo)\x1b\\\
         \x1b[?2026;2$y\x1b[?2027;1$y\x1b[?2004;2$y\x1b[?1004;2$y\x1b[?1006;2$y",
        ghostty_vt::GHOSTTY_VERSION
    );
    client.wait_flat(pane, &hex(&want)).await;

    let second = split(&mut client, pane).await;
    // Kitty keyboard flags, kitty graphics, XTGETTCAP TN, cell size, program status support.
    client.type_line(
        second,
        &probe(
            r"\033[?u\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\\\033P+q544E\033\\\033[16t\033]7501;?\033\\",
        ),
    );
    client.wait_text(second, "READY").await;
    let terminfo: String = "xterm-256color"
        .bytes()
        .map(|byte| format!("{byte:02X}"))
        .collect();
    let want = format!(
        "\x1b[?0u\x1b_Gi=31;OK\x1b\\\x1bP1+r544E={terminfo}\x1b\\\x1b[6;20;10t\x1b]7501;?:"
    );
    client.wait_flat(second, &hex(&want)).await;

    drop(client);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn color_queries_answer_the_clients_theme() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    // Before any theme: Ghostty's default, dark.
    client.type_line(
        pane,
        &probe(r"\033]10;?\033\\\033]11;?\007\033[?996n\033[?2031h"),
    );
    client.wait_text(pane, "READY").await;
    client
        .wait_flat(
            pane,
            &hex("\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:2828/2c2c/3434\x07\x1b[?997;1n"),
        )
        .await;

    // A light theme arrives: the program that asked for scheme reports hears of it.
    let mut palette = vec![[0u8; 3]; 256];
    palette[4] = [0x40, 0x78, 0xf2];
    client.client.set_terminal_colors(TerminalColors {
        foreground: [0x38, 0x3a, 0x42],
        background: [0xfa, 0xfa, 0xfa],
        cursor: Some([0x52, 0x6f, 0xff]),
        palette,
    });
    client.wait_flat(pane, &hex("\x1b[?997;2n")).await;

    let second = split(&mut client, pane).await;
    client.type_line(
        second,
        &probe(r"\033]10;?\033\\\033]11;?\033\\\033]12;?\033\\\033]4;4;?\033\\\033[?996n"),
    );
    client.wait_text(second, "READY").await;
    client
        .wait_flat(
            second,
            &hex(
                "\x1b]10;rgb:3838/3a3a/4242\x1b\\\x1b]11;rgb:fafa/fafa/fafa\x1b\\\
                  \x1b]12;rgb:5252/6f6f/ffff\x1b\\\x1b]4;4;rgb:4040/7878/f2f2\x1b\\\x1b[?997;2n",
            ),
        )
        .await;

    drop(client);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn progress_reports_show_as_the_programs_status() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut client =
        TestClient::connect_program_status(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    client.type_line(pane, r"printf '\033]9;4;1;42\033\\'; sleep 30");
    client
        .until("progress status", |client| {
            client
                .client
                .program_status(pane)
                .is_some_and(|report| report.progress == Some(42))
        })
        .await;

    drop(client);
    daemon.shutdown().await;
}
