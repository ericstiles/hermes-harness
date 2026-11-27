#!/usr/bin/env bash
# Bead hermes-harness-yiv: after RUN_BLOCKED the host makes sure the issue is parked (status blocked,
# no claim, a BLOCKED: note) and the loop goes on with the next ready issue. Several blocked runs in
# a row stop it. Self-contained: `bash tests/blocked_continue_tests.sh`; tests/run_tests.sh runs it
# as a child.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=loop_fixture.sh
. "$HERE/loop_fixture.sh"
unset HERMES_EXCLUDE_LABELS HERMES_CONTINUE_ON_BLOCKED HERMES_MAX_BLOCKED_IN_A_ROW

WHY='BLOCKED: access: needs X. Unblock by: give access to X'
HOSTNOTE='BLOCKED: run ended RUN_BLOCKED without parking the issue; see logs/run-'
STOPPED='Issue blocked — stopping'
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$STUB_DB/$1.json" "$2"; }
# chat N claims <id>, then (with a second argument) parks it the way the workflow says
blocked_run() { # <chat number> <id> [note]
  agent_run "$1" "$2" RUN_BLOCKED
  { echo "bd update $2 --claim"
    [ -z "${3:-}" ] || echo "bd update $2 --status blocked --append-notes '$3'"; } > "$STUB_PLAN/$1.sh"
}
two() { reset_db; bead om-a 2 open; bead om-b 2 open; }
parked() { [ "$(field "$1" status)" = blocked ] && [ -z "$(field "$1" assignee)" ]; }
last_log() { ls "$W"/logs/run-*.log | sed 's/\.log$//' | LC_ALL=C sort | tail -n 1 | sed 's/$/.log/'; }

# --- test_blocked_parks_and_continues ---
two; blocked_run 1 om-a "$WHY"; agent_run 2 om-b NO_READY_WORK
hrun 2
[ "$(chats)" = 2 ] && prompt 2 | grep -q 'Work issue om-b ' && ! say "$out" | grep -q "$STOPPED" \
  && ok "blocked: the loop goes on with the next ready issue" || bad "blocked: continues" "rc=$rc chats=$(chats) $(say "$out" | tail -8)"
say "$out" | grep -qx '== run 1/2 completed: BLOCKED (issue om-a)' \
  && say "$out" | grep -qxF "PARKED: om-a ($WHY)" && grep -qxF "PARKED: om-a ($WHY)" "$(first_log)" \
  && ok "blocked: the run's end and the log name the parked issue and why" || bad "blocked: PARKED line" "$(say "$out" | grep -E 'PARK|== run')"
parked om-a && [ "$(field om-a notes)" = "$WHY" ] && grep -q '^bd dolt push' "$STUB_LOG" \
  && ok "blocked: a well parked issue only loses its claim; its note is left alone" \
  || bad "blocked: agent-parked" "status=$(field om-a status) assignee=$(field om-a assignee) notes=$(field om-a notes)"

# --- test_blocked_unparked_issue_is_parked_by_host ---
two; blocked_run 1 om-a; agent_run 2 om-b NO_READY_WORK
hrun 2
parked om-a && field om-a notes | grep -qF "$HOSTNOTE" && field om-a notes | grep -qF "$(basename "$(first_log)")" \
  && ! field om-a notes | grep -qF "$W" && [ "$(chats)" = 2 ] && prompt 2 | grep -q 'Work issue om-b ' \
  && ok "blocked: the host parks an issue the agent left claimed, naming the run log" \
  || bad "blocked: host park" "status=$(field om-a status) assignee=$(field om-a assignee) notes=$(field om-a notes) chats=$(chats)"
say "$out" | grep -qF "PARKED: om-a ($HOSTNOTE" && grep -q '^bd dolt push' "$STUB_LOG" \
  && ok "blocked: the host's park is logged and pushed" || bad "blocked: host park log" "$(say "$out" | grep PARK)"
# blocked, but the note does not follow the format (an older AGENTS.md): keep what it said
two; blocked_run 1 om-a 'needs a macOS host'
hrun 1
parked om-a && field om-a notes | grep -q '^BLOCKED: run ended RUN_BLOCKED without a BLOCKED: note (it wrote: needs a macOS host); see logs/run-' \
  && ok "blocked: a note without the BLOCKED: prefix is quoted in the host's note" || bad "blocked: unprefixed" "$(field om-a notes)"
# the agent wrote its note but forgot the status
two; agent_run 1 om-a RUN_BLOCKED; printf "bd update om-a --claim\nbd update om-a --append-notes '%s'\n" "$WHY" > "$STUB_PLAN/1.sh"
hrun 1
parked om-a && field om-a notes | grep -qF "$HOSTNOTE" && say "$out" | grep -qxF "PARKED: om-a ($WHY)" \
  && ok "blocked: a note without the status is parked, and the agent's reason is shown" || bad "blocked: no status" "$(field om-a status) $(say "$out" | grep PARK)"
# a BLOCKED: note from an earlier run is not this run's reason
reset_db; bead om-a 2 open "" '"notes": "BLOCKED: access: old reason"'; blocked_run 1 om-a
hrun 1
field om-a notes | grep -qF "$HOSTNOTE" && ! say "$out" | grep -q 'PARKED: om-a (BLOCKED: access: old reason)' \
  && ok "blocked: an earlier run's BLOCKED: note does not count" || bad "blocked: old note" "$(say "$out" | grep PARK)"
# the notes could not be read before the run: a parked issue with a BLOCKED: note is still accepted
two; blocked_run 1 om-a "$WHY"
STUB_SNAPSHOT_FAIL=1 hrun 1
parked om-a && [ "$(field om-a notes)" = "$WHY" ] && say "$out" | grep -qxF "PARKED: om-a ($WHY)" \
  && say "$out" | grep -q '^PARK: could not read the notes from before the run' \
  && ok "blocked: without the earlier notes the agent's park is still accepted, and it says so" \
  || bad "blocked: no snapshot" "$(say "$out" | grep PARK) $(field om-a notes)"
# the pushed WIP branch is named; a review fix's branch is its ticket's
two; blocked_run 1 om-a "$WHY"
STUB_BRANCHES=bd/om-a hrun 1
say "$out" | grep -qxF "PARKED: om-a ($WHY) | WIP branch bd/om-a is on origin" \
  && ok "blocked: the PARKED line names the WIP branch" || bad "blocked: branch" "$(say "$out" | grep PARK)"
two; blocked_run 1 om-a "$WHY"
STUB_BRANCHES=bd/om-aa hrun 1
say "$out" | grep -qxF "PARKED: om-a ($WHY)" && grep -qx 'git ls-remote --heads origin refs/heads/bd/om-a' "$STUB_LOG" \
  && ok "blocked: no branch is named when it is not on origin" || bad "blocked: no branch" "$(say "$out" | grep PARK)"
reset_db; bead om-t 2 in_progress; bead om-f 1 open "" '"origin": "om-t", "labels": ["review-fix"]'; blocked_run 1 om-f "$WHY"
STUB_BRANCHES=bd/om-t hrun 1
say "$out" | grep -qxF "PARKED: om-f ($WHY) | WIP branch bd/om-t is on origin" \
  && ok "blocked: a review fix names its ticket's branch" || bad "blocked: review-fix branch" "$(say "$out" | grep PARK)"
# a failed push is a warning, not a stop
two; blocked_run 1 om-a; agent_run 2 om-b NO_READY_WORK
STUB_PUSH_FAIL=1 hrun 2
[ "$(chats)" = 2 ] && say "$out" | grep -q '^warning: bd dolt push failed' && parked om-a \
  && ok "blocked: a failed push warns and the loop goes on" || bad "blocked: push fail" "chats=$(chats) $(say "$out" | grep -i push)"
# a session resumed after stopping mid-issue: the claim is in the first log
two; printf '  ┊ 💻 $ bd update om-a --claim --json\nShall I go on?\n\nSession: 20260101_000000_abc\nResume this session with:\n' > "$STUB_PLAN/1"
echo "bd update om-a --claim" > "$STUB_PLAN/1.sh"
printf 'RUN_BLOCKED\n\nResume this session with:\n' > "$STUB_PLAN/2"; agent_run 3 om-b NO_READY_WORK
hrun 2
[ "$(chats)" = 3 ] && parked om-a && say "$out" | grep -qF "PARKED: om-a ($HOSTNOTE" \
  && ok "blocked: a block after a resume parks the claimed issue" || bad "blocked: resumed" "chats=$(chats) $(say "$out" | grep -E 'PARK|== run')"

# --- what cannot be parked stops the loop, as before ---
stops() { # <label> <expected PARK line>
  [ $rc -eq 1 ] && [ "$(chats)" = 1 ] && say "$out" | grep -q "$STOPPED" && say "$out" | grep -q "^PARK: .*$2" \
    && ! say "$out" | grep -qE '^PARKED(:|_ISSUES=)' && say "$out" | grep -q '^FINAL_RESULT=BLOCKED$' \
    && ok "not parked: $1" || bad "not parked: $1" "rc=$rc chats=$(chats) $(say "$out" | tail -8)"
}
two; printf 'RUN_BLOCKED\n\nResume this session with:\n' > "$STUB_PLAN/1"
hrun 3; stops "a block without a claim" 'claimed no issue'
two; blocked_run 1 om-a; echo "bd update om-a --status closed" >> "$STUB_PLAN/1.sh"
hrun 3; stops "a closed issue" 'om-a is closed'
[ "$(field om-a status)" = closed ] && ok "not parked: the closed issue is left alone" || bad "not parked: closed changed" "$(field om-a status)"
reset_db; bead om-a 2 in_progress "" '"assignee": "someone"'; bead om-b 2 open
agent_run 1 om-a RUN_BLOCKED
hrun 3; stops "an issue claimed before the run" 'om-a was in_progress before this run'
[ "$(field om-a status)" = in_progress ] && [ "$(field om-a assignee)" = someone ] \
  && ok "not parked: the other claim is kept" || bad "not parked: claim changed" "$(field om-a status) $(field om-a assignee)"
two; blocked_run 1 om-a
STUB_UPDATE_FAIL=1 hrun 3; stops "a park bd refuses" 'could not park om-a'
two; agent_run 1 om-zz RUN_BLOCKED
hrun 3; stops "an issue bd cannot show" 'could not park om-zz'

# --- test_blocked_breaker_stops_after_two_in_a_row ---
two; bead om-c 3 open; blocked_run 1 om-a "$WHY"; blocked_run 2 om-b "$WHY"
hrun 5
[ $rc -eq 1 ] && [ "$(chats)" = 2 ] && say "$out" | grep -q '^FINAL_RESULT=BLOCKED$' \
  && say "$out" | grep -q '^Blocked 2 runs in a row — stopping: likely a systemic problem (sandbox, auth, environment)' \
  && grep -q '^Blocked 2 runs in a row' "$(last_log)" \
  && ok "breaker: two blocked runs in a row stop the loop" || bad "breaker: stops" "rc=$rc chats=$(chats) $(say "$out" | tail -8)"
two; bead om-c 3 open; blocked_run 1 om-a "$WHY"; blocked_run 2 om-b "$WHY"; agent_run 3 om-c NO_READY_WORK
HERMES_MAX_BLOCKED_IN_A_ROW=3 hrun 3
[ "$(chats)" = 3 ] && ! say "$out" | grep -q 'in a row — stopping' \
  && ok "breaker: HERMES_MAX_BLOCKED_IN_A_ROW sets the limit" || bad "breaker: limit" "chats=$(chats)"
for v in 0 two -1 ''; do
  two; HERMES_MAX_BLOCKED_IN_A_ROW=$v hrun 1
  if [ -z "$v" ]; then [ $rc -eq 0 ] && ok "breaker: an empty limit means the default" || bad "breaker: empty limit" "rc=$rc $out"
  else [ $rc -eq 2 ] && [ "$(chats)" = 0 ] && say "$out" | grep -q 'HERMES_MAX_BLOCKED_IN_A_ROW' && [ ! -d "$W/logs/.run-beads.lock" ] \
    && ok "breaker: a limit of '$v' is refused, naming the setting" || bad "breaker: invalid '$v'" "rc=$rc $out"; fi
done

# --- test_blocked_breaker_resets_on_success ---
two; bead om-c 3 open; bead om-d 4 open
blocked_run 1 om-a "$WHY"
printf 'PR https://github.com/o/r/pull/1\n\nResume this session with:\n' > "$STUB_PLAN/2"; echo "bd update om-b --status closed" > "$STUB_PLAN/2.sh"
blocked_run 3 om-c "$WHY"; agent_run 4 om-d NO_READY_WORK
hrun 4
[ "$(chats)" = 4 ] && prompt 4 | grep -q 'Work issue om-d ' && ! say "$out" | grep -q 'in a row — stopping' \
  && ok "breaker: a run that is not blocked resets the count" || bad "breaker: reset" "chats=$(chats) $(say "$out" | grep -E '== run|in a row')"

# --- test_continue_on_blocked_off_restores_stop ---
two; blocked_run 1 om-a
HERMES_CONTINUE_ON_BLOCKED=0 hrun 3
[ $rc -eq 1 ] && [ "$(chats)" = 1 ] && say "$out" | grep -q "$STOPPED" && say "$out" | grep -q '^FINAL_RESULT=BLOCKED$' \
  && ! say "$out" | grep -q 'PARK' && [ "$(field om-a status)" = in_progress ] && [ -z "$(field om-a notes)" ] \
  && ! grep -q '^bd list --all' "$STUB_LOG" \
  && ok "off: HERMES_CONTINUE_ON_BLOCKED=0 stops at the first block and touches nothing" \
  || bad "off" "rc=$rc chats=$(chats) status=$(field om-a status) $(say "$out" | tail -6)"

# --- test_summary_lists_parked_issues ---
two; bead om-c 3 open; blocked_run 1 om-a "$WHY"
printf 'PR https://github.com/o/r/pull/1\n\nResume this session with:\n' > "$STUB_PLAN/2"; echo "bd update om-b --status closed" > "$STUB_PLAN/2.sh"
blocked_run 3 om-c "$WHY"
hrun 3
say "$out" | grep -q '^BEADS: loop worked 2 issue(s): om-a om-c | parked: om-a om-c | closed ' \
  && say "$out" | grep -qx 'PARKED_ISSUES=om-a,om-c' && grep -qx 'PARKED_ISSUES=om-a,om-c' "$(last_log)" \
  && ok "summary: the BEADS: line and PARKED_ISSUES= name every parked issue" \
  || bad "summary" "$(say "$out" | grep -E 'BEADS: loop|PARKED_ISSUES')"
[ $rc -eq 0 ] && say "$out" | grep -q '^FINAL_RESULT=OK_DONE$' \
  && ok "summary: a loop whose last run was blocked and parked ends OK_DONE" || bad "summary: final" "rc=$rc $(say "$out" | tail -3)"
# everything left waits on the parked issue: the queue empties
reset_db; bead om-a 2 open; bead om-b 2 open om-a; blocked_run 1 om-a "$WHY"; printf 'NO_READY_WORK\n\nResume this session with:\n' > "$STUB_PLAN/2"
hrun 5
[ "$(chats)" = 2 ] && say "$out" | grep -q '^FINAL_RESULT=QUEUE_EMPTY$' && grep -qx 'PARKED_ISSUES=om-a' "$(last_log)" \
  && ok "summary: a queue emptied by the block ends QUEUE_EMPTY with the parked list" || bad "summary: queue empty" "chats=$(chats) $(say "$out" | tail -5)"
queue_log=$(last_log)

# --- test_supervise_parked_asks_human_with_list ---
sout=$(sup "$queue_log")
say "$sout" | grep -q '^CLASS=QUEUE_EMPTY$' && say "$sout" | grep -q '^ACTION=ASK_HUMAN$' \
  && say "$sout" | grep -q '^WHY=.*parked.*om-a' && say "$sout" | grep -qx 'evidence: bd show om-a' \
  && ok "supervise: an emptied queue with a parked issue asks the human" || bad "supervise: queue empty" "$sout"
two; blocked_run 1 om-a "$WHY"; blocked_run 2 om-b "$WHY"
hrun 2; sout=$(sup)
say "$sout" | grep -q '^ACTION=ASK_HUMAN$' && say "$sout" | grep -qx 'evidence: bd show om-a' \
  && say "$sout" | grep -qx 'evidence: bd show om-b' && say "$sout" | grep -q '^WHY=.*in a row.*sandbox' \
  && ok "supervise: one bd show per parked issue, and the breaker is explained" || bad "supervise: breaker" "$sout"
two; blocked_run 1 om-a "$WHY"
hrun 1; log=$(last_log); sout=$(sup "$log")
say "$sout" | grep -q '^ACTION=ASK_HUMAN$' && say "$sout" | grep -q '^WHY=.*parked.*om-a' && ! say "$sout" | grep -q 'and stopped' \
  && ok "supervise: a parked last run is not reported as a stopped loop" || bad "supervise: last run" "$sout"
echo "LOOP_STOP=HARNESS_CHANGED left=4 files=lib/x.sh" >> "$log"
sout=$(sup "$log")
say "$sout" | grep -q '^ACTION=AUTO_RELAUNCH$' && say "$sout" | grep -qx 'NEXT=hermes-launch --reason HARNESS_CHANGED --max 4' \
  && say "$sout" | grep -qx 'ALSO=om-a' && say "$sout" | grep -qx 'evidence: bd show om-a' \
  && ok "supervise: a relaunchable stop keeps its action and lists the parked issues as ALSO=" || bad "supervise: ALSO" "$sout"
printf 'RUN_RESULT=AUTH_ERROR\nPARKED_ISSUES=om-a,om-b\n' > "$W/logs/auth.log"; sout=$(sup "$W/logs/auth.log")
say "$sout" | grep -q '^ACTION=ASK_HUMAN$' && say "$sout" | grep -q '^WHY=credentials' && say "$sout" | grep -qx 'ALSO=om-a,om-b' \
  && ok "supervise: another human stop keeps its reason and adds ALSO=" || bad "supervise: auth" "$sout"

# --- a refused requeue is not parked: that path is unchanged ---
reset_db; bead om-a 2 open; agent_run 1 om-a RUN_REQUEUED
hrun 3
[ "$(chats)" = 1 ] && say "$out" | grep -q "$STOPPED" && ! say "$out" | grep -q '^PARK' && [ "$(field om-a status)" = open ] \
  && ok "requeue: a refused requeue still stops the loop and parks nothing" || bad "requeue: refused parked" "chats=$(chats) $(say "$out" | tail -6)"

# --- the workflow text and the settings are documented ---
for f in AGENTS.md templates/AGENTS_WORKFLOW.md; do
  text=$(tr '\n' ' ' < "$ROOT/$f" | tr -s ' ')
  [ "$(say "$text" | grep -o -- '--status blocked --append-notes "BLOCKED: ' | grep -c .)" = 3 ] \
    && say "$text" | grep -qF 'BLOCKED: <kind>: <why>. Unblock by: <what a human must do>' \
    && say "$text" | grep -qF '`requirements`, `access`, `sandbox-denied`, `environment`' \
    && ok "workflow: $f gives the BLOCKED: note format everywhere it blocks" || bad "workflow: $f" "format or kinds missing"
done
grep -q 'HERMES_CONTINUE_ON_BLOCKED' "$ROOT/README.md" && grep -q 'HERMES_MAX_BLOCKED_IN_A_ROW' "$ROOT/README.md" \
  && ok "docs: README names both settings" || bad "docs: README" "missing"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
