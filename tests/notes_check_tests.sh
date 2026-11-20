#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub bd shows $STUB_BEADS/<id>.json, stub gh pr view prints $STUB_PR_BODY).
# Incident 2026-11-19 (organize_music eac): a run classed OK_DONE had wiped the ticket's notes,
# PR link included; hermes-review refused the PR hours later. After an OK_DONE run, hermes-run
# checks that the PR's bead (PR body `Bead:`) is in_progress with the PR URL in its notes, and
# that a review-fix bead it claimed has the URL too. Otherwise the run is NOTES_LOST.
URL=https://github.com/o/r/pull/12; T=learn_hermes-abc; F=learn_hermes-fix
export STUB_BEADS="$tmp/beads"
bead() { # <id> <status> <notes>: what `bd show <id> --json` returns (a one-element list, like bd)
  mkdir -p "$STUB_BEADS"
  python3 -c 'import json,sys; print(json.dumps([{"id":sys.argv[1],"status":sys.argv[2],"notes":sys.argv[3]}]))' \
    "$1" "$2" "$3" > "$STUB_BEADS/$1.json"
}
nc_run() { # [VAR=value ...] -> runs hermes-run 3 with the ok_done fixture unless STUB_FIXTURE is given
  rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
  out=$(env STUB_FIXTURE="$FX/ok_done.log" "$@" bash -c 'cd "$0" && PATH="$1:$PATH" "$2" 3' "$W" "$tmp/bin" "$BIN/hermes-run" 2>&1); rc=$?
  runlog=$(ls "$W"/logs/run-*.log 2>/dev/null | head -n 1)
}
last_result() { tr -d '\r' < "$runlog" | grep '^RUN_RESULT=' | tail -n 1; }

# 1. bead intact -> stays OK_DONE, beads pulled first, nothing written to beads
rm -rf "$STUB_BEADS"; bead "$T" in_progress "Claimed.
PR: $URL"
nc_run STUB_PR_BODY="Bead: $T"
[ "$rc" = 0 ] && echo "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && [ "$(last_result)" = RUN_RESULT=OK_DONE ] \
  && ok "notes check: OK_DONE run whose bead notes contain the PR URL stays OK_DONE" || bad "notes check: intact" "$rc $(echo "$out" | tail -4)"
grep -q "^gh pr view $URL" "$STUB_LOG" && grep -q "^bd show $T --json" "$STUB_LOG" \
  && [ "$(grep -n '^bd dolt pull' "$STUB_LOG" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^bd show' "$STUB_LOG" | head -n 1 | cut -d: -f1)" ] \
  && ok "notes check: reads the PR's Bead: line, pulls beads, then bd show" || bad "notes check: lookups" "$(cat "$STUB_LOG")"
grep -qE '^bd (update|close|unclaim|create|dolt push)' "$STUB_LOG" && bad "notes check: wrote to beads" "$(grep '^bd' "$STUB_LOG")" \
  || ok "notes check: read-only against beads"

# 2. notes wiped -> NOTES_LOST, explained in the log, loop stops
bead "$T" in_progress "Claimed. Working."
nc_run STUB_PR_BODY="Bead: $T"
[ "$rc" = 1 ] && echo "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && [ "$(last_result)" = RUN_RESULT=NOTES_LOST ] \
  && ok "notes check: OK_DONE run whose bead notes lack the PR URL becomes NOTES_LOST" || bad "notes check: lost" "$rc $(echo "$out" | tail -4)"
grep -qxF "NOTES_CHECK: $T missing $URL in notes" "$runlog" && ok "notes check: the log says which bead lost which URL" \
  || bad "notes check: NOTES_CHECK line" "$(grep NOTES_CHECK "$runlog")"
eq "notes check: NOTES_LOST stops the loop" "$(grep -c '^hermes chat' "$STUB_LOG")" 1
eq "notes check: classify reads NOTES_LOST back from the log" "$(hermes_classify "$runlog")" NOTES_LOST

# 3. the ticket is no longer in_progress (the reviewer needs it in_progress)
bead "$T" closed "PR: $URL"
nc_run STUB_PR_BODY="Bead: $T"
echo "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $T status closed, expected in_progress" "$runlog" \
  && ok "notes check: a ticket that is not in_progress is NOTES_LOST" || bad "notes check: status" "$(grep NOTES_CHECK "$runlog") $(echo "$out" | tail -2)"

# 4. review-fix run: claimed F, PR body names T; both need the URL
bead "$T" in_progress "PR: $URL"; bead "$F" in_progress "PR: $URL"
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T"
echo "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q "^bd show $F --json" "$STUB_LOG" && grep -q "^bd show $T --json" "$STUB_LOG" \
  && ok "notes check: review-fix run checks both the ticket and the review-fix bead" || bad "notes check: review-fix ok" "$(cat "$STUB_LOG") $(echo "$out" | tail -2)"
bead "$F" in_progress "Working on the review points."
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T"
echo "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $F missing $URL in notes" "$runlog" \
  && ok "notes check: review-fix run checks the review-fix bead's notes (PR: <url>)" || bad "notes check: review-fix F" "$(grep NOTES_CHECK "$runlog") $(echo "$out" | tail -2)"
bead "$F" in_progress "PR: $URL"; bead "$T" in_progress "replaced by the review-fix run"
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T"
echo "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $T missing $URL in notes" "$runlog" \
  && ok "notes check: a review-fix run that wiped the ticket's notes is NOTES_LOST (the eac incident)" || bad "notes check: eac" "$(grep NOTES_CHECK "$runlog") $(echo "$out" | tail -2)"

# 5. gh cannot read the PR -> fall back to the claimed bead
bead "$T" in_progress "PR: $URL"
nc_run
echo "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q "^bd show $T --json" "$STUB_LOG" \
  && ok "notes check: without the PR body it checks the claimed bead" || bad "notes check: fallback" "$(cat "$STUB_LOG")"
bead "$T" in_progress ""
nc_run
echo "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && ok "notes check: the claimed-bead fallback still catches lost notes" \
  || bad "notes check: fallback lost" "$(echo "$out" | tail -3)"

# 6. cannot check -> warning, original class kept
nc_run STUB_PR_BODY="Bead: $T" STUB_BD_SHOW_FAIL=1
[ "$rc" = 0 ] && echo "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && echo "$out" | grep -q '^warning: notes check skipped' \
  && ok "notes check: bd failure prints a warning and keeps the original class" || bad "notes check: bd failure" "$rc $(echo "$out" | tail -4)"
rm -rf "$STUB_BEADS"
nc_run STUB_PR_BODY="Bead: $T"
[ "$rc" = 0 ] && echo "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && echo "$out" | grep -q '^warning: notes check skipped' \
  && ok "notes check: unreadable bd show output keeps the original class" || bad "notes check: bad json" "$rc $(echo "$out" | tail -4)"
nc_run STUB_FIXTURE="$FX/blocked.log" STUB_PR_BODY="Bead: $T"
grep -q '^bd show' "$STUB_LOG" && bad "notes check: ran for a non-OK_DONE run" "$(cat "$STUB_LOG")" \
  || ok "notes check: only OK_DONE runs are checked"

# 7. supervise: a human repairs the notes
bead "$T" in_progress ""; nc_run STUB_PR_BODY="Bead: $T"
out=$(HERMES_LOG_DIR="$W/logs" runit "$BIN/hermes-supervise" "$runlog")
echo "$out" | grep -q '^CLASS=NOTES_LOST$' && echo "$out" | grep -q '^ACTION=ASK_HUMAN$' \
  && echo "$out" | grep -q "^WHY=.*bd update $T --append-notes \"PR: $URL\"" \
  && ok "notes check: supervise asks the human and shows the repair command" || bad "notes check: supervise" "$out"
rm -rf "$W/logs" "$STUB_BEADS"; unset STUB_BEADS
