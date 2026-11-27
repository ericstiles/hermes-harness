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
[ "$rc" = 0 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && [ "$(last_result)" = RUN_RESULT=OK_DONE ] \
  && ok "notes check: OK_DONE run whose bead notes contain the PR URL stays OK_DONE" || bad "notes check: intact" "$rc $(echo "$out" | tail -4)"
grep -q "^gh pr view $URL" "$STUB_LOG" && grep -q "^bd show $T --json" "$STUB_LOG" \
  && [ "$(grep -n '^bd dolt pull' "$STUB_LOG" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^bd show' "$STUB_LOG" | head -n 1 | cut -d: -f1)" ] \
  && ok "notes check: reads the PR's Bead: line, pulls beads, then bd show" || bad "notes check: lookups" "$(cat "$STUB_LOG")"
grep -qE '^bd (update|close|unclaim|create|dolt push)' "$STUB_LOG" && bad "notes check: wrote to beads" "$(grep '^bd' "$STUB_LOG")" \
  || ok "notes check: read-only against beads"

# 2. notes wiped -> NOTES_LOST, explained in the log, loop stops
bead "$T" in_progress "Claimed. Working."
nc_run STUB_PR_BODY="Bead: $T"
[ "$rc" = 1 ] && say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && [ "$(last_result)" = RUN_RESULT=NOTES_LOST ] \
  && ok "notes check: OK_DONE run whose bead notes lack the PR URL becomes NOTES_LOST" || bad "notes check: lost" "$rc $(echo "$out" | tail -4)"
grep -qxF "NOTES_CHECK: $T missing $URL in notes" "$runlog" && ok "notes check: the log says which bead lost which URL" \
  || bad "notes check: NOTES_CHECK line" "$(grep NOTES_CHECK "$runlog")"
eq "notes check: NOTES_LOST stops the loop" "$(grep -c '^hermes chat' "$STUB_LOG")" 1
eq "notes check: classify reads NOTES_LOST back from the log" "$(hermes_classify "$runlog")" NOTES_LOST

# 3. the ticket is no longer in_progress (the reviewer needs it in_progress)
bead "$T" closed "PR: $URL"
nc_run STUB_PR_BODY="Bead: $T"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $T status closed, expected in_progress" "$runlog" \
  && ok "notes check: a ticket that is not in_progress is NOTES_LOST" || bad "notes check: status" "$(grep NOTES_CHECK "$runlog") $(echo "$out" | tail -2)"

# 4. review-fix run: claimed F, PR body names T; both need the URL
bead "$T" in_progress "PR: $URL"; bead "$F" in_progress "PR: $URL"
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T"
say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q "^bd show $F --json" "$STUB_LOG" && grep -q "^bd show $T --json" "$STUB_LOG" \
  && ok "notes check: review-fix run checks both the ticket and the review-fix bead" || bad "notes check: review-fix ok" "$(cat "$STUB_LOG") $(echo "$out" | tail -2)"
bead "$F" in_progress "Working on the review points."
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $F missing $URL in notes" "$runlog" \
  && ok "notes check: review-fix run checks the review-fix bead's notes (PR: <url>)" || bad "notes check: review-fix F" "$(grep NOTES_CHECK "$runlog") $(echo "$out" | tail -2)"
bead "$F" in_progress "PR: $URL"; bead "$T" in_progress "replaced by the review-fix run"
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $T missing $URL in notes" "$runlog" \
  && ok "notes check: a review-fix run that wiped the ticket's notes is NOTES_LOST (the eac incident)" || bad "notes check: eac" "$(grep NOTES_CHECK "$runlog") $(echo "$out" | tail -2)"

# 5. gh cannot read the PR -> fall back to the claimed bead
rm -f "$STUB_BEADS/$F.json"; bead "$T" in_progress "PR: $URL"
nc_run
say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q "^bd show $T --json" "$STUB_LOG" \
  && ok "notes check: without the PR body it checks the claimed bead" || bad "notes check: fallback" "$(cat "$STUB_LOG")"
bead "$T" in_progress ""
nc_run
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && ok "notes check: the claimed-bead fallback still catches lost notes" \
  || bad "notes check: fallback lost" "$(echo "$out" | tail -3)"

# 6. cannot check -> warning, original class kept
nc_run STUB_PR_BODY="Bead: $T" STUB_BD_SHOW_FAIL=1
[ "$rc" = 0 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && say "$out" | grep -q '^warning: notes check skipped' \
  && ok "notes check: bd failure prints a warning and keeps the original class" || bad "notes check: bd failure" "$rc $(echo "$out" | tail -4)"
rm -rf "$STUB_BEADS"
nc_run STUB_PR_BODY="Bead: $T"
[ "$rc" = 0 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && say "$out" | grep -q '^warning: notes check skipped' \
  && ok "notes check: unreadable bd show output keeps the original class" || bad "notes check: bad json" "$rc $(echo "$out" | tail -4)"
nc_run STUB_FIXTURE="$FX/blocked.log" STUB_PR_BODY="Bead: $T" HERMES_CONTINUE_ON_BLOCKED=0
grep -q '^bd show' "$STUB_LOG" && bad "notes check: ran for a non-OK_DONE run" "$(cat "$STUB_LOG")" \
  || ok "notes check: only OK_DONE runs are checked"

# 7. supervise: a human repairs the notes
bead "$T" in_progress ""; nc_run STUB_PR_BODY="Bead: $T"
out=$(HERMES_LOG_DIR="$W/logs" runit "$BIN/hermes-supervise" "$runlog")
say "$out" | grep -q '^CLASS=NOTES_LOST$' && say "$out" | grep -q '^ACTION=ASK_HUMAN$' \
  && say "$out" | grep -q "^WHY=.*bd update $T --append-notes \"PR: $URL\"" \
  && ok "notes check: supervise asks the human and shows the repair command" || bad "notes check: supervise" "$out"
# 8. the harness writes a missing PR line itself (incident 2026-11-24, organize_music-225), but only
# when the PR's head branch is bd/<T>; status problems are never repaired
rm -rf "$STUB_BEADS"; bead "$T" in_progress "PR: $URL"; bead "$F" in_progress "Working."
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q "^bd update $F --append-notes PR: $URL$" "$STUB_LOG" \
  && grep -q '^bd dolt push' "$STUB_LOG" && say "$out" | grep -qxF "NOTES_FIX: appended PR: $URL to $F (the agent had not written it)" \
  && ok "notes check: appends the review-fix bead's missing PR line, pushes, stays OK_DONE" \
  || bad "notes check: repair F" "$(grep -E 'NOTES|^bd' "$runlog" "$STUB_LOG") $(echo "$out" | tail -3)"
grep -q "^bd update $T " "$STUB_LOG" && bad "notes check: touched the intact ticket" "$(grep '^bd update' "$STUB_LOG")" \
  || ok "notes check: leaves a bead that already has the PR line alone"
rm -f "$STUB_BEADS/$F.json"; bead "$T" in_progress "Claimed."
nc_run STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && grep -q "^bd update $T --append-notes PR: $URL$" "$STUB_LOG" \
  && ok "notes check: appends the ticket's missing PR line" || bad "notes check: repair T" "$(cat "$STUB_LOG") $(echo "$out" | tail -3)"
bead "$T" in_progress "Claimed."
nc_run STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/other-bead"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && ! grep -q '^bd update' "$STUB_LOG" \
  && say "$out" | grep -q "^warning: no PR-line repair: $URL head is 'bd/other-bead', not bd/$T$" \
  && ok "notes check: no repair when the PR's head branch is not bd/<ticket>" || bad "notes check: head mismatch" "$(cat "$STUB_LOG") $(echo "$out" | tail -3)"
bead "$T" closed "Claimed."
nc_run STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && ! grep -q '^bd update' "$STUB_LOG" \
  && ok "notes check: never repairs a ticket that is not in_progress" || bad "notes check: closed no repair" "$(cat "$STUB_LOG")"
bead "$T" in_progress "Claimed."
nc_run STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T" STUB_BD_UPDATE_FAIL=1
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $T missing $URL in notes" "$runlog" \
  && ok "notes check: a failed repair write stays NOTES_LOST" || bad "notes check: repair fails" "$(echo "$out" | tail -3)"

# 9. a bead that got the PR URL during the run but is not T, F or a proper side bead B is a stray
S=learn_hermes-b8p.25; B=learn_hermes-side
bead "$T" in_progress "PR: $URL"; bead "$F" in_progress "PR: $URL"
bead "$S" open "Fixed in PR $URL (commit 5578009). PR: $URL"
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' \
  && grep -qxF "NOTES_CHECK: $S has $URL in notes but is not the PR's bead ($T or $F)" "$runlog" \
  && grep -q -- "--notes-contains $URL --updated-after 20[0-9-]*T[0-9:]*Z --json --limit 0" "$STUB_LOG" \
  && ok "notes check: a bead wrongly carrying the PR URL is NOTES_LOST, named in the log" \
  || bad "notes check: stray" "$(grep -E 'NOTES|^bd list' "$runlog" "$STUB_LOG") $(echo "$out" | tail -3)"
grep -q "^bd update $S" "$STUB_LOG" && bad "notes check: edited the stray" "$(grep '^bd update' "$STUB_LOG")" \
  || ok "notes check: never edits a stray bead"
rm -f "$STUB_BEADS/$S.json"; bead "$B" in_progress "Fixed in PR $URL via review-fix $F"
nc_run STUB_FIXTURE="$FX/review_fix_done.log" STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && ok "notes check: a side bead with the exact review-fix line is not a stray" \
  || bad "notes check: side bead" "$(grep NOTES "$runlog") $(echo "$out" | tail -3)"
rm -f "$STUB_BEADS/$F.json" "$STUB_BEADS/$B.json"
bead "$S" open "PR: $URL"; nc_run STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
out=$(HERMES_LOG_DIR="$W/logs" runit "$BIN/hermes-supervise" "$runlog")
say "$out" | grep -q '^ACTION=ASK_HUMAN$' && say "$out" | grep -q "^WHY=.*remove the PR line from $S" \
  && ok "notes check: supervise tells the human to remove the stray PR line" || bad "notes check: supervise stray" "$out"
# 10. URLs match with a number boundary: .../pull/12 is not .../pull/120 (hermes-harness-hzg)
rm -rf "$STUB_BEADS"; bead "$T" in_progress "PR: $URL"; bead "$S" open "PR: ${URL}0"
nc_run STUB_PR_BODY="Bead: $T" STUB_PR_HEAD="bd/$T"
say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' && ! grep -q "NOTES_CHECK: $S" "$runlog" \
  && ok "notes check: a bead carrying pull/120 is not a stray of pull/12" || bad "notes check: url boundary stray" "$(grep NOTES "$runlog")"
rm -f "$STUB_BEADS/$S.json"; bead "$T" in_progress "PR: ${URL}0"
nc_run STUB_PR_BODY="Bead: $T"
say "$out" | grep -q '^FINAL_RESULT=NOTES_LOST$' && grep -qxF "NOTES_CHECK: $T missing $URL in notes" "$runlog" \
  && ok "notes check: pull/120 in the ticket's notes does not count as pull/12" || bad "notes check: url boundary state" "$(grep NOTES "$runlog")"
rm -rf "$W/logs" "$STUB_BEADS"; unset STUB_BEADS
