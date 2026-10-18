//! `~/.ssh/config` parsing with OpenSSH semantics (ssh_config(5)).
//!
//! Supported: `Host` patterns (`*`, `?`, `!negation`, several per line), `Match` with `all`,
//! `host`, `originalhost` and `user` (other criteria never match), `Include` (globs,
//! relative to `~/.ssh`, nested up to 16 deep, scoped to the enclosing block like OpenSSH),
//! `key value` and `key=value` forms, double-quoted arguments, and the keys `HostName`,
//! `User`, `Port`, `IdentityFile`, `ProxyJump`, `ServerAliveInterval`,
//! `ServerAliveCountMax`, `ConnectTimeout`, `HostKeyAlias`, `ForwardAgent` and `SetEnv`.
//! The first value obtained for a key wins (`IdentityFile` and `SetEnv` accumulate).
//! Other keys in a matching block are reported in [`HostConfig::ignored`].

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::target::{DEFAULT_PORT, Destination, HostSpec, Target};
use crate::{SshError, wildcard};

const MAX_INCLUDE_DEPTH: usize = 16;
const MAX_JUMPS: usize = 16;

/// A parsed ssh_config: an ordered list of directives, each guarded by the `Host`/`Match`
/// condition in effect where it appeared (includes already expanded).
#[derive(Debug, Clone, Default)]
pub struct SshConfig {
    conditions: Vec<Condition>,
    directives: Vec<Directive>,
    warnings: Vec<String>,
    home: Option<PathBuf>,
    local_user: Option<String>,
}

#[derive(Debug, Clone)]
enum Condition {
    Always,
    Host(Vec<Pattern>),
    Match(Vec<Criterion>),
}

#[derive(Debug, Clone)]
struct Pattern {
    negated: bool,
    glob: String,
}

#[derive(Debug, Clone)]
enum Criterion {
    All,
    Host(Vec<Pattern>),
    OriginalHost(Vec<Pattern>),
    User(Vec<Pattern>),
    Unsupported(String),
}

#[derive(Debug, Clone)]
struct Directive {
    condition: usize,
    key: String,
    args: Vec<String>,
}

/// Settings for one host after applying every matching block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostConfig {
    /// The name that was looked up.
    pub alias: String,
    /// The real host name (`HostName`, `%h` expanded), else the alias.
    pub host_name: String,
    /// `User`, if set.
    pub user: Option<String>,
    /// `Port`, else 22.
    pub port: u16,
    /// `IdentityFile`s in order, `~` and `%d %u %h %r %p %%` expanded.
    pub identity_files: Vec<String>,
    /// `ProxyJump` hops in order (empty for none).
    pub proxy_jump: Vec<Destination>,
    /// `ServerAliveInterval` (0 disables, as in OpenSSH).
    pub server_alive_interval: Option<Duration>,
    /// `ServerAliveCountMax`.
    pub server_alive_count_max: Option<u32>,
    /// `ConnectTimeout`.
    pub connect_timeout: Option<Duration>,
    /// `HostKeyAlias`.
    pub host_key_alias: Option<String>,
    /// `ForwardAgent yes`.
    pub forward_agent: bool,
    /// `SetEnv` pairs.
    pub set_env: Vec<(String, String)>,
    /// Keys set for this host that this crate does not apply (shown as "ignored").
    pub ignored: Vec<String>,
}

impl SshConfig {
    /// Parses config text. `Include` lines are not followed (there is no file system to
    /// read them from); each one is recorded in [`warnings`](Self::warnings).
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Config`] for a malformed line (unterminated quote, `Host` with
    /// no pattern).
    ///
    /// # Examples
    ///
    /// ```
    /// let config = ssh::SshConfig::parse("Host box\n  HostName 10.0.0.5\n  Port 2222\n").unwrap();
    /// let host = config.resolve("box");
    /// assert_eq!((host.host_name.as_str(), host.port), ("10.0.0.5", 2222));
    /// ```
    pub fn parse(text: &str) -> Result<Self, SshError> {
        let mut config = Self::default();
        config.read_text(text, 0, None, 0)?;
        Ok(config)
    }

    /// Reads a config file, following `Include`s relative to `home/.ssh`.
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Io`] if `path` cannot be read (missing includes are skipped, as
    /// in OpenSSH) and [`SshError::Config`] for malformed lines.
    pub fn load(path: impl AsRef<Path>, home: Option<PathBuf>) -> Result<Self, SshError> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path)
            .map_err(|e| SshError::io(format!("reading {}", path.display()), e))?;
        let mut config = Self {
            home,
            ..Self::default()
        };
        config.read_text(&text, 0, Some(path), 0)?;
        Ok(config)
    }

    /// `~/.ssh/config` for the current user, or an empty config if there is none.
    ///
    /// # Errors
    ///
    /// As [`load`](Self::load), except that a missing file is not an error.
    pub fn load_default() -> Result<Self, SshError> {
        let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
            return Ok(Self::default());
        };
        let path = home.join(".ssh/config");
        if !path.exists() {
            return Ok(Self {
                home: Some(home),
                ..Self::default()
            });
        }
        Self::load(path, Some(home))
    }

    /// Sets the local user name used by `%u` and `Match localuser`-free defaults.
    #[must_use]
    pub fn with_local_user(mut self, user: impl Into<String>) -> Self {
        self.local_user = Some(user.into());
        self
    }

    /// Sets the home directory `~` and `%d` expand to (for text from [`parse`](Self::parse),
    /// which has none).
    #[must_use]
    pub fn with_home(mut self, home: impl Into<PathBuf>) -> Self {
        self.home = Some(home.into());
        self
    }

    /// Problems found while parsing (unfollowed or unreadable includes).
    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }

    /// The concrete host aliases named on `Host` lines (no wildcards, no negations), in
    /// file order without duplicates: the hosts to offer when importing the config.
    ///
    /// # Examples
    ///
    /// ```
    /// let config = ssh::SshConfig::parse("Host box db *.corp !evil\nHost box\n").unwrap();
    /// assert_eq!(config.host_aliases(), ["box", "db"]);
    /// ```
    pub fn host_aliases(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for condition in &self.conditions {
            let Condition::Host(patterns) = condition else {
                continue;
            };
            for p in patterns {
                let concrete = !p.negated && !p.glob.contains(['*', '?']);
                if concrete && !out.contains(&p.glob) {
                    out.push(p.glob.clone());
                }
            }
        }
        out
    }

    fn read_text(
        &mut self,
        text: &str,
        mut condition: usize,
        path: Option<&Path>,
        depth: usize,
    ) -> Result<(), SshError> {
        if self.conditions.is_empty() {
            self.conditions.push(Condition::Always);
        }
        let origin = path.map_or_else(|| "config".to_owned(), |p| p.display().to_string());
        for (n, line) in text.lines().enumerate() {
            let at = || format!("{origin}:{}", n + 1);
            let Some((key, args)) =
                split_line(line).map_err(|e| SshError::Config(format!("{}: {e}", at())))?
            else {
                continue;
            };
            match key.as_str() {
                "host" => {
                    if args.is_empty() {
                        return Err(SshError::Config(format!("{}: Host needs a pattern", at())));
                    }
                    self.conditions.push(Condition::Host(
                        args.iter().flat_map(|a| patterns(a)).collect(),
                    ));
                    condition = self.conditions.len() - 1;
                }
                "match" => {
                    let criteria = parse_match(&args)
                        .map_err(|e| SshError::Config(format!("{}: {e}", at())))?;
                    for c in &criteria {
                        if let Criterion::Unsupported(name) = c {
                            self.warnings.push(format!(
                                "{}: Match {name} is not supported; the block never matches",
                                at()
                            ));
                        }
                    }
                    self.conditions.push(Condition::Match(criteria));
                    condition = self.conditions.len() - 1;
                }
                "include" => {
                    for arg in &args {
                        self.include(arg, condition, depth)?;
                    }
                }
                _ => self.directives.push(Directive {
                    condition,
                    key,
                    args,
                }),
            }
        }
        Ok(())
    }

    fn include(&mut self, arg: &str, condition: usize, depth: usize) -> Result<(), SshError> {
        if depth >= MAX_INCLUDE_DEPTH {
            return Err(SshError::Config(format!(
                "Include nested too deeply at {arg}"
            )));
        }
        let Some(home) = self.home.clone() else {
            self.warnings.push(format!("Include {arg} not followed"));
            return Ok(());
        };
        let expanded = expand_tilde(arg, &home);
        let pattern = if Path::new(&expanded).is_absolute() {
            PathBuf::from(expanded)
        } else {
            home.join(".ssh").join(expanded)
        };
        let mut files = glob(&pattern);
        files.sort();
        for file in files {
            match std::fs::read_to_string(&file) {
                // A Host or Match line in the included file replaces the condition for the
                // rest of that file only; the caller's condition resumes after it (OpenSSH).
                Ok(text) => self.read_text(&text, condition, Some(&file), depth + 1)?,
                Err(e) => self
                    .warnings
                    .push(format!("Include {}: {e}", file.display())),
            }
        }
        Ok(())
    }

    /// Applies every block matching `alias` (first value wins).
    pub fn resolve(&self, alias: &str) -> HostConfig {
        let original = alias.to_ascii_lowercase();
        let mut values: HashMap<&str, &[String]> = HashMap::new();
        let mut identity: Vec<&str> = Vec::new();
        let mut set_env: Vec<(String, String)> = Vec::new();
        let mut ignored: Vec<String> = Vec::new();
        let mut matched: Vec<Option<bool>> = vec![None; self.conditions.len()];
        for d in &self.directives {
            let is_match = *matched[d.condition].get_or_insert_with(|| {
                let host_name = values
                    .get("hostname")
                    .and_then(|v| v.first())
                    .map_or_else(|| original.clone(), |h| h.replace("%h", &original));
                let user = values
                    .get("user")
                    .and_then(|v| v.first())
                    .map(String::as_str)
                    .or(self.local_user.as_deref());
                self.conditions[d.condition].matches(&original, &host_name, user)
            });
            if !is_match {
                continue;
            }
            match d.key.as_str() {
                "identityfile" => identity.extend(d.args.iter().map(String::as_str)),
                "setenv" => {
                    set_env.extend(d.args.iter().filter_map(|a| {
                        a.split_once('=').map(|(k, v)| (k.to_owned(), v.to_owned()))
                    }))
                }
                "hostname"
                | "user"
                | "port"
                | "proxyjump"
                | "serveraliveinterval"
                | "serveralivecountmax"
                | "connecttimeout"
                | "hostkeyalias"
                | "forwardagent" => {
                    values.entry(d.key.as_str()).or_insert(&d.args);
                }
                other => {
                    if !ignored.iter().any(|k| k == other) {
                        ignored.push(other.to_owned());
                    }
                }
            }
        }
        let first = |key: &str| values.get(key).and_then(|v| v.first()).map(String::as_str);
        let host_name = first("hostname")
            .map_or_else(|| alias.to_owned(), |h| expand_percent(h, &[('h', alias)]));
        let user = first("user").map(ToOwned::to_owned);
        let port = first("port")
            .and_then(|p| p.parse().ok())
            .unwrap_or(DEFAULT_PORT);
        let home = self
            .home
            .as_ref()
            .map(|h| h.display().to_string())
            .unwrap_or_default();
        let port_s = port.to_string();
        let local_user = self.local_user.clone().unwrap_or_default();
        let remote_user = user.clone().unwrap_or_else(|| local_user.clone());
        let tokens = [
            ('d', home.as_str()),
            ('u', local_user.as_str()),
            ('h', host_name.as_str()),
            ('n', alias),
            ('r', remote_user.as_str()),
            ('p', port_s.as_str()),
        ];
        let identity_files = identity
            .iter()
            .map(|f| {
                let f = expand_percent(f, &tokens);
                match &self.home {
                    Some(h) => expand_tilde(&f, h),
                    None => f,
                }
            })
            .collect();
        let proxy_jump = match values.get("proxyjump") {
            Some(args) if !args.first().is_some_and(|a| a.eq_ignore_ascii_case("none")) => args
                .iter()
                .flat_map(|a| a.split(','))
                .filter(|s| !s.is_empty())
                .filter_map(|s| expand_percent(s, &tokens).parse().ok())
                .collect(),
            _ => Vec::new(),
        };
        let seconds = |key: &str| {
            first(key)
                .and_then(|v| v.parse().ok())
                .map(Duration::from_secs)
        };
        HostConfig {
            alias: alias.to_owned(),
            host_name,
            user,
            port,
            identity_files,
            proxy_jump,
            server_alive_interval: seconds("serveraliveinterval"),
            server_alive_count_max: first("serveralivecountmax").and_then(|v| v.parse().ok()),
            connect_timeout: seconds("connecttimeout"),
            host_key_alias: first("hostkeyalias").map(ToOwned::to_owned),
            forward_agent: first("forwardagent").is_some_and(|v| v.eq_ignore_ascii_case("yes")),
            set_env,
            ignored,
        }
    }

    /// Builds the full route to `destination` (`[user@]alias[:port]`): the alias resolved
    /// through this config, and every `ProxyJump` hop resolved too. The first jump's own
    /// `ProxyJump` is followed recursively (like `ssh -J`); later hops' are not.
    ///
    /// `default_user` is used where neither the destination nor the config names a user.
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Config`] for an unparsable destination or a jump loop.
    ///
    /// # Examples
    ///
    /// ```
    /// let config = ssh::SshConfig::parse(
    ///     "Host inner\n  HostName 10.0.0.5\n  ProxyJump admin@bastion:2222\n",
    /// ).unwrap();
    /// let target = config.target("inner", "me").unwrap();
    /// assert_eq!(target.to_string(), "me@10.0.0.5 via admin@bastion:2222");
    /// ```
    pub fn target(&self, destination: &str, default_user: &str) -> Result<Target, SshError> {
        let dest: Destination = destination.parse()?;
        self.route(&dest, default_user, 0)
    }

    fn route(
        &self,
        dest: &Destination,
        default_user: &str,
        depth: usize,
    ) -> Result<Target, SshError> {
        if depth > MAX_JUMPS {
            return Err(SshError::Config(format!("ProxyJump loop at {}", dest.host)));
        }
        let config = self.resolve(&dest.host);
        let host = self.spec(dest, &config, default_user);
        let mut jumps = Vec::new();
        if let Some((first, rest)) = config.proxy_jump.split_first() {
            let first_route = self.route(first, default_user, depth + 1)?;
            jumps.extend(first_route.jumps);
            jumps.push(first_route.host);
            for hop in rest {
                let hop_config = self.resolve(&hop.host);
                jumps.push(self.spec(hop, &hop_config, default_user));
            }
            if jumps.len() > MAX_JUMPS {
                return Err(SshError::Config(format!(
                    "too many jump hosts for {}",
                    dest.host
                )));
            }
        }
        Ok(Target { jumps, host })
    }

    fn spec(&self, dest: &Destination, config: &HostConfig, default_user: &str) -> HostSpec {
        HostSpec {
            host: config.host_name.clone(),
            port: dest.port.unwrap_or(config.port),
            user: dest
                .user
                .clone()
                .or_else(|| config.user.clone())
                .unwrap_or_else(|| default_user.to_owned()),
            host_key_alias: config.host_key_alias.clone(),
        }
    }
}

impl Condition {
    fn matches(&self, original: &str, host_name: &str, user: Option<&str>) -> bool {
        match self {
            Self::Always => true,
            Self::Host(patterns) => match_list(patterns, original),
            Self::Match(criteria) => criteria.iter().all(|c| match c {
                Criterion::All => true,
                Criterion::Host(p) => match_list(p, &host_name.to_ascii_lowercase()),
                Criterion::OriginalHost(p) => match_list(p, original),
                Criterion::User(p) => user.is_some_and(|u| match_list(p, u)),
                Criterion::Unsupported(_) => false,
            }),
        }
    }
}

/// OpenSSH pattern-list semantics: any negated match vetoes; otherwise any positive match.
fn match_list(patterns: &[Pattern], text: &str) -> bool {
    let mut positive = false;
    for p in patterns {
        if wildcard::matches(&p.glob, text) {
            if p.negated {
                return false;
            }
            positive = true;
        }
    }
    positive
}

fn patterns(arg: &str) -> Vec<Pattern> {
    arg.split(',')
        .filter(|s| !s.is_empty())
        .map(|s| match s.strip_prefix('!') {
            Some(rest) => Pattern {
                negated: true,
                glob: rest.to_ascii_lowercase(),
            },
            None => Pattern {
                negated: false,
                glob: s.to_ascii_lowercase(),
            },
        })
        .collect()
}

fn parse_match(args: &[String]) -> Result<Vec<Criterion>, String> {
    let mut criteria = Vec::new();
    let mut it = args.iter();
    while let Some(word) = it.next() {
        let lower = word.to_ascii_lowercase();
        let (negate, name) = match lower.strip_prefix('!') {
            Some(n) => (true, n.to_owned()),
            None => (false, lower),
        };
        let criterion = match name.as_str() {
            "all" => Criterion::All,
            "canonical" | "final" => Criterion::Unsupported(name),
            "host" | "originalhost" | "user" | "localuser" | "exec" | "localnetwork" | "tagged"
            | "version" | "sessiontype" | "command" => {
                let arg = it
                    .next()
                    .ok_or_else(|| format!("Match {name} needs an argument"))?;
                let p = patterns(arg);
                match name.as_str() {
                    "host" => Criterion::Host(p),
                    "originalhost" => Criterion::OriginalHost(p),
                    "user" => Criterion::User(p),
                    _ => Criterion::Unsupported(name),
                }
            }
            other => return Err(format!("unknown Match criterion {other:?}")),
        };
        criteria.push(if negate {
            // A negated criterion we can evaluate is folded into a single-pattern list.
            match criterion {
                Criterion::All => Criterion::Unsupported("!all".into()),
                Criterion::Host(p) => Criterion::Host(negate_all(p)),
                Criterion::OriginalHost(p) => Criterion::OriginalHost(negate_all(p)),
                Criterion::User(p) => Criterion::User(negate_all(p)),
                u @ Criterion::Unsupported(_) => u,
            }
        } else {
            criterion
        });
    }
    if criteria.is_empty() {
        return Err("Match needs a criterion".into());
    }
    Ok(criteria)
}

/// `!host a,b` matches when neither matches: negate each and add a catch-all positive.
fn negate_all(patterns: Vec<Pattern>) -> Vec<Pattern> {
    let mut out: Vec<Pattern> = patterns
        .into_iter()
        .map(|p| Pattern {
            negated: !p.negated,
            glob: p.glob,
        })
        .collect();
    out.push(Pattern {
        negated: false,
        glob: "*".into(),
    });
    out
}

/// Splits a config line into a lower-cased key and its arguments. `None` for blank lines
/// and comments.
fn split_line(line: &str) -> Result<Option<(String, Vec<String>)>, String> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return Ok(None);
    }
    let key_end = line
        .find(|c: char| c.is_whitespace() || c == '=')
        .unwrap_or(line.len());
    let key = line[..key_end].to_ascii_lowercase();
    let mut rest = line[key_end..].trim_start();
    if let Some(r) = rest.strip_prefix('=') {
        rest = r.trim_start();
    }
    let mut args = Vec::new();
    let mut chars = rest.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
            continue;
        }
        if c == '#' {
            break;
        }
        let mut arg = String::new();
        if c == '"' {
            chars.next();
            loop {
                match chars.next() {
                    Some('"') => break,
                    Some(c) => arg.push(c),
                    None => return Err("unterminated quote".into()),
                }
            }
        } else {
            while let Some(&c) = chars.peek() {
                if c.is_whitespace() {
                    break;
                }
                arg.push(c);
                chars.next();
            }
        }
        args.push(arg);
    }
    Ok(Some((key, args)))
}

fn expand_tilde(path: &str, home: &Path) -> String {
    if path == "~" {
        home.display().to_string()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest).display().to_string()
    } else {
        path.to_owned()
    }
}

fn expand_percent(s: &str, tokens: &[(char, &str)]) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('%') => out.push('%'),
            Some(t) => match tokens.iter().find(|(k, _)| *k == t) {
                Some((_, v)) => out.push_str(v),
                None => {
                    out.push('%');
                    out.push(t);
                }
            },
            None => out.push('%'),
        }
    }
    out
}

/// Expands `*`/`?` in any path component.
fn glob(pattern: &Path) -> Vec<PathBuf> {
    let mut paths = vec![PathBuf::new()];
    for component in pattern.components() {
        let part = component.as_os_str().to_string_lossy();
        if !part.contains(['*', '?']) {
            for p in &mut paths {
                p.push(component);
            }
            continue;
        }
        let mut next = Vec::new();
        for dir in &paths {
            let Ok(entries) = std::fs::read_dir(dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if !name.starts_with('.') && wildcard::matches(&part, &name) {
                    next.push(dir.join(name));
                }
            }
        }
        paths = next;
    }
    paths.retain(|p| p.is_file());
    paths
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
# comment
Host box
  HostName 10.0.0.5
  Port 2222
  User alice
  IdentityFile ~/.ssh/box_key
  ServerAliveInterval 20

Host *.corp !gateway.corp
  User corp_user
  ProxyJump gateway.corp

Host gateway.corp
  HostName gw.example.com
  User=jumper

Host deep
  ProxyJump hop1,bob@hop2:2200

Host hop1
  ProxyJump hop0

Host *
  User default_user
  IdentityFile ~/.ssh/id_%h
  ServerAliveInterval 15
  ServerAliveCountMax 4
  Compression yes
"#;

    fn config() -> SshConfig {
        let mut c = SshConfig::parse(SAMPLE).unwrap();
        c.home = Some(PathBuf::from("/home/me"));
        c
    }

    #[test]
    fn first_value_wins_and_identity_accumulates() {
        let h = config().resolve("box");
        assert_eq!(h.host_name, "10.0.0.5");
        assert_eq!(h.port, 2222);
        assert_eq!(h.user.as_deref(), Some("alice"));
        assert_eq!(h.server_alive_interval, Some(Duration::from_secs(20)));
        assert_eq!(h.server_alive_count_max, Some(4));
        assert_eq!(
            h.identity_files,
            ["/home/me/.ssh/box_key", "/home/me/.ssh/id_10.0.0.5"]
        );
        assert_eq!(h.ignored, ["compression"]);
    }

    #[test]
    fn negation_and_wildcards() {
        let h = config().resolve("db.corp");
        assert_eq!(h.user.as_deref(), Some("corp_user"));
        assert_eq!(h.proxy_jump.len(), 1);
        let g = config().resolve("gateway.corp");
        assert_eq!(g.user.as_deref(), Some("jumper"));
        assert!(g.proxy_jump.is_empty());
        assert_eq!(g.host_name, "gw.example.com");
        let other = config().resolve("unknown");
        assert_eq!(other.user.as_deref(), Some("default_user"));
        assert_eq!(other.port, 22);
        assert_eq!(other.host_name, "unknown");
    }

    #[test]
    fn host_matching_is_case_insensitive() {
        assert_eq!(config().resolve("BOX").host_name, "10.0.0.5");
    }

    #[test]
    fn jump_chain_resolves_through_config() {
        let t = config().target("db.corp", "me").unwrap();
        assert_eq!(t.to_string(), "corp_user@db.corp via jumper@gw.example.com");
        let t = config().target("deep", "me").unwrap();
        // hop1's own ProxyJump (hop0) is followed; hop2's settings come from `Host *`.
        assert_eq!(
            t.to_string(),
            "default_user@deep via default_user@hop0,default_user@hop1,bob@hop2:2200"
        );
        let t = config().target("root@box:22", "me").unwrap();
        assert_eq!(t.host.user, "root");
        assert_eq!(t.host.port, 22);
    }

    #[test]
    fn jump_loop_is_an_error() {
        let c = SshConfig::parse("Host a\n ProxyJump b\nHost b\n ProxyJump a\n").unwrap();
        assert!(c.target("a", "me").is_err());
    }

    #[test]
    fn proxy_jump_none() {
        let c = SshConfig::parse("Host x\n ProxyJump none\nHost *\n ProxyJump j\n").unwrap();
        assert!(c.resolve("x").proxy_jump.is_empty());
        assert_eq!(c.resolve("y").proxy_jump.len(), 1);
    }

    #[test]
    fn hostname_percent_h() {
        let c = SshConfig::parse("Host *.l\n HostName %h.example.com\n").unwrap();
        assert_eq!(c.resolve("a.l").host_name, "a.l.example.com");
    }

    #[test]
    fn match_blocks() {
        let c = SshConfig::parse(
            "Match host 10.*\n User ten\nMatch originalhost foo !host bar\n Port 7\n\
             Match exec \"true\"\n Port 9\nMatch all\n User all\n",
        )
        .unwrap();
        assert_eq!(c.resolve("10.1.2.3").user.as_deref(), Some("ten"));
        assert_eq!(c.resolve("foo").port, 7);
        assert_eq!(c.resolve("foo").user.as_deref(), Some("all"));
        assert_eq!(c.resolve("other").port, 22);
    }

    #[test]
    fn quoting_equals_and_comments() {
        let (k, a) = split_line(r#"  IdentityFile "/path/with space/key" # trailing"#)
            .unwrap()
            .unwrap();
        assert_eq!(
            (k.as_str(), a.as_slice()),
            ("identityfile", &["/path/with space/key".to_owned()][..])
        );
        let (k, a) = split_line("Port=2222").unwrap().unwrap();
        assert_eq!((k.as_str(), a[0].as_str()), ("port", "2222"));
        assert!(split_line("Host \"unterminated").is_err());
        assert!(split_line("   # just a comment").unwrap().is_none());
        assert!(SshConfig::parse("Host\n").is_err());
    }

    #[test]
    fn include_is_scoped_and_globbed() {
        let home = tempfile::tempdir().unwrap();
        let ssh = home.path().join(".ssh");
        std::fs::create_dir_all(ssh.join("conf.d")).unwrap();
        std::fs::write(
            ssh.join("conf.d/a.conf"),
            "User from_include\nHost inc\n HostName included.example\n",
        )
        .unwrap();
        std::fs::write(ssh.join("conf.d/b.conf"), "Host b\n Port 2\n").unwrap();
        std::fs::write(
            ssh.join("config"),
            "Host top\n Include conf.d/*.conf\n Port 1\nHost *\n User fallback\n",
        )
        .unwrap();
        let c = SshConfig::load(ssh.join("config"), Some(home.path().to_owned())).unwrap();
        // Lines before the included file's first Host line inherit `Host top`.
        assert_eq!(c.resolve("top").user.as_deref(), Some("from_include"));
        // After the include, `Host top` is in effect again for `Port 1`.
        assert_eq!(c.resolve("top").port, 1);
        assert_eq!(c.resolve("inc").host_name, "included.example");
        assert_eq!(c.resolve("inc").user.as_deref(), Some("fallback"));
        assert_eq!(c.resolve("b").port, 2);
        assert!(c.warnings().is_empty());
        let text_only = SshConfig::parse("Include foo\n").unwrap();
        assert_eq!(text_only.warnings().len(), 1);
    }

    #[test]
    fn set_env_and_forward_agent() {
        let c = SshConfig::parse("Host *\n SetEnv A=1 B=two\n ForwardAgent yes\n").unwrap();
        let h = c.resolve("x");
        assert!(h.forward_agent);
        assert_eq!(
            h.set_env,
            [("A".into(), "1".into()), ("B".into(), "two".into())]
        );
    }
}
