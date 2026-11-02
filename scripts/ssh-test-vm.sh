#!/usr/bin/env bash
# Prepares an OrbStack Linux VM as the sshd for `crates/ssh` integration tests (docs/SSH.md §5).
#
#   scripts/ssh-test-vm.sh [machine]        # default machine: un-linux
#
# Creates a dedicated user `untest` (password + test key, lingering so its systemd --user
# instance runs without a login), installs openssh-server, and writes the environment the
# tests read to target/ssh-test/env. Source that file, then run the ignored tests.
set -euo pipefail

machine="${1:-un-linux}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/target/ssh-test"
mkdir -p "$dir"

if [[ ! -f "$dir/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C untest-ed25519 -f "$dir/id_ed25519"
    ssh-keygen -q -t ecdsa -b 256 -N '' -C untest-ecdsa -f "$dir/id_ecdsa"
    ssh-keygen -q -t rsa -b 3072 -N '' -C untest-rsa -f "$dir/id_rsa"
    ssh-keygen -q -t ed25519 -N 'test passphrase' -C untest-encrypted -f "$dir/id_ed25519_enc"
fi
if [[ ! -f "$dir/password" ]]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 >"$dir/password"
fi

keys="$(cat "$dir"/id_ed25519.pub "$dir"/id_ecdsa.pub "$dir"/id_rsa.pub "$dir"/id_ed25519_enc.pub)"
password="$(cat "$dir/password")"

orb -m "$machine" sudo bash -s -- "$password" "$keys" <<'EOF'
set -euo pipefail
password="$1"
keys="$2"
export DEBIAN_FRONTEND=noninteractive
if ! command -v sshd >/dev/null || ! command -v tmux >/dev/null; then
    apt-get update -qq
    apt-get install -y -qq openssh-server tmux >/dev/null
fi
systemctl enable --now ssh >/dev/null 2>&1
# The tests open many connections in parallel; OpenSSH's default MaxStartups (10:30:100)
# would randomly drop some of them before authentication.
echo 'MaxStartups 200:30:400' >/etc/ssh/sshd_config.d/50-gudo-test.conf
systemctl reload ssh
id untest >/dev/null 2>&1 || useradd -m -s /bin/bash untest
echo "untest:$password" | chpasswd
install -d -m 700 -o untest -g untest /home/untest/.ssh
printf '%s\n' "$keys" >/home/untest/.ssh/authorized_keys
chown untest:untest /home/untest/.ssh/authorized_keys
chmod 600 /home/untest/.ssh/authorized_keys
loginctl enable-linger untest
EOF

# The static daemon build the bootstrap tests install (stripped, as the app would ship it).
arch="$(orb -m "$machine" uname -m)"
mkdir -p "$dir/bin"
(cd "$root" && cargo zigbuild --release -p hostd --target "$arch-unknown-linux-musl")
orb -m "$machine" strip -o "$dir/bin/gudo-hostd-$arch-linux" \
    "$root/target/$arch-unknown-linux-musl/release/gudo-hostd"

ip="$(orb list | awk -v m="$machine" '$1 == m { print $NF }')"
cat >"$dir/env" <<EOF
export GUDO_SSH_TEST_HOST=$ip
export GUDO_SSH_TEST_USER=untest
export GUDO_SSH_TEST_PASSWORD=$password
export GUDO_SSH_TEST_KEYS=$dir
EOF
echo "wrote $dir/env (host $ip, user untest)"
