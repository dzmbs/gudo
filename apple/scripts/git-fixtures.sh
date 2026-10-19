#!/usr/bin/env bash
# The git workspace's UI-test fixtures (apple/scripts/git-ui-test.sh): the W3 fixtures
# (w3-fixtures.sh: HOME with ~/proj, stand-in `claude` and `code`), plus
# - an `origin` the repository is pushed to (main is one commit ahead of it);
# - a second worktree on `fix-login` with changes and no pane;
# - `.unnamed.json` with a setup command and two scripts;
# - a stand-in `gh`: signed in as octo, pull requests from fixtures/pr-<branch>.json
#   (#42 for `quiet-otter`, the New Task test's branch; #41 for `fix-login`), `pr merge`
#   marks the fixture merged; every call is logged to fixtures/log.
#
#   apple/scripts/git-fixtures.sh <dir>
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$1"
"$apple/scripts/w3-fixtures.sh" "$dir" >/dev/null
work="$dir/work"
bin="$dir/bin"
repo="$work/proj"
fixtures="$dir/fixtures"
mkdir -p "$fixtures"

# Start in the repository only when a pane starts at HOME: tabs opened in a worktree stay there.
cat >"$work/.zshrc" <<'EOF'
PROMPT='%1~ %# '
[[ "${PWD:A}" == "${HOME:A}" ]] && cd ~/proj 2>/dev/null
EOF

(
  cd "$repo"
  cat >.unnamed.json <<'EOF'
{
  "setup": "echo setup done > .setup-done",
  "scripts": [
    { "name": "Dev Server", "command": "echo DEV-SERVER-RUNNING", "icon": "play", "tint": "green", "default": true },
    { "name": "Tests", "command": "echo TESTS-RAN", "icon": "testtube.2", "tint": "yellow" }
  ]
}
EOF
  git add .unnamed.json
  git commit -q -m "Repository scripts"
  git init -q --bare "$dir/origin.git"
  git remote add origin "$dir/origin.git"
  git push -q -u origin main
  printf 'A local commit.\n' >CHANGELOG.md
  git add CHANGELOG.md
  git commit -q -m "Local commit"
  git worktree add -q -b fix-login "$work/.wt/fix-login" HEAD
  printf 'login fix in progress\nsecond line\n' >"$work/.wt/fix-login/login.txt"
)

pr() { # branch number title state mergeState
  cat >"$fixtures/pr-$1.json" <<EOF
{"number":$2,"title":"$3","state":"$4","isDraft":false,"headRefName":"$1","additions":128,"deletions":17,"mergeStateStatus":"$5","url":"https://github.com/acme/proj/pull/$2","statusCheckRollup":[
 {"__typename":"CheckRun","name":"build (macos)","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/proj/actions/runs/9001/job/1","workflowName":"CI"},
 {"__typename":"CheckRun","name":"build (linux)","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/proj/actions/runs/9001/job/2","workflowName":"CI"},
 {"__typename":"CheckRun","name":"integration tests","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/acme/proj/actions/runs/9002/job/3","workflowName":"Integration"},
 {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://github.com/acme/proj/actions/runs/9003/job/4","workflowName":"Lint"},
 {"__typename":"StatusContext","context":"deploy/preview","state":"SUCCESS","targetUrl":"https://example.com"}]}
EOF
}
pr quiet-otter 42 "Fix the login redirect loop" OPEN UNSTABLE
pr fix-login 41 "Remember the last signed-in account" OPEN CLEAN

cat >"$bin/gh" <<EOF
#!/bin/sh
F='$fixtures'
echo "\$*" >> "\$F/log"
case "\$1 \$2" in
  "auth status") echo "github.com"; echo "  ✓ Logged in to github.com account octo (keyring)"; exit 0 ;;
  "pr view")
    b=\$(printf %s "\$3" | tr / -)
    if [ -f "\$F/pr-\$b.json" ]; then cat "\$F/pr-\$b.json"; exit 0; fi
    echo "no pull requests found for branch \"\$3\"" >&2; exit 1 ;;
  "pr merge")
    for f in "\$F"/pr-*.json; do
      if grep -q "\"number\":\$3," "\$f"; then
        sed 's/"state":"OPEN"/"state":"MERGED"/' "\$f" > "\$f.tmp" && mv "\$f.tmp" "\$f"
      fi
    done
    exit 0 ;;
  "run rerun") exit 0 ;;
  "pr create")
    b=\$(git branch --show-current)
    sed "s/quiet-otter/\$b/g; s/\"number\":42/\"number\":43/" "\$F/pr-quiet-otter.json" > "\$F/pr-\$b.json"
    exit 0 ;;
esac
echo "fake gh: unsupported \$*" >&2
exit 2
EOF
chmod +x "$bin/gh"

cat >>"$dir/config.toml" <<EOF

[worktrees]
gh = "$bin/gh"
EOF

echo "$dir"
