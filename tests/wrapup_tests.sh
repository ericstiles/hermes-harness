#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN $ROOT
# $STUB_LOG $STUB_COUNT; stub hermes: STUB_FIXTURE for call 1, STUB_FIXTURE_2 for later calls,
# STUB_SESSIONS=1 makes `hermes sessions list` show a harness session started "now").
# Incident 2026-11-20 (organize_music b8p.37): a run spent its whole 90m exploring and was killed;
# nothing survived and the retry would have started from zero. A TIMEOUT, or a Hermes crash
# (AGENT_CRASHED), now resumes the session for a short wrap-up that pushes WIP and appends a
# "WIP:" note, before the claim is released.
. "$ROOT/lib/wrapup.sh"
CF="$FX/agent_crashed.log"; WF="$FX/wrapup_saved.log"
first_line() { grep -n "$2" "$1" | head -n 1 | cut -d: -f1; }

# --- classification: a traceback with a non-timeout exit is a crash ---
eq "classify agent_crashed (traceback, exit 1)" "$(hermes_classify "$CF" 1)" AGENT_CRASHED
eq "a traceback after the timeout kill stays TIMEOUT" "$(hermes_classify "$CF" 124)" TIMEOUT
[ "$(hermes_classify "$CF" 130)" != AGENT_CRASHED ] && ok "a traceback after Ctrl-C (exit 130) is not a crash" || bad "ctrl-c" "$(hermes_classify "$CF" 130)"
eq "a killed run without a traceback stays TIMEOUT" "$(hermes_classify "$FX/timeout_killed.log" 1)" TIMEOUT

# --- helpers ---
eq "project writes ignore /tmp scratch files" "$(hh_project_writes "$CF")" 0
eq "project writes count write/patch outside /tmp" "$(hh_project_writes "$FX/timeout_killed.log")" 2
eq "a git commit counts as a project write" "$(hh_project_writes "$WF")" 1
hh_wip_saved "$WF" && ok "RUN_WIP_SAVED line detected" || bad "wip saved" "$WF"
hh_wip_saved "$FX/timeout_killed.log" && bad "wip saved false positive" "timeout_killed" || ok "no RUN_WIP_SAVED line -> not saved"

# --- hermes-run: timeout -> resume the session for a wrap-up -> then release the claim ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_HANG_FIRST=1 STUB_SESSIONS=1 STUB_FIXTURE_2="$WF" RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1); rc=$?
calls=$(grep -c '^hermes chat' "$STUB_LOG"); second=$(grep '^hermes chat' "$STUB_LOG" | sed -n 2p)
[ "$calls" = 2 ] && say "$second" | grep -qE -- '--resume [0-9]{8}_[0-9]{6}_abc123 ' \
  && ok "timeout: the killed session (found in 'hermes sessions list') is resumed for a wrap-up" || bad "timeout: wrap-up resume" "$calls | $second"
say "$second" | grep -q 'RUN_WIP_SAVED' && say "$second" | grep -q 'bd/widgets-abc' && say "$second" | grep -q 'WIP:' \
  && say "$second" | grep -q 'No human is present' && say "$second" | grep -q 'time limit' \
  && ok "timeout: the wrap-up prompt names the issue, the branch, the WIP note and the sentinel" || bad "timeout: wrap-up prompt" "$second"
say "$out" | grep -q 'wrap-up' && say "$out" | grep -q 'Progress saved' \
  && ok "timeout: hermes-run reports the wrap-up and that progress was saved" || bad "timeout: wrap-up report" "$out"
w=$(first_line "$STUB_LOG" '^hermes chat .*RUN_WIP_SAVED'); u=$(first_line "$STUB_LOG" 'bd unclaim widgets-abc')
[ -n "$w" ] && [ -n "$u" ] && [ "$w" -lt "$u" ] && ok "timeout: the claim is released only after the wrap-up" || bad "timeout: order" "$(cat "$STUB_LOG")"
[ $rc -eq 1 ] && say "$out" | grep -q '^FINAL_RESULT=TIMEOUT$' && ok "timeout: the loop still ends as TIMEOUT" || bad "timeout: final" "$rc $(echo "$out" | tail -3)"
wlog=$(grep -l '^WRAPUP_OF=' "$W"/logs/run-*.log | head -n 1)
[ -n "$wlog" ] && [ "$(grep '^RUN_RESULT=' "$wlog" | tail -n 1)" = RUN_RESULT=TIMEOUT ] && [ -r "$(sed -n 's/^WRAPUP_OF=//p' "$wlog")" ] \
  && ok "timeout: the wrap-up log points at the killed run and ends RUN_RESULT=TIMEOUT" || bad "timeout: wrap-up log" "$(ls "$W/logs")"

# supervise on the wrap-up log: the issue comes from the killed run; it only explored -> split, not relaunch
out=$(HERMES_LOG_DIR="$tmp/l4" runit "$BIN/hermes-supervise" "$wlog")
say "$out" | grep -q '^CLASS=TIMEOUT$' && say "$out" | grep -q '^ISSUE=widgets-abc$' && say "$out" | grep -q '^WIP_SAVED=yes$' \
  && ok "supervise: wrap-up log -> TIMEOUT, issue of the killed run, WIP_SAVED=yes" || bad "supervise: wrap-up" "$out"
say "$out" | grep -q '^ACTION=ASK_HUMAN$' && say "$out" | grep -q '^WHY=.*no project file' && say "$out" | grep -q 'split' \
  && ok "supervise: a timeout that wrote no project file -> split the issue on the first timeout" || bad "supervise: explored only" "$out"

# the wrap-up did not confirm -> warning, still TIMEOUT
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_HANG_FIRST=1 STUB_SESSIONS=1 STUB_FIXTURE_2="$FX/agent_stopped.log" RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1)
say "$out" | grep -q 'did not confirm RUN_WIP_SAVED' && say "$out" | grep -q '^FINAL_RESULT=TIMEOUT$' \
  && ok "timeout: an unconfirmed wrap-up warns and stays TIMEOUT" || bad "timeout: unconfirmed" "$(echo "$out" | tail -5)"

# no session found / wrap-up disabled -> a single run, claim still released
for v in "STUB_SESSIONS=0 HERMES_WRAPUP_TIMEOUT=15m" "STUB_SESSIONS=1 HERMES_WRAPUP_TIMEOUT=0"; do
  rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
  # shellcheck disable=SC2086  # $v is two assignments on purpose
  out=$(export $v; STUB_HANG_FIRST=1 RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1)
  [ "$(grep -c '^hermes chat' "$STUB_LOG")" = 1 ] && grep -q 'bd unclaim widgets-abc' "$STUB_LOG" \
    && ok "timeout with $v: no wrap-up, claim released" || bad "timeout $v" "$(cat "$STUB_LOG")"
  case $v in
    *SESSIONS=0*) say "$out" | grep -q 'no Hermes session found' && ok "no session found -> says why there is no wrap-up" || bad "no session note" "$out" ;;
    *) say "$out" | grep -q 'wrap-up' && bad "wrap-up disabled but mentioned" "$out" || ok "HERMES_WRAPUP_TIMEOUT=0 skips the wrap-up silently" ;;
  esac
done

# retry-on-timeout resumes the same session (keeps its context) instead of starting over
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_HANG_FIRST=1 STUB_SESSIONS=1 HERMES_RETRY_ON_TIMEOUT=1 RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1); rc=$?
second=$(grep '^hermes chat' "$STUB_LOG" | sed -n 2p)
say "$second" | grep -qE -- '--resume [0-9]{8}_[0-9]{6}_abc123 ' && say "$second" | grep -q 'Continue the issue' \
  && ! grep -q 'bd unclaim' "$STUB_LOG" && [ $rc -eq 0 ] \
  && ok "retry-on-timeout resumes the killed session and keeps the claim" || bad "retry resume" "$rc | $second | $(grep bd "$STUB_LOG")"

# --- a Hermes crash gets the same wrap-up ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_PREFIX=learn_hermes STUB_FIXTURE="$CF" STUB_EXIT=1 STUB_SESSIONS=1 STUB_FIXTURE_2="$WF" runit "$BIN/hermes-run" 1 2>&1); rc=$?
second=$(grep '^hermes chat' "$STUB_LOG" | sed -n 2p)
say "$second" | grep -q -- '--resume ' && say "$second" | grep -q 'crash' && say "$second" | grep -q 'bd/learn_hermes-abc' \
  && ok "crash: the session is resumed for a wrap-up that says it crashed" || bad "crash: wrap-up" "$second"
w=$(first_line "$STUB_LOG" '^hermes chat .*RUN_WIP_SAVED'); u=$(first_line "$STUB_LOG" 'bd unclaim learn_hermes-abc')
[ -n "$w" ] && [ -n "$u" ] && [ "$w" -lt "$u" ] && ok "crash: claim released after the wrap-up" || bad "crash: unclaim" "$(cat "$STUB_LOG")"
[ $rc -eq 1 ] && say "$out" | grep -q '^FINAL_RESULT=AGENT_CRASHED$' && say "$out" | grep -q 'crashed' \
  && ok "crash: the loop stops as AGENT_CRASHED" || bad "crash: final" "$rc $(echo "$out" | tail -3)"
clog=$(grep -L '^WRAPUP_OF=' "$W"/logs/run-*.log | head -n 1)   # the crashed run's own log
out=$(HERMES_LOG_DIR="$tmp/l5" runit "$BIN/hermes-supervise" "$clog")
say "$out" | grep -q '^ACTION=AUTO_RELAUNCH$' && say "$out" | grep -q -- '--reason AGENT_CRASHED --issue learn_hermes-abc' \
  && say "$out" | grep -q '^WHY=.*sqlite3.OperationalError: database is locked' \
  && ok "supervise: crash -> AUTO_RELAUNCH, names the exception" || bad "supervise: crash" "$out"

# --- template: the claim is synced at once, and a WIP branch is continued, not restarted ---
T="$ROOT/templates/AGENTS_WORKFLOW.md"
grep -q 'claim --json`, then `bd dolt push`' "$T" && ok "template: push beads right after the claim" || bad "template: claim push" "missing"
grep -q 'WIP:' "$T" && grep -q 'git checkout -B bd/<id> origin/bd/<id>' "$T" \
  && ok "template: continue from a WIP branch and its WIP note" || bad "template: WIP rule" "missing"
rm -rf "$W/logs"
