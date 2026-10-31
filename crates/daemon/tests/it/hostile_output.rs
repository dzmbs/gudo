//! Hostile output in a real pane: whatever a program prints, the daemon's answers to terminal
//! queries never type the program's own bytes back into the shell.

use client_core::ClientConfig;

use crate::support::{TestClient, start, ticket};

const MARK: &str = "MARK;touch /tmp/pwned";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Every query family a terminal answers, each carrying the marker where a careless terminal
/// would echo it, then a status report so the reply stream is known to be live.
fn hostile_queries() -> Vec<u8> {
    let b64 = data_encoding::BASE64.encode(format!("/tmp/{MARK}").as_bytes());
    let text = [
        // Title report (xterm CVE-2003-0063), plain and with 8-bit OSC/ST.
        format!("\x1b]2;{MARK}\x07\x1b[21t\x1b[20t\x1b]1;{MARK}\x1b\\\x1b[20t"),
        // DECRQSS, unknown and known settings (Ghostty CVE-2024-56803, mintty CVE-2022-47583).
        format!("\x1bP$q{MARK}\x1b\\\x1bP$qm\x1b\\\x1bP$qr\x1b\\\x1bP$q q\x1b\\"),
        // XTGETTCAP, unknown and known names.
        format!(
            "\x1bP+q{}\x1b\\\x1bP+q544e;{}\x1b\\",
            hex(MARK.as_bytes()).to_uppercase(),
            hex(b"MARK")
        ),
        // Colour queries, with hostile indices and specs.
        format!(
            "\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07\x1b]4;1;?\x07\x1b]4;{MARK};?\x07\
             \x1b]4;1;{MARK}\x07\x1b]4;1;?\x07\x1b]104\x07\x1b]10;{MARK}\x07\x1b]10;?\x07"
        ),
        // Clipboard reads (OSC 52, kitty OSC 5522), program status and pointer queries.
        format!(
            "\x1b]52;c;?\x07\x1b]52;p;?\x1b\\\x1b]5522;type=read:mime=text/plain;\x1b\\\
             \x1b]7501;?\x1b\\\x1b]22;{MARK}\x07\x1b]8;{MARK};x\x07"
        ),
        // Device attributes, status and position reports, version, modes, window reports.
        "\x1b[c\x1b[>c\x1b[=c\x1b[6n\x1b[?6n\x1b[>q\x1b[?u\x1b[?2004$p\x1b[2004$p\
         \x1b[14t\x1b[16t\x1b[18t\x1b[19t\x1b[?4m\x1b[2$w\x1b[1$w"
            .to_owned(),
        // Screen checksum (DECRQCRA) over the marker, answerback.
        format!("{MARK}\x1b[1;1;1;1;24;80*y\x05"),
        // Kitty graphics: file and unknown-format transmissions naming the marker
        // (CVE-2020-35605), and a query with a hostile id.
        format!(
            "\x1b_Gi=9,a=q,t=f;{b64}\x1b\\\x1b_Gi=9,a=t,t=d,f=999;{b64}\x1b\\\
             \x1b_Gi=MARK,a=q;AAAA\x1b\\"
        ),
        "\x1b[5n".to_owned(),
    ]
    .concat();
    let mut bytes = text.into_bytes();
    // 8-bit C1 controls (CSI, OSC, DCS) as raw bytes.
    bytes.extend_from_slice(b"\x9b21t\x9d2;MARK\x9c\x90$qMARK\x9c");
    bytes.extend_from_slice(b"\x1b[5n");
    bytes
}

#[tokio::test(flavor = "multi_thread")]
async fn hostile_queries_type_nothing_into_the_shell() {
    let state = tempfile::tempdir().unwrap();
    let files = tempfile::tempdir().unwrap();
    let daemon = start(state.path()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;
    c.type_line(pane, "echo ready-$((6*7))");
    c.wait_text(pane, "ready-42").await;

    let path = files.path().join("hostile");
    std::fs::write(&path, hostile_queries()).unwrap();
    // Whatever the daemon answered waits in the shell's input: read it raw and print it as hex
    // between computed markers, so the echoed command line never matches.
    c.type_line(
        pane,
        &format!(
            "stty -icanon -echo min 0 time 20; cat {}; sleep 1; \
             printf 'H%sX<' E; dd bs=65536 count=1 2>/dev/null | od -An -tx1 -v | tr -d ' \\n'; \
             printf '>'; stty sane; echo; echo replied-$((6*7))",
            path.display()
        ),
    );
    c.wait_text(pane, "replied-42").await;
    let flat = c.flat_text(pane);
    let start = flat.rfind("HEX<").expect("marker") + 4;
    let end = start + flat[start..].find('>').expect("end marker");
    let digits: String = flat[start..end]
        .chars()
        .filter(char::is_ascii_hexdigit)
        .collect();
    let replies: Vec<u8> = (0..digits.len() / 2)
        .map(|i| u8::from_str_radix(&digits[2 * i..2 * i + 2], 16).unwrap())
        .collect();
    let shown = String::from_utf8_lossy(&replies).into_owned();

    // The queries reached a live parser: settings, colours, attributes and kitty answered.
    for answered in [
        "\x1b[0n",
        "\x1bP1$r0m",
        "\x1b]4;1;rgb:",
        "\x1b[?62",
        "\x1b_Gi=9;",
    ] {
        assert!(shown.contains(answered), "{answered:?} not in {shown:?}");
    }
    assert!(!shown.contains("MARK"), "{shown:?}");
    assert!(!shown.contains("touch"), "{shown:?}");
    assert!(!shown.contains(&hex(b"MARK")), "{shown:?}");
    assert!(!shown.contains(&hex(b"MARK").to_uppercase()), "{shown:?}");
    // Nothing that would end, edit or interrupt a command line.
    for b in [b'\r', b'\n', 0x03, 0x04, 0x15, 0x17, 0x1a] {
        assert!(!replies.contains(&b), "byte {b:#x} in {shown:?}");
    }
}

/// OSC 52 (copy from vim or tmux, also over ssh) reaches only the device that typed into the
/// pane last: never the owner's other devices, never a guest's clipboard from the owner's
/// typing, and never the owner's from a guest's.
#[tokio::test(flavor = "multi_thread")]
async fn clipboard_writes_reach_only_the_device_that_typed() {
    use client_core::ConnectOptions;
    use client_core::grants::GrantSpec;
    use client_core::proto::{Roles, Scope, UnixMillis};

    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let copying = || {
        let mut config = ClientConfig::new(ClientConfig::generate_key());
        config.relay = client_core::RelayMode::Disabled;
        let options = ConnectOptions {
            clipboard: true,
            ..ConnectOptions::default()
        };
        (config, options)
    };
    let (config, options) = copying();
    let mut mac = TestClient::connect_with(&ticket(&daemon), config, options);
    let pane = mac.attach_and_follow().await;
    let (config, options) = copying();
    let mut ipad = TestClient::connect_with(&ticket(&daemon), config, options.clone());
    ipad.client.attach(None);
    ipad.until("layout", |c| c.layout.is_some()).await;
    ipad.follow(pane).await;
    let mut spec = GrantSpec::new(Roles::DRIVER, Scope::Daemon);
    spec.label = "bob".into();
    spec.expires = Some(UnixMillis(client_core::now_millis().0 + 3_600_000));
    let invite = mac.client.create_invite(spec, "bob".into()).await.unwrap();
    let mut bob = TestClient::join_options(&invite.to_string(), options);
    bob.client.attach(None);
    bob.until("guest layout", |c| c.layout.is_some()).await;
    bob.follow(pane).await;

    let copy = |text: &str| {
        let b64 = data_encoding::BASE64.encode(text.as_bytes());
        format!("printf '\\033]52;c;%s\\007\\033]52;c;?\\007' {b64}")
    };
    mac.type_line(pane, &copy("from-the-mac"));
    mac.until("the Mac copied", |c| !c.clipboard.is_empty())
        .await;

    mac.client.release_control(pane).await.unwrap();
    bob.type_line(pane, &copy("from-bob"));
    bob.until("bob copied", |c| !c.clipboard.is_empty()).await;

    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    for c in [&mut mac, &mut ipad, &mut bob] {
        c.until("settled", |_| true).await;
    }
    assert_eq!(mac.clipboard, [(pane, "from-the-mac".to_owned())]);
    assert_eq!(bob.clipboard, [(pane, "from-bob".to_owned())]);
    assert!(ipad.clipboard.is_empty(), "{:?}", ipad.clipboard);
}
