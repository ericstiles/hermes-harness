#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub hermes: STUB_FIXTURE for call 1, STUB_FIXTURE_2 for later calls).
# Incident 2026-11-19 (organize_music run 20261119_120608): the run log never said why Hermes
# stopped; only ~/.hermes/logs/agent.log had "Turn ended: reason=... api_calls=n/max ... session=".
# hermes-run now copies that line's reason into the run log as STOP_REASON, and a run that used
# its whole tool-call budget is TURN_LIMIT (wrap-up, release the claim), not AGENT_STOPPED.
. "$ROOT/lib/stop_reason.sh"
AL="$FX/agent_log_sample.log"; SF="$FX/agent_stopped.log"; TL="$FX/turn_limit.log"
SID=20261119_120609_702276
with_stop() { { cat "$1"; echo "STOP_REASON: $2"; } > "$tmp/sr.log"; echo "$tmp/sr.log"; }

# --- hh_stop_reason: this session's last Turn ended line, read-only ---
eq "stop reason: picks the line for this session id, not another session's" \
  "$(HERMES_AGENT_LOG="$AL" hh_stop_reason "$SID")" "text_response(finish_reason=stop) api_calls=67/150"
eq "stop reason: a budget hit reports max_iterations_reached" \
  "$(HERMES_AGENT_LOG="$AL" hh_stop_reason 20261121_080000_abcdef)" "max_iterations_reached(150/150) api_calls=150/150"
eq "stop reason: no line for the session -> unknown" "$(HERMES_AGENT_LOG="$AL" hh_stop_reason 20990101_000000_000000)" unknown
eq "stop reason: missing agent.log -> unknown" "$(HERMES_AGENT_LOG="$tmp/nope.log" hh_stop_reason "$SID")" unknown
eq "stop reason: no session id -> unknown" "$(HERMES_AGENT_LOG="$AL" hh_stop_reason "")" unknown
eq "stop reason: a session id that is a prefix of another does not match" \
  "$(HERMES_AGENT_LOG="$AL" hh_stop_reason 20261119_120609)" unknown

# --- classification ---
eq "stop reason: text_response without PR or sentinel stays AGENT_STOPPED (stopped early)" \
  "$(hermes_classify "$(with_stop "$SF" "text_response(finish_reason=stop) api_calls=67/150")" 0)" AGENT_STOPPED
eq "stop reason: api_calls == max classifies TURN_LIMIT" \
  "$(hermes_classify "$(with_stop "$SF" "text_response(finish_reason=stop) api_calls=150/150")" 0)" TURN_LIMIT
eq "stop reason: max_iterations_reached classifies TURN_LIMIT" \
  "$(hermes_classify "$(with_stop "$SF" "max_iterations_reached(150/150) api_calls=150/150")" 0)" TURN_LIMIT
eq "stop reason: budget_exhausted classifies TURN_LIMIT" \
  "$(hermes_classify "$(with_stop "$SF" "budget_exhausted api_calls=90/150")" 0)" TURN_LIMIT
eq "stop reason: Hermes' 'Reached maximum iterations' banner classifies TURN_LIMIT" "$(hermes_classify "$TL" 0)" TURN_LIMIT
eq "stop reason: text_response with PR URL stays OK_DONE" \
  "$(hermes_classify "$(with_stop "$FX/ok_done.log" "max_iterations_reached(150/150) api_calls=150/150")" 0)" OK_DONE
eq "stop reason: unknown keeps the old class" \
  "$(hermes_classify "$(with_stop "$SF" unknown)" 0)" AGENT_STOPPED
eq "stop reason: a sentinel wins over a budget hit" \
  "$(hermes_classify "$(with_stop "$FX/blocked.log" "budget_exhausted api_calls=150/150")" 0)" BLOCKED

# --- hermes-run writes STOP_REASON before RUN_RESULT ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
HERMES_RESUME_ON_STOP=0 HERMES_AGENT_LOG="$AL" STUB_FIXTURE="$SF" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
rl=$(ls "$W"/logs/run-*.log | head -n 1)
s=$(grep -n '^STOP_REASON: ' "$rl" | head -n 1 | cut -d: -f1); r=$(grep -n '^RUN_RESULT=' "$rl" | head -n 1 | cut -d: -f1)
[ "$(grep '^STOP_REASON: ' "$rl")" = "STOP_REASON: text_response(finish_reason=stop) api_calls=67/150" ] \
  && [ -n "$r" ] && [ "$s" -lt "$r" ] && ok "hermes-run: run log has STOP_REASON before RUN_RESULT" || bad "hermes-run STOP_REASON" "$(tail -n 4 "$rl")"
grep -q 'STOP_REASON: text_response' "${rl%.log}.timed.txt" && ok "hermes-run: the timed log has STOP_REASON too" \
  || bad "hermes-run timed STOP_REASON" "$(tail -n 3 "${rl%.log}.timed.txt")"

rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
HERMES_RESUME_ON_STOP=0 HERMES_AGENT_LOG="$tmp/nope.log" STUB_FIXTURE="$SF" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
rl=$(ls "$W"/logs/run-*.log | head -n 1)
grep -qx 'STOP_REASON: unknown' "$rl" && grep -qx 'RUN_RESULT=AGENT_STOPPED' "$rl" \
  && ok "hermes-run: missing agent.log line writes STOP_REASON: unknown and keeps the old class" || bad "hermes-run unknown" "$(tail -n 4 "$rl")"

# --- hermes-run: TURN_LIMIT -> wrap-up to save WIP, release the claim, stop ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(HERMES_AGENT_LOG="$AL" STUB_FIXTURE="$TL" STUB_FIXTURE_2="$FX/wrapup_saved.log" runit "$BIN/hermes-run" 3 2>&1); rc=$?
calls=$(grep -c '^hermes chat' "$STUB_LOG"); second=$(grep '^hermes chat' "$STUB_LOG" | sed -n 2p)
[ "$calls" = 2 ] && say "$second" | grep -q -- '--resume 20261121_080000_abcdef' && say "$second" | grep -q 'tool-call budget' \
  && say "$second" | grep -q 'RUN_WIP_SAVED' && ok "turn limit: the session is resumed once for a wrap-up, not a continue" \
  || bad "turn limit: wrap-up" "$calls | $second"
grep -q 'bd unclaim widgets-abc' "$STUB_LOG" && ok "turn limit: the claim is released after the wrap-up" \
  || bad "turn limit: unclaim" "$(grep '^bd' "$STUB_LOG" | tail -n 5)"
[ $rc -eq 1 ] && say "$out" | grep -q '^FINAL_RESULT=TURN_LIMIT$' && say "$out" | grep -qi 'split' \
  && ok "turn limit: the loop stops as TURN_LIMIT and says to split the issue" || bad "turn limit: final" "$rc $(echo "$out" | tail -n 4)"

# --- supervise: a human splits the issue ---
out=$(HERMES_LOG_DIR="$tmp/l5" runit "$BIN/hermes-supervise" "$TL")
say "$out" | grep -q '^CLASS=TURN_LIMIT$' && say "$out" | grep -q '^ACTION=ASK_HUMAN$' && say "$out" | grep -q '^WHY=.*split' \
  && ok "turn limit: supervise asks the human to split the issue" || bad "turn limit: supervise" "$out"
rm -rf "$W/logs"
