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

# --- timestamps filter (lib/tsfilter.py) ---
. "$HERE/timestamps_tests.sh"
# --- Hermes pre_tool_call hook: block bd update --notes (lib/hooks/bd_notes_guard.py) ---
. "$HERE/notes_guard_tests.sh"
# --- hermes-setup: baseline files for a target repo (AGENTS.md, AGENTS_LOCAL.md, CLAUDE.md, .gitignore) ---
. "$HERE/setup_tests.sh"
# --- every runnable script answers -h / --help ---
. "$HERE/help_tests.sh"

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
# herdr/tmux are stubbed to fail so a test can never open a real tab or session.
mkdir -p "$tmp/nohost"; for c in herdr tmux; do printf '#!/bin/sh\necho "STUB %s called: $*" >> "%s/host_calls.log"\nexit 1\n' "$c" "$tmp" > "$tmp/nohost/$c"; chmod +x "$tmp/nohost/$c"; done
# `ps` is stubbed to "no processes" so a REAL Hermes run on this machine cannot affect the tests.
printf '#!/bin/sh\nexit 0\n' > "$tmp/nohost/ps"; chmod +x "$tmp/nohost/ps"
export PATH="$tmp/nohost:$PATH"
out=$(cd "$W" && env -u GH_TOKEN "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q GH_TOKEN && ok "launch refuses without GH_TOKEN" || bad "launch token refusal" "$rc $out"
out=$(cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1)
echo "$out" | grep -q "cd '$W' &&" && echo "$out" | grep -q "'$ROOT/bin/hermes-run'" && ok "launch targets the current repo with an absolute hermes-run" || bad "launch cmd" "$out"
echo "$out" | grep -q "GITHUB_REPO='acme/widgets'" && ok "launch resolves GITHUB_REPO from origin and shows it in the command" || bad "launch GITHUB_REPO shown" "$out"
echo "$out" | grep -q 'ericstiles' && bad "launch hardcodes repo" "$out" || ok "launch dry-run has no hardcoded repo"
# GITHUB_REPO that cannot be resolved must fail the dry-run, not just the real run
NR="$tmp/norigin"; mkdir -p "$NR"; git -C "$NR" init -q -b main
out=$(cd "$NR" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && ok "dry-run exits 1 when GITHUB_REPO cannot be resolved" || bad "dry-run unresolved rc" "$rc $out"
echo "$out" | grep -q 'GITHUB_REPO is not set' && echo "$out" | grep -q 'export GITHUB_REPO=owner/name' && echo "$out" | grep -q 'git remote add origin' && ok "dry-run says GITHUB_REPO must be set and how" || bad "dry-run unresolved msg" "$out"
echo "$out" | grep -q 'DRY RUN: would start' && bad "dry-run printed a launch command despite the error" "$out" || ok "no launch command printed when a prerequisite is missing"
out=$(cd "$NR" && GITHUB_REPO=acme/override GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1)
echo "$out" | grep -q "GITHUB_REPO='acme/override'" && ok "explicit GITHUB_REPO wins over origin" || bad "override" "$out"
# every missing prerequisite is reported at once
out=$(cd "$NR" && env -u GH_TOKEN "$BIN/hermes-launch" --dry-run 2>&1)
echo "$out" | grep -q 'GITHUB_REPO is not set' && echo "$out" | grep -q 'GH_TOKEN is not set' && ok "dry-run lists all missing prerequisites together" || bad "all problems" "$out"
# a real launch is refused the same way and records nothing
out=$(cd "$NR" && GH_TOKEN=x "$BIN/hermes-launch" 2>&1); rc=$?
[ $rc -eq 1 ] && [ ! -e "$NR/logs/.relaunches" ] && [ ! -e "$tmp/host_calls.log" ] && ok "real launch refused without GITHUB_REPO and records nothing" || bad "real launch unresolved" "$rc $out"
out=$(cd "$tmp" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'not inside a git repo' && ok "launch refuses outside a git repo" || bad "launch no repo" "$rc $out"

rm -rf "$W/logs"; (cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --dry-run >/dev/null 2>&1)
[ ! -e "$W/logs" ] && ok "--dry-run creates nothing in the repo" || bad "dry-run side effect" "$(ls -a "$W/logs")"
# an active run (stubbed ps) blocks a launch, in --dry-run too
mkdir -p "$tmp/busy"; printf '#!/bin/sh\necho "123 bash /x/bin/hermes-run 10"\n' > "$tmp/busy/ps"; chmod +x "$tmp/busy/ps"
out=$(cd "$W" && PATH="$tmp/busy:$PATH" GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'already running' && ok "dry-run refuses while a run is active" || bad "active run refusal" "$rc $out"
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
# scriptable sandbox: see tests/sandbox_clean_tests.sh for the STUB_* knobs
echo "docker $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
  ps) [ -n "$STUB_CONTAINERS" ] && printf '%s\n' $STUB_CONTAINERS; exit 0 ;;
  inspect) echo "${STUB_RUNNING:-true}"; exit 0 ;;
  exec) shift; shift
    case "$*" in
      "test -d"*) [ "${STUB_WS:-1}" = 1 ]; exit $? ;;
      *"git diff HEAD"*) [ -n "$STUB_DIRTY" ] && printf '%s\n' "$STUB_DIRTY"; exit 0 ;;
      *origin/main*) exit "${STUB_RESET_RC:-0}" ;;
    esac ;;
esac
exit 0
S
cat > "$tmp/bin/bd" <<'S'
#!/bin/sh
echo "bd $*" >> "$STUB_LOG"
case "$1 $2" in "list --status=in_progress") echo "◐ ${STUB_PREFIX:-widgets}-abc P2 stuck" ;; esac
# show <id> --json: $STUB_BEADS/<id>.json if present (empty output otherwise); STUB_BD_SHOW_FAIL=1 fails
if [ "$1" = show ]; then
  [ "${STUB_BD_SHOW_FAIL:-0}" = 1 ] && { echo "bd: database locked" >&2; exit 1; }
  [ -n "$STUB_BEADS" ] && [ -f "$STUB_BEADS/$2.json" ] && cat "$STUB_BEADS/$2.json"
fi
exit 0
S
cat > "$tmp/bin/gh" <<'S'
#!/bin/sh
# offline gh: `pr list` prints $STUB_PR_URL (empty = no PR); `pr view` prints $STUB_PR_BODY
# (unset = fails); everything else fails
echo "gh $*" >> "$STUB_LOG"
[ "$1 $2" = "pr list" ] && { [ -n "$STUB_PR_URL" ] && echo "$STUB_PR_URL"; exit 0; }
[ "$1 $2" = "pr view" ] && [ -n "${STUB_PR_BODY+x}" ] && { printf '%s\n' "$STUB_PR_BODY"; exit 0; }
exit 1
S
cat > "$tmp/bin/hermes" <<'S'
#!/bin/sh
# config get -> value; chat -> first call hangs (killed by timeout), later calls finish
[ "$1" = config ] && { echo stub; exit 0; }
echo "hermes $*" >> "$STUB_LOG"
# sessions list: STUB_SESSIONS=1 shows a harness session started now, plus an older harness
# session and a newer-sorting unrelated chat that must both be ignored
if [ "$1" = sessions ]; then
  [ "${STUB_SESSIONS:-0}" = 1 ] || exit 0
  now=$(date +%Y%m%d_%H%M%S)
  echo "Title                 Preview                                  Last Active   ID"
  echo "Other chat            what is a flac file                      just now      ${now}_000000"
  echo "Run Autonomous Beads  Follow AGENTS.md \"Autonomous Beads wor   just now      ${now}_abc123"
  echo "Run Autonomous Beads  Follow AGENTS.md \"Autonomous Beads wor   2y ago        20240101_000000_old000"
  exit 0
fi
echo "env HERMES_HARNESS_RUN=${HERMES_HARNESS_RUN:-}" >> "$STUB_LOG"
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$STUB_COUNT"
f=$STUB_FIXTURE; [ "$n" -ge 2 ] && [ -n "$STUB_FIXTURE_2" ] && f=$STUB_FIXTURE_2
[ -n "$f" ] && { cat "$f"; exit "${STUB_EXIT:-0}"; }
echo "  ┊ 💻 \$ bd update ${STUB_PREFIX:-widgets}-abc --claim --json"
if [ "$n" = 1 ] && [ "$STUB_HANG_FIRST" = 1 ]; then sleep 30; exit 0; fi
# STUB_WRITES="<path> <count>": first call writes <path> <count> times, 0.4s apart, then opens the PR
if [ "$n" = 1 ] && [ -n "$STUB_WRITES" ]; then
  set -- $STUB_WRITES; k=0
  while [ "$k" -lt "$2" ]; do echo "  ┊ ✍️  write     $1  0.1s"; sleep 0.4; k=$((k+1)); done
fi
echo "PR https://github.com/o/r/pull/1"; echo; echo "Resume this session with:"; echo "Messages:       9 (1 user, 8 tool calls)"
S
chmod +x "$tmp/bin/"*
export STUB_LOG="$tmp/stub.log" STUB_COUNT="$tmp/count" GH_TOKEN=x
runit() { (cd "$W" && PATH="$tmp/bin:$PATH" "$@"); }
if ! command -v python3 >/dev/null 2>&1; then echo "skip - hermes-run tests need python3 (watchdog, tsfilter)"; else
  # repo + logs come from the CURRENT directory, not the harness
  out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?
  echo "$out" | grep -q '== repo: acme/widgets ' && ok "repo derived from origin (ssh url)" || bad "derive ssh" "$out"
  ls "$W"/logs/run-*.log >/dev/null 2>&1 && [ ! -d "$ROOT/logs" ] && ok "logs written in the target repo, not the harness" || bad "log location" "$(ls "$W" "$ROOT")"
  [ $rc -eq 0 ] && ok "clean run exits 0" || bad "clean rc" "$rc $out"
  grep -q '^hermes chat .*--pass-session-id' "$STUB_LOG" && ok "hermes gets --pass-session-id (for Hermes-Session in the PR)" || bad "pass-session-id" "$(grep '^hermes' "$STUB_LOG")"
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
  # timestamped twin log, RUN_TIME summaries, raw log unchanged
  . "$HERE/run_timestamps_tests.sh"
  # agent ended its turn early (no PR, no sentinel): classify AGENT_STOPPED, resume once
  . "$HERE/agent_stopped_tests.sh"
  # after an OK_DONE run the bead must still carry the PR link (class NOTES_LOST)
  . "$HERE/notes_check_tests.sh"
  # a TIMEOUT or a Hermes crash resumes the session for a wrap-up that saves WIP (AGENT_CRASHED)
  . "$HERE/wrapup_tests.sh"
  # progress-aware time limit (lib/watchdog.py)
  . "$HERE/watchdog_tests.sh"
  # --clean: reset the sandbox workspace to origin/main, saving uncommitted work first
  . "$HERE/sandbox_clean_tests.sh"
  # no remote and no GITHUB_REPO -> clear error
  git -C "$W" remote remove origin
  out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?
  [ $rc -ne 0 ] && echo "$out" | grep -q 'GITHUB_REPO' && ok "no origin and no GITHUB_REPO -> clear error" || bad "no origin" "$rc $out"
fi
# --- hermes-review: CLI wrapper + Python unit tests (pytest via uv; skipped without uv) ---
out=$("$BIN/hermes-review" --help 2>&1)
echo "$out" | grep -q 'reviewer agent for Hermes PRs' && ok "hermes-review --help" || bad "review help" "$out"
out=$(cd "$tmp" && "$BIN/hermes-review" --dry-run 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'not inside a git repo' && ok "hermes-review outside a repo -> exit 2" || bad "review no repo" "$rc $out"
if command -v uv >/dev/null 2>&1; then
  out=$(cd "$ROOT" && PYTHONPATH="$ROOT/lib" PYTHONDONTWRITEBYTECODE=1 uv run -q --no-project \
        --python 3.12 --with pytest python -m pytest -q -p no:cacheprovider tests/py 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "pr_review unit tests: $(echo "$out" | tail -n 1)" || bad "pr_review unit tests" "$(echo "$out" | tail -n 20)"
  # Lint + format with the repo's ruff.toml (pinned ruff, so results do not drift).
  for lint in "check --output-format concise" "format --check"; do
    # shellcheck disable=SC2086  # $lint is two words on purpose
    out=$(cd "$ROOT" && uvx -q ruff@0.17.6 $lint lib/pr_review lib/hooks lib/watchdog.py tests/py 2>&1); rc=$?
    [ $rc -eq 0 ] && ok "ruff ${lint%% *}: clean" || bad "ruff ${lint%% *}" "$(echo "$out" | tail -n 20)"
  done
else
  echo "skip - pr_review unit tests and ruff (install uv to run them)"
fi
echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
