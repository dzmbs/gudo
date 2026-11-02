# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub:
go to the repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/dzmbs/gudo/security/advisories/new)). This opens a private
advisory that only the maintainers can see.

Include what you can: the affected component (app, host daemon, push relay, relay setup), the
version or commit, steps to reproduce, and what an attacker gains. A proof of concept helps.

We will acknowledge the report, keep you updated while we work on a fix, and credit you in the
advisory unless you ask us not to. Please give us a reasonable time to ship a fix before you
disclose the issue publicly.

Bugs in a dependency (Ghostty, iroh and others) are best reported upstream as well; tell us too
if they affect Gudo.

## Supported versions

Fixes go into the latest release of the apps and of `gudo-hostd`. The app offers hosts an
upgrade to a matching helper.

## Threat model

Gudo's threat model is written down per area in [docs/security/](docs/security/):

- [Transport, identity, pairing and multiplayer](docs/security/transport-identity.md): device
  keys, pairing tickets, grants and roles for guests, revocation, and who can reach the daemon.
- [Terminal output, escape sequences and paste](docs/security/terminal.md): everything printed
  into a pane is treated as attacker-controlled.
- [Agents driving the terminal](docs/security/agent-terminal.md): agents are capable but
  untrusted users; acting on the user's own panes needs the user's yes.
- [Host-local surfaces](docs/security/host-local.md): the hook socket, files and git, port
  forwards, the editor, the state directory, self-upgrade and the CLI.
- [Apple client](docs/security/apple-client.md): device keys in the Keychain and Secure
  Enclave, App Lock, and what a host may and may not do on the device.
- [Hosted services](docs/security/services.md): the push relay, end-to-end sealed push
  payloads, and self-hosted iroh relays.
- [Supply chain](docs/security/supply-chain.md): dependency policy, builds, helper
  distribution and unsafe code.

Each document lists the assets, the attackers it considers, the defences with the tests that
guard them, and the residual risks we accept.
