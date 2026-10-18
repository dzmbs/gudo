//! Process-table inspection: a pane's process tree and the files its processes hold open.
//!

use std::path::PathBuf;

/// `root` and all of its descendants.
pub(crate) fn process_tree(root: u32) -> Vec<u32> {
    let parents = imp::parent_table();
    let mut tree = vec![root];
    let mut i = 0;
    while let Some(&pid) = tree.get(i) {
        tree.extend(
            parents
                .iter()
                .filter(|&&(_, ppid)| ppid == pid)
                .map(|&(child, _)| child),
        );
        i += 1;
    }
    tree
}

/// Paths of the regular files `pid` has open (empty if it is gone or not ours to inspect).
pub(crate) fn open_files(pid: u32) -> Vec<PathBuf> {
    imp::open_files(pid)
}

#[cfg(target_os = "linux")]
mod imp {
    use std::fs;
    use std::path::PathBuf;

    /// `(pid, ppid)` for every process.
    pub fn parent_table() -> Vec<(u32, u32)> {
        let Ok(dir) = fs::read_dir("/proc") else {
            return Vec::new();
        };
        dir.filter_map(Result::ok)
            .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
            .filter_map(|pid| {
                let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
                // `pid (comm) state ppid …`; comm may contain spaces and parentheses.
                let rest = &stat[stat.rfind(')')? + 1..];
                let ppid = rest.split_whitespace().nth(1)?.parse().ok()?;
                Some((pid, ppid))
            })
            .collect()
    }

    pub fn open_files(pid: u32) -> Vec<PathBuf> {
        let Ok(dir) = fs::read_dir(format!("/proc/{pid}/fd")) else {
            return Vec::new();
        };
        dir.filter_map(Result::ok)
            .filter_map(|e| fs::read_link(e.path()).ok())
            .filter(|p| p.is_absolute())
            .collect()
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{CStr, c_int, c_void};
    use std::mem;
    use std::path::PathBuf;

    /// `PROC_PIDFDVNODEPATHINFO` from `<sys/proc_info.h>`.
    const PROC_PIDFDVNODEPATHINFO: c_int = 2;
    /// `sizeof(struct vnode_fdinfowithpath)`: `proc_fileinfo` (24) + `vnode_info` (152) +
    /// `vip_path[MAXPATHLEN]` (1024). Stable ABI; libc does not define the struct.
    const VNODE_FDINFO_WITH_PATH: usize = 1200;
    /// Offset of `pvip.vip_path` in that struct.
    const VIP_PATH_OFFSET: usize = 176;

    pub fn parent_table() -> Vec<(u32, u32)> {
        // SAFETY: a null buffer asks for the number of pids.
        let n = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
        if n <= 0 {
            return Vec::new();
        }
        // Room for processes started in between.
        let mut pids = vec![0 as c_int; n as usize + 64];
        let bytes = (pids.len() * mem::size_of::<c_int>()) as c_int;
        // SAFETY: `pids` is writable for `bytes` bytes.
        let n = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
        if n <= 0 {
            return Vec::new();
        }
        pids.truncate(n as usize);
        pids.into_iter()
            .filter(|&p| p > 0)
            .filter_map(|pid| {
                let size = mem::size_of::<libc::proc_bsdinfo>() as c_int;
                // SAFETY: proc_bsdinfo is plain old data, so all-zero is a valid value.
                let mut info: libc::proc_bsdinfo = unsafe { mem::zeroed() };
                // SAFETY: the buffer is a properly aligned proc_bsdinfo of `size` bytes.
                let ret = unsafe {
                    libc::proc_pidinfo(
                        pid,
                        libc::PROC_PIDTBSDINFO,
                        0,
                        (&raw mut info).cast::<c_void>(),
                        size,
                    )
                };
                (ret == size).then_some((pid as u32, info.pbi_ppid))
            })
            .collect()
    }

    pub fn open_files(pid: u32) -> Vec<PathBuf> {
        let pid = pid as c_int;
        // SAFETY: a null buffer asks for the size of the fd list.
        let bytes =
            unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
        if bytes <= 0 {
            return Vec::new();
        }
        let entry = mem::size_of::<libc::proc_fdinfo>();
        let mut fds = vec![
            libc::proc_fdinfo {
                proc_fd: 0,
                proc_fdtype: 0
            };
            bytes as usize / entry + 16
        ];
        let cap = (fds.len() * entry) as c_int;
        // SAFETY: `fds` is writable for `cap` bytes of proc_fdinfo entries.
        let bytes = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), cap)
        };
        if bytes <= 0 {
            return Vec::new();
        }
        fds.truncate(bytes as usize / entry);
        let mut buf = vec![0u8; VNODE_FDINFO_WITH_PATH];
        fds.iter()
            .filter(|fd| fd.proc_fdtype == libc::PROX_FDTYPE_VNODE as u32)
            .filter_map(|fd| {
                // SAFETY: `buf` is writable for its full length, the size passed.
                let got = unsafe {
                    libc::proc_pidfdinfo(
                        pid,
                        fd.proc_fd,
                        PROC_PIDFDVNODEPATHINFO,
                        buf.as_mut_ptr().cast(),
                        buf.len() as c_int,
                    )
                };
                if got as usize != VNODE_FDINFO_WITH_PATH {
                    return None;
                }
                let path = CStr::from_bytes_until_nul(&buf[VIP_PATH_OFFSET..]).ok()?;
                let path = PathBuf::from(path.to_str().ok()?);
                path.is_absolute().then_some(path)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_children_and_their_open_files() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("held-open.jsonl");
        std::fs::write(&file, "x").unwrap();
        // A grandchild holding the file open on fd 3.
        let mut child = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("exec 3<'{}'; sleep 30 & wait", file.display()))
            .spawn()
            .unwrap();
        let canonical = file.canonicalize().unwrap();
        let mut found = false;
        for _ in 0..100 {
            let tree = process_tree(child.id());
            found = tree.len() >= 2
                && tree.iter().any(|&p| {
                    open_files(p)
                        .iter()
                        .any(|f| f.canonicalize().is_ok_and(|f| f == canonical))
                });
            if found {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        for pid in process_tree(child.id()).into_iter().rev() {
            // SAFETY: plain syscall on pids of processes this test started.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = child.wait();
        assert!(found, "open file not found in the process tree");
    }
}
