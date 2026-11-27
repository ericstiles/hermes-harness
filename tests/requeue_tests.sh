#!/usr/bin/env bash
# Bead hermes-harness-35r: a picked issue blocked by another bead is requeued (RUN_REQUEUED) and the
# loop works the blocker chain before returning to it. Self-contained: `bash tests/requeue_tests.sh`
# runs it alone; tests/run_tests.sh runs it as a child and adds up its ok/FAIL lines.
# No network: bd is a small fixture beads DB, hermes/docker/gh/ps are stubs.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1 (got: ${2:-})"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2 != $3"; }
say() { ( trap '' PIPE; printf '%s\n' "$1" ) 2>/dev/null || true; }
# the temp dir name is the test marker: the harness's "a run is active" check skips such processes
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-harness-test.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
tmp=${tmp%/}; tmp=${tmp//\/\//\/}; ln -s "$ROOT" "$tmp/harness"; H="$tmp/harness"; BIN="$H/bin"
mkdir -p "$tmp/target" "$tmp/bin" "$tmp/plan"; W=$(cd "$tmp/target" && pwd -P)
git -C "$W" init -q -b main; git -C "$W" remote add origin git@github.com:acme/widgets.git
unset GITHUB_REPO HERMES_REPO HERMES_LOG_DIR
export HERMES_AGENT_LOG="$tmp/absent-agent.log" STUB_DB="$tmp/db" STUB_LOG="$tmp/stub.log"
export STUB_PLAN="$tmp/plan" STUB_COUNT="$tmp/count" GH_TOKEN=x

# --- fixture beads DB: one JSON file per bead; `ready` and `show` are computed from them ---
cat > "$tmp/bin/bd" <<'S'
#!/usr/bin/env python3
import glob, json, os, sys

db, args = os.environ["STUB_DB"], sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    print("bd", *args, file=log)
beads = {}
for path in glob.glob(os.path.join(db, "*.json")):
    with open(path) as f:
        bead = json.load(f)
    beads[bead["id"]] = bead


def dep(i, kind):
    b = beads[i]
    return {"id": i, "status": b["status"], "priority": b["priority"], "dependency_type": kind}


def full(b):
    deps = [dep(i, "blocks") for i in b.get("blocks", [])]
    if b.get("parent"):
        deps.append(dep(b["parent"], "parent-child"))
    return {**b, "title": "title " + b["id"], "dependencies": deps}


def flat(b):
    """The shape `bd ready` and `bd list` give dependencies (bd 1.3.4)."""
    deps = [{"depends_on_id": i, "type": "blocks"} for i in b.get("blocks", [])]
    if b.get("origin"):
        deps.append({"depends_on_id": b["origin"], "type": "discovered-from"})
    return {**b, "title": "title " + b["id"], "dependencies": deps}


if args[:1] == ["list"] and "--notes-contains" in args:
    if os.environ.get("STUB_LIST_FAIL") == "1":
        sys.exit(1)
    text = args[args.index("--notes-contains") + 1]
    print(json.dumps([
        flat(b) for b in beads.values()
        if text in b.get("notes", "") and ("--status=open" not in args or b["status"] == "open")
    ]))
elif args[:1] == ["update"] and args[2:3] == ["--append-notes"]:
    path = os.path.join(db, args[1] + ".json")
    old = beads[args[1]].get("notes", "")
    with open(path, "w") as f:
        json.dump({**beads[args[1]], "notes": (old + "\n" if old else "") + args[3]}, f)
elif args[:1] == ["show"]:
    if args[1] not in beads:
        sys.exit(1)
    print(json.dumps([full(beads[args[1]])]))
elif args[:1] == ["ready"]:
    ready = sorted(
        (
            b
            for b in beads.values()
            if b["status"] == "open"
            and b.get("issue_type") != "epic"
            and all(beads[i]["status"] == "closed" for i in b.get("blocks", []))
        ),
        key=lambda b: (b["priority"], b["id"]),
    )
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else 100
    print(json.dumps([flat(b) for b in (ready[:limit] if limit else ready)]))
elif args[:1] == ["stats"]:
    print('{"summary": {"ready_issues": 1, "total_issues": 3}}')
elif args[:2] == ["dolt", "pull"]:
    with open(os.environ["STUB_LOG"]) as log:
        pulls = sum(line.startswith("bd dolt pull") for line in log)
    if str(pulls) == os.environ.get("STUB_CYCLE_AT_PULL"):
        with open(os.path.join(db, "om-b.json"), "w") as f:
            json.dump({**beads["om-b"], "blocks": ["om-a"]}, f)
    sys.exit(1 if os.environ.get("STUB_PULL_FAIL") == "1" else 0)
S
# chat number N prints $STUB_PLAN/N (else a run that opens a PR); the prompt is logged
cat > "$tmp/bin/hermes" <<'S'
#!/bin/sh
[ "$1" = config ] && { echo stub; exit 0; }
[ "$1" = chat ] || exit 1
for last; do :; done
echo "PROMPT: $last" >> "$STUB_LOG"
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT"
[ -n "${STUB_TOUCH:-}" ] && echo "# changed mid-run" >> "$STUB_TOUCH"
if [ -f "$STUB_PLAN/$n" ]; then cat "$STUB_PLAN/$n"
else echo "PR https://github.com/o/r/pull/1"; echo; echo "Resume this session with:"; fi
exit 0
S
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/docker"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ps"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

reset_db() { rm -rf "$STUB_DB" "$STUB_PLAN"; mkdir -p "$STUB_DB" "$STUB_PLAN"; }
bead() { # <id> <priority> <status> [blocker ids, space separated] [extra JSON members]
  local blocks="" b
  for b in ${4:-}; do blocks="$blocks\"$b\","; done
  printf '{"id": "%s", "priority": %s, "status": "%s", "blocks": [%s]%s}\n' \
    "$1" "$2" "$3" "${blocks%,}" "${5:+, $5}" > "$STUB_DB/$1.json"
}
rq() { # <id> <priority> <status> <blockers> : a bead the agent requeued (with the note it writes)
  bead "$1" "$2" "$3" "$4" '"notes": "REQUEUED: blocked by x: why"'
}
set_status() { python3 -c 'import json,sys; p,s=sys.argv[1:]; d=json.load(open(p)); d["status"]=s; json.dump(d,open(p,"w"))' "$STUB_DB/$1.json" "$2"; }
agent_run() { # <chat number> <claimed id> <last words>
  printf '  ┊ 💻 $ bd update %s --claim --json\n%s\n\nResume this session with:\n' "$2" "$3" > "$STUB_PLAN/$1"
}
hrun() { # <max> : hermes-run in the target repo; sets out, rc
  rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
  out=$(cd "$W" && "$BIN/hermes-run" "$@" 2>&1); rc=$?
}
chats() { grep -c '^PROMPT: ' "$STUB_LOG"; }
prompt() { grep '^PROMPT: ' "$STUB_LOG" | sed -n "${1}p"; }
first_log() { ls "$W"/logs/run-*.log | sed 's/\.log$//' | LC_ALL=C sort | head -n 1 | sed 's/$/.log/'; }
sup() { (cd "$W" && HERMES_LOG_DIR="$W/logs" "$BIN/hermes-supervise" "$@"); }

# --- test_classify_run_requeued_marker ---
. "$ROOT/lib/classify.sh"
mark() { agent_run 1 om-a "$1"; hermes_classify "$STUB_PLAN/1" 0; }
reset_db
eq "requeue: classify RUN_REQUEUED" "$(mark RUN_REQUEUED)" REQUEUED
eq "requeue: classify RUN_BLOCKED is still BLOCKED" "$(mark RUN_BLOCKED)" BLOCKED
eq "requeue: both markers are BLOCKED" "$(mark "$(printf 'RUN_REQUEUED\nRUN_BLOCKED')")" BLOCKED
eq "requeue: RUN_REQUEUED inside a sentence is not the marker" "$(mark 'then print RUN_REQUEUED and stop')" AGENT_STOPPED

# --- test_requeued_continues_loop ---
reset_db; bead om-a 2 open om-b; bead om-b 2 open; bead om-x 1 open
agent_run 1 om-a RUN_REQUEUED; agent_run 2 om-b NO_READY_WORK # any clean second run
hrun 2
[ $rc -eq 0 ] && [ "$(chats)" = 2 ] && ! say "$out" | grep -q 'Issue blocked' \
  && ok "requeue: the loop continues after REQUEUED" || bad "requeue: loop continues" "rc=$rc chats=$(chats) $(say "$out" | tail -5)"
prompt 1 | grep -q 'Work issue' && bad "requeue: first prompt names an issue" "$(prompt 1)" \
  || ok "requeue: an empty chain leaves the pick to the agent"
prompt 2 | grep -q 'Follow AGENTS.md "Autonomous Beads workflow".*Work issue om-b ' \
  && ok "requeue: the next run is told to work the blocker, ahead of a higher priority issue" || bad "requeue: chain prompt" "$(prompt 2)"
grep -q '^RUN_RESULT=REQUEUED$' "$(first_log)" && grep -q '^REQUEUE: om-a blocked by om-b$' "$(first_log)" \
  && ok "requeue: the run log records the requeue" || bad "requeue: run log" "$(tail -4 "$(first_log)")"
say "$out" | grep -qx '== run 1/2 completed: REQUEUED (issue om-a)' \
  && say "$out" | grep -qx '== run 2/2 completed: QUEUE_EMPTY (issue om-b)' \
  && ok "run number: each run's end names its number, result and issue" || bad "run number" "$(say "$out" | grep '== run')"
say "$out" | grep -q 'BEADS: next om-b ' && ok "requeue: the BEADS: start line names the chosen issue" \
  || bad "requeue: BEADS next" "$(say "$out" | grep BEADS)"
say "$out" | grep -q '^BEADS: loop worked 2 issue(s): om-a om-b | requeued om-a -> om-b | ' \
  && ok "requeue: the loop summary shows what was requeued" || bad "requeue: summary" "$(say "$out" | grep 'BEADS: loop')"
dolt_pulls=$(grep -c '^bd dolt pull' "$STUB_LOG")
[ "$dolt_pulls" -ge 2 ] && ok "requeue: beads are pulled before the check and the chain pick" || bad "requeue: pulls" "$dolt_pulls"

# the requeue was the last allowed run: a good end, and supervise relaunches
reset_db; bead om-a 2 open om-b; bead om-b 2 open; agent_run 1 om-a RUN_REQUEUED
hrun 1
[ $rc -eq 0 ] && say "$out" | grep -q '^FINAL_RESULT=REQUEUED$' && ok "requeue: a requeue on the last run ends the loop cleanly" \
  || bad "requeue: last run" "rc=$rc $(say "$out" | tail -4)"

# --- test_supervise_requeued_is_done (owner's decision on PR #47: no relaunch, --max stays the cap) ---
log=$(first_log); sout=$(sup "$log")
say "$sout" | grep -q '^CLASS=REQUEUED$' && say "$sout" | grep -q '^ACTION=DONE$' && ! say "$sout" | grep -q '^NEXT=' \
  && say "$sout" | grep -q '^WHY=.*om-a.*waits on its blocker.*hermes-launch' \
  && ok "requeue: supervise says DONE and starts nothing" || bad "requeue: supervise" "$sout"
echo "LOOP_STOP=HARNESS_CHANGED left=4 files=lib/x.sh" >> "$log"
sout=$(sup "$log")
say "$sout" | grep -q '^NEXT=hermes-launch --reason HARNESS_CHANGED --max 4$' \
  && ok "requeue: a harness change after a requeue keeps the issues that were left" || bad "requeue: harness changed" "$sout"

# --- test_requeued_without_edge_is_blocked ---
refused() { # <label> <expected reason>
  hrun 3
  [ $rc -eq 1 ] && [ "$(chats)" = "${CHATS:-1}" ] && say "$out" | grep -q 'Issue blocked — stopping' \
    && say "$out" | grep -q "^REQUEUE_REFUSED: .*$2" && say "$out" | grep -q '^FINAL_RESULT=BLOCKED$' \
    && ok "requeue refused: $1" || bad "requeue refused: $1" "rc=$rc chats=$(chats) $(say "$out" | tail -6)"
}
reset_db; bead om-a 2 open; agent_run 1 om-a RUN_REQUEUED
refused "no blocker edge" 'no open blocker'
say "$out" | grep -qx '== run 1/3 completed: BLOCKED (issue om-a)' && ok "run number: the final result is shown, not the agent's" \
  || bad "run number: refused" "$(say "$out" | grep '== run')"
say "$(sup)" | grep -q '^ACTION=ASK_HUMAN$' && ok "requeue refused: supervise asks the human" || bad "requeue refused: supervise" "$(sup)"
reset_db; bead om-a 2 open om-b; bead om-b 2 closed; agent_run 1 om-a RUN_REQUEUED
refused "only a closed blocker" 'no open blocker'
reset_db; bead om-e 2 open "" '"issue_type": "epic"'; bead om-a 2 open "" '"parent": "om-e"'; agent_run 1 om-a RUN_REQUEUED
refused "an epic parent is not a blocker" 'no open blocker'
reset_db; bead om-a 2 in_progress om-b '"assignee": "hermes"'; bead om-b 2 open; agent_run 1 om-a RUN_REQUEUED
refused "still claimed" 'in_progress'
reset_db; bead om-a 2 open om-b '"assignee": "hermes"'; bead om-b 2 open; agent_run 1 om-a RUN_REQUEUED
refused "still assigned" 'assigned to hermes'
reset_db; bead om-a 2 open om-b; bead om-b 2 open om-a; agent_run 1 om-a RUN_REQUEUED
refused "a dependency cycle" 'cycle: om-a -> om-b -> om-a'
reset_db; agent_run 1 om-a RUN_REQUEUED
refused "bd cannot show the issue" 'bd show om-a failed'
reset_db; printf '\nRUN_REQUEUED\n\nResume this session with:\n' > "$STUB_PLAN/1"
refused "no claimed issue" 'no claimed issue'
reset_db; bead om-a 2 open om-b; bead om-b 2 open; agent_run 1 om-a RUN_REQUEUED; agent_run 2 om-a RUN_REQUEUED
CHATS=2 refused "the same issue twice in one launch" 'already requeued'

# a failed host pull only warns: the local state still decides
reset_db; bead om-a 2 open om-b; bead om-b 2 open; agent_run 1 om-a RUN_REQUEUED
STUB_PULL_FAIL=1 hrun 1
say "$out" | grep -q 'warning: bd dolt pull failed' && say "$out" | grep -q '^FINAL_RESULT=REQUEUED$' \
  && ok "requeue: a failed bd dolt pull warns and still requeues" || bad "requeue: pull fails" "$(say "$out" | tail -6)"

# --- chain-ordered pick (lib/requeue.sh): rebuilt from beads each time, so it survives launches ---
pick() { # sets picked, why (the explanation lines), rc
  local res
  res=$(HARNESS_HOME="$H" bash -c '. "$HARNESS_HOME/lib/requeue.sh"; hh_chain_pick
    echo "PICKED=$HH_CHAIN_PICK"; printf "%s\n" "$HH_CHAIN_LOG"' 2>"$tmp/pick.err"); rc=$?
  picked=$(say "$res" | sed -n 's/^PICKED=//p'); why=$(say "$res" | sed 1d)
}
chain_check() { # <label> <expected pick> <explanation substrings...>
  local label=$1 want=$2 e missing=""; shift 2
  pick
  for e in "$@"; do say "$why" | grep -qF -- "$e" || missing="$missing [$e]"; done
  [ $rc -eq 0 ] && [ "$picked" = "$want" ] && [ -z "$missing" ] && ok "chain pick: $label" \
    || bad "chain pick: $label" "rc=$rc picked='$picked' missing$missing :: $why $(cat "$tmp/pick.err")"
}
# --- test_chain_pick_deepest_ready_blocker ---
reset_db; rq om-a 2 open om-b; bead om-b 2 open om-c; bead om-c 3 open; bead om-x 1 open
chain_check "the deepest ready blocker, not an unrelated higher priority issue" om-c \
  'REQUEUE CHAIN: 1 requeued issue(s) still to be finished: om-a' 'om-a waits on om-b' 'om-b waits on om-c' \
  'next pick: om-c (a ready blocker; chain om-a -> om-b -> om-c)'
# --- test_chain_pick_returns_down_the_chain ---
set_status om-c closed; chain_check "then the next one down" om-b 'next pick: om-b'
set_status om-b closed
chain_check "then the requeued issue, ahead of higher priority" om-a 'next pick: om-a (it was requeued and its blockers are closed)'
set_status om-a in_progress; chain_check "a claimed issue leaves the chain" ""
[ -z "$why" ] && ok "chain pick: nothing requeued, nothing logged" || bad "chain pick: quiet" "$why"
# --- test_chain_pick_falls_back_when_chain_not_ready ---
reset_db; rq om-a 2 open om-b; bead om-b 2 in_progress "" '"assignee": "hermes"'; bead om-x 1 open
chain_check "nothing ready on the chain: the normal pick, and it says why" "" \
  'om-b is in_progress, claimed by hermes (being worked, or its PR waits for review)' \
  'nothing on these chains is ready: picking as usual' 'taken first once its blockers are closed'
# a review fix of a blocker whose PR was rejected is part of the chain
bead om-f 2 open "" '"labels": ["review-fix"], "origin": "om-b"'; bead om-n 1 open "" '"origin": "om-b"'
chain_check "a blocker's open review fix is worked (not other issues discovered from it)" om-f \
  'next pick: om-f (a review fix of om-b; chain om-a -> om-b -> om-f)'
set_status om-f in_progress; chain_check "a claimed review fix waits like its ticket" "" 'picking as usual'
# several blockers: priority then id; one claimed elsewhere is skipped
reset_db; rq om-a 2 open "om-m om-k om-z"; bead om-m 2 open; bead om-k 2 open; bead om-z 1 in_progress
chain_check "several blockers in priority then id order, a claimed one skipped" om-k
# several requeued issues: a finishable one first; else every chain is looked at
reset_db; rq om-a 2 open om-b; bead om-b 2 closed; rq om-d 1 open om-e; bead om-e 2 open
chain_check "an issue that can be finished comes before another chain's blocker" om-a '2 requeued issue(s) still to be finished: om-d om-a'
reset_db; rq om-a 1 open om-b; bead om-b 2 in_progress; rq om-d 2 open om-e; bead om-e 2 open
chain_check "a waiting chain does not hide a ready one" om-e
reset_db; rq om-a 2 open om-b; bead om-b 2 blocked
chain_check "a blocker marked blocked is named for the human" "" 'om-b is blocked: needs a human (bd show om-b)'
# --- cycles and look-alikes ---
reset_db; rq om-a 1 open om-b; bead om-b 2 open om-a; rq om-d 2 open om-e; bead om-e 2 open
chain_check "a cycle is reported and skipped; other chains go on" om-e 'dependency cycle om-a -> om-b -> om-a: needs a human'
reset_db; bead om-a 1 open "" '"notes": "REQUEUED: blocked by om-b: no edge was ever added"'
bead om-b 2 open om-c '"notes": "see REQUEUED: blocked by in the docs"'; bead om-c 2 open
chain_check "a note without an edge, or a mention in prose, is not a requeue" ""
reset_db; rq om-a 2 open om-b
STUB_LIST_FAIL=1 chain_check "a bd failure says so and falls back" "" 'could not read the requeue chain' 'picking as usual'

# --- across launches: the chain is remembered in beads (owner's requirement: get A done) ---
reset_db; bead om-a 2 open om-b; bead om-b 2 open; bead om-x 1 open; agent_run 1 om-a RUN_REQUEUED
hrun 1
grep -q 'bd update om-a --append-notes REQUEUED: blocked by om-b' "$STUB_LOG" && say "$out" | grep -q 'REQUEUE CHAIN: om-a had no REQUEUED note; added it' \
  && ok "requeue: a missing note is added, so later launches remember" || bad "requeue: note added" "$(say "$out" | grep REQUEUE)"
say "$out" | grep -q 'REQUEUE CHAIN: om-a is open again; it is taken first once om-b is closed' \
  && say "$out" | grep -q 'REQUEUE CHAIN: state at the end of this loop' && say "$out" | grep -q 'REQUEUE CHAIN: next pick: om-b' \
  && grep -q '^REQUEUE CHAIN: next pick: om-b' "$(first_log)" \
  && ok "requeue: the loop's end says what comes next, in the run log too" || bad "requeue: end state" "$(say "$out" | grep REQUEUE)"
agent_run 1 om-b NO_READY_WORK; hrun 1
prompt 1 | grep -q 'Work issue om-b ' && ok "requeue: a new launch starts with the blocker" || bad "requeue: next launch" "$(prompt 1)"
grep -q '^REQUEUE CHAIN: next pick: om-b' "$(first_log)" && grep -q 'REQUEUE CHAIN: next pick: om-b' "$W"/logs/run-*.timed.txt \
  && ok "requeue: the run log and the timed log explain the pick" || bad "requeue: pick log" "$(head -8 "$(first_log)")"
set_status om-b closed; agent_run 1 om-a NO_READY_WORK; hrun 1
prompt 1 | grep -q 'Work issue om-a ' && ok "requeue: once the blocker is closed, a new launch takes the requeued issue first" \
  || bad "requeue: A next" "$(prompt 1) $(say "$out" | grep REQUEUE)"
# the loop itself falls back to the agent's own pick when the chain is not ready
reset_db; bead om-a 2 open om-b; bead om-b 2 in_progress; bead om-x 1 open; agent_run 1 om-a RUN_REQUEUED
hrun 2
[ "$(chats)" = 2 ] && ! prompt 2 | grep -q 'Work issue' && say "$out" | grep -q 'nothing on these chains is ready' \
  && ok "requeue: the loop falls back to the normal pick and says why" || bad "requeue: loop fallback" "$(prompt 2) $(say "$out" | grep REQUEUE)"
# a cycle synced in after the requeue (STUB_CYCLE_AT_PULL) is reported; the loop goes on
reset_db; bead om-a 2 open om-b; bead om-b 2 open; agent_run 1 om-a RUN_REQUEUED; agent_run 2 om-x NO_READY_WORK
STUB_CYCLE_AT_PULL=3 hrun 2
[ "$(chats)" = 2 ] && say "$out" | grep -q 'dependency cycle om-a -> om-b -> om-a: needs a human' && ! prompt 2 | grep -q 'Work issue' \
  && ok "requeue: a cycle found at the pick is reported, not worked" || bad "requeue: loop cycle" "rc=$rc chats=$(chats) $(say "$out" | grep REQUEUE)"

# --- the loop counts these files as its own code (bead eyx), and the workflow text says what to do ---
loaded=$(bash -c '. "$1/lib/code_stamp.sh"; hh_loaded_files "$1"' _ "$H")
say "$loaded" | grep -qx 'sourced lib/requeue.sh' && say "$loaded" | grep -qx 'run lib/requeue.py' \
  && ok "requeue: the new files are part of the loaded code" || bad "requeue: loaded files" "$loaded"
for doc in AGENTS.md templates/AGENTS_WORKFLOW.md; do
  missing=""
  for want in 'RUN_REQUEUED' 'RUN_BLOCKED' 'bd dep add <id> <blocker>' 'bd unclaim <id>' 'REQUEUED: blocked by <blocker>' 'Work issue <id>'; do
    grep -qF -- "$want" "$ROOT/$doc" || missing="$missing [$want]"
  done
  [ -z "$missing" ] && ok "requeue: $doc describes the requeue steps" || bad "requeue: $doc" "missing$missing"
  # review of PR #47: bd refuses `dep add` over another edge type (discovered-from, related)
  grep -qF 'already exists with type' "$ROOT/$doc" && grep -qF 'bd dep remove <id> <blocker>' "$ROOT/$doc" \
    && ok "requeue: $doc replaces an edge of another type" || bad "requeue: $doc edge type" "missing"
  # review of PR #47: the next run shares the clone, so nothing may stay uncommitted
  grep -qF 'git add -A && git commit -m "wip(<id>): <summary>"' "$ROOT/$doc" \
    && [ "$(grep -cF 'git status --porcelain' "$ROOT/$doc")" -ge 3 ] \
    && grep -qF 'commit and push anything uncommitted to `bd/<T>`' "$ROOT/$doc" \
    && grep -qF 'git log origin/main..bd/<id>' "$ROOT/$doc" && grep -qF 'git checkout -b bd/<id> origin/main' "$ROOT/$doc" \
    && grep -qF 'WIP: bd/<T>' "$ROOT/$doc" \
    && ok "requeue: $doc leaves a clean clone, review-fix too" || bad "requeue: $doc clean clone" "missing"
done

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
