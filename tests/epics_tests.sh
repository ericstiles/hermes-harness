#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub bd: STUB_EPICS plays back `bd epic close-eligible` rounds,
# STUB_EPICS_FAIL=1 fails it, $STUB_EPIC_COUNT counts the rounds).
# Bead hermes-harness-xw2.2: a finished epic left open can block all remaining work, so the agent
# finds nothing ready and the loop stops QUEUE_EMPTY although work exists. Before stopping,
# hermes-run closes eligible epics (cascading) and, if any closed, runs again.
export STUB_EPIC_COUNT="$tmp/epic-count"
epics_run() { # <max> [env...] : run hermes-run with run 1 = QUEUE_EMPTY and later runs OK_DONE
  local max=$1; shift
  rm -rf "$W/logs" "$STUB_COUNT" "$STUB_EPIC_COUNT"; : > "$STUB_LOG"
  out=$( (export "$@" STUB_FIXTURE="$FX/queue_empty.log" STUB_FIXTURE_2="$FX/ok_done.log"
          runit "$BIN/hermes-run" "$max") 2>&1 ); rc=$?
}

# --- an eligible epic: it closes, the loop runs again and picks up the unblocked work ---
EP_STATS='{"schema_version":1,"summary":{"blocked_issues":0,"closed_issues":3,"epics_eligible_for_closure":0,"in_progress_issues":0,"open_issues":1,"ready_issues":1,"total_issues":4}}'
epics_run 2 STUB_EPICS="w-e1||" STUB_STATS="$EP_STATS"
say "$out" | grep -q '^EPICS_CLOSED: w-e1$' && [ "$(grep -c '^hermes chat' "$STUB_LOG")" = 2 ] \
  && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' \
  && ok "epics: queue-empty check closes eligible epics and retries ready work" \
  || bad "epics: close and retry" "rc=$rc $(say "$out" | grep -E 'EPICS|FINAL|Queue') chats=$(grep -c '^hermes chat' "$STUB_LOG")"
grep -q '^bd dolt push' "$STUB_LOG" && ok "epics: closed epics are pushed (bd dolt push)" \
  || bad "epics: push after closing" "$(grep '^bd ' "$STUB_LOG")"
# the loop summary (bead 9jj) still prints once, just before RUN_TIME total=, on the epic-retry path
[ "$(say "$out" | grep -c '^BEADS: loop worked ')" = 1 ] \
  && say "$out" | grep -E '^(BEADS: loop worked |RUN_TIME total=)' | head -n 1 | grep -q '^BEADS: loop worked ' \
  && ok "epics: the loop summary prints once, before RUN_TIME total=, after an epic retry" \
  || bad "epics: summary on retry path" "$(say "$out" | grep -E '^(BEADS|RUN_TIME total)')"

# --- nested: a child epic, then its parent, close in one check ---
epics_run 2 STUB_EPICS="w-e1.1|w-e1|"
eq "epics: nested epics close in one check" "$(say "$out" | grep '^EPICS_CLOSED: ')" "EPICS_CLOSED: w-e1.1 w-e1"

# --- nothing eligible: stops QUEUE_EMPTY exactly as before ---
epics_run 3 STUB_EPICS=""
say "$out" | grep -q '^EPICS_CLOSED' && bad "epics: no-op prints nothing" "$(say "$out" | grep EPICS)" || true
eq "epics: no eligible epics is a no-op and the loop stops QUEUE_EMPTY" \
  "$rc|$(say "$out" | grep '^FINAL_RESULT=')|$(grep -c '^hermes chat' "$STUB_LOG")|$(grep -c '^bd dolt push' "$STUB_LOG")" \
  "0|FINAL_RESULT=QUEUE_EMPTY|1|0"

# --- bd failing: same result as before ---
epics_run 3 STUB_EPICS_FAIL=1
eq "epics: a failing close-eligible does not change the run's result" \
  "$rc|$(say "$out" | grep '^FINAL_RESULT=')|$(grep -c '^hermes chat' "$STUB_LOG")" "0|FINAL_RESULT=QUEUE_EMPTY|1"

# --- rounds are capped: a close-eligible that never runs dry stops after 10 rounds ---
epics_run 1 STUB_EPICS="a|b|c|d|e|f|g|h|i|j|k|l|m"
eq "epics: close-eligible rounds are capped at 10" "$(cat "$STUB_EPIC_COUNT")" 10
say "$out" | grep -q '^warning: stopped closing epics after 10 rounds; more may be eligible' \
  && ok "epics: hitting the round cap is logged as a warning" || bad "epics: cap warning" "$(say "$out" | grep -E 'EPICS|warning')"

# --- the classifier ignores EPICS_CLOSED lines ---
same=0; total=0
for f in timeout_killed blocked queue_empty model_api_error beads_sync auth_error sandbox_down ok_done \
         trap_test_404_and_aux_timeout trap_sentinel_in_prose trap_sync_in_prose; do
  total=$((total + 1)); { cat "$FX/$f.log"; echo "EPICS_CLOSED: w-e1.1 w-e1"; } > "$tmp/epics-fx.log"
  [ "$(hermes_classify "$FX/$f.log")" = "$(hermes_classify "$tmp/epics-fx.log")" ] && same=$((same + 1))
done
eq "epics: EPICS_CLOSED lines match no classifier pattern" "$same" "$total"
rm -rf "$W/logs" "$tmp/epics-fx.log" "$STUB_EPIC_COUNT"; unset STUB_EPIC_COUNT
