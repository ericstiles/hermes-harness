#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad, $ROOT). The Hermes pre_tool_call hook
# lib/hooks/bd_notes_guard.py must block `bd update ... --notes` (it replaces the whole notes
# field; incident 2026-11-19 wiped a bead's PR link) and allow everything else.
NG="$ROOT/lib/hooks/bd_notes_guard.py"
# The hook only acts in hermes-run sessions (hermes-run exports HERMES_HARNESS_RUN=1); the
# helpers set it per call so it never leaks into the hermes-run tests.

ng_payload() { # <tool_name> <command> -> the stdin JSON Hermes sends
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name": "pre_tool_call",
    "tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}, "session_id": "s",
    "cwd": "/", "extra": {}}))' "$1" "$2"
}
ng_blocks() { # <name> <command>
  local out rc
  out=$(ng_payload terminal "$2" | HERMES_HARNESS_RUN=1 "$NG" 2>/dev/null); rc=$?
  [ $rc -eq 0 ] && say "$out" | grep -q '"decision": "block"' && say "$out" | grep -q -- '--append-notes' \
    && ok "notes guard: blocks $1" || bad "notes guard: blocks $1" "rc=$rc $out"
}
ng_allows() { # <name> <command> [tool]
  local out rc
  out=$(ng_payload "${3:-terminal}" "$2" | HERMES_HARNESS_RUN=1 "$NG" 2>/dev/null); rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && ok "notes guard: allows $1" || bad "notes guard: allows $1" "rc=$rc $out"
}

ng_blocks "bd update X --notes @/tmp/f" 'bd update organize_music-6ut.10 --notes @/tmp/6ut10_notes.txt'
ng_blocks "bd update X --notes 'text'" "bd update om-1 --notes 'PR: https://x/pull/1'"
ng_blocks "bd update X --notes=text" 'bd update om-1 --notes=hello'
ng_blocks "--notes before the issue id" 'bd update --notes x om-1'
ng_blocks "it after cd and &&" 'cd /workspace/om && bd update om-1 --notes "x"'
ng_blocks "it on a later line" $'git status\nbd update om-1 --notes x'
ng_blocks "it inside bash -c" "bash -c 'bd update om-1 --notes x'"
ng_blocks "a bd path" '/usr/local/bin/bd update om-1 --notes x'
ng_blocks "env assignments and command/env prefixes" 'BEADS_DIR=/w env FOO=1 command bd update om-1 --notes x'
ng_blocks "unbalanced quotes (regex fallback)" "bd update om-1 --notes \"oops"
ng_allows "bd update X --append-notes 'PR: url'" "bd update om-1 --append-notes 'PR: https://x/pull/1'"
ng_allows "--notes only inside a quoted append-notes value" "bd update om-1 --append-notes 'do not use --notes here'"
ng_allows "an append-notes value that is exactly --notes" "bd update om-1 --append-notes --notes"
ng_allows "bd show / bd create" 'bd show om-1 && bd create "t" --notes x'
ng_allows "unrelated commands" 'git log --notes; echo update --notes'
ng_allows "non-terminal tools" 'bd update om-1 --notes x' execute_code
out=$(ng_payload terminal 'bd update om-1 --notes x' | env -u HERMES_HARNESS_RUN "$NG" 2>/dev/null); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "notes guard: does nothing outside a hermes-run session" \
  || bad "notes guard: outside hermes-run" "rc=$rc $out"
out=$(ng_payload terminal 'bd update om-1 --notes x' | HERMES_HARNESS_RUN=0 "$NG" 2>/dev/null)
[ -z "$out" ] && ok "notes guard: HERMES_HARNESS_RUN=0 counts as outside" || bad "notes guard: =0" "$out"

# The workflow template states the same rule the hook enforces (hermes-harness-xgc).
TPL="$ROOT/templates/AGENTS_WORKFLOW.md"
grep -q 'Never replace notes' "$TPL" && grep -q -- '--append-notes' "$TPL" \
  && ok "template: notes are append-only" || bad "template: append-only rule" "missing"
bad_notes=$(grep -nE -- '--notes[ =]' "$TPL" | grep -v 'Never replace notes' || true)
[ -z "$bad_notes" ] && ok "template: --notes appears only in the prohibition" || bad "template: --notes use" "$bad_notes"
grep -q -- '- \[x\]' "$TPL" && ok "template: tick a checklist item by appending a [x] line" || bad "template: tick rule" "missing"
grep -q 'no `@file`' "$TPL" && ok "template: no @file on bd flags" || bad "template: @file rule" "missing"
[ "$(grep -c 'verify with `bd show' "$TPL")" -ge 2 ] && ok "template: verify-after-write in the normal and review-fix paths" \
  || bad "template: verify step" "$(grep -c 'verify with `bd show' "$TPL")"

out=$(printf 'not json' | HERMES_HARNESS_RUN=1 "$NG" 2>&1 >/dev/null); rc=$?
[ $rc -eq 0 ] && say "$out" | grep -q 'bd_notes_guard' && ok "notes guard: malformed payload fails open with a log line" \
  || bad "notes guard: malformed payload" "rc=$rc $out"
out=$(printf '{"tool_name":"terminal","tool_input":null}' | HERMES_HARNESS_RUN=1 "$NG" 2>/dev/null); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "notes guard: missing tool_input is allowed" || bad "notes guard: no tool_input" "rc=$rc $out"

# Claim check (incident 2026-11-24: the PR link went to organize_music-b8p.25 instead of
# organize_music-225): with HERMES_HARNESS_CLAIMS set, --append-notes only on beads claimed this run.
CL="$tmp/claims"
ngc() { # <command> -> hook output with the claims file
  ng_payload terminal "$1" | HERMES_HARNESS_RUN=1 HERMES_HARNESS_CLAIMS="$CL" "$NG" 2>/dev/null
}
: > "$CL"
out=$(ngc 'bd update om-225 --append-notes "PR: https://x/pull/1"')
say "$out" | grep -q '"decision": "block"' && say "$out" | grep -q 'has not claimed om-225' \
  && ok "claim guard: blocks append-notes before any claim" || bad "claim guard: no claims" "$out"
out=$(ngc 'cd /w && bd update om-225 --claim --json')
[ -z "$out" ] && grep -qx 'om-225' "$CL" && ok "claim guard: records a claim" || bad "claim guard: record" "$out | $(cat "$CL")"
out=$(ngc 'bd update om-225 --append-notes "PR: https://x/pull/1"')
[ -z "$out" ] && ok "claim guard: allows append-notes on the claimed bead" || bad "claim guard: claimed" "$out"
out=$(ngc 'bd update om-b8p.25 --append-notes "PR: https://x/pull/1"')
say "$out" | grep -q '"decision": "block"' && say "$out" | grep -q 'om-b8p.25' && say "$out" | grep -q 'claimed: om-225' \
  && ok "claim guard: blocks append-notes on a look-alike bead (b8p.25 vs 225)" || bad "claim guard: look-alike" "$out"
out=$(ngc 'bd update 225 --append-notes x')
say "$out" | grep -q '"decision": "block"' && ok "claim guard: a shortened id does not match the claim" || bad "claim guard: short id" "$out"
out=$(ngc 'bd update om-side --claim && bd update om-side --append-notes "Fixed in PR u via review-fix om-225"')
[ -z "$out" ] && grep -qx 'om-side' "$CL" && ok "claim guard: a claim earlier in the same command counts" || bad "claim guard: same command" "$out"
out=$(ngc 'bd update om-225 --status blocked --append-notes "needs B"')
[ -z "$out" ] && ok "claim guard: flags before append-notes are parsed (status value is not an id)" || bad "claim guard: flags" "$out"
out=$(ngc 'bd update --append-notes x')
say "$out" | grep -q 'without a bead id' && ok "claim guard: blocks append-notes with no id" || bad "claim guard: no id" "$out"
out=$(ngc "bash -c 'bd update om-zzz --append-notes x'")
say "$out" | grep -q '"decision": "block"' && ok "claim guard: checks inside bash -c" || bad "claim guard: bash -c" "$out"
out2=$(ng_payload terminal 'bd update om-zzz --append-notes x' | HERMES_HARNESS_RUN=1 "$NG" 2>/dev/null)
[ -z "$out2" ] && ok "claim guard: off without HERMES_HARNESS_CLAIMS" || bad "claim guard: unset" "$out2"
out=$(ngc 'bd update om-225 --append-notes "ran bd update om-9 --notes x earlier"')
[ -z "$out" ] && ok "claim guard: an appended note that mentions --notes is not a command" || bad "claim guard: note text" "$out"
out=$(ngc 'bd update om-225 --notes x')
say "$out" | grep -q 'replaces the whole notes field' && ok "claim guard: --notes is still blocked on a claimed bead" || bad "claim guard: --notes" "$out"
# bd update flags that take a value: the value is never a bead id (hermes-harness-hzg)
for flags in '--design-file d.md' '--session s1' '--await-id 123' '--set-metadata k=v' \
  '--unset-metadata k' '--database db1' '-C /w' '--directory /w' '--dolt-auto-commit off' \
  '--mem-profile m.out'; do
  out=$(ngc "bd update om-225 $flags --append-notes x")
  [ -z "$out" ] && ok "claim guard: the value of $flags is not a bead id" || bad "claim guard: $flags" "$out"
done
out=$(ngc 'bd update om-225 --design-file=d.md --append-notes x')
[ -z "$out" ] && ok "claim guard: --flag=value form" || bad "claim guard: =value" "$out"
# The guard's value flags are exactly what `bd update --help` lists as taking one, when bd is real
if bd update --help >/dev/null 2>&1 && bd update --help 2>&1 | grep -q -- '--append-notes string'; then
  missing=$(bd update --help 2>&1 | sed -nE 's/^ +(-[a-zA-Z], )?(--[a-z-]+) (string|strings|stringArray|int) .*/\1\2/p' \
    | tr -d ',' | tr ' ' '\n' | grep . | while read -r f; do
      python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import bd_notes_guard as g
sys.exit(0 if sys.argv[2] in g._VALUE_FLAGS else 1)' "$ROOT/lib/hooks" "$f" || echo "$f"; done)
  [ -z "$missing" ] && ok "claim guard: every value flag of bd update --help is known" || bad "claim guard: value flags" "$missing"
fi
grep -q 'never retype' "$ROOT/AGENTS.md" && ok "AGENTS.md: copy bead ids, never retype them" || bad "AGENTS.md: id rule" "missing"
