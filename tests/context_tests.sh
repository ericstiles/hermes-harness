#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub hermes: STUB_SID adds a "Session:" footer, STUB_EXPORT is what
# `hermes sessions export` prints, STUB_SESSIONS=1 lists a harness session started "now").
# Bead hermes-harness-39w.2: after each run, one CONTEXT: line (lib/context_usage.py) goes to the
# terminal and both logs, after classification and before RUN_RESULT, never changing the result.
CTX_SECRET="CTX-SECRET-5d1e"
CTX_EXPORT="$tmp/ctx-export.json"
printf '{"id":"20261121_120000_aaa111","model":"stub-model","input_tokens":10,"output_tokens":2,"cache_read_tokens":300,"api_call_count":4,"system_prompt":"%s","messages":[{"role":"user","content":"%s"}]}\n' \
  "$CTX_SECRET" "$CTX_SECRET" > "$CTX_EXPORT"
ctx_log() { ls -t "$W"/logs/run-*.log 2>/dev/null | head -n 1; }
line_no() { grep -n "$2" "$1" | head -n 1 | cut -d: -f1; }

# --- finished run: footer session -> export -> CONTEXT: used line, exit code unchanged ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; mkdir -p "$tmp/ctx-tmpdir"
out=$(TMPDIR="$tmp/ctx-tmpdir" STUB_SID=20261121_120000_aaa111 STUB_EXPORT="$CTX_EXPORT" HERMES_CONTEXT_WINDOW=4096 \
      runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ctx_log)
want='CONTEXT: used cumulative in=10 out=2 cache_read=300 api_calls=4 model=stub-model'
grep -q "^$want .*\[window: 4096 (explicit --window)\]$" "$log" \
  && ok "context: finished run logs CONTEXT: used from its session export" || bad "context: used line" "$(grep CONTEXT "$log")"
grep -q '^hermes sessions export --session-id 20261121_120000_aaa111 -$' "$STUB_LOG" \
  && ok "context: the export is asked for the footer's session id" || bad "context: export call" "$(grep 'sessions' "$STUB_LOG")"
say "$out" | grep -q "^$want " && ok "context: CONTEXT line is shown on the terminal" || bad "context: terminal" "$out"
grep -q "\] $want " "$W"/logs/run-*.timed.txt && ok "context: CONTEXT line is in the timed log" || bad "context: timed log" "$(grep CONTEXT "$W"/logs/run-*.timed.txt)"
eq "context: a finished run still exits 0 and classifies OK_DONE" "$rc|$(tail -n 1 "$log")" "0|RUN_RESULT=OK_DONE"
c=$(line_no "$log" '^CONTEXT: '); r=$(line_no "$log" '^RUN_RESULT=')
[ -n "$c" ] && [ -n "$r" ] && [ "$c" -lt "$r" ] && [ "$(grep -c '^RUN_RESULT=' "$log")" = 1 ] \
  && ok "context: CONTEXT lines come before RUN_RESULT in the log" || bad "context: order" "CONTEXT@$c RUN_RESULT@$r"
leak=$(grep -rl "$CTX_SECRET" "$W" "$tmp/ctx-tmpdir" 2>/dev/null)
[ -z "$leak" ] && [ -z "$(ls -A "$tmp/ctx-tmpdir")" ] \
  && ok "context: no export file left in the repo, logs dir or TMPDIR" || bad "context: leftovers" "$leak $(ls -A "$tmp/ctx-tmpdir")"

# --- killed run, no footer and no session found: unavailable, result unchanged ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_HANG_FIRST=1 RUN_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ls -t "$W"/logs/run-*.log | tail -n 1)
grep -q '^CONTEXT: unavailable (no session found: no Session: footer and no harness session in hermes sessions list)$' "$log" \
  && ok "context: killed run without a session logs 'unavailable'" || bad "context: killed unavailable" "$(grep CONTEXT "$log")"
eq "context: ... and the run result is unchanged" "$rc|$(grep '^RUN_RESULT=' "$log" | tail -n 1)" "1|RUN_RESULT=TIMEOUT"
grep -q 'sessions export' "$STUB_LOG" && bad "context: no export without a session id" "$(grep sessions "$STUB_LOG")" \
  || ok "context: no export is attempted without a session id"

# --- killed run: the harness session that started with it is exported ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_HANG_FIRST=1 STUB_SESSIONS=1 STUB_FIXTURE_2="$FX/wrapup_saved.log" STUB_EXPORT="$CTX_EXPORT" RUN_TIMEOUT=1s \
      runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ls -t "$W"/logs/run-*.log | tail -n 1)
grep -qE '^hermes sessions export --session-id [0-9]{8}_[0-9]{6}_abc123 -$' "$STUB_LOG" \
  && grep -q "^$want " "$log" && ok "context: killed run exports the harness session that started with it" \
  || bad "context: killed run session" "$(grep sessions "$STUB_LOG") / $(grep CONTEXT "$log")"

# --- export broken (empty or garbage): one unavailable line, run unchanged ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; echo 'not json' > "$tmp/ctx-bad.json"
out=$(STUB_SID=20261121_120000_aaa111 STUB_EXPORT="$tmp/ctx-bad.json" runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ctx_log)
eq "context: a broken export logs one 'unavailable' line and the run still exits 0" \
  "$rc|$(grep -c '^CONTEXT: ' "$log")|$(grep '^CONTEXT: ' "$log")" "0|1|CONTEXT: unavailable (not JSON)"

# --- the classifier ignores CONTEXT lines (all 11 fixtures, both line kinds appended) ---
same=0; total=0
for f in timeout_killed blocked queue_empty model_api_error beads_sync auth_error sandbox_down ok_done \
         trap_test_404_and_aux_timeout trap_sentinel_in_prose trap_sync_in_prose; do
  for extra in "$want (summed over all API calls; no peak available, so no %) [window: 262144 (ollama /api/ps)]" \
               "CONTEXT: unavailable (no session found: no Session: footer and no harness session in hermes sessions list)"; do
    total=$((total + 1)); { cat "$FX/$f.log"; echo "$extra"; } > "$tmp/ctx-fx.log"
    [ "$(hermes_classify "$FX/$f.log")" = "$(hermes_classify "$tmp/ctx-fx.log")" ] && same=$((same + 1))
  done
done
eq "context: all 11 classifier fixtures classify identically with CONTEXT: lines appended" "$same" "$total"
rm -rf "$W/logs" "$tmp"/ctx-*
