//! libproc / sysctl process inspection.

use std::ffi::{c_int, c_void};
use std::mem;

fn bsd_info(pid: u32) -> Option<libc::proc_bsdinfo> {
    let size = mem::size_of::<libc::proc_bsdinfo>() as c_int;
    // SAFETY: proc_bsdinfo is plain old data, so all-zero is a valid value.
    let mut info: libc::proc_bsdinfo = unsafe { mem::zeroed() };
    // SAFETY: the buffer is a properly aligned proc_bsdinfo of exactly `size` bytes.
    let written = unsafe {
        libc::proc_pidinfo(
            pid as c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&raw mut info).cast::<c_void>(),
            size,
        )
    };
    (written == size).then_some(info)
}

/// `e_tpgid`: the foreground process group of `pid`'s controlling terminal.
pub(super) fn terminal_pgid_of(pid: u32) -> Option<u32> {
    let tpgid = bsd_info(pid)?.e_tpgid;
    (tpgid > 0).then_some(tpgid)
}

pub(super) fn process_name(pid: u32) -> Option<String> {
    let Some(info) = bsd_info(pid) else {
        // libproc refuses other users' processes (setuid `top`); sysctl does not.
        return short_bsd_comm(pid);
    };
    // `pbi_name` (up to 2 * MAXCOMLEN) is the longer form; `pbi_comm` is truncated at 16.
    [&info.pbi_name[..], &info.pbi_comm[..]]
        .into_iter()
        .map(c_chars_to_string)
        .find(|name| !name.is_empty())
}

/// `pbsi_comm` from `PROC_PIDT_SHORTBSDINFO`, which libproc answers for any process.
fn short_bsd_comm(pid: u32) -> Option<String> {
    let size = mem::size_of::<libc::proc_bsdshortinfo>() as c_int;
    // SAFETY: proc_bsdshortinfo is plain old data, so all-zero is a valid value.
    let mut info: libc::proc_bsdshortinfo = unsafe { mem::zeroed() };
    // SAFETY: the buffer is a properly aligned proc_bsdshortinfo of exactly `size` bytes.
    let written = unsafe {
        libc::proc_pidinfo(
            pid as c_int,
            libc::PROC_PIDT_SHORTBSDINFO,
            0,
            (&raw mut info).cast::<c_void>(),
            size,
        )
    };
    (written == size)
        .then(|| c_chars_to_string(&info.pbsi_comm))
        .filter(|name| !name.is_empty())
}

fn c_chars_to_string(chars: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = chars
        .iter()
        .take_while(|&&ch| ch != 0)
        .map(|&ch| ch as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

pub(super) fn process_argv(pid: u32) -> Option<Vec<String>> {
    parse_procargs2(&procargs2(pid)?)
}

/// Raw `sysctl(KERN_PROCARGS2)`: `[argc: i32][exec_path\0][\0 padding][argv\0 ...][env\0 ...]`.
fn procargs2(pid: u32) -> Option<Vec<u8>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as c_int];
    let mut size: libc::size_t = 0;
    // SAFETY: a null output buffer asks only for the required size.
    let status = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 || size == 0 {
        return None;
    }
    let mut args = vec![0u8; size];
    // SAFETY: `args` is writable for `size` bytes and sysctl updates `size` to what it wrote.
    let status = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            args.as_mut_ptr().cast::<c_void>(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return None;
    }
    args.truncate(size);
    Some(args)
}

fn parse_procargs2(raw: &[u8]) -> Option<Vec<String>> {
    let argc = i32::from_ne_bytes(raw.get(..4)?.try_into().ok()?);
    let rest = &raw[4..];
    let exec_end = rest.iter().position(|&byte| byte == 0)?;
    let argv_start = exec_end + rest[exec_end..].iter().position(|&byte| byte != 0)?;
    let argc = usize::try_from(argc).ok()?;
    let argv: Vec<String> = rest[argv_start..]
        .split(|&byte| byte == 0)
        .take(argc)
        .map(|arg| String::from_utf8_lossy(arg).into_owned())
        .collect();
    (argv.len() == argc).then_some(argv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_procargs2_layout() {
        let mut raw = 2i32.to_ne_bytes().to_vec();
        raw.extend_from_slice(b"/usr/bin/node\0\0\0\0claude\0--resume\0HOME=/x\0");
        assert_eq!(
            parse_procargs2(&raw).unwrap(),
            vec!["claude".to_string(), "--resume".to_string()]
        );
    }

    #[test]
    fn reads_own_process() {
        let own_pid = std::process::id();
        assert!(process_name(own_pid).is_some());
        assert!(!process_argv(own_pid).unwrap().is_empty());
    }
}
