//! `gudo devices`: the devices paired with this computer. In a terminal, a full-screen list
//! to pair a new device, rename one or remove one; otherwise a plain table, or JSON.

use std::io::{IsTerminal, Write};
use std::os::fd::AsFd;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use daemon::PairedDevice;

const REFRESH: Duration = Duration::from_millis(500);

pub fn run(state_dir: &Path, json: bool) -> Result<()> {
    let devices = daemon::list_paired(state_dir)
        .with_context(|| format!("reading {}", state_dir.display()))?;
    if json {
        println!("{}", json_list(&devices));
        return Ok(());
    }
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        print!("{}", table(&devices, now_millis()));
        return Ok(());
    }
    interactive(state_dir, devices)
}

pub fn rename(state_dir: &Path, prefix: &str, name: &str) -> Result<()> {
    let renamed = daemon::rename_device(state_dir, prefix, name)
        .with_context(|| format!("renaming in {}", state_dir.display()))?;
    println!(
        "{} is now {}",
        short_key(&renamed.device),
        display_name(&renamed)
    );
    Ok(())
}

/// What kind of device it is, from what it calls itself.
pub fn kind(device: &PairedDevice) -> &'static str {
    let own = device.own_name.to_lowercase();
    if own.contains("iphone") {
        "iPhone"
    } else if own.contains("ipad") {
        "iPad"
    } else if own.contains("mac") {
        "Mac"
    } else {
        "Device"
    }
}

pub fn display_name(device: &PairedDevice) -> &str {
    let renamed = !device.name.is_empty() && device.name != device.own_name;
    if device.this_computer && !renamed {
        brand::THIS_COMPUTER_APP
    } else if device.name.is_empty() {
        "Unnamed device"
    } else {
        &device.name
    }
}

fn short_key(device: &str) -> &str {
    &device[..device.len().min(12)]
}

/// "just now", "5 min ago", "3 h ago", "2 days ago"; "never" for 0.
pub fn ago(then_ms: u64, now_ms: u64) -> String {
    if then_ms == 0 {
        return "never".into();
    }
    let minutes = now_ms.saturating_sub(then_ms) / 60_000;
    match minutes {
        0 => "just now".into(),
        1..60 => format!("{minutes} min ago"),
        60..1440 => format!("{} h ago", minutes / 60),
        1440..2880 => "yesterday".into(),
        _ => format!("{} days ago", minutes / 1440),
    }
}

pub fn json_list(devices: &[PairedDevice]) -> String {
    let list: Vec<_> = devices
        .iter()
        .map(|device| {
            serde_json::json!({
                "device": device.device,
                "name": device.name,
                "kind": kind(device),
                "paired_at_ms": device.paired_at,
                "last_seen_ms": (device.last_seen != 0).then_some(device.last_seen),
                "this_computer": device.this_computer,
            })
        })
        .collect();
    serde_json::Value::Array(list).to_string()
}

pub fn table(devices: &[PairedDevice], now_ms: u64) -> String {
    if devices.is_empty() {
        return format!(
            "No devices paired yet. Run `{} pair` to pair one.\n",
            brand::CLI_BIN
        );
    }
    let rows: Vec<[String; 5]> = devices
        .iter()
        .map(|device| {
            [
                display_name(device).to_owned(),
                kind(device).to_owned(),
                ago(device.last_seen, now_ms),
                ago(device.paired_at, now_ms),
                short_key(&device.device).to_owned(),
            ]
        })
        .collect();
    let header = ["NAME", "KIND", "LAST SEEN", "PAIRED", "KEY"].map(str::to_owned);
    let widths: Vec<usize> = (0..5)
        .map(|column| {
            std::iter::once(&header)
                .chain(&rows)
                .map(|row| row[column].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for row in std::iter::once(&header).chain(&rows) {
        let cells: Vec<String> = row
            .iter()
            .zip(&widths)
            .map(|(cell, &width)| pad(cell, width))
            .collect();
        out.push_str(cells.join("  ").trim_end());
        out.push('\n');
    }
    out
}

fn pad(text: &str, width: usize) -> String {
    let length = text.chars().count();
    if length >= width {
        text.chars().take(width).collect()
    } else {
        format!("{text}{}", " ".repeat(width - length))
    }
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

/// A key the list reacts to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Up,
    Down,
    Enter,
    Escape,
    Backspace,
    Interrupt,
    Char(char),
}

/// Splits what the terminal sent into keys; unknown escape sequences are dropped.
pub fn parse_keys(input: &[u8]) -> Vec<Key> {
    let mut keys = Vec::new();
    let text = String::from_utf8_lossy(input);
    let mut chars = text.chars().peekable();
    while let Some(character) = chars.next() {
        let key = match character {
            '\u{1b}' => match chars.peek() {
                Some('[' | 'O') => {
                    chars.next();
                    let mut last = None;
                    for next in chars.by_ref() {
                        if next.is_ascii_alphabetic() || next == '~' {
                            last = Some(next);
                            break;
                        }
                    }
                    match last {
                        Some('A') => Key::Up,
                        Some('B') => Key::Down,
                        _ => continue,
                    }
                }
                _ => Key::Escape,
            },
            '\r' | '\n' => Key::Enter,
            '\u{7f}' | '\u{8}' => Key::Backspace,
            '\u{3}' => Key::Interrupt,
            character if character.is_control() => continue,
            character => Key::Char(character),
        };
        keys.push(key);
    }
    keys
}

/// What the list is showing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    List,
    Rename { name: String },
    ConfirmRemove,
    Pairing { link: String, devices_before: usize },
}

/// What the loop must do after a key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Nothing,
    Quit,
    Pair,
    Rename { device: String, name: String },
    Remove { device: String },
}

/// The interactive list's state, apart from the terminal.
#[derive(Debug)]
pub struct DeviceList {
    pub devices: Vec<PairedDevice>,
    pub selected: usize,
    pub mode: Mode,
    /// One line under the list: what just happened.
    pub status: Option<String>,
}

impl DeviceList {
    pub fn new(devices: Vec<PairedDevice>) -> Self {
        Self {
            devices,
            selected: 0,
            mode: Mode::List,
            status: None,
        }
    }

    fn current(&self) -> Option<&PairedDevice> {
        self.devices.get(self.selected)
    }

    /// Takes the devices as the file has them now; while pairing, a new one ends it.
    pub fn reload(&mut self, devices: Vec<PairedDevice>) {
        let selected_key = self.current().map(|device| device.device.clone());
        if let Mode::Pairing { devices_before, .. } = self.mode
            && devices.len() > devices_before
        {
            let newest = devices.iter().max_by_key(|device| device.paired_at);
            self.status = Some(format!(
                "Paired {}.",
                newest.map_or("a new device", display_name)
            ));
            self.selected = newest
                .and_then(|newest| devices.iter().position(|device| device == newest))
                .unwrap_or(0);
            self.mode = Mode::List;
            self.devices = devices;
            return;
        }
        self.selected = selected_key
            .and_then(|key| devices.iter().position(|device| device.device == key))
            .unwrap_or(self.selected)
            .min(devices.len().saturating_sub(1));
        if self.devices.len() != devices.len() && matches!(self.mode, Mode::ConfirmRemove) {
            self.mode = Mode::List;
        }
        self.devices = devices;
    }

    pub fn key(&mut self, key: Key) -> Action {
        if key == Key::Interrupt {
            return Action::Quit;
        }
        match &mut self.mode {
            Mode::List => self.list_key(key),
            Mode::Rename { name } => match key {
                Key::Enter => {
                    let name = name.clone();
                    self.mode = Mode::List;
                    match self.current() {
                        Some(device) => Action::Rename {
                            device: device.device.clone(),
                            name,
                        },
                        None => Action::Nothing,
                    }
                }
                Key::Escape => {
                    self.mode = Mode::List;
                    Action::Nothing
                }
                Key::Backspace => {
                    name.pop();
                    Action::Nothing
                }
                Key::Char(character) => {
                    if name.chars().count() < daemon::DEVICE_NAME_MAX {
                        name.push(character);
                    }
                    Action::Nothing
                }
                _ => Action::Nothing,
            },
            Mode::ConfirmRemove => {
                self.mode = Mode::List;
                match (key, self.current()) {
                    (Key::Char('y' | 'Y'), Some(device)) => Action::Remove {
                        device: device.device.clone(),
                    },
                    _ => Action::Nothing,
                }
            }
            Mode::Pairing { .. } => match key {
                Key::Escape | Key::Char('q' | 'b') | Key::Enter => {
                    self.mode = Mode::List;
                    Action::Nothing
                }
                _ => Action::Nothing,
            },
        }
    }

    fn list_key(&mut self, key: Key) -> Action {
        self.status = None;
        match key {
            Key::Up | Key::Char('k') => {
                self.selected = self.selected.saturating_sub(1);
                Action::Nothing
            }
            Key::Down | Key::Char('j') => {
                self.selected = (self.selected + 1).min(self.devices.len().saturating_sub(1));
                Action::Nothing
            }
            Key::Char('q') | Key::Escape => Action::Quit,
            Key::Char('p' | 'a' | 'n') => Action::Pair,
            Key::Char('r') | Key::Enter => {
                if let Some(device) = self.current() {
                    self.mode = Mode::Rename {
                        name: device.name.clone(),
                    };
                }
                Action::Nothing
            }
            Key::Char('d' | 'x') | Key::Backspace => {
                if self.current().is_some() {
                    self.mode = Mode::ConfirmRemove;
                }
                Action::Nothing
            }
            _ => Action::Nothing,
        }
    }

    /// The screen as lines of at most `width` columns, with SGR styling.
    pub fn render(&self, width: usize, height: usize, now_ms: u64, host: &str) -> Vec<String> {
        if let Mode::Pairing { link, .. } = &self.mode {
            return render_pairing(link, width, height);
        }
        let mut lines = vec![
            String::new(),
            format!("  {BOLD}Devices paired with {host}{RESET}"),
            String::new(),
        ];
        if self.devices.is_empty() {
            lines.push("  No devices yet.".into());
            lines.push(format!(
                "  {DIM}Press p to pair your iPhone, iPad or Mac.{RESET}"
            ));
        } else {
            let name_width = self
                .devices
                .iter()
                .map(|device| display_name(device).chars().count())
                .max()
                .unwrap_or(0)
                .clamp(4, 32);
            lines.push(format!(
                "    {DIM}{}  {}  {}  PAIRED{RESET}",
                pad("NAME", name_width),
                pad("KIND", 6),
                pad("LAST SEEN", 12)
            ));
            for (index, device) in self.devices.iter().enumerate() {
                let row = format!(
                    "{}  {}  {}  {}",
                    pad(display_name(device), name_width),
                    pad(kind(device), 6),
                    pad(&ago(device.last_seen, now_ms), 12),
                    ago(device.paired_at, now_ms)
                );
                lines.push(if index == self.selected {
                    format!("  {BOLD}›{RESET} {REVERSE}{row}{RESET}")
                } else {
                    format!("    {row}")
                });
            }
        }
        lines.push(String::new());
        match &self.mode {
            Mode::Rename { name } => {
                lines.push(format!("  Name: {name}{REVERSE} {RESET}"));
                lines.push(format!(
                    "  {DIM}enter save · esc cancel · leave empty for the device's own name{RESET}"
                ));
            }
            Mode::ConfirmRemove => {
                lines.push(format!(
                    "  {BOLD}Remove {}?{RESET}   y remove   n keep",
                    self.current().map_or("this device", display_name)
                ));
                lines.push(format!(
                    "  {DIM}It is signed out now and needs a new pairing code to come back.{RESET}"
                ));
            }
            _ => lines.extend(self.status.as_ref().map(|status| format!("  {status}"))),
        }
        while lines.len() + 1 < height {
            lines.push(String::new());
        }
        let hints = if self.devices.is_empty() {
            "p pair a device   q quit"
        } else {
            "↑↓ select   p pair a device   r rename   d remove   q quit"
        };
        lines.push(format!("  {DIM}{hints}{RESET}"));
        lines.into_iter().map(|line| clip(&line, width)).collect()
    }
}

const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const REVERSE: &str = "\x1b[7m";
const RESET: &str = "\x1b[0m";

/// Cuts a line to `width` visible columns, keeping its escape sequences.
fn clip(line: &str, width: usize) -> String {
    let mut out = String::new();
    let mut visible = 0;
    let mut in_escape = false;
    for character in line.chars() {
        if in_escape {
            out.push(character);
            in_escape = !character.is_ascii_alphabetic();
            continue;
        }
        if character == '\x1b' {
            in_escape = true;
            out.push(character);
            continue;
        }
        if visible == width {
            continue;
        }
        visible += 1;
        out.push(character);
    }
    out.push_str(RESET);
    out
}

fn render_pairing(link: &str, width: usize, height: usize) -> Vec<String> {
    let qr = crate::qr_lines(link);
    let qr_width = qr.first().map_or(0, |line| line.chars().count());
    let mut lines = vec![
        String::new(),
        format!("  {BOLD}Pair a device{RESET}"),
        "  On your iPhone or iPad, open Gudo, tap Add Host, then Scan.".into(),
        String::new(),
    ];
    if qr.len() + 8 <= height && qr_width + 2 <= width {
        lines.extend(qr.into_iter().map(|line| format!("  {line}")));
    } else {
        lines.push(format!(
            "  {DIM}Make the window bigger to show the code, or paste this link in the app:{RESET}"
        ));
    }
    lines.push(String::new());
    let link_chars: Vec<char> = link.chars().collect();
    for chunk in link_chars.chunks(width.saturating_sub(4).max(16)) {
        lines.push(format!(
            "  {DIM}{}{RESET}",
            chunk.iter().collect::<String>()
        ));
    }
    lines.push("  Valid for 10 minutes, for one device. Waiting for it to connect…".into());
    while lines.len() + 1 < height {
        lines.push(String::new());
    }
    lines.push(format!("  {DIM}esc back{RESET}"));
    lines
        .into_iter()
        .map(|line| clip(&line, width.max(1)))
        .collect()
}

fn interactive(state_dir: &Path, devices: Vec<PairedDevice>) -> Result<()> {
    let host = daemon::info::hostname();
    let host = host.split('.').next().unwrap_or(&host).to_owned();
    let mut list = DeviceList::new(devices);
    let _screen = Screen::enter()?;
    let stdin = std::io::stdin();
    let mut buffer = [0u8; 256];
    loop {
        draw(&list, &host)?;
        let mut fds = [rustix::event::PollFd::new(
            &stdin,
            rustix::event::PollFlags::IN,
        )];
        let timeout = rustix::event::Timespec::try_from(REFRESH).ok();
        let ready = rustix::event::poll(&mut fds, timeout.as_ref()).unwrap_or(0);
        if ready == 0 {
            list.reload(daemon::list_paired(state_dir).unwrap_or_else(|_| list.devices.clone()));
            continue;
        }
        let read = rustix::io::read(stdin.as_fd(), &mut buffer).unwrap_or(0);
        if read == 0 {
            return Ok(());
        }
        for key in parse_keys(&buffer[..read]) {
            match list.key(key) {
                Action::Nothing => {}
                Action::Quit => return Ok(()),
                Action::Pair => match daemon::mint_ticket_text(state_dir, daemon::PAIRING_TTL) {
                    Ok(link) => {
                        list.mode = Mode::Pairing {
                            link,
                            devices_before: list.devices.len(),
                        };
                    }
                    Err(error) => {
                        list.status = Some(format!("Could not make a pairing code: {error}"))
                    }
                },
                Action::Rename { device, name } => {
                    list.status = Some(match daemon::rename_device(state_dir, &device, &name) {
                        Ok(renamed) => format!("Renamed to {}.", display_name(&renamed)),
                        Err(error) => format!("Could not rename: {error}"),
                    });
                    list.reload(daemon::list_paired(state_dir).unwrap_or_default());
                }
                Action::Remove { device } => {
                    list.status = Some(match daemon::unpair_device(state_dir, &device) {
                        Ok(removed) if removed.this_computer => format!(
                            "Removed {}. The app pairs again when it next connects.",
                            display_name(&removed)
                        ),
                        Ok(removed) => format!("Removed {}.", display_name(&removed)),
                        Err(error) => format!("Could not remove: {error}"),
                    });
                    list.reload(daemon::list_paired(state_dir).unwrap_or_default());
                }
            }
        }
    }
}

fn draw(list: &DeviceList, host: &str) -> Result<()> {
    let size = rustix::termios::tcgetwinsize(std::io::stdout().as_fd()).ok();
    let width = size.map_or(80, |size| usize::from(size.ws_col.max(20)));
    let height = size.map_or(24, |size| usize::from(size.ws_row.max(5)));
    let lines = list.render(width, height, now_millis(), host);
    let mut frame = String::from("\x1b[H");
    for (index, line) in lines.iter().take(height).enumerate() {
        frame.push_str(line);
        frame.push_str("\x1b[K");
        if index + 1 < height.min(lines.len()) {
            frame.push_str("\r\n");
        }
    }
    frame.push_str("\x1b[J");
    let mut out = std::io::stdout().lock();
    out.write_all(frame.as_bytes())?;
    out.flush()?;
    Ok(())
}

/// The alternate screen in raw mode, cursor hidden; restored when dropped.
struct Screen(rustix::termios::Termios);

impl Screen {
    fn enter() -> Result<Self> {
        let stdin = std::io::stdin();
        let saved = rustix::termios::tcgetattr(stdin.as_fd()).context("stdin is not a terminal")?;
        let mut raw = saved.clone();
        raw.make_raw();
        raw.output_modes
            .insert(rustix::termios::OutputModes::OPOST | rustix::termios::OutputModes::ONLCR);
        rustix::termios::tcsetattr(stdin.as_fd(), rustix::termios::OptionalActions::Now, &raw)?;
        let mut out = std::io::stdout().lock();
        out.write_all(b"\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J")?;
        out.flush()?;
        Ok(Self(saved))
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(b"\x1b[?25h\x1b[?1049l");
        let _ = out.flush();
        let _ = rustix::termios::tcsetattr(
            std::io::stdin().as_fd(),
            rustix::termios::OptionalActions::Now,
            &self.0,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000_000;

    fn device(key: &str, name: &str, own_name: &str, paired_ago_min: u64) -> PairedDevice {
        PairedDevice {
            device: key.into(),
            paired_at: NOW - paired_ago_min * 60_000,
            name: name.into(),
            own_name: own_name.into(),
            last_seen: 0,
            this_computer: false,
        }
    }

    fn sample() -> Vec<PairedDevice> {
        vec![
            device(&"a1".repeat(32), "Work phone", "iPhone", 3 * 1440),
            device(&"b2".repeat(32), "iPad", "iPad", 30),
        ]
    }

    #[test]
    fn plain_output_is_a_table_with_kind_and_times() {
        let mut devices = sample();
        devices[1].last_seen = NOW - 5 * 60_000;
        let printed = table(&devices, NOW);
        let lines: Vec<&str> = printed.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("NAME"));
        assert!(
            lines[1].starts_with("Work phone  iPhone  never"),
            "{}",
            lines[1]
        );
        assert!(lines[1].contains("3 days ago") && lines[1].ends_with(&"a1".repeat(6)));
        assert!(lines[2].contains("5 min ago") && lines[2].contains("30 min ago"));
        assert!(!printed.contains('\x1b'), "no styling when not a terminal");
        assert_eq!(
            table(&[], NOW),
            "No devices paired yet. Run `gudo pair` to pair one.\n"
        );
    }

    #[test]
    fn the_app_on_this_computer_is_named_for_what_it_is() {
        let mut app = device(&"c3".repeat(32), "Studio", "Studio", 1);
        app.this_computer = true;
        assert_eq!(display_name(&app), "This Mac (Gudo app)");
        app.name = "Desk app".into();
        assert_eq!(display_name(&app), "Desk app", "the owner's name stands");
    }

    #[test]
    fn json_output_lists_every_device() {
        let parsed: serde_json::Value = serde_json::from_str(&json_list(&sample())).unwrap();
        assert_eq!(parsed[0]["name"], "Work phone");
        assert_eq!(parsed[0]["kind"], "iPhone");
        assert_eq!(parsed[0]["last_seen_ms"], serde_json::Value::Null);
        assert_eq!(parsed[1]["device"], "b2".repeat(32));
    }

    #[test]
    fn keys_from_the_terminal() {
        assert_eq!(
            parse_keys(b"\x1b[A\x1bOBjx\r\x7f\x1b\x03"),
            [
                Key::Up,
                Key::Down,
                Key::Char('j'),
                Key::Char('x'),
                Key::Enter,
                Key::Backspace,
                Key::Escape,
                Key::Interrupt
            ]
        );
        assert_eq!(parse_keys("é".as_bytes()), [Key::Char('é')]);
        assert_eq!(parse_keys(b"\x1b[1;5C"), []);
    }

    #[test]
    fn rename_edits_the_current_name() {
        let mut list = DeviceList::new(sample());
        assert_eq!(list.key(Key::Down), Action::Nothing);
        assert_eq!(list.key(Key::Char('r')), Action::Nothing);
        assert_eq!(
            list.mode,
            Mode::Rename {
                name: "iPad".into()
            }
        );
        for key in [
            Key::Backspace,
            Key::Backspace,
            Key::Backspace,
            Key::Backspace,
        ] {
            list.key(key);
        }
        for character in "Studio".chars() {
            list.key(Key::Char(character));
        }
        assert_eq!(
            list.key(Key::Enter),
            Action::Rename {
                device: "b2".repeat(32),
                name: "Studio".into()
            }
        );
        assert_eq!(list.mode, Mode::List);

        list.key(Key::Char('r'));
        list.key(Key::Char('!'));
        assert_eq!(list.key(Key::Escape), Action::Nothing);
        assert_eq!(list.mode, Mode::List, "esc cancels without renaming");
    }

    #[test]
    fn remove_asks_first() {
        let mut list = DeviceList::new(sample());
        list.key(Key::Char('d'));
        assert_eq!(list.mode, Mode::ConfirmRemove);
        let screen = list.render(120, 20, NOW, "studio").join("\n");
        assert!(screen.contains("Remove Work phone?"), "{screen}");
        assert_eq!(list.key(Key::Char('n')), Action::Nothing);
        assert_eq!(list.mode, Mode::List);
        list.key(Key::Char('d'));
        assert_eq!(
            list.key(Key::Char('y')),
            Action::Remove {
                device: "a1".repeat(32)
            }
        );
    }

    #[test]
    fn pairing_ends_when_a_new_device_appears() {
        let mut list = DeviceList::new(sample());
        assert_eq!(list.key(Key::Char('p')), Action::Pair);
        list.mode = Mode::Pairing {
            link: "gudo://pair/abc".into(),
            devices_before: 2,
        };
        let screen = list.render(100, 60, NOW, "studio").join("\n");
        assert!(screen.contains("tap Add Host, then Scan") && screen.contains("gudo://pair/abc"));
        assert!(screen.contains('▀') || screen.contains('▄') || screen.contains('█'));

        list.reload(sample());
        assert!(matches!(list.mode, Mode::Pairing { .. }));
        let mut more = sample();
        more.push(device(&"c3".repeat(32), "", "iPhone", 0));
        list.reload(more);
        assert_eq!(list.mode, Mode::List);
        assert_eq!(list.selected, 2);
        assert_eq!(list.status.as_deref(), Some("Paired Unnamed device."));
    }

    #[test]
    fn the_list_shows_names_kinds_and_key_hints() {
        let list = DeviceList::new(sample());
        let screen = list.render(100, 12, NOW, "studio");
        assert_eq!(screen.len(), 12);
        let text = screen.join("\n");
        assert!(text.contains("Devices paired with studio"));
        assert!(text.contains("Work phone") && text.contains("iPhone"));
        assert!(screen[11].contains("p pair a device") && screen[11].contains("d remove"));
        let empty = DeviceList::new(Vec::new())
            .render(60, 10, NOW, "studio")
            .join("\n");
        assert!(empty.contains("Press p to pair"));
    }

    #[test]
    fn times_read_plainly() {
        assert_eq!(ago(0, NOW), "never");
        assert_eq!(ago(NOW - 10_000, NOW), "just now");
        assert_eq!(ago(NOW - 2 * 3_600_000, NOW), "2 h ago");
        assert_eq!(ago(NOW - 30 * 3_600_000, NOW), "yesterday");
        assert_eq!(ago(NOW - 72 * 3_600_000, NOW), "3 days ago");
    }

    #[test]
    fn long_lines_are_clipped_to_the_window() {
        let clipped = clip(&format!("{BOLD}abcdef{RESET}"), 3);
        assert_eq!(clipped, format!("{BOLD}abc{RESET}{RESET}"));
    }
}
