//! Where to connect: a destination host and the jump hosts in front of it.

use std::fmt;
use std::str::FromStr;

use crate::SshError;

/// The default SSH port.
pub const DEFAULT_PORT: u16 = 22;

/// One SSH server to authenticate to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSpec {
    /// Name or address to dial (for a hop behind a jump host, as seen from that jump host).
    pub host: String,
    pub port: u16,
    pub user: String,
    /// Name to look the host key up under instead of `host` (`HostKeyAlias`).
    pub host_key_alias: Option<String>,
}

impl HostSpec {
    /// A host on port 22 with no key alias.
    pub fn new(host: impl Into<String>, user: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            port: DEFAULT_PORT,
            user: user.into(),
            host_key_alias: None,
        }
    }

    #[must_use]
    pub fn with_port(mut self, port: u16) -> Self {
        self.port = port;
        self
    }

    /// The name host keys are stored under: the alias if set, else `host`.
    pub fn key_host(&self) -> &str {
        self.host_key_alias.as_deref().unwrap_or(&self.host)
    }
}

impl fmt::Display for HostSpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        if self.port == DEFAULT_PORT {
            write!(f, "{}@{host}", self.user)
        } else {
            write!(f, "{}@{host}:{}", self.user, self.port)
        }
    }
}

/// A destination plus the jump hosts to reach it through (`ProxyJump`), outermost first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// Jump hosts: `jumps[0]` is dialled directly, each later one through the previous.
    pub jumps: Vec<HostSpec>,
    pub host: HostSpec,
}

impl Target {
    /// A destination with no jump hosts.
    pub fn direct(host: HostSpec) -> Self {
        Self {
            jumps: Vec::new(),
            host,
        }
    }

    /// Every server in dialling order, the destination last.
    pub fn hops(&self) -> impl Iterator<Item = &HostSpec> {
        self.jumps.iter().chain(std::iter::once(&self.host))
    }
}

impl fmt::Display for Target {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.host)?;
        if !self.jumps.is_empty() {
            let jumps: Vec<String> = self.jumps.iter().map(ToString::to_string).collect();
            write!(f, " via {}", jumps.join(","))?;
        }
        Ok(())
    }
}

/// A parsed `[ssh://][user@]host[:port]` destination, as typed or as in `ProxyJump`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Destination {
    pub user: Option<String>,
    /// Host name, alias or address (IPv6 without brackets).
    pub host: String,
    pub port: Option<u16>,
}

impl FromStr for Destination {
    type Err = SshError;

    /// Parses `host`, `user@host`, `host:port`, `[v6]:port` and the `ssh://` URL form.
    ///
    /// # Examples
    ///
    /// ```
    /// let destination: ssh::Destination = "me@box:2222".parse().unwrap();
    /// assert_eq!(destination.port, Some(2222));
    /// ```
    fn from_str(input: &str) -> Result<Self, Self::Err> {
        let bad = || SshError::Config(format!("bad destination {input:?}"));
        let input = input.trim();
        let (is_url, rest) = match input.strip_prefix("ssh://") {
            Some(rest) => (true, rest.trim_end_matches('/')),
            None => (false, input),
        };
        let (user, hostport) = match rest.rsplit_once('@') {
            Some((user, hostport)) if !user.is_empty() => (Some(user.to_owned()), hostport),
            Some(_) => return Err(bad()),
            None => (None, rest),
        };
        let (host, port) = if let Some(v6) = hostport.strip_prefix('[') {
            let (host, after) = v6.split_once(']').ok_or_else(bad)?;
            let port = match after.strip_prefix(':') {
                Some(port) => Some(port.parse().map_err(|_| bad())?),
                None if after.is_empty() => None,
                None => return Err(bad()),
            };
            (host.to_owned(), port)
        } else if hostport.matches(':').count() == 1 {
            let (host, port) = hostport.split_once(':').ok_or_else(bad)?;
            (host.to_owned(), Some(port.parse().map_err(|_| bad())?))
        } else if hostport.contains(':') && !is_url {
            // A bare IPv6 address.
            (hostport.to_owned(), None)
        } else {
            (hostport.to_owned(), None)
        };
        if host.is_empty() || host.contains(char::is_whitespace) {
            return Err(bad());
        }
        Ok(Self { user, host, port })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(input: &str) -> (Option<String>, String, Option<u16>) {
        let destination: Destination = input.parse().unwrap();
        (destination.user, destination.host, destination.port)
    }

    #[test]
    fn destinations() {
        assert_eq!(parts("box"), (None, "box".into(), None));
        assert_eq!(parts("me@box"), (Some("me".into()), "box".into(), None));
        assert_eq!(
            parts("me@box:2222"),
            (Some("me".into()), "box".into(), Some(2222))
        );
        assert_eq!(
            parts("ssh://me@box:22/"),
            (Some("me".into()), "box".into(), Some(22))
        );
        assert_eq!(parts("[::1]:2200"), (None, "::1".into(), Some(2200)));
        assert_eq!(parts("fe80::1"), (None, "fe80::1".into(), None));
        assert_eq!(
            parts("first.last@corp@bastion"),
            (Some("first.last@corp".into()), "bastion".into(), None)
        );
        assert!("@box".parse::<Destination>().is_err());
        assert!("box:port".parse::<Destination>().is_err());
        assert!("".parse::<Destination>().is_err());
    }

    #[test]
    fn display() {
        let target = Target {
            jumps: vec![HostSpec::new("bastion", "a").with_port(2222)],
            host: HostSpec::new("10.0.0.5", "b"),
        };
        assert_eq!(target.to_string(), "b@10.0.0.5 via a@bastion:2222");
    }
}
