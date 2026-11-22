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
