# Demo host for App Review

App Review needs a computer to pair the iOS app with. These scripts turn a throwaway Ubuntu
server into one: a locked-down box where an unprivileged `reviewer` user runs `gudo-hostd`,
paired through one reusable ticket that several reviewers and devices can use for days.

A reusable ticket is a shared secret: anyone who sees it gets a shell as `reviewer` until it
expires or is revoked (docs/security/transport-identity.md). Use it only on a box like this,
never on a real computer.

## What `setup.sh` does

- SSH: keys only, root only, reachable only from `--ssh-from`. fail2ban on SSH.
- Firewall (ufw): everything in is closed except SSH from that address and the daemon's UDP
  port (default 7844). Outbound mail ports are closed.
- Unattended security upgrades, with a reboot at 04:30 UTC when one needs it.
- `reviewer`: no password, no sudo, no SSH, no cron. Its home is its own file system (default
  8 GB), so it cannot fill the disk.
- `gudo-hostd` as the system service `gudo-demo`, as `reviewer`, in a slice limited to 1.5
  CPUs, 2.5 GB of memory and 1024 tasks. The service sees only the reviewer's home: the rest
  of the system is read-only, `/root` and other homes are hidden, `/tmp` is a small private
  tmpfs, other users' processes are invisible, and nothing can gain privileges.
- A sample git project, `~/hello-gudo`. No coding agents and no credentials are installed.
- A pairing ticket for up to 20 devices for 30 days, written to `/root/gudo-demo/`:
  `pairing-qr.png`, `pairing-link.txt` and `review-notes.txt` (text for App Store Connect).

Running it again changes only what differs, keeps the pending ticket (`--new-ticket` replaces
it) and restarts the daemon only for a new binary or unit.

## Steps

1. Create a small server (for example 2 vCPU, 4 GB, arm64) with Ubuntu 24.04 or 26.04 and
   your SSH key for root.
2. Build the daemon: `cargo xtask build-hostd-linux`, then take
   `apple/build/hostd/gudo-hostd-<arch>-linux.gz` for the server's CPU and note its SHA-256
   (`shasum -a 256 <file>`).
3. Copy and run:

   ```sh
   scp scripts/demo-host/*.sh apple/build/hostd/gudo-hostd-aarch64-linux.gz root@<host>:
   ssh root@<host> ./setup.sh --ssh-from <your IP> \
       --binary ./gudo-hostd-aarch64-linux.gz --sha256 <sha256>
   scp root@<host>:/root/gudo-demo/pairing-qr.png .
   ```

4. Pair a device of your own with the link to check it, then remove it in the app
   (Settings → Devices). Put the QR code and `review-notes.txt` in the review notes.

`./setup.sh --help` lists the limits you can change.

## While the review runs

```sh
ssh root@<host> runuser -u reviewer -- gudo --state-dir /home/reviewer/.local/state/gudo devices
ssh root@<host> runuser -u reviewer -- gudo --state-dir /home/reviewer/.local/state/gudo pair --list
ssh root@<host> journalctl -u gudo-demo -f
```

To update the daemon, run `setup.sh` again with the new binary and checksum. The daemon
cannot replace its own binary on this box, so updates offered in the app fail here.

## Afterwards

- `./teardown.sh revoke` revokes every ticket and unpairs every device; the box stays.
- `./teardown.sh all` also removes the service, the user, its home and the binary.
- Then delete the server. That is the real teardown.
