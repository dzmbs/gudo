#!/usr/bin/env bash
# Ends a demo host made by setup.sh. Run as root on the host.
#
#   ./teardown.sh revoke   revoke every pending ticket and unpair every device; the box stays
#   ./teardown.sh all      also remove the service, the reviewer user, its home and the binary
#
# The firewall, SSH and upgrade settings stay. Deleting the server is the real teardown.
set -euo pipefail

user_name="reviewer"
service_name="gudo-demo"
install_dir="/usr/local/bin"
output_dir="/root/gudo-demo"
image_dir="/var/lib/gudo-demo"
home_dir="/home/$user_name"
state_dir="$home_dir/.local/state/gudo"

die() {
    echo "error: $*" >&2
    exit 1
}

mode="${1:-}"
[[ "$mode" == "revoke" || "$mode" == "all" ]] || die "usage: $0 revoke|all"
[[ $EUID -eq 0 ]] || die "run as root"

as_reviewer() {
    runuser -u "$user_name" -- env HOME="$home_dir" "$install_dir/gudo-hostd" \
        --state-dir "$state_dir" "$@"
}

if id "$user_name" >/dev/null 2>&1 && [[ -x "$install_dir/gudo-hostd" && -d "$state_dir" ]]; then
    echo "==> revoking pending tickets"
    as_reviewer pair --revoke all
    echo "==> unpairing every device"
    as_reviewer devices --json | python3 -c '
import json, sys
for device in json.load(sys.stdin):
    print(device["device"])
' | while read -r device; do
        as_reviewer unpair "$device"
    done
fi
rm -f "$output_dir"/ticket.json "$output_dir"/pairing-*.{png,txt} "$output_dir"/review-notes.txt

[[ "$mode" == "all" ]] || exit 0

echo "==> removing the service"
systemctl disable --now "$service_name".service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/"$service_name".service /etc/systemd/system/"$service_name".slice
systemctl daemon-reload

echo "==> removing the $user_name user and home"
pkill -KILL -u "$user_name" 2>/dev/null || true
if mountpoint -q "$home_dir"; then
    umount "$home_dir"
fi
sed -i "\\|^$image_dir/$user_name-home.ext4 |d" /etc/fstab
rm -rf "$image_dir"
if id "$user_name" >/dev/null 2>&1; then
    userdel "$user_name"
fi
rm -rf "$home_dir"
for deny in /etc/cron.deny /etc/at.deny; do
    if [[ -f "$deny" ]]; then
        sed -i "/^$user_name\$/d" "$deny"
    fi
done

echo "==> removing gudo-hostd"
rm -f "$install_dir/gudo-hostd" "$install_dir/gudo"
rmdir "$output_dir" 2>/dev/null || true
echo "done; the firewall, SSH and upgrade settings are unchanged"
