#!/bin/zsh
# Run by with-daemon.sh: a mount whose server stops answering (SIGSTOP), with a pane and a git
# worktree on it and a client watching repositories (Caps::REPO_STATUS), next to a healthy
# repository. Measures echo, opening tabs and the sidebar for the healthy repository while
# the mount hangs, and agents splitting panes into it (pane_split cwd=…).
#
# The mount is FUSE without root: sshfs to this host (key login to localhost) or bindfs.
# Elsewhere set DEADMOUNT_MOUNT, DEADMOUNT_PID (prints the server's pid once mounted) and
# DEADMOUNT_UNMOUNT, all run with $SRC and $MNT set, e.g. an NFS export whose nfsd you stop.
. "$(dirname $0)/jobs.sh"
SRC=$ROOT/mount-source MNT=$ROOT/mount HEALTHY=$ROOT/healthy
mkdir -p "$SRC" "$MNT" "$HEALTHY"
export SRC MNT
if [ -n "${DEADMOUNT_MOUNT:-}" ]; then
  MOUNT=$DEADMOUNT_MOUNT PID=$DEADMOUNT_PID UNMOUNT=$DEADMOUNT_UNMOUNT
elif command -v bindfs >/dev/null; then
  MOUNT='bindfs "$SRC" "$MNT"' PID='pgrep -f "bindfs $SRC" | head -1'
elif command -v sshfs >/dev/null && ssh -o BatchMode=yes localhost true 2>/dev/null; then
  MOUNT='sshfs "localhost:$SRC" "$MNT"' PID='pgrep -f "sshfs localhost:$SRC" | head -1'
else
  echo "SKIPPED: no FUSE (bindfs, or sshfs with key login to localhost) and no DEADMOUNT_MOUNT"
  exit 0
fi
UNMOUNT=${UNMOUNT:-'umount "$MNT" 2>/dev/null || fusermount -u "$MNT"'}
repo() {
  git -C "$1" init -q && git -C "$1" -c user.name=s -c user.email=s@s commit -q --allow-empty -m one
}
sh -c "$MOUNT" || { echo "SKIPPED: mounting failed"; exit 0; }
repo "$MNT"
repo "$HEALTHY"
SERVER=$(sh -c "$PID")
echo "== mount server pid $SERVER; stalled with SIGSTOP during the run"
# An agent pane keeps splitting into the stalled mount the whole time.
job split term 4 40 pane_split "{\"cwd\":\"$MNT\"}"
"$BIN/gudo-stress" dead-mount --healthy "$HEALTHY" --dead "$MNT" --secs ${DEADMOUNT_SECS:-30} \
  --stall "kill -STOP $SERVER" --resume "kill -CONT $SERVER"
waitfor 1
cat $OUT
kill -CONT $SERVER 2>/dev/null
sh -c "$UNMOUNT"
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
