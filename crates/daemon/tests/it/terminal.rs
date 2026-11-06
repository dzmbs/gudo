//! Terminal completeness end to end: key, mouse and paste encoding per the program's modes,
//! scrollback history paging, and daemon-side search and links.

use std::time::Duration;

use client_core::proto::{
    CaseMode, FullKeyEvent, InputPayload, KeyAction, LayoutOp, LinkKind, MouseAction, MouseButton,
    MouseEvent, OpOutcome, PaneLaunch, PaneSize, SearchMode, SearchQuery,
};
use client_core::{ClientConfig, ClientEvent};
use ghostty_vt::Key;

use crate::support::{TestClient, start, start_with, ticket};

/// A shell line that puts the tty in raw mode, turns on `modes`, prints READY (split so the
/// echoed command line does not contain it), then shows every input byte as `<hex>`. Raw mode
/// comes first: the tty translates input when it arrives, not when it is read.
fn probe(modes: &str) -> String {
    format!(
        "stty raw -echo -icrnl; printf '{modes}%s%s\\r\\n' REA DY; \
         while :; do b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); printf '<%s>' $b; done"
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("<{byte:02x}>")).collect()
}

fn key(key: Key, mods: u16, text: Option<&str>) -> FullKeyEvent {
    FullKeyEvent {
        key: key.0,
        mods,
        consumed_mods: 0,
        action: KeyAction::Press,
        text: text.map(Into::into),
        unshifted_codepoint: text.and_then(|text| text.chars().next()).map(u32::from),
        composing: false,
    }
}

fn click(col: u16, row: u16) -> MouseEvent {
    MouseEvent {
        action: MouseAction::Press,
        button: MouseButton::Left,
        col,
        row,
        mods: 0,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn focus_reports_do_not_replace_the_other_clients_terminal_size() {
    for report in [b"\x1b[I".as_slice(), b"\x1b[O", b"\x9bI", b"\x9bO"] {
        let directory = tempfile::tempdir().unwrap();
        let daemon = start(directory.path()).await;
        let mut desktop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        let pane = desktop.attach_and_follow().await;
        desktop.client.resize(
            pane,
            PaneSize {
                cols: 160,
                rows: 40,
                width_px: 0,
                height_px: 0,
            },
        );
        desktop
            .until("desktop size", |client| {
                client
                    .metas
                    .get(&pane)
                    .is_some_and(|meta| meta.size.cols == 160)
            })
            .await;
        desktop.type_line(pane, &format!("stty raw -echo; printf '%s%s\\r\\n' REA DY; dd bs=1 count={} >/dev/null 2>&1; printf '\\r\\n%s%s ' FO CUS; stty size; exec /bin/sh", report.len()));
        desktop.wait_text(pane, "READY").await;
        let mut phone = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        phone.attach_and_follow().await;
        phone.client.resize(
            pane,
            PaneSize {
                cols: 45,
                rows: 20,
                width_px: 0,
                height_px: 0,
            },
        );
        phone.op(LayoutOp::Focus { pane_id: pane }).await;
        phone.client.send_input(pane, report.to_vec());
        desktop.wait_text(pane, "FOCUS ").await;
        assert!(
            desktop.text(pane).contains("FOCUS 40 160"),
            "focus report {report:?} changed the size: {}",
            desktop.text(pane)
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn generated_bytes_and_mouse_reports_do_not_claim_the_grid() {
    for payload in [
        InputPayload::GeneratedBytes(b"abc".to_vec()),
        InputPayload::Mouse(click(0, 0)),
    ] {
        let count = match &payload {
            InputPayload::GeneratedBytes(bytes) => bytes.len(),
            InputPayload::Mouse(_) => 6,
            _ => unreachable!(),
        };
        let directory = tempfile::tempdir().unwrap();
        let daemon = start(directory.path()).await;
        let mut desktop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        let pane = desktop.attach_and_follow().await;
        desktop.client.resize(
            pane,
            PaneSize {
                cols: 160,
                rows: 40,
                width_px: 0,
                height_px: 0,
            },
        );
        desktop
            .until("desktop size", |client| {
                client
                    .metas
                    .get(&pane)
                    .is_some_and(|meta| meta.size.cols == 160)
            })
            .await;
        desktop.type_line(pane, &format!("printf '\\033[?1000h'; stty raw -echo; printf '%s%s\\r\\n' REA DY; dd bs=1 count={count} >/dev/null 2>&1; printf '\\r\\n%s%s ' RE PORT; stty size; exec /bin/sh"));
        desktop.wait_text(pane, "READY").await;
        let mut phone = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        phone.attach_and_follow().await;
        phone.client.resize(
            pane,
            PaneSize {
                cols: 45,
                rows: 20,
                width_px: 0,
                height_px: 0,
            },
        );
        phone.op(LayoutOp::Focus { pane_id: pane }).await;
        match payload {
            InputPayload::GeneratedBytes(bytes) => phone.client.send_generated_input(pane, bytes),
            InputPayload::Mouse(event) => phone.client.send_mouse(pane, event),
            _ => unreachable!(),
        }
        desktop.wait_text(pane, "REPORT ").await;
        assert!(
            desktop.text(pane).contains("REPORT 40 160"),
            "a terminal report claimed the grid: {}",
            desktop.text(pane)
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_burst_of_window_sizes_emits_one_final_grid_resize() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = start(directory.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;
    client
        .until("initial size", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.size.cols == 100)
        })
        .await;
    for cols in 120..140 {
        client.client.resize(
            pane,
            PaneSize {
                cols,
                rows: 30,
                width_px: 0,
                height_px: 0,
            },
        );
    }
    client
        .until("final resize in stream", |client| {
            client
                .log
                .iter()
                .any(|event| event.starts_with("PaneResized") && event.contains("cols: 139,"))
        })
        .await;
    let resize_events = client
        .log
        .iter()
        .filter(|event| event.starts_with("PaneResized") && !event.contains("cols: 100,"))
        .count();
    assert_eq!(resize_events, 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn input_takeover_cancels_the_previous_windows_deferred_resize() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = start(directory.path()).await;
    let mut desktop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = desktop.attach_and_follow().await;
    desktop.type_line(pane, "stty raw -echo; printf '%s%s\\r\\n' REA DY; dd bs=1 count=5 >/dev/null 2>&1; printf '\\r\\n%s%s ' FI NAL; stty size; exec /bin/sh");
    desktop.wait_text(pane, "READY").await;
    let mut phone = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    phone.attach_and_follow().await;
    phone.client.resize(
        pane,
        PaneSize {
            cols: 45,
            rows: 20,
            width_px: 0,
            height_px: 0,
        },
    );
    phone.op(LayoutOp::Focus { pane_id: pane }).await;
    desktop.client.resize(
        pane,
        PaneSize {
            cols: 140,
            rows: 40,
            width_px: 0,
            height_px: 0,
        },
    );
    desktop.op(LayoutOp::Focus { pane_id: pane }).await;
    phone.client.send_input(pane, b"ab".to_vec());
    phone
        .until("input changed the sizing client", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.size.cols == 45)
        })
        .await;
    tokio::time::sleep(Duration::from_millis(180)).await;
    phone.client.send_input(pane, b"\x1b[I".to_vec());
    desktop.wait_text(pane, "FINAL ").await;
    assert!(
        desktop.text(pane).contains("FINAL 20 45"),
        "a deferred resize replaced the input client's grid: {}",
        desktop.text(pane)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn keys_mouse_and_paste_follow_the_program_modes() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    // Application cursor keys, SGR mouse tracking, bracketed paste.
    client.type_line(pane, &probe(r"\033[?1h\033[?1000h\033[?1006h\033[?2004h"));
    client.wait_text(pane, "READY").await;
    client.client.send_key(pane, key(Key::ARROW_UP, 0, None));
    client.wait_flat(pane, &hex(b"\x1bOA")).await;
    client.client.send_mouse(pane, click(4, 2));
    client.wait_flat(pane, &hex(b"\x1b[<0;5;3M")).await;
    // An embedded end marker cannot close the bracket early: ESC becomes a space.
    client.client.send_paste(pane, "a\x1b[201~b\nc".into());
    client
        .wait_flat(pane, &hex(b"\x1b[200~a [201~b\nc\x1b[201~"))
        .await;

    // A second pane with the kitty keyboard protocol (disambiguate) and no mouse tracking.
    let OpOutcome::PaneCreated { pane_id: kitty } = client
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: client_core::proto::Axis::Horizontal,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed");
    };
    client.follow(kitty).await;
    client.type_line(kitty, &probe(r"\033[>1u"));
    client.wait_text(kitty, "READY").await;
    client.client.send_key(kitty, key(Key::C, 0b10, Some("c")));
    client.client.send_key(kitty, key(Key::ARROW_UP, 0, None));
    // Not tracked: the click sends nothing, so the next byte seen is the `a`.
    client.client.send_mouse(kitty, click(1, 1));
    client.client.send_key(kitty, key(Key::A, 0, Some("a")));
    client.client.send_paste(kitty, "x\ny".into());
    let want = hex(b"\x1b[99;5u\x1b[Aax\ry");
    client.wait_flat(kitty, &want).await;

    drop(client);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn history_older_than_ready_is_paged_newest_first() {
    let dir = tempfile::tempdir().unwrap();
    // Enough daemon scrollback for all 20000 rows (10 MiB holds about 8500 at 100 columns).
    let daemon = start_with(dir.path(), |config| config.scrollback_bytes = 64 << 20).await;

    let mut writer = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = writer.attach_and_follow().await;
    writer.type_line(
        pane,
        "i=0; while [ $i -lt 20000 ]; do echo history-line-$i; i=$((i+1)); done; echo DO''NE",
    );
    writer.wait_text(pane, "DONE").await;

    // A new client gets a snapshot whose READY part holds only the newest rows.
    let mut reader = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    reader.client.attach(None);
    reader
        .until("layout", |client| client.layout.is_some())
        .await;
    reader.follow(pane).await;
    let first_line = |client: &TestClient| -> Option<u32> {
        let all = client.client.pane_text_all(pane)?;
        all.lines()
            .find_map(|line| line.strip_prefix("history-line-")?.parse().ok())
    };
    let ready_oldest = first_line(&reader).expect("recent lines in READY");
    assert!(ready_oldest > 0, "READY should not hold all 20000 lines");

    let mut oldest = ready_oldest;
    let mut pages = 0;
    loop {
        assert!(reader.client.fetch_history(pane, 16 << 10), "fetch refused");
        let before = reader.history.len();
        reader
            .until("history page", |client| client.history.len() > before)
            .await;
        pages += 1;
        let (_, done) = *reader.history.last().unwrap();
        let now = first_line(&reader).unwrap();
        assert!(
            now <= oldest,
            "history must grow backwards: {now} after {oldest}"
        );
        oldest = now;
        if done {
            break;
        }
        assert!(pages < 10_000);
    }
    assert!(pages > 1, "expected several pages, got {pages}");
    assert_eq!(oldest, 0);
    assert!(
        !reader.client.fetch_history(pane, 16 << 10),
        "nothing left to fetch"
    );
    let all = reader.client.pane_text_all(pane).unwrap();
    let numbers: Vec<u32> = all
        .lines()
        .filter_map(|line| line.strip_prefix("history-line-")?.parse().ok())
        .collect();
    assert_eq!(numbers, (0..20000).collect::<Vec<_>>());

    drop((writer, reader));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn search_and_links_cover_the_whole_scrollback() {
    let dir = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(work.path().join("src")).unwrap();
    std::fs::write(work.path().join("src/lib.rs"), "").unwrap();
    let daemon = start(dir.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    // The shell is plain sh without OSC 7, so report the directory the way shells do.
    let cwd = work.path().canonicalize().unwrap();
    client.type_line(
        pane,
        &format!(
            "cd '{0}' && printf '\\033]7;file://h{0}\\007'; echo Needle-early; \
             i=0; while [ $i -lt 3000 ]; do echo filler $i; i=$((i+1)); done; \
             printf 'see https://example.com/docs and src/lib.rs:7:3 \\033]8;;https://ghostty.org\\033\\\\site\\033]8;;\\033\\\\\\n'; \
             echo needle-late; echo E''ND",
            cwd.display()
        ),
    );
    client.wait_text(pane, "END").await;

    let query = |pattern: &str, mode, case| SearchQuery {
        pattern: pattern.into(),
        mode,
        case,
    };
    // Smart case: lowercase matches both; newest first; paged.
    let id = client.client.search(
        pane,
        query("needle-", SearchMode::Plain, CaseMode::Smart),
        0,
        1,
    );
    let ClientEvent::SearchResult { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let page = result.unwrap();
    // The typed command line contains "Needle-early" and "needle-late" too.
    assert!(page.total >= 4, "{page:?}");
    assert_eq!(page.matches.len(), 1);
    assert!(page.matches[0].line.starts_with("needle-late"), "{page:?}");
    let next = page.next.unwrap();
    let id = client.client.search(
        pane,
        query("needle-", SearchMode::Plain, CaseMode::Smart),
        next,
        100,
    );
    let ClientEvent::SearchResult { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let rest = result.unwrap();
    let early = rest
        .matches
        .iter()
        .find(|found| found.line == "Needle-early")
        .expect("found far back in scrollback");
    assert!(rest.total_rows - early.row > 3000, "{early:?}");
    // Case-sensitive regex.
    let id = client.client.search(
        pane,
        query(r"^N\w+-early$", SearchMode::Regex, CaseMode::Sensitive),
        0,
        10,
    );
    let ClientEvent::SearchResult { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    assert_eq!(result.unwrap().total, 1);
    // A bad regex is a bad request, not a crash.
    let id = client
        .client
        .search(pane, query("(", SearchMode::Regex, CaseMode::Smart), 0, 10);
    let ClientEvent::SearchResult { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    assert!(matches!(
        result,
        Err(client_core::proto::RpcError::BadRequest(_))
    ));

    let id = client.client.links(pane, 3);
    let ClientEvent::Links { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let links = result.unwrap();
    assert_eq!(links.cwd.as_deref(), Some(cwd.to_str().unwrap()));
    let find = |kind: LinkKind, target: &str| {
        links
            .links
            .iter()
            .find(|link| link.kind == kind && link.target == target)
            .unwrap_or_else(|| panic!("no {kind:?} {target} in {links:#?}"))
    };
    find(LinkKind::Url, "https://example.com/docs");
    assert_eq!(
        find(LinkKind::Hyperlink, "https://ghostty.org").text,
        "site"
    );
    let path = find(LinkKind::Path, cwd.join("src/lib.rs").to_str().unwrap());
    assert_eq!(
        (path.line, path.column, path.exists),
        (Some(7), Some(3), Some(true))
    );

    drop(client);
    daemon.shutdown().await;
}

/// Metadata is pushed when it changes, not every time the core mentions the pane: agents set
/// the same title and report events many times a second, and every push re-renders sidebars.
#[tokio::test(flavor = "multi_thread")]
async fn unchanged_pane_metadata_is_not_pushed_again() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;
    client.type_line(pane, r"printf '\033]0;same\007'; echo first-$((1+1))");
    client.wait_text(pane, "first-2").await;
    client
        .until("title", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.title == "same")
        })
        .await;
    let pushes = client.meta_events;
    for i in 0..5 {
        client.type_line(
            pane,
            &format!(r"printf '\033]0;same\007'; echo again-{i}-$((1+1))"),
        );
        client.wait_text(pane, &format!("again-{i}-2")).await;
    }
    client.type_line(pane, r"printf '\033]0;other\007'; echo last-$((1+1))");
    client
        .until("new title", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.title == "other")
        })
        .await;
    assert_eq!(
        client.meta_events,
        pushes + 1,
        "only the real change is pushed"
    );
    drop(client);
    daemon.shutdown().await;
}
