//! Native password prompts (`proto::askpass`, docs/DAEMON.md §9).
//!
//! - **Askpass.** Every pane gets `SUDO_ASKPASS`, `SSH_ASKPASS` (+
//!   `SSH_ASKPASS_REQUIRE=prefer`) and `GIT_ASKPASS` naming `<state>/askpass/<cli>-askpass`, a
//!   two-line script that runs the hook shim's `askpass` mode. The helper sends one
//!   [`AskpassCall`] line on the hook socket and waits for one [`HelperReply`] line. The
//!   daemon pushes the prompt to every owner device with [`Caps::ASKPASS`] that shows the
//!   pane's session, never to a guest's (a host that is not theirs must not ask for their
//!   passwords); the first answer wins. While a guest holds the pane's lease the prompt
//!   names them ([`AskpassPush::PromptWhileGuestDrives`]): they may have typed the command. With nobody able to answer (now,
//!   or for [`AskpassConfig::grace`] while the prompt is open), the helper is told to ask on
//!   the terminal itself.
//! - **Detected prompts.** While a pane's termios is `-echo icanon` and the cursor row looks
//!   like a password prompt, [`AskpassPush::Detected`] is pushed; `TypeSecret` writes a
//!   secret plus Return only while echo is still off.
//!
//! Secrets are never logged, persisted or put in an event other than the reply to the asking
//! program; buffers that held them are zeroed.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proto::{
    AskpassError, AskpassId, AskpassPush, AskpassRequest, Caps, CloseReason, DetectedPrompt,
    PaneId, PrincipalId, Secret, SecretPrompt, SecretSource, UnixMillis,
};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::sync::oneshot;

use crate::config::AskpassConfig;
use crate::core::{ConnId, Core, Event, PaneEntry, lock};
use crate::fsutil;
use crate::mp::{Authz, Need, Target, policy};
use crate::shell::Injection;

/// The askpass protocol version in [`AskpassCall::v`].
pub const ASKPASS_VERSION: u32 = 1;

/// Longest prompt or program text shown, in characters.
const MAX_TEXT: usize = 512;

/// How long after an answer the same question from the same pane counts as a retry.
const RETRY_WINDOW: Duration = Duration::from_secs(60);

/// What the askpass helper sends on the hook socket: one JSON line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AskpassCall {
    /// [`ASKPASS_VERSION`].
    pub v: u32,
    /// The hook token from the pane's environment.
    pub token: String,
    /// The pane id from the pane's environment.
    pub pane: String,
    /// The question.
    pub askpass: HelperQuery,
}

/// The helper's question.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HelperQuery {
    /// The prompt the program passed as the helper's first argument.
    #[serde(default)]
    pub prompt: String,
    /// The asking program's command line (the helper's parent), if known.
    #[serde(default)]
    pub program: String,
    /// `SSH_ASKPASS_PROMPT=confirm`: a yes/no question.
    #[serde(default)]
    pub confirm: bool,
    /// Only ask whether an app could answer now (the `sudo` wrapper): answered with
    /// [`HelperReply::Available`].
    #[serde(default)]
    pub probe: bool,
}

/// The daemon's answer to an [`AskpassCall`]: one JSON line.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HelperReply {
    /// The secret, to print on stdout.
    Answer(String),
    /// Declined, timed out or abandoned: exit non-zero.
    Cancelled,
    /// Nobody can answer in the app: ask on the terminal.
    Terminal,
    /// Answer to a probe.
    Available(bool),
}

impl std::fmt::Debug for HelperReply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Answer(_) => f.write_str("Answer(…)"),
            Self::Cancelled => f.write_str("Cancelled"),
            Self::Terminal => f.write_str("Terminal"),
            Self::Available(a) => write!(f, "Available({a})"),
        }
    }
}

impl Drop for HelperReply {
    fn drop(&mut self) {
        if let Self::Answer(s) = self {
            zeroize::Zeroize::zeroize(s);
        }
    }
}

enum Outcome {
    Answer(Secret, PrincipalId),
    Cancel(PrincipalId),
}

struct Open {
    prompt: SecretPrompt,
    /// The guest holding the pane's lease when the program asked.
    guest: Option<String>,
    reply: oneshot::Sender<Outcome>,
}

impl Open {
    fn push(&self) -> AskpassPush {
        prompt_push(self.prompt.clone(), self.guest.clone())
    }
}

fn prompt_push(prompt: SecretPrompt, guest: Option<String>) -> AskpassPush {
    match guest {
        Some(guest) => AskpassPush::PromptWhileGuestDrives { prompt, guest },
        None => AskpassPush::Prompt(prompt),
    }
}

/// Open prompts, the connections that may answer them, and the helper's location.
pub(crate) struct Askpass {
    /// `<state>/askpass/<cli>-askpass`, once written.
    helper: Option<PathBuf>,
    /// Directory of the shell wrappers (`sudo -A`), once written.
    wrappers: Option<PathBuf>,
    next: AtomicU64,
    open: Mutex<HashMap<AskpassId, Open>>,
    /// Connections that announced [`Caps::ASKPASS`].
    conns: Mutex<HashMap<ConnId, Authz>>,
    /// When `(pane, prompt)` was last answered, for [`SecretPrompt::retry`].
    answered: Mutex<HashMap<(PaneId, String), Instant>>,
}

impl Askpass {
    /// Writes the helper script and the shell wrappers under `state_dir`. Failures are logged
    /// and leave the feature off.
    pub fn install(cfg: &AskpassConfig, state_dir: &Path, hook_bin: &Path) -> Self {
        let mut this = Self {
            helper: None,
            wrappers: None,
            next: AtomicU64::new(1),
            open: Mutex::default(),
            conns: Mutex::default(),
            answered: Mutex::default(),
        };
        if !cfg.enabled {
            return this;
        }
        let dir = state_dir.join("askpass");
        let helper = dir.join(format!("{}-askpass", brand::CLI_BIN));
        let script = format!(
            "#!/bin/sh\n# Written by {}: asks the app for a password (docs/DAEMON.md §9).\nexec {} askpass \"$@\"\n",
            brand::DAEMON_BIN,
            agents_quote(&hook_bin.to_string_lossy()),
        );
        match write_executable(&helper, &script) {
            Ok(()) => this.helper = Some(helper),
            Err(e) => {
                tracing::warn!("writing the askpass helper: {e}");
                return this;
            }
        }
        if cfg.sudo {
            let si = state_dir.join("shell-integration");
            match write_wrappers(&dir, &si) {
                Ok(()) => this.wrappers = Some(dir),
                Err(e) => tracing::warn!("writing the sudo wrappers: {e}"),
            }
        }
        this
    }

    /// Variables every pane gets while askpass is on.
    pub fn pane_env(&self, core: &Core, pane: PaneId) -> Vec<(String, std::ffi::OsString)> {
        let Some(helper) = &self.helper else {
            return Vec::new();
        };
        let hooks = &core.hooks;
        let mut env: Vec<(String, std::ffi::OsString)> = vec![
            ("SUDO_ASKPASS".into(), helper.clone().into()),
            ("SSH_ASKPASS".into(), helper.clone().into()),
            ("SSH_ASKPASS_REQUIRE".into(), "prefer".into()),
            ("GIT_ASKPASS".into(), helper.clone().into()),
            (brand::env_var("ASKPASS"), helper.clone().into()),
            (brand::env_var("SOCK"), hooks.socket().to_owned().into()),
            (brand::env_var("TOKEN"), hooks.pane_token(pane).into()),
            (
                brand::env_var("ENDPOINT_FILE"),
                hooks.endpoint_file().to_owned().into(),
            ),
        ];
        if self.wrappers.is_some() {
            env.push((brand::env_var("ASKPASS_SUDO"), "1".into()));
        }
        env
    }

    /// Points the shell at the wrappers that define `sudo` (zsh: our `ZDOTDIR`, which loads
    /// Ghostty's; bash: our `ENV`, which sources Ghostty's). fish finds its wrapper next to
    /// Ghostty's in `vendor_conf.d` by itself.
    pub fn wrap_injection(&self, inj: &mut Injection) {
        let Some(dir) = &self.wrappers else {
            return;
        };
        for (k, v) in &mut inj.env {
            match k.as_str() {
                "ZDOTDIR" => *v = dir.join("zsh").to_string_lossy().into_owned(),
                "ENV" if v.ends_with("ghostty.bash") => {
                    *v = dir.join("askpass.bash").to_string_lossy().into_owned();
                }
                _ => {}
            }
        }
    }

    pub fn register(&self, conn: ConnId, authz: &Authz, caps: Caps) {
        if caps.contains(Caps::ASKPASS) {
            lock(&self.conns).insert(conn, authz.clone());
        }
    }

    pub fn forget_conn(&self, conn: ConnId) {
        lock(&self.conns).remove(&conn);
    }

    /// The open prompts of `pane`, as pushes.
    pub fn open_in(&self, pane: PaneId) -> Vec<AskpassPush> {
        let open = lock(&self.open);
        let mut mine: Vec<&Open> = open.values().filter(|o| o.prompt.pane_id == pane).collect();
        mine.sort_by_key(|o| o.prompt.id);
        mine.into_iter().map(Open::push).collect()
    }

    fn pane_of(&self, id: AskpassId) -> Option<PaneId> {
        lock(&self.open).get(&id).map(|o| o.prompt.pane_id)
    }

    fn resolve(&self, id: AskpassId, outcome: Outcome) -> Result<(), AskpassError> {
        let open = lock(&self.open).remove(&id).ok_or(AskpassError::Gone)?;
        open.reply.send(outcome).map_err(|_| AskpassError::Gone)
    }
}

impl Core {
    /// Whether a connection that may answer a prompt in `pane` (an owner device's) is attached
    /// to its session.
    pub fn askpass_audience(&self, pane: PaneId) -> bool {
        let Some(session) = self.session_of_pane(pane) else {
            return false;
        };
        let conns: Vec<(ConnId, Authz)> = lock(&self.askpass.conns)
            .iter()
            .map(|(c, a)| (*c, a.clone()))
            .collect();
        conns.into_iter().any(|(conn, authz)| {
            self.attached_session(conn) == Some(session)
                && self.mp.still_valid(&authz)
                && authz.is_owner_device(self)
        })
    }
}

// --- the helper's side of the hook socket ---------------------------------------------------

/// Serves one askpass call. `rest` is the rest of the helper's connection: it reaching EOF
/// means the program gave up (Ctrl-C, its own timeout).
pub(crate) async fn serve(
    core: &Arc<Core>,
    call: AskpassCall,
    peer_uid: Option<u32>,
    mut rest: impl AsyncRead + Unpin,
) -> HelperReply {
    if !core.hooks.verify(&call.token, &call.pane) {
        tracing::warn!("askpass call with a bad token");
        return HelperReply::Terminal;
    }
    // Same user only: the socket is in the state directory, this is belt and braces.
    // SAFETY: getuid has no preconditions and cannot fail.
    if peer_uid.is_some_and(|uid| uid != unsafe { libc::getuid() }) {
        tracing::warn!("askpass call from another user");
        return HelperReply::Terminal;
    }
    let Some(pane) = call.pane.parse().ok().map(PaneId) else {
        return HelperReply::Terminal;
    };
    if core.pane(pane).is_none() || core.askpass.helper.is_none() {
        return HelperReply::Terminal;
    }
    let audience = core.askpass_audience(pane);
    if call.askpass.probe {
        return HelperReply::Available(audience);
    }
    if !audience {
        return HelperReply::Terminal;
    }

    let query = call.askpass;
    let mut text = proto::clean_prompt_text(&query.prompt, MAX_TEXT);
    if text.is_empty() {
        text = "Password:".into();
    }
    let program = proto::clean_prompt_text(&query.program, MAX_TEXT);
    let lower = text.to_lowercase();
    let echo = query.confirm
        || lower.contains("(yes/no")
        || lower.starts_with("username")
        || lower.contains("continue connecting");
    let retry = {
        let mut answered = lock(&core.askpass.answered);
        answered.retain(|_, at| at.elapsed() < RETRY_WINDOW);
        answered.contains_key(&(pane, text.clone()))
    };
    let timeout = core.cfg.askpass.timeout;
    let id = AskpassId(core.askpass.next.fetch_add(1, Ordering::Relaxed));
    let prompt = SecretPrompt {
        id,
        pane_id: pane,
        source: classify(&program),
        prompt: text.clone(),
        program,
        echo,
        retry,
        expires_at: UnixMillis(crate::identity::now_millis() + timeout.as_millis() as u64),
    };
    let guest = core.mp.guest_driving(pane);
    let (tx, rx) = oneshot::channel();
    lock(&core.askpass.open).insert(
        id,
        Open {
            prompt: prompt.clone(),
            guest: guest.clone(),
            reply: tx,
        },
    );
    tracing::info!(pane = %pane, id = %id, source = ?prompt.source, guest_driving = guest.is_some(), "askpass prompt");
    core.emit(Event::Askpass(prompt_push(prompt, guest)));

    let (reason, reply) = tokio::select! {
        outcome = rx => match outcome {
            Ok(Outcome::Answer(secret, by)) => {
                lock(&core.askpass.answered).insert((pane, text), Instant::now());
                let answer = String::from_utf8_lossy(secret.expose()).into_owned();
                (CloseReason::Answered { by }, HelperReply::Answer(answer))
            }
            Ok(Outcome::Cancel(by)) => (CloseReason::Cancelled { by: Some(by) }, HelperReply::Cancelled),
            Err(_) => (CloseReason::Cancelled { by: None }, HelperReply::Cancelled),
        },
        () = tokio::time::sleep(timeout) => (CloseReason::TimedOut, HelperReply::Cancelled),
        () = gone(&mut rest) => (CloseReason::Abandoned, HelperReply::Cancelled),
        () = audience_lost(core, pane, core.cfg.askpass.grace) => {
            (CloseReason::MovedToTerminal, HelperReply::Terminal)
        }
    };
    lock(&core.askpass.open).remove(&id);
    tracing::info!(pane = %pane, id = %id, ?reason, "askpass prompt closed");
    core.emit(Event::Askpass(AskpassPush::Closed {
        id,
        pane_id: pane,
        reason,
    }));
    reply
}

/// Resolves once the helper's side of the connection closes.
pub(crate) async fn gone(rest: &mut (impl AsyncRead + Unpin)) {
    let mut buf = [0u8; 64];
    loop {
        match rest.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}

/// Resolves once nobody could answer a prompt in `pane` for `grace`.
async fn audience_lost(core: &Core, pane: PaneId, grace: Duration) {
    let mut since: Option<Instant> = None;
    loop {
        tokio::time::sleep(Duration::from_millis(250)).await;
        if core.pane(pane).is_none() {
            return;
        }
        if core.askpass_audience(pane) {
            since = None;
        } else if since.get_or_insert_with(Instant::now).elapsed() >= grace {
            return;
        }
    }
}

/// The kind of program from its command line (a script's name, not its interpreter's).
fn classify(program: &str) -> SecretSource {
    let base = |word: &str| -> String {
        let name = word.rsplit('/').next().unwrap_or(word);
        name.strip_prefix('-').unwrap_or(name).to_owned()
    };
    let mut words = program.split_whitespace();
    let mut name = base(words.next().unwrap_or(""));
    if matches!(
        name.as_str(),
        "sh" | "bash" | "zsh" | "dash" | "fish" | "env" | "perl" | "python" | "python3"
    ) && let Some(script) = words.find(|w| !w.starts_with('-'))
    {
        name = base(script);
    }
    match name.as_str() {
        "sudo" | "sudoedit" => SecretSource::Sudo,
        "ssh" | "scp" | "sftp" | "ssh-add" | "ssh-keygen" | "ssh-agent" | "rsync" => {
            SecretSource::Ssh
        }
        n if n == "git" || n.starts_with("git-") => SecretSource::Git,
        n if n.starts_with("gpg") || n.starts_with("pinentry") => SecretSource::Gpg,
        _ => SecretSource::Other,
    }
}

// --- client requests ------------------------------------------------------------------------

/// Whether `secret` holds bytes the terminal or the reading program would act on.
fn has_controls(secret: &Secret) -> bool {
    secret.expose().iter().any(|&b| b < 0x20 || b == 0x7f)
}

/// Handles an [`AskpassRequest`] from a connection acting as `authz`.
pub(crate) async fn request(
    core: &Arc<Core>,
    authz: &Authz,
    req: AskpassRequest,
) -> Result<(), AskpassError> {
    let allow = |pane| {
        policy::check(core, authz, Need::Drive, Target::Pane(pane))
            .map_err(|e| AskpassError::Denied(e.to_string()))
    };
    // Prompts go to owner devices only; so do their answers.
    let owner = || {
        authz
            .is_owner_device(core)
            .then_some(())
            .ok_or_else(|| AskpassError::Denied("password prompts are the host owner's".into()))
    };
    let principal = authz.actor.principal;
    match req {
        AskpassRequest::Answer { id, secret } => {
            owner()?;
            allow(core.askpass.pane_of(id).ok_or(AskpassError::Gone)?)?;
            if has_controls(&secret) {
                return Err(AskpassError::Failed(
                    "the answer contains control characters".into(),
                ));
            }
            core.askpass.resolve(id, Outcome::Answer(secret, principal))
        }
        AskpassRequest::Cancel { id } => {
            owner()?;
            allow(core.askpass.pane_of(id).ok_or(AskpassError::Gone)?)?;
            core.askpass.resolve(id, Outcome::Cancel(principal))
        }
        AskpassRequest::TypeSecret { pane_id, secret } => {
            if !core.scope_within(proto::Scope::Pane(pane_id), authz.scope) {
                return Err(AskpassError::UnknownPane);
            }
            allow(pane_id)?;
            let entry = core.pane(pane_id).ok_or(AskpassError::UnknownPane)?;
            if has_controls(&secret) {
                return Err(AskpassError::Failed(
                    "the secret contains control characters".into(),
                ));
            }
            if let Err(lease) = core.mp.input(core, pane_id, authz.actor) {
                let _ = lease;
                return Err(AskpassError::Denied(
                    "someone else holds the pane's control lease".into(),
                ));
            }
            // The secret goes in only while the terminal hides input, so it can never be
            // echoed, land in the shell's history or run as a command.
            if !entry.pane.echo().is_hidden_input() || entry.pane.alt_screen() {
                return Err(AskpassError::NotHidden);
            }
            let mut bytes = Vec::with_capacity(secret.len() + 1);
            bytes.extend_from_slice(secret.expose());
            bytes.push(b'\r');
            entry
                .pane
                .write(bytes)
                .await
                .map_err(|_| AskpassError::UnknownPane)?;
            Ok(())
        }
    }
}

// --- detected prompts -----------------------------------------------------------------------

/// Re-checks `entry` for a password prompt the program printed itself and pushes a change.
pub(crate) fn detect(core: &Core, entry: &PaneEntry) {
    if core.askpass.helper.is_none() {
        return;
    }
    let pane = &entry.pane;
    let found = (pane.echo().is_hidden_input() && !pane.alt_screen())
        .then(|| pane.cursor_line())
        .flatten()
        .filter(|line| proto::looks_like_password_prompt(line))
        .map(|line| proto::clean_prompt_text(&line, MAX_TEXT));
    let changed = {
        let mut meta = lock(&entry.meta);
        let changed = meta.secret_prompt != found;
        meta.secret_prompt.clone_from(&found);
        changed
    };
    if !changed {
        return;
    }
    let pane_id = pane.id;
    core.emit(Event::Askpass(match found {
        Some(prompt) => AskpassPush::Detected(DetectedPrompt {
            pane_id,
            prompt,
            at_seq: pane.head(),
        }),
        None => AskpassPush::DetectedGone { pane_id },
    }));
}

/// The detected prompt of `pane` now, for a connection that just attached.
pub(crate) fn detected(core: &Core, pane: PaneId) -> Option<DetectedPrompt> {
    let entry = core.pane(pane)?;
    let prompt = lock(&entry.meta).secret_prompt.clone()?;
    Some(DetectedPrompt {
        pane_id: pane,
        prompt,
        at_seq: entry.pane.head(),
    })
}

/// The pane a push is about.
pub(crate) fn push_pane(push: &AskpassPush) -> PaneId {
    match push {
        AskpassPush::Prompt(p) | AskpassPush::PromptWhileGuestDrives { prompt: p, .. } => p.pane_id,
        AskpassPush::Closed { pane_id, .. }
        | AskpassPush::DetectedGone { pane_id }
        | AskpassPush::Detected(DetectedPrompt { pane_id, .. }) => *pane_id,
    }
}

// --- files ----------------------------------------------------------------------------------

fn agents_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/._-+=:,@".contains(&b))
    {
        return s.to_owned();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

pub(crate) fn write_executable(path: &Path, contents: &str) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if std::fs::read(path).is_ok_and(|old| old == contents.as_bytes()) {
        return Ok(());
    }
    fsutil::write_atomic(path, contents.as_bytes())?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
}

/// The `sudo` wrapper for bash and zsh: `sudo -A` while an app can answer (asked through the
/// helper's `--available` probe), plain `sudo` otherwise and whenever the caller already
/// chose how sudo reads the password (`-A`, `-S`, `-n`).
const SUDO_SH: &str = r#"sudo() {
  if [ -n "${GUDO_ASKPASS_SUDO-}" ] && [ -x "${GUDO_ASKPASS-}" ]; then
    local __un_arg
    for __un_arg in "$@"; do
      case $__un_arg in
        -A|--askpass|-S|--stdin|-n|--non-interactive) command sudo "$@"; return ;;
        -*|*=*) ;;
        *) break ;;
      esac
    done
    if "$GUDO_ASKPASS" --available 2>/dev/null; then
      command sudo -A "$@"
      return
    fi
  fi
  command sudo "$@"
}
"#;

const SUDO_FISH: &str = r#"if status is-interactive; and set -q GUDO_ASKPASS_SUDO; and set -q GUDO_ASKPASS
    function sudo --wraps sudo
        for __un_arg in $argv
            switch $__un_arg
                case -A --askpass -S --stdin -n --non-interactive
                    command sudo $argv
                    return
                case '-*' '*=*'
                case '*'
                    break
            end
        end
        if $GUDO_ASKPASS --available 2>/dev/null
            command sudo -A $argv
        else
            command sudo $argv
        end
    end
end
"#;

/// Writes the zsh `ZDOTDIR` and bash `ENV` wrappers under `dir`, and fish's next to Ghostty's
/// `vendor_conf.d` script under `si`.
fn write_wrappers(dir: &Path, si: &Path) -> io::Result<()> {
    let prefix = brand::ENV_PREFIX;
    let sudo_sh = SUDO_SH.replace("GUDO_", prefix);
    let ghostty_zshenv = agents_quote(&si.join("zsh/.zshenv").to_string_lossy());
    let zshenv = format!(
        "# Written by {daemon}: Ghostty's zsh integration, then the askpass `sudo` wrapper\n\
         # (docs/DAEMON.md §9).\n\
         builtin source {ghostty_zshenv}\n\
         if [[ -o interactive ]]; then\n{sudo_sh}fi\n",
        daemon = brand::DAEMON_BIN,
    );
    write_executable(&dir.join("zsh/.zshenv"), &zshenv)?;
    let ghostty_bash = agents_quote(&si.join("bash/ghostty.bash").to_string_lossy());
    let bash = format!(
        "# Written by {daemon}: Ghostty's bash integration, then the askpass `sudo` wrapper\n\
         # (docs/DAEMON.md §9).\n\
         builtin source {ghostty_bash}\n\
         if [[ $- == *i* ]]; then\n{sudo_sh}fi\n",
        daemon = brand::DAEMON_BIN,
    );
    write_executable(&dir.join("askpass.bash"), &bash)?;
    let fish = format!(
        "# Written by {}: the askpass `sudo` wrapper (docs/DAEMON.md §9).\n{}",
        brand::DAEMON_BIN,
        SUDO_FISH.replace("GUDO_", prefix)
    );
    write_executable(
        &si.join(format!(
            "fish/vendor_conf.d/{}-askpass.fish",
            brand::CLI_BIN
        )),
        &fish,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_programs() {
        assert_eq!(classify("sudo apt upgrade"), SecretSource::Sudo);
        assert_eq!(classify("/usr/bin/ssh host"), SecretSource::Ssh);
        assert_eq!(
            classify("git-remote-https origin https://example.com/r"),
            SecretSource::Git
        );
        assert_eq!(classify("git push"), SecretSource::Git);
        assert_eq!(classify("gpg --sign"), SecretSource::Gpg);
        assert_eq!(classify("/bin/sh /tmp/t/sudo -l"), SecretSource::Sudo);
        assert_eq!(classify("-zsh"), SecretSource::Other);
        assert_eq!(classify(""), SecretSource::Other);
    }

    #[test]
    fn replies_hide_the_secret() {
        let reply = HelperReply::Answer("hunter2".into());
        assert!(!format!("{reply:?}").contains("hunter2"));
        let line = serde_json::to_string(&reply).unwrap();
        assert_eq!(line, r#"{"answer":"hunter2"}"#);
        assert_eq!(
            serde_json::to_string(&HelperReply::Terminal).unwrap(),
            r#""terminal""#
        );
    }

    #[test]
    fn controls_are_refused() {
        assert!(has_controls(&Secret::new(b"a\nb".to_vec())));
        assert!(has_controls(&Secret::new(b"\x03".to_vec())));
        assert!(!has_controls(&Secret::new("pässwörd".as_bytes().to_vec())));
    }

    #[test]
    fn writes_the_helper_and_wrappers() {
        let dir = tempfile::tempdir().unwrap();
        let si = crate::shell::ShellIntegration::install(dir.path()).unwrap();
        let askpass = Askpass::install(
            &AskpassConfig::default(),
            dir.path(),
            Path::new("/opt/x y/gudo-hook"),
        );
        let helper = askpass.helper.clone().unwrap();
        let script = std::fs::read_to_string(&helper).unwrap();
        assert!(
            script.contains("exec '/opt/x y/gudo-hook' askpass \"$@\""),
            "{script}"
        );
        let zshenv = std::fs::read_to_string(dir.path().join("askpass/zsh/.zshenv")).unwrap();
        assert!(zshenv.contains("shell-integration/zsh/.zshenv"));
        assert!(zshenv.contains("command sudo -A \"$@\""));

        let mut inj = si
            .injection(Path::new("/bin/zsh"), |_| None)
            .expect("zsh is integrated");
        askpass.wrap_injection(&mut inj);
        let zdotdir = &inj.env.iter().find(|(k, _)| k == "ZDOTDIR").unwrap().1;
        assert!(zdotdir.ends_with("askpass/zsh"), "{zdotdir}");

        let off = Askpass::install(
            &AskpassConfig {
                enabled: false,
                ..AskpassConfig::default()
            },
            dir.path(),
            Path::new("/x"),
        );
        assert!(off.helper.is_none());
    }
}
