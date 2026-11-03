//! The replies coding-agent TUIs (Claude Code, Codex) and their libraries probe a terminal with,
//! held to what Ghostty answers for the same theme (`vendor/ghostty/src/termio/stream_handler.zig`
//! and `src/terminal/stream_terminal.zig`).

use std::sync::{Arc, Mutex};

use ghostty_vt::{COLOR_SCHEME_REPORTS, DefaultColors, Identity, Rgb, Terminal};

const XTVERSION: &str = "ghostty 1.4.0 (Gudo)";

fn terminal(colors: Option<&DefaultColors>) -> (Terminal, Arc<Mutex<Vec<u8>>>) {
    let mut terminal = Terminal::new(80, 24).unwrap();
    terminal.resize(80, 24, (9, 18)).unwrap();
    let replies = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&replies);
    terminal
        .set_reply_sink(Box::new(move |reply| {
            sink.lock().unwrap().extend_from_slice(reply)
        }))
        .unwrap();
    terminal
        .answer_queries(&Identity {
            xtversion: XTVERSION.into(),
            terminfo: "xterm-256color".into(),
        })
        .unwrap();
    if let Some(colors) = colors {
        terminal.set_default_colors(colors).unwrap();
    }
    (terminal, replies)
}

fn ask(terminal: &mut Terminal, replies: &Mutex<Vec<u8>>, query: &str) -> String {
    replies.lock().unwrap().clear();
    terminal.write(query.as_bytes());
    String::from_utf8_lossy(&replies.lock().unwrap()).into_owned()
}

fn hex(text: &str) -> String {
    text.bytes().map(|byte| format!("{byte:02X}")).collect()
}

fn light_theme() -> DefaultColors {
    let mut palette = Box::new([Rgb::default(); 256]);
    for (index, color) in palette.iter_mut().enumerate() {
        *color = Rgb::new(index as u8, 0x10, 0x20);
    }
    DefaultColors {
        foreground: Rgb::new(0x38, 0x3a, 0x42),
        background: Rgb::new(0xfa, 0xfa, 0xfa),
        cursor: Some(Rgb::new(0x52, 0x6f, 0xff)),
        palette: Some(palette),
    }
}

#[test]
fn identity_matches_ghostty() {
    let (mut terminal, replies) = terminal(None);
    let mut ask = |query: &str| ask(&mut terminal, &replies, query);
    assert_eq!(ask("\x1b[c"), "\x1b[?62;22;52c");
    assert_eq!(ask("\x1b[0c"), "\x1b[?62;22;52c");
    assert_eq!(ask("\x1b[>c"), "\x1b[>1;10;0c");
    assert_eq!(ask("\x1b[>q"), format!("\x1bP>|{XTVERSION}\x1b\\"));
    assert_eq!(
        ask(&format!("\x1bP+q{}\x1b\\", hex("TN"))),
        format!("\x1bP1+r{}={}\x1b\\", hex("TN"), hex("xterm-256color"))
    );
    assert_eq!(ask("\x1b[5n"), "\x1b[0n");
}

#[test]
fn modes_agent_tuis_probe_match_ghostty() {
    let (mut terminal, replies) = terminal(None);
    let mut ask = |query: &str| ask(&mut terminal, &replies, query);
    // Synchronized output, bracketed paste, focus events, SGR mouse, pixel mouse and color
    // scheme reports are known and off; grapheme clusters are on, as in Ghostty.
    for (mode, state) in [
        (2026, 2),
        (2027, 1),
        (2004, 2),
        (1004, 2),
        (1006, 2),
        (1016, 2),
        (2031, 2),
        (2048, 2),
    ] {
        assert_eq!(
            ask(&format!("\x1b[?{mode}$p")),
            format!("\x1b[?{mode};{state}$y"),
            "mode {mode}"
        );
    }
    assert_eq!(ask("\x1b[?u"), "\x1b[?0u");
    ask("\x1b[>1u");
    assert_eq!(ask("\x1b[?u"), "\x1b[?1u");
}

#[test]
fn sizes_are_reported_in_cells_and_pixels() {
    let (mut terminal, replies) = terminal(None);
    let mut ask = |query: &str| ask(&mut terminal, &replies, query);
    assert_eq!(ask("\x1b[18t"), "\x1b[8;24;80t");
    assert_eq!(ask("\x1b[16t"), "\x1b[6;18;9t");
    assert_eq!(ask("\x1b[14t"), "\x1b[4;432;720t");
}

#[test]
fn default_colors_are_ghosttys_until_a_theme_arrives() {
    let (mut terminal, replies) = terminal(Some(&DefaultColors::default()));
    let mut ask = |query: &str| ask(&mut terminal, &replies, query);
    assert_eq!(ask("\x1b]10;?\x1b\\"), "\x1b]10;rgb:ffff/ffff/ffff\x1b\\");
    assert_eq!(ask("\x1b]11;?\x07"), "\x1b]11;rgb:2828/2c2c/3434\x07");
    assert_eq!(ask("\x1b[?996n"), "\x1b[?997;1n");
}

#[test]
fn color_queries_answer_the_theme() {
    let (mut terminal, replies) = terminal(Some(&light_theme()));
    let mut ask = |query: &str| ask(&mut terminal, &replies, query);
    assert_eq!(ask("\x1b]10;?\x1b\\"), "\x1b]10;rgb:3838/3a3a/4242\x1b\\");
    assert_eq!(ask("\x1b]11;?\x1b\\"), "\x1b]11;rgb:fafa/fafa/fafa\x1b\\");
    assert_eq!(ask("\x1b]12;?\x1b\\"), "\x1b]12;rgb:5252/6f6f/ffff\x1b\\");
    assert_eq!(
        ask("\x1b]4;1;?;200;?\x1b\\"),
        "\x1b]4;1;rgb:0101/1010/2020\x1b\\\x1b]4;200;rgb:c8c8/1010/2020\x1b\\"
    );
    assert_eq!(ask("\x1b[?996n"), "\x1b[?997;2n");
    // A program's own override is answered until it resets it.
    ask("\x1b]11;#000000\x1b\\");
    assert_eq!(ask("\x1b]11;?\x1b\\"), "\x1b]11;rgb:0000/0000/0000\x1b\\");
    ask("\x1b]111\x1b\\");
    assert_eq!(ask("\x1b]11;?\x1b\\"), "\x1b]11;rgb:fafa/fafa/fafa\x1b\\");
}

#[test]
fn a_theme_change_is_reported_to_programs_that_asked() {
    let (mut terminal, replies) = terminal(Some(&DefaultColors::default()));
    ask(&mut terminal, &replies, "\x1b[?2031h");
    replies.lock().unwrap().clear();
    terminal.set_default_colors(&light_theme()).unwrap();
    assert_eq!(&*replies.lock().unwrap(), b"\x1b[?997;2n");
    replies.lock().unwrap().clear();
    terminal.set_default_colors(&light_theme()).unwrap();
    assert!(
        replies.lock().unwrap().is_empty(),
        "unchanged scheme reported"
    );
    ask(&mut terminal, &replies, "\x1b[?2031l");
    terminal
        .set_default_colors(&DefaultColors::default())
        .unwrap();
    assert!(
        replies.lock().unwrap().is_empty(),
        "reported without mode 2031"
    );
    assert!(!terminal.mode(COLOR_SCHEME_REPORTS));
}

#[test]
fn graphics_and_status_protocols_are_announced() {
    let (mut terminal, replies) = terminal(None);
    let mut ask = |query: &str| ask(&mut terminal, &replies, query);
    assert_eq!(
        ask("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"),
        "\x1b_Gi=31;OK\x1b\\"
    );
    assert!(
        ask("\x1b]7501;?\x1b\\").starts_with("\x1b]7501;?:states="),
        "program status query unanswered"
    );
}
