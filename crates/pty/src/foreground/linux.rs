//! `/proc` process inspection.

use std::fs;

/// Field 8 of `/proc/<pid>/stat` (`tpgid`): the foreground process group of `pid`'s
/// controlling terminal.
pub(super) fn terminal_pgid_of(pid: u32) -> Option<u32> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    parse_tpgid(&stat)
}

fn parse_tpgid(stat: &str) -> Option<u32> {
    // `comm` (field 2) is parenthesised and may itself contain spaces and parentheses, so
    // count fields from the last ')'. After it: state(3) ppid(4) pgrp(5) session(6) tty_nr(7)
    // tpgid(8).
    let after_comm = &stat[stat.rfind(')')? + 1..];
    let tpgid: i64 = after_comm.split_whitespace().nth(5)?.parse().ok()?;
    u32::try_from(tpgid).ok().filter(|&p| p > 0)
}

pub(super) fn process_name(pid: u32) -> Option<String> {
    let comm = fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    Some(comm.trim_end_matches('\n').to_owned())
}

pub(super) fn process_argv(pid: u32) -> Option<Vec<String>> {
    let cmdline = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    // Empty for kernel threads and zombies; otherwise each argument is NUL-terminated.
    let args = cmdline.strip_suffix(b"\0")?;
    Some(
        args.split(|&b| b == 0)
            .map(|arg| String::from_utf8_lossy(arg).into_owned())
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tpgid_with_tricky_comm() {
        let stat = "123 (a) b (c) S 1 123 123 34816 4567 4194560 0 0";
        assert_eq!(parse_tpgid(stat), Some(4567));
        assert_eq!(parse_tpgid("1 (x) S 0 1 1 0 -1 0"), None);
    }
}
