#!/bin/zsh
# The "shell" of every bench pane: picks a workload by creation order (BENCH_ROLE marks the
# processes so the bench can kill them). Pane 1 is the focused one and stays a shell.
n=$(( $(cat $BENCH_ROOT/counter 2>/dev/null || echo 0) + 1 ))
echo $n > $BENCH_ROOT/counter
role=idle
if [ "$BENCH_ACTIVE" = yes ]; then
  case $n in
    2) role=flood ;;             # yes
    3) role=cat ;;               # cat of a 64 MB file, again and again
    4|5|6|7|8) role=top ;;       # full-screen redraw every second
    9|10|11|12|13) role=tail ;;  # tail -f of a log growing 10 lines/s
    14|15|16|17|18) role=build ;; # steady build-like output, ~50 lines/s
    19|20|21|22|23) role=spinner ;; # one-line spinner, 12 updates/s
    24|25) role=agent ;;         # fake agent: OSC 9/7501 status + bursts
  esac
fi
export BENCH_ROLE=$role
case $role in
  idle) exec /bin/zsh -f ;;
  flood) exec yes ;;
  cat) while true; do cat $BENCH_DIR/big.txt; done ;;
  top) exec top -s 1 ;;
  tail)
    log=$BENCH_ROOT/log.$n; : > $log
    (while true; do echo "$(date +%T.%N) INFO request handled path=/api/items id=$RANDOM" >> $log; sleep 0.1; done) &
    exec tail -f $log ;;
  build)
    i=0; while true; do i=$((i+1)); echo "   Compiling crate-$i v0.1.$((i%50)) (/src/crate-$i)"; sleep 0.02; done ;;
  spinner)
    s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; i=0
    while true; do i=$(( (i+1) % 10 )); printf '\r%s Working… (%ds · esc to interrupt)' "${s:$i:1}" $SECONDS; sleep 0.08; done ;;
  agent)
    while true; do
      printf '\e]9;Agent finished a step\a'
      printf '\e]7501;state=working:app=fake-agent\a'
      for j in $(seq 1 20); do echo "agent: reading file src/module_$j.rs and thinking about it"; done
      sleep 2
      printf '\e]7501;state=idle:app=fake-agent\a'
      sleep 1
    done ;;
esac
