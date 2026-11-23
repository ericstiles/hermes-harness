#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit,
# $tmp $W $FX $BIN, and the stub hermes: STUB_FIXTURE=<file> is printed, STUB_EXIT=<n>).
# hermes-run keeps the RAW log untouched and writes a timestamped twin run-*.timed.txt.
only_log() { ls "$W"/logs/run-*.log; }
only_timed() { ls "$W"/logs/run-*.timed.txt 2>/dev/null; }

# every classifier fixture, run through hermes-run: raw log = CONTEXT: baseline line (39w.3) + fixture
# + STOP_REASON + exactly one
# CONTEXT: line (39w.2) + RUN_RESULT (STOP_REASON is "unknown": run_tests.sh points HERMES_AGENT_LOG
# at a file that does not exist; the CONTEXT text depends on the fixture, so it is copied)
ctx_of() { # <raw log> -> its single CONTEXT: line, or a marker that makes cmp fail
  [ "$(grep -c '^CONTEXT: [^b]' "$1")" = 1 ] && grep '^CONTEXT: [^b]' "$1" || echo "<not exactly one CONTEXT: line>"
}
beads_of() { # <raw log> -> its second line if it is the BEADS: start line (9jj), else a marker
  sed -n 2p "$1" | grep '^BEADS: ' || echo "<no BEADS: second line>"
}
base_of() { # <raw log> -> its first line if it is the CONTEXT: baseline line (39w.3), else a marker
  head -n 1 "$1" | grep '^CONTEXT: baseline ' || echo "<no CONTEXT: baseline first line>"
}
same=yes; diffs=""
for pair in timeout_killed:TIMEOUT blocked:BLOCKED queue_empty:QUEUE_EMPTY model_api_error:MODEL_API_ERROR \
            beads_sync:BEADS_SYNC_ERROR auth_error:AUTH_ERROR sandbox_down:SANDBOX_DOWN ok_done:OK_DONE \
            trap_test_404_and_aux_timeout:OK_DONE trap_sentinel_in_prose:OK_DONE trap_sync_in_prose:OK_DONE; do
  n=${pair%%:*}; want=${pair##*:}; rm -rf "$W/logs"
  STUB_FIXTURE="$FX/$n.log" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
  { base_of "$(only_log)"; beads_of "$(only_log)"; cat "$FX/$n.log"; echo "STOP_REASON: unknown"; ctx_of "$(only_log)"; echo "RUN_RESULT=$want"; } > "$tmp/want_raw"
  cmp -s "$tmp/want_raw" "$(only_log)" || { same=no; diffs="$diffs $n"; }
done
eq "timestamps: raw run log still classifies exactly as before (11 fixtures)" "$same" "yes${diffs:+ ($diffs)}"

# the timed twin: every line stamped, ends with the result, and is not a *.log
rm -rf "$W/logs"
out=$(STUB_FIXTURE="$FX/ok_done.log" runit "$BIN/hermes-run" 1 2>&1)
t=$(only_timed)
[ -n "$t" ] && [ -s "$t" ] && ! grep -qvE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}(,[^] ]+)?\] ' "$t" \
  && ok "timestamps: hermes-run writes run-*.timed.txt with [HH:MM:SS] on every line" || bad "timestamps: timed twin" "$(ls "$W/logs"; head -3 "$t" 2>/dev/null)"
grep -q '^\[[0-9:]*,learn_hermes-abc\] RUN_RESULT=OK_DONE$' "$t" 2>/dev/null && ok "timestamps: timed twin ends with the RUN_RESULT, stamped with the claimed bead" || bad "timestamps: timed RUN_RESULT" "$(tail -3 "$t" 2>/dev/null)"
say "$out" | grep -q '^\[[0-9:]*,learn_hermes-abc\] Resume this session with:' && ok "timestamps: terminal shows timestamped Hermes output, with the claimed bead" || bad "timestamps: terminal" "$out"

# run summary: one RUN_TIME per run, a total before FINAL_RESULT; never in the raw log
fx_issue=$(sed -n 's/.*bd update \([^ ]*\) --claim.*/\1/p' "$FX/ok_done.log" | head -n 1)
say "$out" | grep -qE "^RUN_TIME start=[0-9]{2}:[0-9]{2}:[0-9]{2} end=[0-9]{2}:[0-9]{2}:[0-9]{2} elapsed=[0-9]+s issue=${fx_issue:-MISSING}\$" \
  && say "$out" | grep -qE '^RUN_TIME total=[0-9]+s start=[0-9:]{8} end=[0-9:]{8} runs=1$' \
  && [ "$(say "$out" | grep -E '^(RUN_TIME total|FINAL_RESULT)' | head -n 1 | cut -c1-14)" = "RUN_TIME total" ] \
  && ok "timestamps: run summary line has start, end and total elapsed" || bad "timestamps: RUN_TIME" "$out"
raw_logs=$(only_log 2>/dev/null)
[ "$(say "$raw_logs" | grep -c .)" = 1 ] && ! grep -q RUN_TIME "$raw_logs" \
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
{ base_of "$(only_log)"; beads_of "$(only_log)"; cat "$tmp/big.log"; echo "STOP_REASON: unknown"; ctx_of "$(only_log)"; echo "RUN_RESULT=OK_DONE"; } > "$tmp/want_big"
[ $rc -eq 0 ] && cmp -s "$tmp/want_big" "$(only_log)" && say "$out" | grep -q 'timestamp filter' \
  && ok "timestamps: a dead filter leaves the raw log complete and warns" || bad "timestamps: dead filter" "$rc $(wc -l < "$(only_log)") $(echo "$out" | tail -3)"
# BSD tee with SIGPIPE ignored prints "Broken pipe" per write; that must not flood the terminal
n_bp=$(say "$out" | grep -c 'Broken pipe')
[ "$n_bp" -eq 0 ] && ok "timestamps: a dead filter does not flood the terminal with tee errors" || bad "timestamps: tee flood" "$n_bp Broken pipe lines"

# status and supervise keep reading the raw log, even when the timed twin is newer
rm -rf "$W/logs"; STUB_FIXTURE="$FX/blocked.log" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
sleep 1; touch "$W"/logs/run-*.timed.txt
# offline: no gh, and git may only use file:// so the fetch fails at once
mkdir -p "$tmp/nogh"; printf '#!/bin/sh\nexit 1\n' > "$tmp/nogh/gh"; chmod +x "$tmp/nogh/gh"
out=$(PATH="$tmp/nogh:$PATH" GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 runit "$BIN/hermes-status" 2>&1)
say "$out" | grep -qE '^file: .*/run-[0-9-]+\.log ' && say "$out" | grep -q '^class: BLOCKED$' \
  && ok "status: latest log is the raw log, not its timed twin" || bad "status: twin" "$(say "$out" | grep -E '^(file|class):')"
# refused PRs (bead gbd): runit puts the general stubs first, so these two put their own gh
# ahead of them. Offline the section says unavailable and status carries on.
out=$(cd "$W" && PATH="$tmp/nogh:$tmp/bin:$PATH" GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 "$BIN/hermes-status" 2>&1)
say "$out" | grep -q "^== refused by hermes-review" && say "$out" | grep -q "^unavailable: hermes-review --list-refused failed" \
  && say "$out" | grep -q "^== beads" \
  && ok "status: refused-PR section is shown, and offline it says unavailable" \
  || bad "status: refused section offline" "$(say "$out" | grep -A2 'refused by hermes-review')"
# ... and with gh answering, a PR refused at its current head is listed with the reason
mkdir -p "$tmp/refgh"; cat > "$tmp/refgh/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "pr list") echo '[{"number":47,"title":"feat(b8p.14): x","body":"","headRefName":"bd/r-b8p.14","headRefOid":"abc1234def","url":"u","isDraft":false},{"number":48,"title":"fix(r-c1): y","body":"","headRefName":"bd/r-c1","headRefOid":"new5678abc","url":"u","isDraft":false}]' ;;
  "pr view") case "$3" in
      47) printf '%s\n' '{"comments":[{"body":"<!-- pr-review-refused:abc1234def:0123456789 -->\n**Reviewer agent: not reviewed.** cannot identify the bead\n"}],"reviews":[]}' ;;
      48) printf '%s\n' '{"comments":[{"body":"<!-- pr-review-refused:old0000aaa:0123456789 -->\n**Reviewer agent: not reviewed.** an old reason\n"}],"reviews":[]}' ;;
    esac ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/refgh/gh"
out=$(cd "$W" && PATH="$tmp/refgh:$tmp/bin:$PATH" GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 "$BIN/hermes-status" 2>&1)
say "$out" | grep -q '^PR #47 (bd/r-b8p.14) refused at abc1234: cannot identify the bead$' \
  && ok "status: lists a PR refused at its current head, with the reason" \
  || bad "status: refused PR listed" "$(say "$out" | grep -A2 'refused by hermes-review')"
say "$out" | grep -q '^PR #48 ' && bad "status: a PR whose head moved past its refusal is not listed" "$(say "$out" | grep '^PR #48')" \
  || ok "status: a PR whose head moved past its refusal is not listed"
eq "supervise: latest log is the raw log, not its timed twin" "$(runit "$BIN/hermes-supervise" | sed -n 's/^CLASS=//p')" BLOCKED
rm -rf "$W/logs"
