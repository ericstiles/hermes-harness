#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub bd: STUB_STATS / STUB_READY answer `bd stats` / `bd ready`,
# STUB_BD_STATS_HANG=1 hangs). Bead hermes-harness-9jj: each run starts with the bead it is about to
# work and the queue's numbers; each run names the bead it claimed; the loop ends with a summary.
BS_STATS='{"schema_version":1,"summary":{"blocked_issues":2,"closed_issues":7,"epics_eligible_for_closure":0,"in_progress_issues":0,"open_issues":5,"ready_issues":3,"total_issues":12}}'
BS_READY='[{"id":"widgets-abc","title":"Do the thing","priority":2,"status":"open"}]'
BS_START='BEADS: next widgets-abc "Do the thing" (P2) | ready 3 in_progress 0 blocked 2 | open 5 closed 7 of 12 | epics ready to close 0'
bs_log() { ls "$W"/logs/run-*.log 2>/dev/null | head -n 1; }

# `bd show` of the picked bead: as it stands once the run has opened its PR (the notes check reads it)
mkdir -p "$tmp/bs-beads"
printf '[{"id":"widgets-abc","title":"Do the thing","priority":2,"status":"in_progress","notes":"PR: %s"}]\n' \
  https://github.com/o/r/pull/1 > "$tmp/bs-beads/widgets-abc.json"
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$( (export STUB_STATS="$BS_STATS" STUB_READY="$BS_READY" STUB_BEADS="$tmp/bs-beads"; runit "$BIN/hermes-run" 1) 2>&1); rc=$?
log=$(bs_log)
eq "beads: start line names the expected next bead and the counts" "$(sed -n 2p "$log")" "$BS_START"
say "$out" | grep -qF "$BS_START" && grep -qF "] $BS_START" "$W"/logs/run-*.timed.txt \
  && ok "beads: start line is on the terminal and in the timed log" || bad "beads: start terminal/timed" "$out"
grep -q '^bd ready --exclude-type epic --exclude-label owner-present --sort priority --limit 1 --json$' "$STUB_LOG" \
  && grep -qx 'bd show widgets-abc --json' "$STUB_LOG" \
  && ok "beads: next is the issue picked with the agent's own command" || bad "beads: pick command" "$(grep -E '^bd (ready|show)' "$STUB_LOG")"
say "$out" | grep -q '^BEADS: worked widgets-abc$' \
  && ok "beads: worked line confirms the claimed bead" || bad "beads: worked line" "$(say "$out" | grep '^BEADS:')"
say "$out" | grep -q '^BEADS: loop worked 1 issue(s): widgets-abc | closed 7 of 12 | still to do: ready 3, open 5, blocked 2$' \
  && ok "beads: loop summary lists worked ids and what is left" || bad "beads: summary" "$(say "$out" | grep '^BEADS:')"
eq "beads: the run's result is unchanged" "$rc|$(tail -n 1 "$log")" "0|RUN_RESULT=OK_DONE"

# bd giving nothing (stub default) -> one unavailable line, run unchanged
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?; log=$(bs_log)
eq "beads: bd giving no stats gives one unavailable line and the run continues" \
  "$rc|$(sed -n 2p "$log")|$(tail -n 1 "$log")" "0|BEADS: unavailable (empty input)|RUN_RESULT=OK_DONE"

# bd ready failing while bd stats works -> "next unavailable", never "next none" beside ready 3 (bead 97j)
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$( (export STUB_STATS="$BS_STATS" STUB_BD_READY_FAIL=1; runit "$BIN/hermes-run" 1) 2>&1); rc=$?; log=$(bs_log)
eq "beads: a failing bd ready says next unavailable, not an empty queue" \
  "$rc|$(grep -m 1 '^BEADS:' "$log")|$(tail -n 1 "$log")" \
  "0|BEADS: next unavailable | ready 3 in_progress 0 blocked 2 | open 5 closed 7 of 12 | epics ready to close 0|RUN_RESULT=OK_DONE"

# bd hanging -> stopped at HERMES_BEADS_TIMEOUT, run unchanged and quick
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; began=$(date +%s)
out=$( (export STUB_BD_STATS_HANG=1 HERMES_BEADS_TIMEOUT=1s; runit "$BIN/hermes-run" 1) 2>&1); rc=$?
took=$(( $(date +%s) - began )); log=$(bs_log)
eq "beads: a hanging bd gives one unavailable line and the run continues" \
  "$rc|$(sed -n 2p "$log")|$(tail -n 1 "$log")" "0|BEADS: unavailable (bd stats timed out after 1s)|RUN_RESULT=OK_DONE"
[ "$took" -lt 20 ] && ok "beads: a hanging bd does not hold up the run (${took}s)" || bad "beads: bd hang" "${took}s"

# the classifier ignores BEADS: lines (all 11 fixtures, lines first and last)
same=0; total=0
for f in timeout_killed blocked queue_empty model_api_error beads_sync auth_error sandbox_down ok_done \
         trap_test_404_and_aux_timeout trap_sentinel_in_prose trap_sync_in_prose; do
  total=$((total + 1)); { echo "$BS_START"; cat "$FX/$f.log"; echo "BEADS: worked widgets-abc"; } > "$tmp/bs-fx.log"
  [ "$(hermes_classify "$FX/$f.log")" = "$(hermes_classify "$tmp/bs-fx.log")" ] && same=$((same + 1))
done
eq "beads: all classifier fixtures classify identically with BEADS: lines" "$same" "$total"
rm -rf "$W/logs" "$tmp/bs-fx.log"
