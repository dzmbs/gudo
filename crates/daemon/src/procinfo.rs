//! Process-table inspection: a pane's process tree, the files its processes hold open, the TCP
//! ports they listen on, and a process's name, executable and environment.
//!
//! the ports a pane's dev servers listen on (Linux: `/proc/net/tcp{,6}` mapped through
//! `/proc/<pid>/fd` socket inodes; macOS: `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, no `lsof`),
//! to find an editor server's CLI channel, and a pane variable a helper's ancestors carry.

use std::path::PathBuf;

/// `root` and all of its descendants.
pub(crate) fn process_tree(root: u32) -> Vec<u32> {
    process_trees(&[root]).pop().unwrap_or_default()
}

/// The process tree of each root, reading the process table once.
pub(crate) fn process_trees(roots: &[u32]) -> Vec<Vec<u32>> {
    let parents = imp::parent_table();
    roots
        .iter()
        .map(|&root| {
            let mut tree = vec![root];
            let mut i = 0;
            while let Some(&pid) = tree.get(i) {
                tree.extend(
                    parents
                        .iter()
                        .filter(|&&(child, ppid)| ppid == pid && child != pid)
                        .map(|&(child, _)| child),
                );
                i += 1;
            }
            tree
        })
        .collect()
}

/// Paths of the regular files `pid` has open (empty if it is gone or not ours to inspect).
pub(crate) fn open_files(pid: u32) -> Vec<PathBuf> {
    imp::open_files(pid)
}

/// A listening TCP socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Listener {
    pub pid: u32,
    pub port: u16,
    /// Bound to 127.0.0.1 or ::1 only.
    pub loopback: bool,
}

/// TCP sockets in `LISTEN` state held by any of `pids`.
pub(crate) fn listening_ports(pids: &[u32]) -> Vec<Listener> {
    imp::listening_ports(pids)
}

/// The short process name (`comm`), if the process exists.
pub(crate) fn process_name(pid: u32) -> Option<String> {
    imp::process_name(pid)
}

/// The value of `name` in a process's environment, if readable.
pub(crate) fn process_env_var(pid: u32, name: &str) -> Option<String> {
    let prefix = format!("{name}=");
    imp::process_env(pid)?
        .into_iter()
        .find_map(|e| e.strip_prefix(&prefix).map(str::to_owned))
}

/// The value of `name` in the environment of this process's nearest ancestor that has it.
///
/// For a helper whose launcher cleared its environment (Codex starts MCP servers with a short
/// allowlist) but whose ancestors still carry the pane's variables.
pub fn inherited_env_var(name: &str) -> Option<String> {
    let parents: std::collections::HashMap<u32, u32> = imp::parent_table().into_iter().collect();
    let mut pid = std::os::unix::process::parent_id();
    while pid > 1 {
        if let Some(value) = process_env_var(pid, name) {
            return Some(value);
        }
        pid = *parents.get(&pid)?;
    }
    None
}

/// The process's executable.
pub(crate) fn exe_path(pid: u32) -> Option<PathBuf> {
    imp::exe_path(pid)
}

#[cfg(target_os = "linux")]
mod imp {
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;

    use super::Listener;

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

    /// `inode → (port, loopback)` for listening sockets in `/proc/net/tcp` and `tcp6`.
    fn listen_table() -> HashMap<u64, (u16, bool)> {
        let mut table = HashMap::new();
        for (file, v6) in [("/proc/net/tcp", false), ("/proc/net/tcp6", true)] {
            let Ok(text) = fs::read_to_string(file) else {
                continue;
            };
            for line in text.lines().skip(1) {
                // sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
                let cols: Vec<&str> = line.split_whitespace().collect();
                if cols.len() < 10 || cols[3] != "0A" {
                    continue;
                }
                let Some((addr, port)) = cols[1].split_once(':') else {
                    continue;
                };
                let (Ok(port), Ok(inode)) = (u16::from_str_radix(port, 16), cols[9].parse()) else {
                    continue;
                };
                // The address is hex of the in-memory words: 127.0.0.1 is `0100007F`, ::1
                // is three zero words and `01000000`, ::ffff:127.0.0.1 ends in `0100007F`.
                let loopback = if v6 {
                    addr == "00000000000000000000000001000000"
                        || (addr.starts_with("0000000000000000FFFF0000") && addr.ends_with("7F"))
                } else {
                    addr.ends_with("7F")
                };
                table.insert(inode, (port, loopback));
            }
        }
        table
    }

    pub fn listening_ports(pids: &[u32]) -> Vec<Listener> {
        let table = listen_table();
        if table.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for &pid in pids {
            let Ok(dir) = fs::read_dir(format!("/proc/{pid}/fd")) else {
                continue;
            };
            for link in dir
                .filter_map(Result::ok)
                .filter_map(|e| fs::read_link(e.path()).ok())
            {
                let link = link.to_string_lossy();
                let Some(inode) = link
                    .strip_prefix("socket:[")
                    .and_then(|r| r.strip_suffix(']'))
                    .and_then(|n| n.parse::<u64>().ok())
                else {
                    continue;
                };
                if let Some(&(port, loopback)) = table.get(&inode) {
                    out.push(Listener {
                        pid,
                        port,
                        loopback,
                    });
                }
            }
        }
        out
    }

    pub fn process_name(pid: u32) -> Option<String> {
        let comm = fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
        Some(comm.trim_end().to_owned())
    }

    pub fn process_env(pid: u32) -> Option<Vec<String>> {
        let env = fs::read(format!("/proc/{pid}/environ")).ok()?;
        Some(
            env.split(|&b| b == 0)
                .filter(|e| !e.is_empty())
                .map(|e| String::from_utf8_lossy(e).into_owned())
                .collect(),
        )
    }

    pub fn exe_path(pid: u32) -> Option<PathBuf> {
        fs::read_link(format!("/proc/{pid}/exe")).ok()
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{CStr, c_int, c_void};
    use std::mem;
    use std::path::PathBuf;

    use super::Listener;

    /// `PROC_PIDFDVNODEPATHINFO` from `<sys/proc_info.h>`.
    const PROC_PIDFDVNODEPATHINFO: c_int = 2;
    /// `sizeof(struct vnode_fdinfowithpath)`: `proc_fileinfo` (24) + `vnode_info` (152) +
    /// `vip_path[MAXPATHLEN]` (1024). Stable ABI; libc does not define the struct.
    const VNODE_FDINFO_WITH_PATH: usize = 1200;
    /// Offset of `pvip.vip_path` in that struct.
    const VIP_PATH_OFFSET: usize = 176;

    /// `PROC_PIDFDSOCKETINFO` and the parts of `struct socket_fdinfo` we read. libc does not
    /// define the struct; the offsets were checked against the macOS 26 SDK with `offsetof`
    /// (`sizeof(struct socket_fdinfo)` = 792).
    const PROC_PIDFDSOCKETINFO: c_int = 3;
    const SOCKET_FDINFO_SIZE: usize = 792;
    /// `psi.soi_kind`.
    const SOI_KIND: usize = 24 + 232;
    /// `psi.soi_proto` (the `tcp_sockinfo`, which starts with an `in_sockinfo`).
    const SOI_PROTO: usize = 24 + 240;
    const SOCKINFO_TCP: i32 = 2;
    const TSI_S_LISTEN: i32 = 1;
    /// In `in_sockinfo`: `insi_lport` (network byte order), `insi_vflag`, `insi_laddr`.
    const INSI_LPORT: usize = 4;
    const INSI_VFLAG: usize = 24;
    const INSI_LADDR: usize = 48;
    /// `tcp_sockinfo.tcpsi_state`.
    const TCPSI_STATE: usize = 80;
    const INI_IPV4: u8 = 1;

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

    fn fds(pid: c_int) -> Vec<libc::proc_fdinfo> {
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
        fds.truncate(bytes.max(0) as usize / entry);
        fds
    }

    pub fn open_files(pid: u32) -> Vec<PathBuf> {
        let pid = pid as c_int;
        let mut buf = vec![0u8; VNODE_FDINFO_WITH_PATH];
        fds(pid)
            .iter()
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

    fn i32_at(buf: &[u8], at: usize) -> i32 {
        i32::from_ne_bytes(buf[at..at + 4].try_into().expect("4 bytes"))
    }

    pub fn listening_ports(pids: &[u32]) -> Vec<Listener> {
        let mut out = Vec::new();
        let mut buf = vec![0u8; SOCKET_FDINFO_SIZE];
        for &pid in pids {
            let cpid = pid as c_int;
            for fd in fds(cpid) {
                if fd.proc_fdtype != libc::PROX_FDTYPE_SOCKET as u32 {
                    continue;
                }
                // SAFETY: `buf` is writable for its full length, the size passed.
                let got = unsafe {
                    libc::proc_pidfdinfo(
                        cpid,
                        fd.proc_fd,
                        PROC_PIDFDSOCKETINFO,
                        buf.as_mut_ptr().cast(),
                        buf.len() as c_int,
                    )
                };
                if got as usize != SOCKET_FDINFO_SIZE
                    || i32_at(&buf, SOI_KIND) != SOCKINFO_TCP
                    || i32_at(&buf, SOI_PROTO + TCPSI_STATE) != TSI_S_LISTEN
                {
                    continue;
                }
                let lport = i32_at(&buf, SOI_PROTO + INSI_LPORT);
                let port = u16::from_be(lport as u16);
                let laddr = &buf[SOI_PROTO + INSI_LADDR..SOI_PROTO + INSI_LADDR + 16];
                let loopback = if buf[SOI_PROTO + INSI_VFLAG] & INI_IPV4 != 0 {
                    // in4in6_addr: 12 bytes of padding, then the IPv4 address.
                    laddr[12] == 127
                } else {
                    laddr[..15].iter().all(|&b| b == 0) && laddr[15] == 1
                };
                out.push(Listener {
                    pid,
                    port,
                    loopback,
                });
            }
        }
        out
    }

    pub fn process_name(pid: u32) -> Option<String> {
        let mut buf = [0u8; 256];
        // SAFETY: `buf` is writable for its length.
        let n = unsafe { libc::proc_name(pid as c_int, buf.as_mut_ptr().cast(), buf.len() as u32) };
        (n > 0).then(|| String::from_utf8_lossy(&buf[..n as usize]).into_owned())
    }

    pub fn exe_path(pid: u32) -> Option<PathBuf> {
        let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: `buf` is writable for its length.
        let n =
            unsafe { libc::proc_pidpath(pid as c_int, buf.as_mut_ptr().cast(), buf.len() as u32) };
        (n > 0).then(|| PathBuf::from(String::from_utf8_lossy(&buf[..n as usize]).into_owned()))
    }

    /// The environment from `KERN_PROCARGS2`: `argc`, the executable path, padding, `argc`
    /// arguments, then `KEY=value` strings, all NUL-terminated.
    pub fn process_env(pid: u32) -> Option<Vec<String>> {
        let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as c_int];
        let mut size: libc::size_t = 0;
        // SAFETY: a null buffer asks for the size.
        let ret = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                3,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if ret != 0 || size < 4 {
            return None;
        }
        let mut buf = vec![0u8; size];
        // SAFETY: `buf` is writable for `size` bytes.
        let ret = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                3,
                buf.as_mut_ptr().cast::<c_void>(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if ret != 0 {
            return None;
        }
        buf.truncate(size);
        let argc = i32::from_ne_bytes(buf[..4].try_into().ok()?) as usize;
        let mut parts = buf[4..].split(|&b| b == 0).filter(|p| !p.is_empty());
        parts.next()?; // the executable path
        Some(
            parts
                .skip(argc)
                .map(|p| String::from_utf8_lossy(p).into_owned())
                .filter(|e| e.contains('='))
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_variable_an_ancestor_carries() {
        // The test runner's parent (cargo or the shell) has a PATH; nobody has this one.
        assert!(inherited_env_var("PATH").is_some());
        assert_eq!(inherited_env_var("UN_TEST_NOBODY_HAS_THIS"), None);
    }

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

    #[test]
    fn finds_own_listening_sockets_and_environment() {
        let v4 = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let any = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
        let me = std::process::id();
        let found = listening_ports(&[me]);
        let p4 = v4.local_addr().unwrap().port();
        let pany = any.local_addr().unwrap().port();
        assert!(
            found.contains(&Listener {
                pid: me,
                port: p4,
                loopback: true
            }),
            "{found:?}"
        );
        assert!(
            found.contains(&Listener {
                pid: me,
                port: pany,
                loopback: false
            }),
            "{found:?}"
        );
        assert!(process_name(me).is_some());
        assert!(exe_path(me).is_some());
        // macOS hides the environment of Apple platform binaries, so read our own (the
        // editor servers this is for are not platform binaries).
        assert_eq!(
            process_env_var(me, "PATH"),
            std::env::var("PATH").ok(),
            "environment of {me}"
        );
    }
}
