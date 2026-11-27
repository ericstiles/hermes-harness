#!/usr/bin/env bash
# Shared setup of the self-contained hermes-run loop tests (requeue_tests.sh, exclude_labels_tests.sh):
# source it after setting HERE and ROOT. No network: bd is a small fixture beads DB, and
# hermes/docker/gh/ps are stubs. Gives ok/bad/eq/say, $tmp $W $BIN, bead/rq/hrun/prompt and friends.
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
    def opt(name):
        return set(args[args.index(name) + 1].split(",")) if name in args else set()

    if os.environ.get("STUB_READY_FAIL") == "1":
        sys.exit(1)
    skip, only = opt("--exclude-label"), opt("--label-any")
    if only:
        with open(os.environ["STUB_LOG"]) as log:
            reads = sum("--label-any" in line for line in log)
        if reads <= int(os.environ.get("STUB_WAITING_FAILS") or 0):
            sys.exit(1)
    ready = sorted(
        (
            b
            for b in beads.values()
            if b["status"] == "open"
            and b.get("issue_type") != "epic"
            and all(beads[i]["status"] == "closed" for i in b.get("blocks", []))
            and not skip & set(b.get("labels", []))
            and (not only or only & set(b.get("labels", [])))
        ),
        key=lambda b: (b["priority"], b["id"]),
    )
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else 100
    shown = ready[:limit] if limit else ready
    late = os.environ.get("STUB_LATE_BEAD")
    if late and limit == 1 and late not in beads:  # synced in just after this read
        with open(os.path.join(db, late + ".json"), "w") as f:
            json.dump({"id": late, "priority": 0, "status": "open", "blocks": []}, f)
    if "--json" in args:
        print(json.dumps([flat(b) for b in shown]))
    else:
        for b in shown:
            print("o", b["id"], "title", b["id"])
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
