#!/usr/bin/env bash
# Runs WorkflowsUITests (the palette's "/" workflows, the argument form, insert vs ⌘↩ run, New
# Workflow from Last Command) on a simulator against a local gudo-hostd on the W3 fixtures
# (w3-fixtures.sh: HOME is a scratch work directory, ~/proj a git repository) plus workflow
# files: two in ~/proj/.gudo/workflows and one global in ~/.config/gudo/workflows.
#
#   apple/scripts/workflows-ui-test.sh [simulator-udid] [test-name …]
#
# WORKFLOWS_RESULTS keeps the result bundle (screenshots) and the daemon's log. Needs
# `cargo build -p hostd` and the app project (xcodegen). PORT defaults to 48614.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
shift || true
state="$(mktemp -d "${TMPDIR:-/tmp}/gudo-workflows.XXXXXX")"
"$apple/scripts/w3-fixtures.sh" "$state" >/dev/null
work="$state/work"
brand="$(sed -n 's/^BRAND_NAME *= *//p' "$apple/Brand.xcconfig" | tr '[:upper:]' '[:lower:]')"
brand="${brand:-gudo}"

mkdir -p "$work/proj/.$brand/workflows" "$work/.config/$brand/workflows"
cat >"$work/proj/.$brand/workflows/greet.yaml" <<'EOF'
---
name: Greet Someone
command: "echo {{greeting}} {{name}} > greet-out.txt"
description: Writes a greeting to greet-out.txt
tags:
  - demo
arguments:
  - name: greeting
    description: How to greet
    default_value: Hello
  - name: name
    description: Who to greet
    default_value: world
EOF
cat >"$work/proj/.$brand/workflows/status.yaml" <<'EOF'
name: Short Status
command: git status --short
description: Changed files, one per line
EOF
cat >"$work/.config/$brand/workflows/disk.yaml" <<'EOF'
name: Disk Usage
command: du -sh {{path}}
arguments:
  - name: path
    default_value: .
EOF

export PORT="${PORT:-48614}"
daemon() { PORT="$PORT" "$apple/scripts/w3-daemon.sh" "$1" "$state"; }
ticket="$(daemon start)"
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon stop; rm -rf "$state"'

only=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do only+=("-only-testing:AppUITests/WorkflowsUITests/$name"); done
else
  only=("-only-testing:AppUITests/WorkflowsUITests")
fi

log="$state/xcodebuild.log"
results="${WORKFLOWS_RESULTS:-$state/Workflows.xcresult}"
rm -rf "$results"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" TEST_RUNNER_WORKFLOW_FIXTURES="$state" TEST_RUNNER_BRAND="$brand" xcodebuild -collect-test-diagnostics never \
  -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -resultBundlePath "$results" "${only[@]}" test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -40
if [[ -n "${WORKFLOWS_RESULTS:-}" ]]; then
  cp "$state/log" "$WORKFLOWS_RESULTS.daemon.log" 2>/dev/null || true
  cp "$log" "$WORKFLOWS_RESULTS.xcodebuild.log" 2>/dev/null || true
fi
exit "$status"
