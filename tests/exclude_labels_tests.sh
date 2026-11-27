#!/usr/bin/env bash
# Bead hermes-harness-66y: unattended runs never pick an issue labelled for a person (default
# owner-present, HERMES_EXCLUDE_LABELS). hermes-run makes the pick and names it in the prompt.
# Self-contained: `bash tests/exclude_labels_tests.sh`; tests/run_tests.sh runs it as a child.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=loop_fixture.sh
. "$HERE/loop_fixture.sh"
unset HERMES_EXCLUDE_LABELS

OWNER='"labels": ["owner-present"]'; MANUAL='"labels": ["manual"]'
STEP1='bd ready --json --exclude-type epic --exclude-label owner-present --sort priority'
log1() { cat "$(first_log)"; }
db() { reset_db; bead om-a 1 open "" "$OWNER"; bead om-b 2 open; }
# one run on the current DB with the given settings; the fake agent finds nothing to do
once() { agent_run 1 om-b NO_READY_WORK; hrun 1; }

# --- test_pick_skips_owner_present ---
db; once
prompt 1 | grep -q 'Work issue om-b ' && ok "exclude: the pick skips an owner-present issue" \
  || bad "exclude: pick" "rc=$rc $(prompt 1)"
log1 | grep -qx 'PICK: skipping owner-present issues: om-a (a person must run them)' \
  && say "$out" | grep -q 'PICK: skipping owner-present issues: om-a' \
  && ok "exclude: the run log and the terminal name the skipped issues" || bad "exclude: skip line" "$(log1 | head -8)"
say "$out" | grep -q 'BEADS: next om-b ' && ok "exclude: the BEADS: line names the same issue" \
  || bad "exclude: BEADS next" "$(say "$out" | grep BEADS)"
prompt 1 | grep -qF "if bd ready does not list it after bd dolt pull, pick with exactly this command and take the FIRST item: \`$STEP1\`" \
  && ok "exclude: the fallback in the prompt excludes the label too" || bad "exclude: fallback" "$(prompt 1)"

# --- test_exclude_labels_configurable ---
db; bead om-m 0 open "" "$MANUAL"
HERMES_EXCLUDE_LABELS=manual once
prompt 1 | grep -q 'Work issue om-a ' && prompt 1 | grep -qF -- '--exclude-label manual --sort' \
  && ! prompt 1 | grep -q 'owner-present' && log1 | grep -q '^PICK: skipping manual issues: om-m ' \
  && ok "exclude: HERMES_EXCLUDE_LABELS replaces the default label" || bad "exclude: configurable" "$(prompt 1)"
db; bead om-m 0 open "" "$MANUAL"
HERMES_EXCLUDE_LABELS=' owner-present, manual,' once
prompt 1 | grep -q 'Work issue om-b ' && prompt 1 | grep -qF -- '--exclude-label owner-present,manual --sort' \
  && log1 | grep -q '^PICK: skipping owner-present,manual issues: om-m om-a ' \
  && ok "exclude: several labels, with stray spaces and commas" || bad "exclude: several" "$(prompt 1) $(log1 | grep PICK)"

# --- test_exclude_labels_empty_disables ---
db
HERMES_EXCLUDE_LABELS='' once
prompt 1 | grep -q 'Work issue om-a ' && ! prompt 1 | grep -q -- '--exclude-label' && ! log1 | grep -q 'skipping' \
  && ok "exclude: an empty HERMES_EXCLUDE_LABELS picks any issue" || bad "exclude: disabled" "$(prompt 1)"

# a value that is not a list of labels refuses the run before anything starts
db
HERMES_EXCLUDE_LABELS='owner present; rm x' once
[ $rc -eq 2 ] && [ "$(chats)" = 0 ] && say "$out" | grep -q 'HERMES_EXCLUDE_LABELS' && [ ! -d "$W/logs/.run-beads.lock" ] \
  && ok "exclude: an invalid value is refused, naming the setting" || bad "exclude: invalid" "rc=$rc chats=$(chats) $out"

# --- the skipped issues are listed once per launch ---
db; bead om-c 3 open; agent_run 2 om-c NO_READY_WORK # run 1: the stub's default, a run that opens a PR
hrun 2
[ "$(chats)" = 2 ] && [ "$(say "$out" | grep -c 'PICK: skipping')" = 1 ] \
  && ok "exclude: one skip line per launch" || bad "exclude: once per launch" "chats=$(chats) $(say "$out" | grep PICK)"

# --- nothing left for an unattended run: no issue is named, and the prompt's command excludes ---
reset_db; bead om-a 1 open "" "$OWNER"; once
! prompt 1 | grep -q 'Work issue' && prompt 1 | grep -qF "In step 1, pick with exactly this command and take the FIRST item: \`$STEP1\`" \
  && say "$out" | grep -q 'BEADS: next none' \
  && ok "exclude: only excluded issues ready: Hermes gets the excluding command" || bad "exclude: only excluded" "$(prompt 1) $(say "$out" | grep BEADS)"

# --- bd ready failing: say so, leave the pick to Hermes, still excluding ---
db; STUB_READY_FAIL=1 once
! prompt 1 | grep -q 'Work issue' && prompt 1 | grep -qF "$STEP1" \
  && log1 | grep -q '^PICK: could not read the ready list .*: Hermes picks in step 1' \
  && log1 | grep -q '^PICK: could not list the owner-present issues' \
  && ok "exclude: a failing bd ready is reported and the run goes on" || bad "exclude: bd failure" "$(log1 | head -8)"

# --- test_requeue_chain_respects_exclusion ---
reset_db; rq om-a 1 open om-b; bead om-b 1 open "" "$OWNER"; bead om-c 3 open; once
prompt 1 | grep -q 'Work issue om-c ' \
  && log1 | grep -qx 'REQUEUE CHAIN: om-b is open but labelled owner-present: a person must run it' \
  && log1 | grep -qx 'PICK: skipping owner-present issues: om-b (a person must run them)' \
  && ok "exclude: an owner-present blocker is not picked; the normal pick runs and the log says why" \
  || bad "exclude: chain blocker" "$(prompt 1) $(log1 | grep -E 'PICK|CHAIN')"
reset_db; rq om-a 1 open om-b; set_status om-a open; bead om-b 1 closed; bead om-c 3 open
rq om-a 1 open om-b; python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["labels"]=["owner-present"]; json.dump(d,open(p,"w"))' "$STUB_DB/om-a.json"
once
prompt 1 | grep -q 'Work issue om-c ' && log1 | grep -q '^REQUEUE CHAIN: om-a is open but labelled owner-present' \
  && ok "exclude: a finishable requeued issue that is owner-present is not picked" \
  || bad "exclude: chain root" "$(prompt 1) $(log1 | grep -E 'PICK|CHAIN')"

# --- test_status_lists_excluded_ready ---
status() { (cd "$W" && GIT_SSH_COMMAND=false "$BIN/hermes-status" 2>&1); }
waiting() { sed -n '/^-- waiting on you/,/^-- in progress/p'; }
db; s=$(status)
say "$s" | grep -qx -- '-- waiting on you (ready, labelled owner-present: unattended runs skip them)' \
  && say "$s" | waiting | grep -q 'om-a' && ! say "$s" | waiting | grep -q 'om-b' \
  && ok "exclude: hermes-status lists the issues waiting on you" || bad "exclude: status" "$(say "$s" | sed -n '/beads/,/active run/p')"
s=$(HERMES_EXCLUDE_LABELS=manual status)
say "$s" | grep -q 'waiting on you (ready, labelled manual' && ! say "$s" | waiting | grep -q 'om-a' \
  && ok "exclude: hermes-status follows the setting" || bad "exclude: status setting" "$(say "$s" | waiting)"
s=$(HERMES_EXCLUDE_LABELS='' status)
! say "$s" | grep -q 'waiting on you' && say "$s" | grep -q '^-- ready' \
  && ok "exclude: hermes-status has no waiting list when nothing is excluded" || bad "exclude: status disabled" "$s"
s=$(HERMES_EXCLUDE_LABELS='a b' status)
say "$s" | grep -q 'unavailable: .*HERMES_EXCLUDE_LABELS' && say "$s" | grep -q '^== active run ==' \
  && ok "exclude: hermes-status names an invalid value and carries on" || bad "exclude: status invalid" "$(say "$s" | sed -n '/beads/,/active run/p')"

# --- help and the workflow text ---
say "$("$BIN/hermes-run" --help)" | grep -q 'HERMES_EXCLUDE_LABELS=owner-present' \
  && ok "exclude: hermes-run --help documents the setting" || bad "exclude: help" "no HERMES_EXCLUDE_LABELS"
for doc in AGENTS.md templates/AGENTS_WORKFLOW.md; do
  text=$(tr '\n' ' ' < "$ROOT/$doc" | tr -s ' ')
  say "$text" | grep -qF "\`$STEP1\`" && say "$text" | grep -qF 'If your prompt gives another pick command, use that one' \
    && say "$text" | grep -qF 'bd ready --exclude-type epic --exclude-label owner-present --sort priority' \
    && ok "workflow: $doc: step 1 and the diagram leave out owner-present" || bad "workflow: $doc step 1" "missing"
  say "$text" | grep -qF 'real host names, IP addresses, usernames or home or library paths' \
    && say "$text" | grep -qF 'notes, PR text, commit messages' \
    && ok "workflow: $doc: no real hosts, IPs or usernames in notes, PRs or commits" || bad "workflow: $doc hosts rule" "missing"
done

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
