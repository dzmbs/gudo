# Sourced by the test scripts: whatever a script starts stops when it exits, and cleaning up
# never changes the script's exit status.
#
#   . "$apple/scripts/lib/cleanup.sh"
#   on_exit 'daemon stop' 'rm -rf "$state"'
#
# At exit the script's background jobs are stopped first (they may talk to the daemons), then
# the `on_exit` commands run in order, each allowed to fail.

_on_exit=()

on_exit() {
  _on_exit+=("$@")
}

_cleanup() {
  local status=$?
  set +eu
  local pids
  pids="$(jobs -p)"
  if [[ -n $pids ]]; then
    kill $pids 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 $pids 2>/dev/null || break
      sleep 0.2
    done
    kill -9 $pids 2>/dev/null
  fi
  wait 2>/dev/null
  local command
  for command in "${_on_exit[@]}"; do
    eval "$command" >/dev/null 2>&1
  done
  exit "$status"
}

trap _cleanup EXIT
trap 'exit 130' INT TERM
