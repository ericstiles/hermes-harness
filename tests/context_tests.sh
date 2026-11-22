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
c=$(line_no "$log" '^CONTEXT: [^b]'); r=$(line_no "$log" '^RUN_RESULT=')
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

# --- export hangs (stuck Hermes CLI): stopped at HERMES_CONTEXT_TIMEOUT, run unchanged (bead 8qn) ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
began=$(date +%s)
out=$(STUB_SID=20261121_120000_aaa111 STUB_EXPORT_HANG=1 HERMES_CONTEXT_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1); rc=$?
took=$(( $(date +%s) - began )); log=$(ctx_log)
eq "context: a hung export times out with one unavailable line and the run result is unchanged" \
  "$rc|$(grep -c '^CONTEXT: [^b]' "$log")|$(grep '^CONTEXT: [^b]' "$log")|$(tail -n 1 "$log")" \
  "0|1|CONTEXT: unavailable (export timed out after 1s)|RUN_RESULT=OK_DONE"
[ "$took" -lt 20 ] && ok "context: a hung export does not hold up the loop (${took}s)" \
  || bad "context: a hung export does not hold up the loop" "${took}s"
grep -q '^WATCHDOG: ' "$log" && bad "context: the export's watchdog note stays out of the raw log" "$(grep '^WATCHDOG: ' "$log")" \
  || ok "context: the export's watchdog note stays out of the raw log"

# --- export broken (empty or garbage): one unavailable line, run unchanged ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; echo 'not json' > "$tmp/ctx-bad.json"
out=$(STUB_SID=20261121_120000_aaa111 STUB_EXPORT="$tmp/ctx-bad.json" runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ctx_log)
eq "context: a broken export logs one 'unavailable' line and the run still exits 0" \
  "$rc|$(grep -c '^CONTEXT: [^b]' "$log")|$(grep '^CONTEXT: [^b]' "$log")" "0|1|CONTEXT: unavailable (not JSON)"

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

# --- baseline at run start: `hermes prompt-size --json` in the repo root -> first raw-log line (39w.3) ---
CTX_BASE='CONTEXT: baseline system_prompt=100 chars tools=3 (900 B schema) memory=10 skills_index=20 context_files=30 (chars and bytes; Hermes reports no token count)'
printf '{\n "system_prompt": {"chars": 100, "bytes": 101},\n "skills_index": {"chars": 20, "bytes": 20},\n "memory": {"chars": 10, "bytes": 10},\n "tools": {"count": 3, "json_bytes": 900},\n "sections": [["stable", 1, 1], ["context (AGENTS.md/cwd files)", 30, 30]]\n}\n' > "$tmp/ctx-ps.json"
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_PROMPT_SIZE="$tmp/ctx-ps.json" runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ctx_log)
eq "context: baseline line comes from 'hermes prompt-size --json' at the start of the run" \
  "$(head -n 1 "$log")|$(grep -c '^hermes prompt-size --json$' "$STUB_LOG")|$(grep '^prompt-size cwd=' "$STUB_LOG")" \
  "$CTX_BASE|1|prompt-size cwd=$W"
say "$out" | grep -qF "$CTX_BASE" && grep -qF "] $CTX_BASE" "$W"/logs/run-*.timed.txt \
  && ok "context: baseline line is on the terminal and in the timed log" || bad "context: baseline terminal/timed" "$out"
[ "$(grep -n '^  ┊' "$log" | head -n 1 | cut -d: -f1)" -gt 1 ] && [ "$rc" = 0 ] \
  && ok "context: baseline line is above Hermes output and the run still exits 0" || bad "context: baseline position" "$rc $(head -n 3 "$log")"

rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(runit "$BIN/hermes-run" 1 2>&1); rc=$?
log=$(ctx_log)
eq "context: baseline failure prints 'baseline unavailable' and the run continues" \
  "$rc|$(head -n 1 "$log")|$(tail -n 1 "$log")" "0|CONTEXT: baseline unavailable (hermes prompt-size exited 1)|RUN_RESULT=OK_DONE"
eq "context: a failing prompt-size names its exit code" "$(head -n 1 "$log")" "CONTEXT: baseline unavailable (hermes prompt-size exited 1)"
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; : > "$tmp/ctx-empty.json"
out=$(STUB_PROMPT_SIZE="$tmp/ctx-empty.json" runit "$BIN/hermes-run" 1 2>&1); log=$(ctx_log)
eq "context: prompt-size that succeeds with no output is 'empty input'" "$(head -n 1 "$log")" "CONTEXT: baseline unavailable (empty input)"

rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; began=$(date +%s)
out=$(STUB_PROMPT_SIZE_HANG=1 HERMES_BASELINE_TIMEOUT=1s runit "$BIN/hermes-run" 1 2>&1); rc=$?
took=$(( $(date +%s) - began )); log=$(ctx_log)
eq "context: a hung prompt-size is stopped and the run continues" \
  "$rc|$(head -n 1 "$log")|$(tail -n 1 "$log")" "0|CONTEXT: baseline unavailable (hermes prompt-size timed out after 1s)|RUN_RESULT=OK_DONE"
[ "$took" -lt 20 ] && ok "context: a hung prompt-size does not hold up the run (${took}s)" || bad "context: prompt-size hang" "${took}s"

same=0; total=0
for f in timeout_killed blocked queue_empty model_api_error beads_sync auth_error sandbox_down ok_done \
         trap_test_404_and_aux_timeout trap_sentinel_in_prose trap_sync_in_prose; do
  for first in "$CTX_BASE" "CONTEXT: baseline unavailable (hermes prompt-size timed out after 15s)"; do
    total=$((total + 1)); { echo "$first"; cat "$FX/$f.log"; } > "$tmp/ctx-fx.log"
    [ "$(hermes_classify "$FX/$f.log")" = "$(hermes_classify "$tmp/ctx-fx.log")" ] && same=$((same + 1))
  done
done
eq "context: all 11 classifier fixtures classify identically with a baseline line first" "$same" "$total"

# --- resumed / wrap-up runs skip the fresh-session baseline (0af) ---
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_HANG_FIRST=1 STUB_SESSIONS=1 STUB_FIXTURE_2="$FX/wrapup_saved.log" STUB_PROMPT_SIZE="$tmp/ctx-ps.json" RUN_TIMEOUT=1s \
      runit "$BIN/hermes-run" 1 2>&1)
first=$(ls -t "$W"/logs/run-*.log | tail -n 1); wrap=$(ls -t "$W"/logs/run-*.log | head -n 1)
[ "$first" != "$wrap" ] && head -n 1 "$first" | grep -q '^CONTEXT: baseline ' && ! grep -q '^CONTEXT: baseline' "$wrap" \
  && [ "$(grep -c '^hermes prompt-size' "$STUB_LOG")" = 1 ] \
  && ok "context: a resumed run logs no baseline line" \
  || bad "context: a resumed run logs no baseline line" "$(head -n 1 "$first") / $(head -n 1 "$wrap") / $(grep -c '^hermes prompt-size' "$STUB_LOG") calls"

# --- docs and repo hygiene ---
for v in HERMES_CONTEXT_TIMEOUT HERMES_BASELINE_TIMEOUT HERMES_CONTEXT_WINDOW; do
  grep -q "\`$v\`" "$ROOT/README.md" && ok "docs: README lists $v" || bad "docs: README lists $v" "missing"
done
git -C "$ROOT" -c core.excludesFile=/dev/null check-ignore -q .beads/issues.jsonl \
  && ok "repo: .beads/issues.jsonl is ignored by the repo itself" || bad "repo: issues.jsonl ignore" "not in .beads/.gitignore"
rm -rf "$W/logs" "$tmp"/ctx-*
