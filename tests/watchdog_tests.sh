#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $BIN
# $STUB_LOG $STUB_COUNT; stub hermes: STUB_WRITES="<path> <count>" writes <path> every 0.4s on the
# first call, then opens a PR). Bead 7zi: at RUN_TIMEOUT, lib/watchdog.py extends a run that made
# progress (HERMES_EXTEND, up to HERMES_EXTEND_CAP) and stops one that did not.
fresh() { rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; }

# a run still writing project files at RUN_TIMEOUT is extended and finishes its PR
fresh
out=$(STUB_WRITES="/workspace/widgets/src/a.py 6" RUN_TIMEOUT=1s HERMES_EXTEND=1s HERMES_EXTEND_CAP=10s runit "$BIN/hermes-run" 1 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q '^WATCHDOG: EXTENDED +1s' "$W"/logs/run-*.log \
  && ok "watchdog: a progressing run is extended past RUN_TIMEOUT and finishes OK_DONE" || bad "watchdog: extend" "$rc $(echo "$out" | tail -4)"
grep -q 'WATCHDOG: EXTENDED' "$W"/logs/run-*.timed.txt && ok "watchdog: decisions are in the timed log too" || bad "watchdog: timed log" "$(ls "$W/logs")"

# a run writing only /tmp scratch files is stopped at RUN_TIMEOUT
fresh
out=$(STUB_WRITES="/tmp/probe.py 8" RUN_TIMEOUT=1s HERMES_EXTEND=1s HERMES_EXTEND_CAP=10s HERMES_WRAPUP_TIMEOUT=0 runit "$BIN/hermes-run" 1 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q '^FINAL_RESULT=TIMEOUT$' && grep -q '^WATCHDOG: NO_PROGRESS' "$W"/logs/run-*.log \
  && ok "watchdog: a run with only /tmp writes is stopped as TIMEOUT (NO_PROGRESS)" || bad "watchdog: no progress" "$rc $(echo "$out" | tail -4)"

# progress forever: stopped at HERMES_EXTEND_CAP
fresh; t0=$(date +%s)
out=$(STUB_WRITES="/workspace/widgets/src/a.py 30" RUN_TIMEOUT=1s HERMES_EXTEND=1s HERMES_EXTEND_CAP=3s HERMES_WRAPUP_TIMEOUT=0 runit "$BIN/hermes-run" 1 2>&1); rc=$?
el=$(( $(date +%s) - t0 ))
[ $rc -eq 1 ] && grep -q '^WATCHDOG: CAP_REACHED (3s)' "$W"/logs/run-*.log && [ "$el" -lt 10 ] \
  && ok "watchdog: never runs past HERMES_EXTEND_CAP (${el}s)" || bad "watchdog: cap" "$rc ${el}s $(echo "$out" | tail -4)"

# HERMES_EXTEND=0 keeps the old hard limit
fresh
out=$(STUB_WRITES="/workspace/widgets/src/a.py 8" RUN_TIMEOUT=1s HERMES_EXTEND=0 HERMES_WRAPUP_TIMEOUT=0 runit "$BIN/hermes-run" 1 2>&1)
grep -q '^WATCHDOG: TIME_LIMIT' "$W"/logs/run-*.log && echo "$out" | grep -q '^FINAL_RESULT=TIMEOUT$' \
  && ok "watchdog: HERMES_EXTEND=0 is a hard limit at RUN_TIMEOUT" || bad "watchdog: extend 0" "$(echo "$out" | tail -4)"

# the wrap-up is never extended: it gets exactly HERMES_WRAPUP_TIMEOUT
fresh
out=$(STUB_HANG_FIRST=1 STUB_SESSIONS=1 STUB_FIXTURE_2="$FX/wrapup_saved.log" RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1)
echo "$out" | grep -q 'timeout: 1s (+20m on progress, cap 180m)' && ok "watchdog: the run header shows the limit, extension and cap" || bad "watchdog: header" "$(echo "$out" | head -2)"

# supervise shows the watchdog's last decision
fresh
STUB_WRITES="/tmp/probe.py 8" RUN_TIMEOUT=1s HERMES_EXTEND=1s HERMES_WRAPUP_TIMEOUT=0 runit "$BIN/hermes-run" 1 >/dev/null 2>&1
out=$(HERMES_LOG_DIR="$W/logs" runit "$BIN/hermes-supervise")
echo "$out" | grep -q '^WATCHDOG=WATCHDOG: NO_PROGRESS' && ok "supervise: shows the watchdog's last decision" || bad "supervise: watchdog" "$out"

grep -q 'PROGRESS:' "$ROOT/templates/AGENTS_WORKFLOW.md" && ok "template: PROGRESS: notes at milestones" || bad "template: PROGRESS rule" "missing"
rm -rf "$W/logs"
