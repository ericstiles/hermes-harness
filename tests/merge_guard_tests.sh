#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad/eq, $tmp, $ROOT).
# .claude/hooks/gh_merge_guard.py: Claude Code PreToolUse hook; only `gh pr merge <N> --rebase` may run.
MG="$ROOT/.claude/hooks/gh_merge_guard.py"
mg() { # <tool> <command> -> exit code of the hook
  python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$1" "$2" \
    | python3 "$MG" >/dev/null 2>"$tmp/mg.err"
}
for cmd in "gh pr merge 4 --rebase" "gh pr merge --rebase 4" "cd /x && gh pr merge 12 --rebase" "git status" "gh pr view 4" \
           "git commit -m 'allow only gh pr merge <N> --rebase'" "bd note x 'the old rule let gh pr merge -s 4 through'" \
           "echo 'gh pr merge -s 0'" "gh pr view 5 --json state" \
           "gh pr view 5 --json state,mergeable -q '.state|@tsv'" "gh pr list --json mergeable -q '.[]|.mergeable'" \
           $'git commit -m "first line\ngh pr merge -s 4 is now blocked"' $'git status\ngh pr view 4' \
           "python3 -c 'import sys; print(\"gh pr merge -s 4\")'" "gh pr view \$N --json mergeable" \
           "gh pr create --body-file \"\$F\" --title 'x'"; do
  mg Bash "$cmd"; eq "merge guard: allows '$cmd'" "$?" 0
done
for cmd in "gh pr merge -s 4" "gh pr merge 4 -ds" "gh pr merge 4 -s" "gh pr merge 4 --rebase --admin" \
           "gh pr merge 4 --rebase -d" "gh pr merge 4 --squash" "gh pr merge 4" "gh pr merge --auto --rebase 4" \
           "echo \$(gh pr merge 4 -m)" "echo \`gh pr merge 4 -m\`" "git status; gh  pr  merge -m 4" \
           "GH_X=1 gh pr merge 4 --rebase" "env gh pr merge -s 4" "bash -c 'gh pr merge -s 4'" \
           "eval gh pr merge -s 4" "/opt/homebrew/bin/gh pr merge -s 4" "(gh pr merge -s 4)" "gh -R o/r pr merge -s 4" \
           "gh pr -R o/r merge 5 -s" "gh pr --repo=o/r merge 5 --squash" "gh pr -R o/r merge 5 --rebase" \
           "gh api -X PUT repos/o/r/pulls/5/merge -f merge_method=squash" "gh api repos/o/r/pulls/5/merge -X PUT" \
           "g''h pr merge 5 -s" "g\\h pr merge 5 -s" "/usr/bin/g''h pr merge 5 --squash" \
           "gh pr me''rge 5 -s" "gh pr merg\\e 5 -s" "g\"\"h pr m\"\"erge 5 -s" \
           $'gh pr me\\\nrge 5 -s' $'g\\\nh pr merge 5 -s' $'gh pr "me\\\nrge" 5 -s' \
           "echo 'gh pr merge 5 -s' | sh" "printf '%s\\n' 'gh pr merge 5 --squash' | bash" \
           "echo 'gh pr merge 5 -s' | xargs -0 sh -c" ". <(echo 'gh pr merge 5 -s')" "source <(echo 'gh pr merge 5 -s')" \
           "env -S 'gh pr merge 5 -s'" "env -S'gh pr merge 5 -s'" "/usr/bin/env --split-string='gh pr merge 5 -s'" \
           "echo 'pr merge 5 -s' | xargs gh" "echo merge 5 -s | xargs gh pr" "printf '%s ' merge 5 -s | xargs gh pr" \
           "if true; then gh pr merge 5 -s; fi" "! gh pr merge 5 -s" "timeout 60 gh pr merge 5 -s" \
           "\\gh pr merge 5 -s" "'gh' pr merge 5 -s" "gh pr 'merge' 5 -s" "timeout 60 bash -c 'gh pr merge -s 4'" \
           "echo gh pr merge -s 0" "echo \$(date) gh pr merge -s 0" "gh pr merge 5 -s &" "gh pr merge 5 --rebase 'x" \
           $'git status\ngh pr merge 5 -s' "gh pr view 5 -q '.a|.b' && gh pr merge 5 -s" \
           "\$'gh' pr merge -s 4" "gh pr \$'merge' 4 -s" "x=merge; gh pr \$x 4 -s" "gh pr \"\$(echo merge)\" 4 -s" \
           "G=gh; \$G pr merge -s 4" "gh pr merge 4 --rebase#x"; do
  mg Bash "$cmd"; eq "merge guard: blocks '$cmd'" "$?" 2
done
mg Bash "gh pr merge -s 4"; grep -q "gh pr merge <N> --rebase" "$tmp/mg.err" \
  && ok "merge guard: block message names the allowed form" || bad "merge guard: block message" "$(cat "$tmp/mg.err")"
mg Read "gh pr merge -s 4"; eq "merge guard: ignores non-Bash tools" "$?" 0
echo 'not json' | python3 "$MG" >/dev/null 2>&1; eq "merge guard: unreadable input without a merge passes" "$?" 0
echo 'garbage gh pr merge -s 4' | python3 "$MG" >/dev/null 2>&1; eq "merge guard: unreadable input mentioning a merge is blocked" "$?" 2

# --- the hook COMMAND in .claude/settings.json finds the guard (bead lm3) ---
# Claude Code keeps $CLAUDE_PROJECT_DIR at the directory the session started in, even after /cd into
# this repo, so the command looks in the current repo first and falls back to $CLAUDE_PROJECT_DIR.
# A guard found nowhere must still block (fail closed).
HOOK_CMD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$ROOT/.claude/settings.json")
HK="$tmp/hook-cwd"; mkdir -p "$HK/elsewhere" "$HK/plain" "$HK/norepo"; git -C "$HK/norepo" init -q
hk() { # <cwd> <CLAUDE_PROJECT_DIR> <command> -> exit code of the settings.json hook command
  python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$3" \
    | (cd "$1" && CLAUDE_PROJECT_DIR="$2" sh -c "$HOOK_CMD") >/dev/null 2>"$tmp/hk.err"
}
hk "$ROOT" "$HK/elsewhere" "pwd"
eq "merge guard hook: runs when CLAUDE_PROJECT_DIR is another repo (session /cd'd here)" "$?" 0
hk "$ROOT" "$HK/elsewhere" "gh pr merge 5 --squash"
eq "merge guard hook: still blocks a squash merge when CLAUDE_PROJECT_DIR is another repo" "$?" 2
hk "$ROOT/tests" "$HK/elsewhere" "pwd"
eq "merge guard hook: found from a subdirectory of the repo" "$?" 0
hk "$HK/plain" "$ROOT" "pwd"
eq "merge guard hook: runs from CLAUDE_PROJECT_DIR when the cwd is not a git repo" "$?" 0
hk "$HK/plain" "$ROOT" "gh pr merge 5 --squash"
eq "merge guard hook: blocks through the CLAUDE_PROJECT_DIR fallback too" "$?" 2
hk "$HK/norepo" "$HK/elsewhere" "pwd"; rc=$?
[ "$rc" -ne 0 ] && ok "merge guard hook: fails closed when the guard is missing everywhere (exit $rc)" || bad "merge guard hook: fail closed" "$rc"
