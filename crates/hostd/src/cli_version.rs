use std::ffi::OsStr;
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(super) fn read(program: &OsStr) -> io::Result<Option<Vec<u8>>> {
    let mut process = Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let result = (|| {
        let mut stdout = process
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("missing version output"))?;
        let flags = rustix::fs::fcntl_getfl(&stdout)?;
        rustix::fs::fcntl_setfl(&stdout, flags | rustix::fs::OFlags::NONBLOCK)?;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut bytes = [0; 128];
        let mut used = 0;
        let mut ended = false;
        loop {
            if !ended {
                match stdout.read(&mut bytes[used..]) {
                    Ok(0) => ended = true,
                    Ok(count) => {
                        used += count;
                        if used == bytes.len() {
                            return Ok(None);
                        }
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error),
                }
            }
            if ended && let Some(status) = process.try_wait()? {
                return Ok(status.success().then(|| bytes[..used].to_vec()));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    if process.try_wait()?.is_none() {
        process.kill()?;
        process.wait()?;
    }
    result
}

/// `read`, kept in `cache_dir` for the installed program as it is now: every launch would
/// otherwise start the program once more and wait for its answer.
pub(super) fn read_cached(program: &OsStr, cache_dir: &Path) -> io::Result<Option<Vec<u8>>> {
    let installed = installed(program)?;
    let cache = cache_dir.join(format!(
        "{}.version",
        Path::new(program)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default()
    ));
    if let Some(cached) = std::fs::read(&cache)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<CachedVersion>(&bytes).ok())
        .filter(|cached| cached.installed == installed)
    {
        return Ok(Some(cached.version.into_bytes()));
    }
    let version = read(installed.path.as_os_str())?;
    if let Some(text) = version
        .as_deref()
        .and_then(|bytes| std::str::from_utf8(bytes).ok())
    {
        let cached = CachedVersion {
            installed,
            version: text.to_owned(),
        };
        if let Ok(bytes) = serde_json::to_vec(&cached) {
            let staged = cache.with_extension("version.new");
            if std::fs::write(&staged, bytes).is_ok() {
                let _ = std::fs::rename(&staged, &cache);
            }
        }
    }
    Ok(version)
}

#[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct Installed {
    path: PathBuf,
    length: u64,
    modified_ns: i128,
    inode: u64,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct CachedVersion {
    installed: Installed,
    version: String,
}

/// The file `program` runs, found on `PATH` as `exec` finds it, and what tells a new install
/// from it.
fn installed(program: &OsStr) -> io::Result<Installed> {
    let path = if Path::new(program).components().count() > 1 {
        Some(PathBuf::from(program))
    } else {
        std::env::var_os("PATH").and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|directory| directory.join(program))
                .find(|candidate| {
                    std::fs::metadata(candidate).is_ok_and(|metadata| {
                        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
                    })
                })
        })
    }
    .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
    // The target, not a link to it: an update replaces the file a link names.
    let metadata = std::fs::metadata(&path)?;
    let modified = metadata.modified()?;
    let modified_ns = match modified.duration_since(std::time::UNIX_EPOCH) {
        Ok(since) => since.as_nanos() as i128,
        Err(before) => -(before.duration().as_nanos() as i128),
    };
    Ok(Installed {
        path,
        length: metadata.len(),
        modified_ns,
        inode: metadata.ino(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_version_is_asked_once_per_install() {
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("agent");
        let count = directory.path().join("asked");
        let write = |version: &str| {
            std::fs::write(
                &program,
                format!(
                    "#!/bin/sh\necho x >> '{}'\necho '{version}'\n",
                    count.display()
                ),
            )
            .unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        };
        write("1.0.0");
        let asked = || {
            std::fs::read_to_string(&count)
                .unwrap_or_default()
                .lines()
                .count()
        };
        for _ in 0..3 {
            assert_eq!(
                read_cached(program.as_os_str(), directory.path()).unwrap(),
                Some(b"1.0.0\n".to_vec())
            );
        }
        assert_eq!(asked(), 1);
        std::thread::sleep(std::time::Duration::from_millis(20));
        write("2.0.0 longer");
        assert_eq!(
            read_cached(program.as_os_str(), directory.path()).unwrap(),
            Some(b"2.0.0 longer\n".to_vec())
        );
        assert_eq!(asked(), 2);
        let missing = directory.path().join("missing");
        assert_eq!(
            read_cached(missing.as_os_str(), directory.path())
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
    }
}
