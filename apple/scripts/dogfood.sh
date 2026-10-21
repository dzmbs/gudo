#!/bin/zsh
# Builds the macOS app (Debug) and runs a dogfood scenario in it: apple/Dogfood/README.md.
#
#   apple/scripts/dogfood.sh [scenario] [--no-build] [--case <name>] [--out <dir>] [--real-history]
#
# scenario: a path, or a name in apple/Dogfood (default: core). Exit status is the app's:
# 0 passed, 1 a case failed, 2 bad scenario, 3 hang / time limit.
#
# Needs no permissions: events are synthesized inside the app, screenshots are rendered by the app.
# The shells are the user's login zsh with their config, but with a throwaway HISTFILE (unless
# --real-history) so scenario commands neither pollute nor come from the real history.
set -euo pipefail

APPLE_DIR=${0:A:h:h}
scenario=core
build=1
only_case=""
out=""
real_history=0
while (( $# )); do
  case $1 in
    --no-build) build=0 ;;
    --case) only_case=$2; shift ;;
    --out) out=$2; shift ;;
    --real-history) real_history=1 ;;
    -h|--help) sed -n '2,12p' $0; exit 0 ;;
    *) scenario=$1 ;;
  esac
  shift
done
[[ -f $scenario ]] || scenario=$APPLE_DIR/Dogfood/${scenario%.json}.json
[[ -f $scenario ]] || { print -u2 "no scenario $scenario"; exit 2 }
scenario=${scenario:A}
out=${out:-$APPLE_DIR/build/dogfood/$(date +%Y%m%d-%H%M%S)}
mkdir -p $out
out=${out:A}

if (( build )); then
  [[ -d $APPLE_DIR/App.xcodeproj ]] || (cd $APPLE_DIR && xcodegen >/dev/null)
  print "building…"
  xcodebuild -project $APPLE_DIR/App.xcodeproj -scheme App -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath $APPLE_DIR/build/DerivedData build -quiet 2>&1 | grep -v 'appintentsmetadataprocessor' || true
fi
app=$(ls -d $APPLE_DIR/build/DerivedData/Build/Products/Debug/*.app 2>/dev/null | grep -v -- -Runner.app | head -1)
[[ -n $app ]] || { print -u2 "no Debug build in build/DerivedData"; exit 2 }
binary=$app/Contents/MacOS/$(defaults read $app/Contents/Info.plist CFBundleExecutable)

if (( ! real_history )); then
  # A ZDOTDIR that loads the user's own startup files, then switches history to a scratch file.
  zdot=$out/zdotdir
  mkdir -p $zdot
  print '[[ -f ~/.zshenv ]] && source ~/.zshenv' > $zdot/.zshenv
  print '[[ -f ~/.zprofile ]] && source ~/.zprofile' > $zdot/.zprofile
  print "[[ -f ~/.zshrc ]] && source ~/.zshrc
HISTFILE=$out/zsh_history" > $zdot/.zshrc
  print '[[ -f ~/.zlogin ]] && source ~/.zlogin' > $zdot/.zlogin
  export ZDOTDIR=$zdot
fi

args=(-ApplePersistenceIgnoreState YES -dogfood $scenario -dogfoodOut $out)
# In the background by default (no Dock icon, never in front of your work);
# DOGFOOD_FOREGROUND=1 runs it as a normal, active window.
[[ -n ${DOGFOOD_FOREGROUND:-} ]] || args+=(-dogfoodBackground YES)
[[ -n $only_case ]] && args+=(-dogfoodCase $only_case)
print "running ${scenario:t} → $out"
set +e
# The app's stderr (progress lines start with "dogfood:") goes to app.log; follow it meanwhile.
$binary $args 2> $out/app.log &
pid=$!
tail -n +1 -f $out/app.log 2>/dev/null | grep --line-buffered '^dogfood' &
tailer=$!
wait $pid
code=$?
sleep 0.2
kill $tailer 2>/dev/null
pkill -P $$ tail 2>/dev/null
set -e

python3 -I - $out/report.json <<'EOF' || true
import json, sys
r = json.load(open(sys.argv[1]))
for c in r.get("cases", []):
    print(f"{'PASS' if c['passed'] else 'FAIL'}  {c['name']:<28} {c['ms']/1000:6.1f} s")
    for s in c["steps"]:
        if not s["passed"]:
            print(f"      step {s['index']} {s['action']}: {s.get('error', '')}")
        if s.get("screenshot"):
            print(f"      screenshot {s['screenshot']}")
    if c.get("failureScreenshot"):
        print(f"      failure screenshot {c['failureScreenshot']}")
for key, label in (("keystrokeToEcho", "keystroke→echo "), ("keystrokeToFrame", "keystroke→frame")):
    l = r.get(key)
    if l:
        print(f"{label} p50 {l['p50Ms']:.1f} ms  p95 {l['p95Ms']:.1f} ms  max {l['maxMs']:.1f} ms  (n={l['count']})")
if r.get("framesMissed"):
    print(f"frames missed: {r['framesMissed']} (display link idle: window occluded or screen locked)")
print(f"max main-thread stall {r.get('maxMainThreadStallMs', 0):.0f} ms; leaked processes: {len(r.get('leakedProcesses', []))}")
if r.get("aborted"): print("ABORTED:", r["aborted"])
env = r.get("environment", {})
if env.get("isActive") == "false":
    print("note: app was not active (screen locked or another app in front): keys went to the window's first responder; disabled ⌘ menu items ran their actions")
print(f"{'PASSED' if r.get('passed') else 'FAILED'} {r.get('casesPassed', 0)}/{len(r.get('cases', []))}  report: {sys.argv[1]}")
EOF
exit $code
