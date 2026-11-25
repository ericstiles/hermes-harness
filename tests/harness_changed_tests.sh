#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq/say, runit, $tmp $W $FX $ROOT
# $STUB_LOG $STUB_COUNT; stub hermes: STUB_FIXTURE, and STUB_TOUCH=<file> appends a line to that file
# during each hermes chat). Bead eyx: a loop whose harness code changed since it started stops before
# its next run (never mid-run) and says why. Runs a COPY of the harness, so the edits never touch $ROOT.
HC="$tmp/harness-copy"; rm -rf "$HC"; mkdir -p "$HC"; cp -R "$ROOT/bin" "$ROOT/lib" "$HC/"
hc_run() { rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; runit "$HC/bin/hermes-run" "$@" 2>&1; }
chats() { grep -c '^hermes chat' "$STUB_LOG"; }

# --- lib/code_stamp.sh ---
stamp=$(bash -c ". '$HC/lib/code_stamp.sh'; hh_code_stamp '$HC'")
say "$stamp" | grep -qE '^[0-9]+ [0-9]+ bin/hermes-run$' && say "$stamp" | grep -qE ' lib/watchdog\.py$' && say "$stamp" | grep -qE ' lib/code_stamp\.sh$' \
  && ok "harness changed: the stamp covers hermes-run, what it sources and what it runs" || bad "harness changed: stamp" "$stamp"
out=$(bash -c ". '$HC/lib/code_stamp.sh'; hh_code_changes '$HC' \"\$1\"" _ "$stamp"); rc=$?
[ $rc -ne 0 ] && [ -z "$out" ] && ok "harness changed: an unchanged harness reports no change" || bad "harness changed: unchanged" "$rc $out"
cp "$HC/lib/epics.sh" "$tmp/epics.bak"; rm "$HC/lib/epics.sh"
out=$(bash -c ". '$HC/lib/code_stamp.sh'; hh_code_changes '$HC' \"\$1\"" _ "$stamp"); rc=$?
cp "$tmp/epics.bak" "$HC/lib/epics.sh"
[ $rc -eq 0 ] && [ "$out" = lib/epics.sh ] && ok "harness changed: a removed file is named" || bad "harness changed: removed file" "$rc $out"

# --- unchanged harness: the loop runs every issue as before ---
out=$(STUB_FIXTURE="$FX/ok_done.log" hc_run 2); rc=$?
[ $rc -eq 0 ] && [ "$(chats)" = 2 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && ! say "$out" | grep -q HARNESS_CHANGED \
  && ok "harness changed: an unchanged harness runs all issues" || bad "harness changed: unchanged loop" "$rc $(chats) $(say "$out" | tail -3)"

# --- a file it does not load (README) changes: no stop ---
touch "$HC/README.md"
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_TOUCH="$HC/README.md" hc_run 2); rc=$?
[ $rc -eq 0 ] && [ "$(chats)" = 2 ] && ! say "$out" | grep -q HARNESS_CHANGED \
  && ok "harness changed: a change to a file hermes-run does not load does not stop the loop" || bad "harness changed: README" "$rc $(chats) $(say "$out" | tail -3)"

# --- a sourced lib changes during run 1: run 1 finishes normally, the loop stops before run 2 ---
cp "$HC/lib/classify.sh" "$tmp/classify.bak"
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_TOUCH="$HC/lib/classify.sh" hc_run 3); rc=$?
cp "$tmp/classify.bak" "$HC/lib/classify.sh"
runlog=$(ls "$W"/logs/run-*.log | head -n 1)
[ $rc -eq 1 ] && [ "$(chats)" = 1 ] && say "$out" | grep -q '^FINAL_RESULT=HARNESS_CHANGED$' \
  && ok "harness changed: a changed sourced lib stops the loop after the current run" || bad "harness changed: stop" "$rc $(chats) $(say "$out" | tail -4)"
say "$out" | grep -q '^HARNESS_CHANGED: .*(lib/classify.sh)\..*Stopping before run 2.*hermes-launch --reason HARNESS_CHANGED --max 2$' \
  && ok "harness changed: the message names the changed file, why it stopped, and the relaunch command" || bad "harness changed: message" "$(say "$out" | grep HARNESS_CHANGED)"
grep -q '^RUN_RESULT=OK_DONE$' "$runlog" && [ "$(tail -n 1 "$runlog")" = "LOOP_STOP=HARNESS_CHANGED files=lib/classify.sh" ] \
  && ok "harness changed: the finished run keeps RUN_RESULT=OK_DONE; its log ends with LOOP_STOP" || bad "harness changed: run log" "$(tail -3 "$runlog")"
say "$out" | grep -q '^RUN_TIME total=.* runs=1$' && say "$out" | tail -n 3 | grep -q '^BEADS: ' \
  && ok "harness changed: the loop summary still prints" || bad "harness changed: summary" "$(say "$out" | tail -5)"

# --- hermes-supervise: shows why the loop stopped and relaunches ---
out=$(HERMES_LOG_DIR="$W/logs" runit "$HC/bin/hermes-supervise" "$runlog")
say "$out" | grep -q '^CLASS=OK_DONE$' && say "$out" | grep -q '^ACTION=AUTO_RELAUNCH$' \
  && say "$out" | grep -q '^NEXT=hermes-launch --reason HARNESS_CHANGED$' \
  && say "$out" | grep -q '^LOOP_STOP=HARNESS_CHANGED files=lib/classify.sh$' && say "$out" | grep -q '^WHY=.*harness code changed' \
  && ok "harness changed: supervise reports it and relaunches" || bad "harness changed: supervise" "$out"

# --- hermes-run itself changes (a pull or branch switch): same stop ---
cp "$HC/bin/hermes-run" "$tmp/run.bak"
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_TOUCH="$HC/bin/hermes-run" hc_run 2); rc=$?
cp "$tmp/run.bak" "$HC/bin/hermes-run"
[ $rc -eq 1 ] && [ "$(chats)" = 1 ] && say "$out" | grep -q '^HARNESS_CHANGED: .*(bin/hermes-run)' && say "$out" | grep -q '^FINAL_RESULT=HARNESS_CHANGED$' \
  && ok "harness changed: a change to hermes-run itself stops the loop cleanly" || bad "harness changed: hermes-run edited" "$rc $(chats) $(say "$out" | tail -4)"
