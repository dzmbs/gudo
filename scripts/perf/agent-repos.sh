#!/bin/zsh
# Creates N scratch git repos for the agent benchmark.
set -eu
N=${1:-20}
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/unnamed-bench}; mkdir -p $OUT
ROOT=$OUT/agent-repos
mkdir -p $ROOT
for i in $(seq -w 1 $N); do
  r=$ROOT/repo-$i
  [ -d $r/.git ] && continue
  mkdir -p $r/.claude
  cat > $r/stats.py <<'EOF'
import sys

def words(text):
    return text.split()

def main():
    text = sys.stdin.read()
    print(len(words(text)))

if __name__ == "__main__":
    main()
EOF
  cat > $r/.claude/settings.json <<'EOF'
{
  "permissions": {
    "allow": ["Read", "Edit", "Write", "Glob", "Grep", "Bash(python3:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(mkdir:*)"]
  }
}
EOF
  (cd $r && git init -q && git add -A && git -c user.email=bench@example.com -c user.name=bench commit -qm seed)
done
