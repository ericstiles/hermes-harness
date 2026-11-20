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
  [ $rc -eq 0 ] && echo "$out" | grep -q '"decision": "block"' && echo "$out" | grep -q -- '--append-notes' \
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
[ $rc -eq 0 ] && echo "$out" | grep -q 'bd_notes_guard' && ok "notes guard: malformed payload fails open with a log line" \
  || bad "notes guard: malformed payload" "rc=$rc $out"
out=$(printf '{"tool_name":"terminal","tool_input":null}' | HERMES_HARNESS_RUN=1 "$NG" 2>/dev/null); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "notes guard: missing tool_input is allowed" || bad "notes guard: no tool_input" "rc=$rc $out"
