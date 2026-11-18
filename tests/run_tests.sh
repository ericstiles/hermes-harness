#!/usr/bin/env bash
# Tests for hermes-harness: classify / supervise / status / launch / run, against a
# throwaway TARGET repo with stubbed hermes/bd/docker. No network, no real agents.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
FX="$HERE/fixtures"; BIN="$ROOT/bin"; pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1 (got: ${2:-})"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2 != $3"; }
. "$ROOT/lib/classify.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# Target repo (what the harness acts on) with an origin remote.
mkdir -p "$tmp/target" "$tmp/bin"; W=$(cd "$tmp/target" && pwd -P)
git -C "$W" init -q -b main; git -C "$W" remote add origin git@github.com:acme/widgets.git
unset GITHUB_REPO HERMES_REPO HERMES_LOG_DIR

# --- classification (one fixture per class + false-positive traps) ---
for pair in timeout_killed:TIMEOUT blocked:BLOCKED queue_empty:QUEUE_EMPTY model_api_error:MODEL_API_ERROR \
            beads_sync:BEADS_SYNC_ERROR auth_error:AUTH_ERROR sandbox_down:SANDBOX_DOWN ok_done:OK_DONE \
            trap_test_404_and_aux_timeout:OK_DONE trap_sentinel_in_prose:OK_DONE trap_sync_in_prose:OK_DONE; do
  n=${pair%%:*}; want=${pair##*:}
  eq "classify $n" "$(hermes_classify "$FX/$n.log")" "$want"
done
eq "exit code 124 wins" "$(hermes_classify "$FX/ok_done.log" 124)" TIMEOUT
eq "missing file" "$(hermes_classify /nonexistent)" UNKNOWN
eq "supervise --classify needs no repo" "$(cd "$tmp" && "$BIN/hermes-supervise" --classify "$FX/timeout_killed.log")" TIMEOUT

# --- supervise: output contract, read-only, no secrets ---
sup() { (cd "$W" && "$BIN/hermes-supervise" "$@"); }
before=$(git -C "$W" status --porcelain)
out=$(GH_TOKEN=SECRET_TOKEN_VALUE HERMES_LOG_DIR="$tmp/logs1" sup "$FX/timeout_killed.log")
echo "$out" | grep -q '^CLASS=TIMEOUT$' && ok "supervise prints CLASS" || bad "supervise CLASS" "$out"
echo "$out" | grep -q '^ACTION=AUTO_RELAUNCH$' && ok "timeout -> AUTO_RELAUNCH" || bad "timeout action" "$out"
echo "$out" | grep -q -- '--timeout 120m' && ok "timeout doubled and capped at 120m" || bad "timeout arg" "$out"
echo "$out" | grep -q '^NEXT=hermes-launch ' && ok "NEXT uses the PATH command, not a repo-relative script" || bad "NEXT form" "$out"
echo "$out" | grep -q SECRET_TOKEN_VALUE && bad "token leaked" || ok "no token in output"
eq "auth -> ASK_HUMAN" "$(HERMES_LOG_DIR=$tmp/l sup "$FX/auth_error.log" | sed -n 's/^ACTION=//p')" ASK_HUMAN
eq "blocked -> ASK_HUMAN" "$(HERMES_LOG_DIR=$tmp/l sup "$FX/blocked.log" | sed -n 's/^ACTION=//p')" ASK_HUMAN
eq "queue empty -> DONE" "$(HERMES_LOG_DIR=$tmp/l sup "$FX/queue_empty.log" | sed -n 's/^ACTION=//p')" DONE
# second timeout on same issue today -> stop and split (any issue prefix)
mkdir -p "$tmp/l2"; d=$(date +%Y%m%d)
printf '%s TIMEOUT widgets-abc\n%s TIMEOUT widgets-abc\n' "$d" "$d" > "$tmp/l2/.relaunches"
sed 's/learn_hermes-[a-z0-9]*/widgets-abc/g' "$FX/timeout_killed.log" > "$tmp/widgets_timeout.log"
out=$(HERMES_LOG_DIR="$tmp/l2" sup "$tmp/widgets_timeout.log")
echo "$out" | grep -q '^ISSUE=widgets-abc$' && ok "issue id parsed for a non-learn_hermes prefix" || bad "issue prefix" "$out"
echo "$out" | grep -q '^ACTION=ASK_HUMAN$' && echo "$out" | grep -q 'split' && ok "2nd timeout -> split issue" || bad "split rule" "$out"
eq "target repo status unchanged by supervise" "$(git -C "$W" status --porcelain)" "$before"
out=$(cd "$tmp" && "$BIN/hermes-supervise" 2>&1)
echo "$out" | grep -q '^ACTION=ASK_HUMAN$' && ok "supervise outside a git repo asks the human" || bad "no repo" "$out"

# --- launch: refusals and repo-agnostic command ---
out=$(cd "$W" && env -u GH_TOKEN "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q GH_TOKEN && ok "launch refuses without GH_TOKEN" || bad "launch token refusal" "$rc $out"
out=$(cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1)
echo "$out" | grep -q "cd '$W' &&" && echo "$out" | grep -q "'$ROOT/bin/hermes-run'" && ok "launch targets the current repo with an absolute hermes-run" || bad "launch cmd" "$out"
echo "$out" | grep -q 'GITHUB_REPO=' && bad "launch hardcodes repo" "$out" || ok "launch dry-run has no hardcoded repo"
out=$(cd "$tmp" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'not inside a git repo' && ok "launch refuses outside a git repo" || bad "launch no repo" "$rc $out"

rm -rf "$W/logs"; (cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run >/dev/null 2>&1)
[ ! -e "$W/logs" ] && ok "--dry-run creates nothing in the repo" || bad "dry-run side effect" "$(ls -a "$W/logs")"
# --- launch --help / -h: detailed, no side effects, works anywhere without a token ---
for flag in -h --help; do
  out=$(cd "$tmp" && env -u GH_TOKEN "$BIN/hermes-launch" "$flag" 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "launch $flag exits 0 outside a repo without GH_TOKEN" || bad "launch $flag rc" "$rc $out"
  for want in 'Usage:' '--timeout' '--reason' '--issue' '--max' '--dry-run' 'GH_TOKEN' 'GITHUB_REPO' 'HERMES_REPO' 'herdr' 'tmux' 'WHAT HAPPENS' 'EXIT STATUS' 'EXAMPLES'; do
    echo "$out" | grep -q -- "$want" && ok "launch $flag mentions $want" || bad "launch $flag missing $want" "$out"
  done
done
out=$(cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --timeout 5m --help 2>&1)
echo "$out" | grep -q 'WHAT HAPPENS' && ok "--help wins over other flags (nothing is launched)" || bad "help with flags" "$out"
[ ! -e "$W/logs/.relaunches" ] && ok "--help writes no relaunch record" || bad "help side effect" "$(cat "$W/logs/.relaunches")"

# --- symlinked install: PATH symlink resolves back to the harness ---
mkdir -p "$tmp/linkbin"; ln -s "$BIN/hermes-launch" "$tmp/linkbin/hermes-launch"
out=$(cd "$W" && GH_TOKEN=x PATH="$tmp/linkbin:$PATH" hermes-launch --dry-run 2>&1)
echo "$out" | grep -q "'$ROOT/bin/hermes-run'" && ok "works through a PATH symlink" || bad "symlink" "$out"

# --- hermes-run with stubbed hermes/bd/docker ---
cat > "$tmp/bin/docker" <<'S'
#!/bin/sh
exit 0
S
cat > "$tmp/bin/bd" <<'S'
#!/bin/sh
echo "bd $*" >> "$STUB_LOG"
case "$1 $2" in "list --status=in_progress") echo "◐ ${STUB_PREFIX:-widgets}-abc P2 stuck" ;; esac
exit 0
S
cat > "$tmp/bin/hermes" <<'S'
#!/bin/sh
# config get -> value; chat -> first call hangs (killed by timeout), later calls finish
[ "$1" = config ] && { echo stub; exit 0; }
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_COUNT"
echo "  ┊ 💻 \$ bd update ${STUB_PREFIX:-widgets}-abc --claim --json"
if [ "$n" = 1 ] && [ "$STUB_HANG_FIRST" = 1 ]; then sleep 30; exit 0; fi
echo "PR https://github.com/o/r/pull/1"; echo; echo "Resume this session with:"; echo "Messages:       9 (1 user, 8 tool calls)"
S
chmod +x "$tmp/bin/"*
export STUB_LOG="$tmp/stub.log" STUB_COUNT="$tmp/count" GH_TOKEN=x
TOUT=$(command -v timeout || command -v gtimeout)
runit() { (cd "$W" && PATH="$tmp/bin:$PATH" "$@"); }
if [ -z "$TOUT" ]; then echo "skip - hermes-run tests need timeout/gtimeout"; else
  # repo + logs come from the CURRENT directory, not the harness
  out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?
  echo "$out" | grep -q '== repo: acme/widgets ' && ok "repo derived from origin (ssh url)" || bad "derive ssh" "$out"
  ls "$W"/logs/run-*.log >/dev/null 2>&1 && [ ! -d "$ROOT/logs" ] && ok "logs written in the target repo, not the harness" || bad "log location" "$(ls "$W" "$ROOT")"
  [ $rc -eq 0 ] && ok "clean run exits 0" || bad "clean rc" "$rc $out"
  rm -rf "$W/logs" "$STUB_COUNT"
  # lock: a live pid holding the lock blocks a second instance
  mkdir -p "$W/logs/.run-beads.lock"; echo $$ > "$W/logs/.run-beads.lock/pid"
  out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?
  [ $rc -eq 3 ] && echo "$out" | grep -q 'already running' && ok "second instance refused by lock" || bad "lock" "$rc $out"
  rm -rf "$W/logs/.run-beads.lock"
  # hang first call; no retry -> TIMEOUT, claim released, RUN_RESULT line written
  : > "$STUB_LOG"; rm -f "$STUB_COUNT"
  out=$(STUB_HANG_FIRST=1 RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1); rc=$?
  [ $rc -eq 1 ] && ok "timeout run exits non-zero" || bad "timeout rc" "$rc"
  grep -q '^RUN_RESULT=TIMEOUT$' "$W"/logs/run-*.log && ok "RUN_RESULT=TIMEOUT written to log" || bad "RUN_RESULT line" "$out"
  grep -q 'bd unclaim widgets-abc' "$STUB_LOG" && ok "stale claim released after timeout" || bad "unclaim" "$(cat "$STUB_LOG")"
  # a different beads prefix works too
  rm -f "$W"/logs/run-*.log "$STUB_COUNT"; : > "$STUB_LOG"
  STUB_PREFIX=other_proj STUB_HANG_FIRST=1 RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 >/dev/null 2>&1
  grep -q 'bd unclaim other_proj-abc' "$STUB_LOG" && ok "unclaim works for any issue prefix" || bad "prefix" "$(cat "$STUB_LOG")"
  # retry-on-timeout: second attempt (bigger timeout) completes
  rm -f "$W"/logs/run-*.log "$STUB_COUNT"; : > "$STUB_LOG"
  out=$(STUB_HANG_FIRST=1 RUN_TIMEOUT=1s HERMES_RETRY_ON_TIMEOUT=1 runit "$BIN/hermes-run" 1 2>&1); rc=$?
  [ $rc -eq 0 ] && echo "$out" | grep -q 'retrying the issue once' && echo "$out" | grep -q 'FINAL_RESULT=OK_DONE' && ok "retry-on-timeout recovers" || bad "retry" "$rc $out"
  [ ! -d "$W/logs/.run-beads.lock" ] && ok "lock released on exit" || bad "lock cleanup"
  # URL styles
  for url in https://github.com/acme/widgets.git https://github.com/acme/widgets; do
    git -C "$W" remote set-url origin "$url"
    out=$(runit "$BIN/hermes-run" 1 2>&1)
    echo "$out" | grep -q '== repo: acme/widgets ' && ok "repo derived from origin ($url)" || bad "derive $url" "$out"
  done
  # no remote and no GITHUB_REPO -> clear error
  git -C "$W" remote remove origin
  out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?
  [ $rc -ne 0 ] && echo "$out" | grep -q 'GITHUB_REPO' && ok "no origin and no GITHUB_REPO -> clear error" || bad "no origin" "$rc $out"
fi
echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
