//! Channels on a [`Connection`]: exec with captured output, interactive PTY shells, and
//! uploads over `exec` with a SHA-256 check.

use std::io::Write as _;
use std::sync::Arc;

use russh::client::Msg;
use russh::{ChannelMsg, ChannelReadHalf, ChannelWriteHalf, Pty};
use tokio::io::AsyncRead;

use crate::SshError;
use crate::client::Connection;

/// The result of a remote command.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExecOutput {
    /// Standard output.
    pub stdout: Vec<u8>,
    /// Standard error.
    pub stderr: Vec<u8>,
    /// Exit status, if the server sent one.
    pub exit_status: Option<u32>,
    /// Name of the signal that killed the command, if any (`TERM`, `KILL`, …).
    pub exit_signal: Option<String>,
}

impl ExecOutput {
    /// Whether the command exited with status 0.
    pub fn success(&self) -> bool {
        self.exit_status == Some(0)
    }

    /// Standard output as text (lossy UTF-8).
    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    /// `Ok(self)` on success, else [`SshError::Remote`] with the status and stderr.
    ///
    /// # Errors
    ///
    /// [`SshError::Remote`] for a non-zero status, a signal, or no status at all.
    pub fn check(self) -> Result<Self, SshError> {
        if self.success() {
            return Ok(self);
        }
        let status = match (&self.exit_status, &self.exit_signal) {
            (_, Some(sig)) => format!("signal {sig}"),
            (Some(code), None) => format!("exit {code}"),
            (None, None) => "no exit status".into(),
        };
        Err(SshError::Remote {
            status,
            stderr: String::from_utf8_lossy(&self.stderr).trim().to_owned(),
        })
    }
}

/// A request for an interactive terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtyRequest {
    /// `TERM` for the remote side.
    pub term: String,
    /// Columns.
    pub cols: u32,
    /// Rows.
    pub rows: u32,
    /// Environment to set first (servers only accept names in their `AcceptEnv`, usually
    /// `LANG` and `LC_*`; the rest are silently dropped).
    pub env: Vec<(String, String)>,
    /// A command to run instead of the login shell.
    pub command: Option<String>,
}

impl PtyRequest {
    /// A login shell of `cols × rows` with `TERM=xterm-256color`.
    pub fn new(cols: u32, rows: u32) -> Self {
        Self {
            term: "xterm-256color".into(),
            cols,
            rows,
            env: Vec::new(),
            command: None,
        }
    }
}

/// Something that happened on a shell channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShellEvent {
    /// Terminal output (stdout; with a PTY, stderr is merged into it remotely).
    Data(Vec<u8>),
    /// Extended data (stderr), for commands run without merging.
    Stderr(Vec<u8>),
    /// The remote process exited.
    Exit {
        /// Exit status.
        status: Option<u32>,
        /// Signal name, if killed by one.
        signal: Option<String>,
    },
}

/// The writing side of an interactive shell. Cheap to clone.
#[derive(Clone)]
pub struct Shell {
    write: Arc<ChannelWriteHalf<Msg>>,
    conn: Connection,
}

/// The reading side of an interactive shell.
pub struct ShellOutput {
    read: ChannelReadHalf,
    conn: Connection,
}

impl Connection {
    /// Runs `command` and collects its output.
    ///
    /// # Errors
    ///
    /// Fails if the channel cannot be opened or the connection drops before the command
    /// finishes. A non-zero exit is not an error here; see [`ExecOutput::check`].
    pub async fn exec(&self, command: &str) -> Result<ExecOutput, SshError> {
        self.exec_with_input(command, tokio::io::empty()).await
    }

    /// Runs `command` with `input` streamed to its stdin (then EOF) and collects its output.
    ///
    /// # Errors
    ///
    /// As [`exec`](Self::exec), plus read errors from `input`.
    pub async fn exec_with_input<R>(&self, command: &str, input: R) -> Result<ExecOutput, SshError>
    where
        R: AsyncRead + Unpin,
    {
        self.guard(self.exec_inner(command, input)).await
    }

    async fn exec_inner<R>(&self, command: &str, input: R) -> Result<ExecOutput, SshError>
    where
        R: AsyncRead + Unpin,
    {
        let channel = self.handle().channel_open_session().await?;
        channel.exec(true, command).await?;
        let (mut read, write) = channel.split();
        // Write and read concurrently so a chatty command cannot fill its window and stall
        // the upload.
        let writer = async {
            write.data(input).await?;
            write.eof().await?;
            Ok::<_, SshError>(())
        };
        let reader = async {
            let mut out = ExecOutput::default();
            let mut closed = false;
            while let Some(msg) = read.wait().await {
                match msg {
                    ChannelMsg::Data { data } => out.stdout.extend_from_slice(&data),
                    ChannelMsg::ExtendedData { data, .. } => out.stderr.extend_from_slice(&data),
                    ChannelMsg::ExitStatus { exit_status } => out.exit_status = Some(exit_status),
                    ChannelMsg::ExitSignal { signal_name, .. } => {
                        out.exit_signal = Some(signal_name_str(&signal_name));
                    }
                    ChannelMsg::Close => {
                        closed = true;
                        break;
                    }
                    _ => {}
                }
            }
            if !closed && out.exit_status.is_none() && out.exit_signal.is_none() {
                return Err(SshError::Disconnected(format!("while running {command:?}")));
            }
            Ok(out)
        };
        let (written, output) = tokio::join!(writer, reader);
        let output = output?;
        // The command may exit without reading all of its input (that is its business),
        // so a write error only matters if it never reported a status.
        if let Err(e) = written
            && output.exit_status.is_none()
        {
            return Err(e);
        }
        Ok(output)
    }

    /// Opens an interactive shell (or `request.command`) on a PTY.
    ///
    /// # Errors
    ///
    /// Fails if the channel, PTY or shell request is refused.
    pub async fn open_shell(&self, request: &PtyRequest) -> Result<(Shell, ShellOutput), SshError> {
        self.guard(self.open_shell_inner(request)).await
    }

    async fn open_shell_inner(
        &self,
        request: &PtyRequest,
    ) -> Result<(Shell, ShellOutput), SshError> {
        let channel = self.handle().channel_open_session().await?;
        for (name, value) in &request.env {
            channel
                .set_env(false, name.as_str(), value.as_str())
                .await?;
        }
        // IUTF8 makes the remote line editor erase whole UTF-8 characters.
        channel
            .request_pty(
                true,
                &request.term,
                request.cols,
                request.rows,
                0,
                0,
                &[(Pty::IUTF8, 1)],
            )
            .await?;
        match &request.command {
            Some(cmd) => channel.exec(true, cmd.as_str()).await?,
            None => channel.request_shell(true).await?,
        }
        let (read, write) = channel.split();
        Ok((
            Shell {
                write: Arc::new(write),
                conn: self.clone(),
            },
            ShellOutput {
                read,
                conn: self.clone(),
            },
        ))
    }
}

impl Shell {
    /// Sends input (keystrokes, paste) to the remote terminal.
    ///
    /// # Errors
    ///
    /// [`SshError::Disconnected`] if the channel or connection is gone.
    pub async fn write(&self, data: &[u8]) -> Result<(), SshError> {
        self.conn.note_input();
        self.conn
            .guard(async { self.write.data(data).await.map_err(SshError::from) })
            .await
    }

    /// Tells the remote side the terminal's new size.
    ///
    /// # Errors
    ///
    /// [`SshError::Disconnected`] if the channel or connection is gone.
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), SshError> {
        self.conn
            .guard(async {
                self.write
                    .window_change(cols, rows, 0, 0)
                    .await
                    .map_err(SshError::from)
            })
            .await
    }

    /// Closes the channel (the remote shell gets SIGHUP).
    pub async fn close(&self) {
        let _ = self.write.eof().await;
        let _ = self.write.close().await;
    }

    /// The connection the shell runs on.
    pub fn connection(&self) -> &Connection {
        &self.conn
    }
}

impl ShellOutput {
    /// The next event; `None` once the channel is closed or the connection is dead.
    pub async fn next(&mut self) -> Option<ShellEvent> {
        loop {
            let msg = tokio::select! {
                msg = self.read.wait() => msg?,
                _ = self.conn.closed() => return None,
            };
            match msg {
                ChannelMsg::Data { data } => return Some(ShellEvent::Data(data.to_vec())),
                ChannelMsg::ExtendedData { data, .. } => {
                    return Some(ShellEvent::Stderr(data.to_vec()));
                }
                ChannelMsg::ExitStatus { exit_status } => {
                    return Some(ShellEvent::Exit {
                        status: Some(exit_status),
                        signal: None,
                    });
                }
                ChannelMsg::ExitSignal { signal_name, .. } => {
                    return Some(ShellEvent::Exit {
                        status: None,
                        signal: Some(signal_name_str(&signal_name)),
                    });
                }
                ChannelMsg::Close => return None,
                _ => {}
            }
        }
    }
}

fn signal_name_str(sig: &russh::Sig) -> String {
    let debug = format!("{sig:?}");
    match debug.strip_prefix("Custom(\"") {
        Some(rest) => rest.trim_end_matches("\")").to_owned(),
        None => debug,
    }
}

/// What [`Connection::upload`] wrote.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadReport {
    /// Remote path as given.
    pub path: String,
    /// Bytes of the file.
    pub size: u64,
    /// SHA-256 of the file, hex, as verified on the remote.
    pub sha256: String,
    /// Bytes sent on the wire (smaller when compressed).
    pub sent: u64,
}

/// How to send an upload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadEncoding {
    /// As is (`cat`).
    Raw,
    /// gzip on the wire, `gzip -dc` on the remote (needs gzip there).
    Gzip,
}

impl Connection {
    /// Writes `data` to `path` on the remote atomically: streamed to a temporary file next
    /// to it, SHA-256-checked there, `chmod`ed to `mode`, then renamed into place. Parent
    /// directories are created. `path` may start with `~/`.
    ///
    /// Uses only POSIX `sh`, `cat`/`gzip`, `mkdir`, `chmod`, `mv` and one of `sha256sum`,
    /// `shasum` or `openssl` on the remote; no SFTP subsystem needed.
    ///
    /// # Errors
    ///
    /// [`SshError::ChecksumMismatch`] if the remote copy differs (nothing is installed),
    /// [`SshError::Remote`] if a remote step fails.
    pub async fn upload(
        &self,
        path: &str,
        data: &[u8],
        mode: u32,
        encoding: UploadEncoding,
    ) -> Result<UploadReport, SshError> {
        let sha256 = sha256_hex(data);
        let wire = match encoding {
            UploadEncoding::Raw => data.to_vec(),
            UploadEncoding::Gzip => {
                let mut gz = flate2::write::GzEncoder::new(
                    Vec::with_capacity(data.len() / 2),
                    flate2::Compression::new(6),
                );
                gz.write_all(data)
                    .and_then(|()| gz.finish())
                    .map_err(|e| SshError::io("compressing the upload", e))?
            }
        };
        let decode = match encoding {
            UploadEncoding::Raw => "cat",
            UploadEncoding::Gzip => "gzip -dc",
        };
        let script = format!(
            r#"set -e
f={path}
t="$f.tmp.$$"
mkdir -p "$(dirname "$f")"
trap 'rm -f "$t"' EXIT
umask 077
{decode} > "$t"
h=$( (sha256sum "$t" 2>/dev/null || shasum -a 256 "$t" 2>/dev/null || openssl dgst -sha256 -r "$t") | cut -d' ' -f1)
echo "sha256=$h"
[ "$h" = "{sha256}" ] || exit 3
chmod {mode:o} "$t"
mv -f "$t" "$f"
trap - EXIT"#,
            path = remote_path(path),
        );
        let out = self
            .exec_with_input(&sh_command(&script), wire.as_slice())
            .await?;
        let remote_hash = out
            .stdout_text()
            .lines()
            .find_map(|l| l.strip_prefix("sha256=").map(str::to_owned))
            .unwrap_or_default();
        if out.exit_status == Some(3) {
            return Err(SshError::ChecksumMismatch {
                path: path.to_owned(),
                expected: sha256,
                actual: remote_hash,
            });
        }
        out.check()?;
        Ok(UploadReport {
            path: path.to_owned(),
            size: data.len() as u64,
            sha256,
            sent: wire.len() as u64,
        })
    }

    /// Reads a remote file into memory.
    ///
    /// # Errors
    ///
    /// [`SshError::Remote`] if it cannot be read.
    pub async fn download(&self, path: &str) -> Result<Vec<u8>, SshError> {
        let out = self
            .exec(&sh_command(&format!("cat {}", remote_path(path))))
            .await?
            .check()?;
        Ok(out.stdout)
    }
}

/// Lower-case hex SHA-256.
pub fn sha256_hex(data: &[u8]) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, data);
    digest.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// Single-quotes `s` for POSIX sh.
///
/// # Examples
///
/// ```
/// assert_eq!(ssh::shell_quote("it's"), r#"'it'\''s'"#);
/// ```
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// A shell expression for a remote path: `~/x` becomes `"$HOME"/'x'`, anything else is
/// quoted as is.
pub(crate) fn remote_path(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => format!("\"$HOME\"/{}", shell_quote(rest)),
        None if path == "~" => "\"$HOME\"".into(),
        None => shell_quote(path),
    }
}

/// Wraps a POSIX script so it runs under `sh` whatever the user's login shell is (fish,
/// nushell, …).
pub(crate) fn sh_command(script: &str) -> String {
    format!("sh -c {}", shell_quote(script))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("plain"), "'plain'");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(remote_path("~/.local/bin/x"), r#""$HOME"/'.local/bin/x'"#);
        assert_eq!(
            remote_path("~/Library/Application Support/u"),
            r#""$HOME"/'Library/Application Support/u'"#
        );
        assert_eq!(remote_path("/tmp/a b"), "'/tmp/a b'");
        assert_eq!(sh_command("echo 'hi'"), r#"sh -c 'echo '\''hi'\'''"#);
    }

    #[test]
    fn sha256() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
