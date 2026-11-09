use std::ffi::OsStr;
use std::io::{self, Read};
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
