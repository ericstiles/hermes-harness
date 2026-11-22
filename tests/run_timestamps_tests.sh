#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit,
# $tmp $W $FX $BIN, and the stub hermes: STUB_FIXTURE=<file> is printed, STUB_EXIT=<n>).
# hermes-run keeps the RAW log untouched and writes a timestamped twin run-*.timed.txt.
only_log() { ls "$W"/logs/run-*.log; }
only_timed() { ls "$W"/logs/run-*.timed.txt 2>/dev/null; }

# every classifier fixture, run through hermes-run: raw log = fixture + STOP_REASON + exactly one
# CONTEXT: line (39w.2) + RUN_RESULT (STOP_REASON is "unknown": run_tests.sh points HERMES_AGENT_LOG
# at a file that does not exist; the CONTEXT text depends on the fixture, so it is copied)
ctx_of() { # <raw log> -> its single CONTEXT: line, or a marker that makes cmp fail
  [ "$(grep -c '^CONTEXT: ' "$1")" = 1 ] && grep '^CONTEXT: ' "$1" || echo "<not exactly one CONTEXT: line>"
}
same=yes; diffs=""
for pair in timeout_killed:TIMEOUT blocked:BLOCKED queue_empty:QUEUE_EMPTY model_api_error:MODEL_API_ERROR \
            beads_sync:BEADS_SYNC_ERROR auth_error:AUTH_ERROR sandbox_down:SANDBOX_DOWN ok_done:OK_DONE \
            trap_test_404_and_aux_timeout:OK_DONE trap_sentinel_in_prose:OK_DONE trap_sync_in_prose:OK_DONE; do
  n=${pair%%:*}; want=${pair##*:}; rm -rf "$W/logs"
  STUB_FIXTURE="$FX/$n.log" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
  { cat "$FX/$n.log"; echo "STOP_REASON: unknown"; ctx_of "$(only_log)"; echo "RUN_RESULT=$want"; } > "$tmp/want_raw"
  cmp -s "$tmp/want_raw" "$(only_log)" || { same=no; diffs="$diffs $n"; }
done
eq "timestamps: raw run log still classifies exactly as before (11 fixtures)" "$same" "yes${diffs:+ ($diffs)}"

# the timed twin: every line stamped, ends with the result, and is not a *.log
rm -rf "$W/logs"
out=$(STUB_FIXTURE="$FX/ok_done.log" runit "$BIN/hermes-run" 1 2>&1)
t=$(only_timed)
[ -n "$t" ] && [ -s "$t" ] && ! grep -qv '^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] ' "$t" \
  && ok "timestamps: hermes-run writes run-*.timed.txt with [HH:MM:SS] on every line" || bad "timestamps: timed twin" "$(ls "$W/logs"; head -3 "$t" 2>/dev/null)"
grep -q '^\[[0-9:]*\] RUN_RESULT=OK_DONE$' "$t" 2>/dev/null && ok "timestamps: timed twin ends with the RUN_RESULT" || bad "timestamps: timed RUN_RESULT" "$(tail -3 "$t" 2>/dev/null)"
echo "$out" | grep -q '^\[[0-9:]*\] Resume this session with:' && ok "timestamps: terminal shows timestamped Hermes output" || bad "timestamps: terminal" "$out"

# run summary: one RUN_TIME per run, a total before FINAL_RESULT; never in the raw log
fx_issue=$(sed -n 's/.*bd update \([^ ]*\) --claim.*/\1/p' "$FX/ok_done.log" | head -n 1)
echo "$out" | grep -qE "^RUN_TIME start=[0-9]{2}:[0-9]{2}:[0-9]{2} end=[0-9]{2}:[0-9]{2}:[0-9]{2} elapsed=[0-9]+s issue=${fx_issue:-MISSING}\$" \
  && echo "$out" | grep -qE '^RUN_TIME total=[0-9]+s start=[0-9:]{8} end=[0-9:]{8} runs=1$' \
  && [ "$(echo "$out" | grep -E '^(RUN_TIME total|FINAL_RESULT)' | head -n 1 | cut -c1-14)" = "RUN_TIME total" ] \
  && ok "timestamps: run summary line has start, end and total elapsed" || bad "timestamps: RUN_TIME" "$out"
raw_logs=$(only_log 2>/dev/null)
[ "$(echo "$raw_logs" | grep -c .)" = 1 ] && ! grep -q RUN_TIME "$raw_logs" \
  && ok "timestamps: RUN_TIME lines stay out of the raw log" || bad "timestamps: RUN_TIME in raw log" "$raw_logs $(tail -3 $raw_logs 2>/dev/null)"

# hermes chat's own exit status survives the 3-stage pipeline (PR url + exit 3 is not OK_DONE)
rm -rf "$W/logs"
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_EXIT=3 runit "$BIN/hermes-run" 1 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q '^RUN_RESULT=UNKNOWN$' "$(only_log)" \
  && ok "timestamps: exit status of hermes chat is preserved through the filter" || bad "timestamps: exit status" "$rc $(tail -2 "$(only_log)")"

# a dead filter (here: a python3 that exits at once for tsfilter.py only; the watchdog still
# runs on the real python3) must not cut the raw log or kill the run
rm -rf "$W/logs"; mkdir -p "$tmp/deadpy"
printf '#!/bin/sh\ncase "$*" in *tsfilter.py*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$tmp/deadpy/python3"; chmod +x "$tmp/deadpy/python3"
{ seq 1 20000 | sed 's/^/filler line /'; tail -n 8 "$FX/ok_done.log"; } > "$tmp/big.log"
out=$(PATH="$tmp/deadpy:$PATH" STUB_FIXTURE="$tmp/big.log" runit "$BIN/hermes-run" 1 2>&1); rc=$?
{ cat "$tmp/big.log"; echo "STOP_REASON: unknown"; ctx_of "$(only_log)"; echo "RUN_RESULT=OK_DONE"; } > "$tmp/want_big"
[ $rc -eq 0 ] && cmp -s "$tmp/want_big" "$(only_log)" && echo "$out" | grep -q 'timestamp filter' \
  && ok "timestamps: a dead filter leaves the raw log complete and warns" || bad "timestamps: dead filter" "$rc $(wc -l < "$(only_log)") $(echo "$out" | tail -3)"
# BSD tee with SIGPIPE ignored prints "Broken pipe" per write; that must not flood the terminal
n_bp=$(echo "$out" | grep -c 'Broken pipe')
[ "$n_bp" -eq 0 ] && ok "timestamps: a dead filter does not flood the terminal with tee errors" || bad "timestamps: tee flood" "$n_bp Broken pipe lines"

# status and supervise keep reading the raw log, even when the timed twin is newer
rm -rf "$W/logs"; STUB_FIXTURE="$FX/blocked.log" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
sleep 1; touch "$W"/logs/run-*.timed.txt
# offline: no gh, and git may only use file:// so the fetch fails at once
mkdir -p "$tmp/nogh"; printf '#!/bin/sh\nexit 1\n' > "$tmp/nogh/gh"; chmod +x "$tmp/nogh/gh"
out=$(PATH="$tmp/nogh:$PATH" GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 runit "$BIN/hermes-status" 2>&1)
echo "$out" | grep -qE '^file: .*/run-[0-9-]+\.log ' && echo "$out" | grep -q '^class: BLOCKED$' \
  && ok "status: latest log is the raw log, not its timed twin" || bad "status: twin" "$(echo "$out" | grep -E '^(file|class):')"
eq "supervise: latest log is the raw log, not its timed twin" "$(runit "$BIN/hermes-supervise" | sed -n 's/^CLASS=//p')" BLOCKED
rm -rf "$W/logs"
