//! What people type or paste into a host field: an alias, `user@host:port`, an `ssh://`
//! URL, or a whole `ssh -p 2222 -i key user@host` command line.

use std::str::FromStr;

use crate::target::Destination;

/// ssh(1) options that take an argument (its getopt string, minus the flags).
const OPTIONS_WITH_ARGUMENT: &str = "BbcDEeFIiJLlmOoPpQRSWw";

/// A host field's text, split into what it names. Values given as options (`-l`, `-p`)
/// win over those in the destination, as in ssh(1).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostInput {
    pub user: Option<String>,
    /// Host name, address or ssh_config alias (IPv6 without brackets).
    pub host: String,
    pub port: Option<u16>,
    /// `-i` (the first one).
    pub identity_file: Option<String>,
    /// `-J` or `-o ProxyJump=`, as written (`a,b@c:22`).
    pub proxy_jump: Option<String>,
}

impl HostInput {
    /// Parses a host field.
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Config`](crate::SshError::Config) when no destination can be
    /// found or a port is not a number.
    ///
    /// # Examples
    ///
    /// ```
    /// let input = ssh::HostInput::parse("ssh -p 2222 -i ~/.ssh/work root@10.0.0.5").unwrap();
    /// assert_eq!(input.user.as_deref(), Some("root"));
    /// assert_eq!(input.port, Some(2222));
    /// assert_eq!(input.identity_file.as_deref(), Some("~/.ssh/work"));
    /// ```
    pub fn parse(text: &str) -> Result<Self, crate::SshError> {
        let words = shell_words(text.trim());
        let is_command = words
            .first()
            .is_some_and(|first| first == "ssh" || first.ends_with("/ssh"));
        if !is_command {
            return match words.as_slice() {
                [single] => Self::from_destination(single),
                _ => Err(crate::SshError::Config(format!("bad destination {text:?}"))),
            };
        }
        Self::from_command(&words[1..])
    }

    fn from_destination(text: &str) -> Result<Self, crate::SshError> {
        let destination = Destination::from_str(text)?;
        Ok(Self {
            user: destination.user,
            host: destination.host,
            port: destination.port,
            identity_file: None,
            proxy_jump: None,
        })
    }

    fn from_command(words: &[String]) -> Result<Self, crate::SshError> {
        let mut options = Self::default();
        let mut words = words.iter();
        let mut destination = None;
        let mut options_ended = false;
        while let Some(word) = words.next() {
            match word.strip_prefix('-') {
                Some("-") if !options_ended => options_ended = true,
                Some(flags) if !options_ended && !flags.is_empty() => {
                    options.apply_flags(flags, &mut words)?;
                }
                _ if destination.is_none() => destination = Some(word),
                // The remote command.
                _ => break,
            }
        }
        let destination = destination
            .ok_or_else(|| crate::SshError::Config("the ssh command names no host".into()))?;
        let parsed = Self::from_destination(destination)?;
        Ok(Self {
            user: options.user.or(parsed.user),
            host: if options.host.is_empty() {
                parsed.host
            } else {
                options.host
            },
            port: options.port.or(parsed.port),
            identity_file: options.identity_file,
            proxy_jump: options.proxy_jump,
        })
    }

    /// One `-xyz` word: flags, then at most one option that takes an argument (attached,
    /// as in `-p2222`, or the next word).
    fn apply_flags<'a>(
        &mut self,
        flags: &str,
        words: &mut impl Iterator<Item = &'a String>,
    ) -> Result<(), crate::SshError> {
        let Some((index, flag)) = flags
            .char_indices()
            .find(|(_, flag)| OPTIONS_WITH_ARGUMENT.contains(*flag))
        else {
            return Ok(());
        };
        let attached = &flags[index + flag.len_utf8()..];
        let argument = if attached.is_empty() {
            words.next().cloned().unwrap_or_default()
        } else {
            attached.to_owned()
        };
        match flag {
            'l' => {
                self.user.get_or_insert(argument);
            }
            'p' => {
                let port = parse_port(&argument)?;
                self.port.get_or_insert(port);
            }
            'i' => {
                self.identity_file.get_or_insert(argument);
            }
            'J' => {
                self.proxy_jump.get_or_insert(argument);
            }
            'o' => self.apply_option(&argument)?,
            _ => {}
        }
        Ok(())
    }

    /// `-o Key=Value` / `-o "Key Value"` for the keys a host field can show.
    fn apply_option(&mut self, option: &str) -> Result<(), crate::SshError> {
        let (key, value) = option
            .split_once(['=', ' ', '\t'])
            .map(|(key, value)| (key.trim(), value.trim().trim_start_matches('=').trim()))
            .unwrap_or((option, ""));
        if value.is_empty() {
            return Ok(());
        }
        match key.to_ascii_lowercase().as_str() {
            "user" => {
                self.user.get_or_insert_with(|| value.to_owned());
            }
            "port" => {
                let port = parse_port(value)?;
                self.port.get_or_insert(port);
            }
            "hostname" => {
                if self.host.is_empty() {
                    value.clone_into(&mut self.host);
                }
            }
            "identityfile" => {
                self.identity_file.get_or_insert_with(|| value.to_owned());
            }
            "proxyjump" => {
                self.proxy_jump.get_or_insert_with(|| value.to_owned());
            }
            _ => {}
        }
        Ok(())
    }
}

fn parse_port(text: &str) -> Result<u16, crate::SshError> {
    text.parse()
        .map_err(|_| crate::SshError::Config(format!("bad port {text:?} in the ssh command")))
}

/// Splits like a POSIX shell for the cases people paste: whitespace, single and double
/// quotes, backslash escapes.
fn shell_words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_word = true;
                word.extend(chars.by_ref().take_while(|&c| c != '\''));
            }
            '"' => {
                in_word = true;
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => word.extend(chars.next()),
                        c => word.push(c),
                    }
                }
            }
            '\\' => {
                in_word = true;
                word.extend(chars.next());
            }
            c if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            c => {
                in_word = true;
                word.push(c);
            }
        }
    }
    if in_word {
        words.push(word);
    }
    words
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> HostInput {
        HostInput::parse(text).unwrap()
    }

    #[test]
    fn plain_destinations() {
        assert_eq!(
            parse("box"),
            HostInput {
                host: "box".into(),
                ..HostInput::default()
            }
        );
        let input = parse("  root@62.238.108.86 ");
        assert_eq!(
            (input.user.as_deref(), input.host.as_str(), input.port),
            (Some("root"), "62.238.108.86", None)
        );
        let input = parse("deploy@box.example.com:2222");
        assert_eq!(
            (input.user.as_deref(), input.port),
            (Some("deploy"), Some(2222))
        );
        let input = parse("ssh://me@[fe80::1]:22");
        assert_eq!((input.host.as_str(), input.port), ("fe80::1", Some(22)));
    }

    #[test]
    fn pasted_commands() {
        let input = parse("ssh -p 2222 -i ~/.ssh/work root@10.0.0.5");
        assert_eq!(input.user.as_deref(), Some("root"));
        assert_eq!(input.host, "10.0.0.5");
        assert_eq!(input.port, Some(2222));
        assert_eq!(input.identity_file.as_deref(), Some("~/.ssh/work"));

        let input = parse("/usr/bin/ssh -At -p2200 -J admin@bastion:22,hop2 me@inner uptime");
        assert_eq!(input.port, Some(2200));
        assert_eq!(input.proxy_jump.as_deref(), Some("admin@bastion:22,hop2"));
        assert_eq!(input.host, "inner");

        let input = parse("ssh -l alice -o Port=2022 -o 'User bob' -v box");
        assert_eq!(input.user.as_deref(), Some("alice"));
        assert_eq!(input.port, Some(2022));

        let input = parse("ssh -l alice bob@box:2200 -p 9 uptime -p 10");
        assert_eq!(input.user.as_deref(), Some("alice"));
        assert_eq!(input.port, Some(9));

        let input = parse(r#"ssh -i "/Users/me/My Keys/id" -o ProxyJump=jump box"#);
        assert_eq!(input.identity_file.as_deref(), Some("/Users/me/My Keys/id"));
        assert_eq!(input.proxy_jump.as_deref(), Some("jump"));

        let input = parse("ssh -4 -- box");
        assert_eq!(input.host, "box");
    }

    #[test]
    fn rejects() {
        assert!(HostInput::parse("").is_err());
        assert!(HostInput::parse("two words").is_err());
        assert!(HostInput::parse("ssh -p 22").is_err());
        assert!(HostInput::parse("ssh -p port box").is_err());
        assert!(HostInput::parse("box:port").is_err());
    }
}
