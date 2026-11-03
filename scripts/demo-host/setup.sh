#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 or 26.04 server (arm64 or x86_64) into a disposable demo host
# for App Review: hardened, one unprivileged `reviewer` user running gudo-hostd under
# resource limits, a few harmless sample files, and a reusable pairing ticket (link + QR PNG).
#
#   scp gudo-hostd-aarch64-linux.gz setup.sh root@<host>:
#   ssh root@<host> ./setup.sh --ssh-from <your IP or CIDR> \
#       --binary ./gudo-hostd-aarch64-linux.gz --sha256 <hex>
#
# Safe to run again: it converges to the same state, keeps a pending ticket unless
# --new-ticket is given, and restarts the daemon on a new binary. See README.md.
set -euo pipefail

user_name="reviewer"
service_name="gudo-demo"
install_dir="/usr/local/bin"
output_dir="/root/gudo-demo"
image_dir="/var/lib/gudo-demo"

ssh_from=""
binary=""
sha256=""
udp_port=7844
ticket_uses=20
ticket_days=30
home_size="8G"
memory_max="2560M"
cpu_quota="150%"
tasks_max=1024
new_ticket=false
assume_yes=false

usage() {
    cat <<EOF
Usage: $0 --ssh-from <IP|CIDR> --binary <path> --sha256 <hex> [options]

Required:
  --ssh-from <IP|CIDR>   the only address allowed to reach SSH (your operator IP)
  --binary <path>        the musl gudo-hostd for this CPU (raw or .gz, as built by
                         cargo xtask build-hostd-linux)
  --sha256 <hex>         SHA-256 of that file as given

Options:
  --udp-port <n>         UDP port the daemon listens on, opened to everyone (default $udp_port)
  --uses <n>             devices the ticket may pair, 2 to 20 (default $ticket_uses)
  --days <n>             days the ticket stays valid, 1 to 30 (default $ticket_days)
  --home-size <size>     size of the reviewer's home file system (default $home_size)
  --memory <size>        memory limit for everything the reviewer runs (default $memory_max)
  --cpu <percent>        CPU limit, 100% is one core (default $cpu_quota)
  --new-ticket           revoke the pending ticket and mint a new one
  --yes                  do not stop when --ssh-from does not cover this SSH session
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

step() {
    echo "==> $*"
}

in_range() {
    [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= $2 && $1 <= $3))
}

# Writes stdin to $1 (mode 0644) unless it already holds exactly that; succeeds only on a change.
write_if_changed() {
    local path="$1" staged
    staged="$(mktemp)" || die "mktemp failed"
    cat >"$staged" || die "staging $path failed"
    if cmp -s "$staged" "$path"; then
        rm -f "$staged"
        return 1
    fi
    install -m 0644 "$staged" "$path" || die "writing $path failed"
    rm -f "$staged"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-from) ssh_from="${2:?}"; shift 2 ;;
        --binary) binary="${2:?}"; shift 2 ;;
        --sha256) sha256="${2:?}"; shift 2 ;;
        --udp-port) udp_port="${2:?}"; shift 2 ;;
        --uses) ticket_uses="${2:?}"; shift 2 ;;
        --days) ticket_days="${2:?}"; shift 2 ;;
        --home-size) home_size="${2:?}"; shift 2 ;;
        --memory) memory_max="${2:?}"; shift 2 ;;
        --cpu) cpu_quota="${2:?}"; shift 2 ;;
        --new-ticket) new_ticket=true; shift ;;
        --yes) assume_yes=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$ssh_from" && -n "$binary" && -n "$sha256" ]] || { usage >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "run as root"
[[ -f "$binary" ]] || die "no such file: $binary"
[[ "$sha256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 takes 64 hex digits"
in_range "$udp_port" 1 65535 || die "--udp-port takes 1 to 65535"
in_range "$ticket_uses" 2 20 || die "--uses takes 2 to 20"
in_range "$ticket_days" 1 30 || die "--days takes 1 to 30"
[[ "$home_size" =~ ^[0-9]+[MG]$ ]] || die "--home-size takes a size such as 8G"
[[ "$memory_max" =~ ^[0-9]+[MG]$ ]] || die "--memory takes a size such as 2560M"
[[ "$cpu_quota" =~ ^[0-9]+%$ ]] || die "--cpu takes a percentage such as 150%"

# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "this script supports Ubuntu only"
case "$(uname -m)" in
    aarch64 | x86_64) ;;
    *) die "unsupported CPU: $(uname -m)" ;;
esac

export DEBIAN_FRONTEND=noninteractive

step "checking the SSH allowlist"
command -v python3 >/dev/null || apt-get install -y -qq python3 >/dev/null
python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$ssh_from" ||
    die "--ssh-from is not an IP address or CIDR"
session_ip="${SSH_CLIENT:-}"
session_ip="${session_ip%% *}"
if [[ -n "$session_ip" ]] && ! python3 -c '
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
' "$session_ip" "$ssh_from"; then
    $assume_yes || die "this SSH session comes from $session_ip, outside --ssh-from $ssh_from; \
the firewall would lock it out (pass --yes if that is intended)"
fi
if [[ ! -s /root/.ssh/authorized_keys ]]; then
    die "/root/.ssh/authorized_keys is empty: add your key before password logins are turned off"
fi

step "verifying the binary"
actual="$(sha256sum "$binary" | cut -d' ' -f1)"
[[ "${actual,,}" == "${sha256,,}" ]] || die "SHA-256 mismatch: got $actual"

step "installing packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ufw fail2ban unattended-upgrades qrencode git python3 htop tree e2fsprogs >/dev/null

step "hardening SSH"
cat >/etc/ssh/sshd_config.d/00-gudo-demo.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
AllowUsers root
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
EOF
install -d -m 0755 /run/sshd
sshd -t
systemctl try-reload-or-restart ssh.service

step "firewall: SSH from $ssh_from only, UDP $udp_port for the daemon"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow from "$ssh_from" to any port 22 proto tcp comment 'operator SSH' >/dev/null
ufw allow "$udp_port"/udp comment 'gudo-hostd QUIC' >/dev/null
for mail_port in 25 465 587; do
    ufw deny out "$mail_port"/tcp comment 'no outbound mail' >/dev/null
done
ufw --force enable >/dev/null
rm -f /etc/ufw/*.rules.[0-9]*

step "fail2ban"
cat >/etc/fail2ban/jail.d/gudo-demo.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $ssh_from
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban

step "unattended security upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat >/etc/apt/apt.conf.d/52gudo-demo <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1

step "kernel settings"
cat >/etc/sysctl.d/60-gudo-demo.conf <<EOF
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
EOF
sysctl -q --system

step "the $user_name home: a $home_size file system of its own"
home_dir="/home/$user_name"
image="$image_dir/$user_name-home.ext4"
mkdir -p "$image_dir"
chmod 700 "$image_dir"
if [[ ! -f "$image" ]]; then
    fallocate -l "$home_size" "$image"
    chmod 600 "$image"
    mkfs.ext4 -q -L reviewer-home -m 0 "$image"
fi
mkdir -p "$home_dir"
fstab_line="$image $home_dir ext4 loop,nosuid,nodev,noatime 0 2"
grep -qF "$image " /etc/fstab || echo "$fstab_line" >>/etc/fstab
mountpoint -q "$home_dir" || mount "$home_dir"

step "the $user_name user: no password, no sudo, no SSH"
if ! id "$user_name" >/dev/null 2>&1; then
    useradd --no-create-home --home-dir "$home_dir" --shell /bin/bash --user-group "$user_name"
fi
for group in sudo adm admin lxd docker; do
    gpasswd -d "$user_name" "$group" >/dev/null 2>&1 || true
done
passwd -l "$user_name" >/dev/null
# Jobs started by cron would run outside the service's sandbox and limits.
for deny in /etc/cron.deny /etc/at.deny; do
    grep -qx "$user_name" "$deny" 2>/dev/null || echo "$user_name" >>"$deny"
done
if [[ ! -f "$home_dir/.bashrc" ]]; then
    rm -rf "$home_dir/lost+found"
    cp -rT /etc/skel "$home_dir"
    chown -R "$user_name:$user_name" "$home_dir"
fi
chown "$user_name:$user_name" "$home_dir"
chmod 700 "$home_dir"
chmod 700 /root

step "sample files"
project="$home_dir/hello-gudo"
if [[ ! -d "$project/.git" ]]; then
    runuser -u "$user_name" -- mkdir -p "$project/src"
    runuser -u "$user_name" -- tee "$project/README.md" >/dev/null <<'EOF'
# Hello, Gudo

A small sample project on a demo computer, to try Gudo with.

- `python3 src/hello.py` prints a greeting.
- `python3 src/primes.py 50` lists the primes up to 50.
- `git log --oneline` shows the history.

Nothing here is private: this computer is set up only for trying the app, and is wiped
afterwards.
EOF
    runuser -u "$user_name" -- tee "$project/src/hello.py" >/dev/null <<'EOF'
import getpass
import platform

print(f"Hello from {platform.node()}, signed in as {getpass.getuser()}.")
EOF
    runuser -u "$user_name" -- git -C "$project" init -q -b main
    runuser -u "$user_name" -- git -C "$project" add .
    runuser -u "$user_name" -- git -C "$project" -c user.name="Gudo Demo" \
        -c user.email=demo@example.invalid commit -q -m "Start the sample project"
    runuser -u "$user_name" -- tee "$project/src/primes.py" >/dev/null <<'EOF'
import sys


def primes(limit):
    found = []
    for number in range(2, limit + 1):
        if all(number % prime for prime in found if prime * prime <= number):
            found.append(number)
    return found


if __name__ == "__main__":
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    print(" ".join(str(prime) for prime in primes(limit)))
EOF
    runuser -u "$user_name" -- git -C "$project" add .
    runuser -u "$user_name" -- git -C "$project" -c user.name="Gudo Demo" \
        -c user.email=demo@example.invalid commit -q -m "List primes"
fi

step "installing gudo-hostd"
staged="$(mktemp)"
trap 'rm -f "$staged"' EXIT
if [[ "$binary" == *.gz ]]; then
    gzip -dc "$binary" >"$staged"
else
    cp "$binary" "$staged"
fi
install -m 0755 -o root -g root "$staged" "$install_dir/gudo-hostd.new"
"$install_dir/gudo-hostd.new" build-info >/dev/null ||
    die "the binary does not run on this machine (wrong CPU?)"
binary_changed=true
if cmp -s "$install_dir/gudo-hostd.new" "$install_dir/gudo-hostd" 2>/dev/null; then
    binary_changed=false
fi
mv -f "$install_dir/gudo-hostd.new" "$install_dir/gudo-hostd"
ln -sfn gudo-hostd "$install_dir/gudo"
"$install_dir/gudo-hostd" build-info

step "the $service_name service, limited to $cpu_quota CPU, $memory_max memory, $tasks_max tasks"
state_dir="$home_dir/.local/state/gudo"
unit_changed=false
write_if_changed /etc/systemd/system/"$service_name".slice <<EOF && unit_changed=true
[Unit]
Description=Gudo demo host limits

[Slice]
CPUQuota=$cpu_quota
MemoryMax=$memory_max
MemorySwapMax=0
TasksMax=$tasks_max
IOWeight=50
EOF
write_if_changed /etc/systemd/system/"$service_name".service <<EOF && unit_changed=true
[Unit]
Description=Gudo demo host daemon
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$home_dir

[Service]
User=$user_name
Group=$user_name
Slice=$service_name.slice
WorkingDirectory=$home_dir
ExecStart=$install_dir/gudo-hostd --state-dir $state_dir run --bind 0.0.0.0:$udp_port
Restart=always
RestartSec=2
KillMode=control-group
UMask=0077
RuntimeDirectory=$service_name
Environment=XDG_RUNTIME_DIR=/run/$service_name
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
ProtectSystem=strict
ProtectHome=tmpfs
BindPaths=$home_dir
TemporaryFileSystem=/tmp:size=512M,mode=1777 /var/tmp:size=256M,mode=1777
PrivateDevices=yes
ProtectProc=invisible
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$service_name".service >/dev/null 2>&1
if $binary_changed || $unit_changed || ! systemctl is-active -q "$service_name".service; then
    systemctl restart "$service_name".service
fi

as_reviewer() {
    runuser -u "$user_name" -- env HOME="$home_dir" "$install_dir/gudo-hostd" \
        --state-dir "$state_dir" "$@"
}

step "pairing ticket"
mkdir -p "$output_dir"
chmod 700 "$output_dir"
ticket_json="$output_dir/ticket.json"
pending_id=""
if [[ -f "$ticket_json" ]]; then
    pending_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["ticket_id"] or "")' \
        "$ticket_json")"
    if [[ -n "$pending_id" ]] && ! as_reviewer pair --list --json | python3 -c '
import json, sys
sys.exit(0 if any(t["id"] == sys.argv[1] for t in json.load(sys.stdin)) else 1)
' "$pending_id"; then
        pending_id=""
    fi
fi
if [[ -n "$pending_id" ]] && $new_ticket; then
    as_reviewer pair --revoke "$pending_id"
    pending_id=""
fi
if [[ -z "$pending_id" ]]; then
    as_reviewer pair --json --wait 60 --uses "$ticket_uses" --minutes $((ticket_days * 1440)) \
        >"$ticket_json.new"
    mv -f "$ticket_json.new" "$ticket_json"
    chmod 600 "$ticket_json"
fi

link="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["ticket"])' "$ticket_json")"
ticket_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["ticket_id"])' \
    "$ticket_json")"
expires="$(python3 -c '
import datetime, json, sys
ms = json.load(open(sys.argv[1]))["expires_unix_ms"]
print(datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
' "$ticket_json")"
printf '%s\n' "$link" >"$output_dir/pairing-link.txt"
# Upper case lets the QR code use alphanumeric mode, as `gudo pair` does; parsing ignores case.
qrencode -o "$output_dir/pairing-qr.png" -s 10 -m 4 "${link^^}"
cat >"$output_dir/review-notes.txt" <<EOF
Gudo connects to a computer the user owns. We set up a demo computer for review.

1. Open Gudo and tap Add Host, then Scan.
2. Scan the attached QR code, or open this link on the device:
   $link
3. Tap Pair. The demo computer opens with a sample project, hello-gudo.

The code works on up to $ticket_uses devices until $expires.
EOF
chmod 600 "$output_dir"/*

qrencode -t ANSIUTF8 -m 2 "${link^^}"
echo
echo "Link:     $link"
echo "Ticket:   $ticket_id, up to $ticket_uses devices, until $expires"
echo "Files:    $output_dir/pairing-qr.png, pairing-link.txt, review-notes.txt"
echo "Fetch:    scp root@<host>:$output_dir/pairing-qr.png ."
echo "Devices:  runuser -u $user_name -- $install_dir/gudo --state-dir $state_dir devices"
echo "Revoke:   ./teardown.sh revoke"
