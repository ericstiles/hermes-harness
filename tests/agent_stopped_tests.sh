#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub hermes: STUB_FIXTURE for call 1, STUB_FIXTURE_2 for later calls).
# Incident 2026-11-19: the model answered a question nobody asked and ended its turn mid-issue.
# Such a run (footer, exit 0, no PR, no sentinel) is AGENT_STOPPED, and hermes-run resumes it once.
SF="$FX/agent_stopped.log"; SID=20261119_120609_702276

eq "classify agent_stopped" "$(hermes_classify "$SF")" AGENT_STOPPED
eq "agent_stopped needs a clean exit (exit 3 stays UNKNOWN)" "$(hermes_classify "$SF" 3)" UNKNOWN

# resumed once with the same session; the resumed run opens the PR -> loop continues as OK_DONE
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_FIXTURE="$SF" STUB_FIXTURE_2="$FX/ok_done.log" runit "$BIN/hermes-run" 1 2>&1); rc=$?
calls=$(grep -c '^hermes chat' "$STUB_LOG")
second=$(grep '^hermes chat' "$STUB_LOG" | sed -n 2p)
[ "$calls" = 2 ] && say "$second" | grep -q -- "--resume $SID" && say "$second" | grep -q -- '--pass-session-id' \
  && ok "agent_stopped: hermes-run resumes the same session once" || bad "agent_stopped: resume" "$calls | $second"
[ "$(grep -c '^env HERMES_HARNESS_RUN=1$' "$STUB_LOG")" = 2 ] && [ -z "${HERMES_HARNESS_RUN:-}" ] \
  && ok "hermes-run sets HERMES_HARNESS_RUN=1 for every hermes chat (gates the notes guard hook)" \
  || bad "hermes-run HERMES_HARNESS_RUN" "$(grep '^env' "$STUB_LOG")"
say "$second" | grep -q 'No human is present' && ok "agent_stopped: the resume prompt says no human is present" || bad "agent_stopped: resume prompt" "$second"
[ $rc -eq 0 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && ok "agent_stopped: a successful resume counts as OK_DONE" || bad "agent_stopped: resume result" "$rc $(echo "$out" | tail -4)"
[ "$(ls "$W"/logs/run-*.log | wc -l | tr -d ' ')" = 2 ] && grep -q '^RUN_RESULT=AGENT_STOPPED$' "$W"/logs/run-*.log \
  && ok "agent_stopped: the stopped run and the resumed run have their own logs" || bad "agent_stopped: logs" "$(ls "$W/logs")"

# never resumed twice: a second early stop ends the loop as AGENT_STOPPED
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_FIXTURE="$SF" STUB_FIXTURE_2="$SF" runit "$BIN/hermes-run" 3 2>&1); rc=$?
[ "$(grep -c '^hermes chat' "$STUB_LOG")" = 2 ] && [ $rc -eq 1 ] && say "$out" | grep -q '^FINAL_RESULT=AGENT_STOPPED$' \
  && ok "agent_stopped: resumed at most once, then the loop stops" || bad "agent_stopped: once" "$rc $(grep -c '^hermes chat' "$STUB_LOG") $(echo "$out" | tail -3)"

# it already opened a PR but never printed the URL (real run 2026-11-18 "opened PR #6"):
# GitHub is the source of truth -> OK_DONE, no resume
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_PR_URL=https://github.com/acme/widgets/pull/77 STUB_FIXTURE="$SF" runit "$BIN/hermes-run" 1 2>&1); rc=$?
[ "$(grep -c '^hermes chat' "$STUB_LOG")" = 1 ] && [ $rc -eq 0 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' \
  && [ "$(grep '^RUN_RESULT=' "$W"/logs/run-*.log | tail -n 1 | cut -d: -f2-)" = RUN_RESULT=OK_DONE ] \
  && grep -q 'gh pr list .*--head bd/organize_music-6ut.10' "$STUB_LOG" \
  && ok "agent_stopped: an existing PR for the claimed issue counts as OK_DONE, no resume" || bad "agent_stopped: existing PR" "$rc $(cat "$STUB_LOG") $(echo "$out" | tail -3)"

# opt-out
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
HERMES_RESUME_ON_STOP=0 STUB_FIXTURE="$SF" runit "$BIN/hermes-run" 1 >/dev/null 2>&1
eq "agent_stopped: HERMES_RESUME_ON_STOP=0 disables the resume" "$(grep -c '^hermes chat' "$STUB_LOG")" 1

# every fresh run's prompt tells the agent nobody will answer
grep '^hermes chat' "$STUB_LOG" | head -n 1 | grep -q 'No human is present' && ok "agent_stopped: the run prompt says no human is present" \
  || bad "agent_stopped: run prompt" "$(head -n 1 "$STUB_LOG")"
grep -q 'No human is present' "$ROOT/templates/AGENTS_WORKFLOW.md" && ok "agent_stopped: AGENTS_WORKFLOW template has the no-questions rule" \
  || bad "agent_stopped: template rule" "missing"

# supervise: a human decides, and is given the exact resume command
out=$(HERMES_LOG_DIR="$tmp/l3" runit "$BIN/hermes-supervise" "$SF")
say "$out" | grep -q '^ACTION=ASK_HUMAN$' && say "$out" | grep -q "^WHY=.*hermes --resume $SID" \
  && ok "agent_stopped: supervise asks the human and shows the resume command" || bad "agent_stopped: supervise" "$out"
rm -rf "$W/logs"
