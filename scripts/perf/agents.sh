#!/bin/zsh
# Usage: agents.sh <bin_dir> <label> <claude> <idle> [pi] [kimi]
# Real coding-agent sessions in daemon panes, each in its own scratch repo, plus idle shell
# panes around them. Claude Code is launched the daemon's way (`split --agent claude`: hooks,
# settings, OSC status); pi and kimi as commands in a shell pane. Measures the daemon while
# they work, then kills everything.
set -u
BIN=$1; LABEL=$2; NC=$3; NI=$4; NP=${5:-0}; NK=${6:-0}
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/unnamed-bench}; mkdir -p $OUT
REPOS=$OUT/agent-repos
for r in $REPOS/repo-*; do (cd $r && git reset -q --hard && git clean -qfdx); done
ROOT=$(mktemp -d $OUT/run-XXXX); STATE=$ROOT/state; CFG=$ROOT/cfg; mkdir -p $STATE $CFG
export XDG_CONFIG_HOME=$CFG
WINDOW=${WINDOW:-30}
# The client: this build's `un` (it needs `send` and `split --cwd`) unless UN names another.
UN=${UN:-$BIN/un}
U() { $UN --no-relay "$@" < /dev/null; }
PROMPT="This is a scratch repo for a performance benchmark; keep working without asking me anything. Do eight rounds, one after another. In each round add one feature to stats.py (round 1 line and character counts, then most common words, a --top option, reading files given as arguments, a JSON output flag, ignoring a stop-word list, per-file totals, and a --sort option), write unittest tests for it in test_stats.py, run the whole suite with python3 -m unittest -v and fix any failures. Only after round eight, write a short summary. Stay inside this directory and do not use the network."
# A clean environment: nothing from the shell that runs this bench leaks into the agents.
env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 \
  TMPDIR=$TMPDIR PATH=$HOME/.local/bin:$HOME/.kimi-code/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  ANTHROPIC_MODEL=haiku UN_LOG=warn \
  $BIN/unnamed-hostd --state-dir $STATE run --no-relay --bind 127.0.0.1:0 --shell /bin/zsh 2>$ROOT/daemon.log &
DPID=$!
cleanup() {
  pkill -f "$UN --no-relay attach" 2>/dev/null; pkill -f 'sleep 100000'
  kill $DPID 2>/dev/null; sleep 2
  pkill -f "$STATE" 2>/dev/null
  rm -rf $ROOT
}
trap cleanup EXIT
sleep 3
csw() { top -l 1 -pid $1 -stats csw | tail -1 | tr -d '+ '; }
cpu_secs() { ps -o time= -p $1 | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
measure() {
  local what=$1
  local c0=$(cpu_secs $DPID) w0=$(csw $DPID)
  sleep $WINDOW
  local c1=$(cpu_secs $DPID) w1=$(csw $DPID)
  local rss=$(ps -o rss= -p $DPID)
  local working=$(for p in "${AGENT_PANES[@]}"; do U search --pane $p --regex "… \([0-9]+s" 2>/dev/null | head -1; done | grep -c "^[1-9]")
  printf "%s\t%s claude + %s pi + %s kimi + %s idle\t%s\trss_mb=%.1f\tcpu%%=%s\tctx_switches/s=%s\tworking=%s\n" $LABEL $NC $NP $NK $NI "$what" \
    $(echo "$rss/1024" | bc -l) $(echo "$c0 $c1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3*100}') $(echo "$w0 $w1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3}') $working
}
screen_has() { U search --pane $1 --regex "$2" 2>/dev/null | head -1 | grep -q "^[1-9]"; }
TICKET=$($BIN/unnamed-hostd --state-dir $STATE pair --json --local --wait 10 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
U pair "$TICKET" >/dev/null
for ((i=1; i<=NI; i++)); do U tab new >/dev/null; done
AGENT_PANES=()
start_agent() { # kind index
  local kind=$1 i=$2 repo=$REPOS/repo-$(printf %02d $2) pane
  U tab new >/dev/null
  if [ $kind = claude ]; then
    pane=$(U split --agent claude --cwd $repo | sed 's/[^0-9]//g')
  else
    pane=$(U split --cwd $repo | sed 's/[^0-9]//g')
    sleep 1
    U send --pane $pane "$kind" --enter
  fi
  AGENT_PANES+=($pane)
  echo "$kind $i pane $pane" >> $ROOT/panes
}
prompt_agent() { # pane kind
  local pane=$1 kind=$2
  for t in $(seq 1 40); do
    if screen_has $pane "Log in|login|Sign in|sign in|API key"; then echo "LOGIN PROMPT in pane $pane ($kind): stopping"; exit 3; fi
    if [ $kind = claude ] && screen_has $pane "Yes, I trust this folder"; then
      # Deliberately trust the scratch repo: Up selects "Yes", checked before Enter.
      screen_has $pane "❯ Yes, I trust this folder" || U send --pane $pane --raw $'\e[A'
      sleep 0.5
      screen_has $pane "❯ Yes, I trust this folder" && U send --pane $pane --raw $'\r'
      sleep 3; continue
    fi
    if [ $kind = kimi ] && screen_has $pane "Trust this folder"; then
      screen_has $pane "Trust and continue" && U send --pane $pane --raw $'\r'
      sleep 3; continue
    fi
    if [ $t -gt 4 ] && { [ $kind != claude ] && [ $t -gt 7 ] || screen_has $pane "^ *❯"; }; then
      U send --pane $pane "$PROMPT" --enter
      return
    fi
    sleep 1
  done
  echo "pane $pane ($kind) never showed a prompt"
}
for ((i=1; i<=NC; i++)); do start_agent claude $i; done
for ((i=1; i<=NP; i++)); do start_agent pi $((NC + i)); done
for ((i=1; i<=NK; i++)); do start_agent kimi $((NC + NP + i)); done
while read kind i _ pane; do prompt_agent $pane $kind; done < $ROOT/panes
sleep 10
if [ -n "${DEBUG:-}" ]; then for p in "${AGENT_PANES[@]}"; do U search --pane $p --regex --limit 200 "^." | head -30; done; exit 0; fi
measure "no client"
(sleep 100000 | script -q /dev/null /bin/zsh -c "stty rows 50 cols 160; exec $UN --no-relay attach" >/dev/null 2>&1) &
sleep 3
measure "1 client attached"
pkill -f "$UN --no-relay attach"
cp $ROOT/panes $OUT/last-panes.txt
for p in "${AGENT_PANES[@]}"; do echo "== pane $p"; U search --pane $p --regex --limit 200 "^." | head -25; done > $OUT/last-screens.txt
