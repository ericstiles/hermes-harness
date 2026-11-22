#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT). The stub docker answers: STUB_CONTAINERS (ids from `ps`),
# STUB_RUNNING (true|false), STUB_WS=0 (no /workspace/<name>), STUB_DIRTY (diff output),
# STUB_RESET_RC (exit of the reset).
# hermes-run --clean resets /workspace/<name> in the sandbox to origin/main, saving uncommitted work first.
fresh() { rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; }
execs() { grep '^docker exec' "$STUB_LOG"; }
chats() { grep -c '^hermes chat' "$STUB_LOG"; }

fresh; STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS=c1 runit "$BIN/hermes-run" 1 >/dev/null 2>&1
[ -z "$(execs)" ] && ok "clean: without --clean the sandbox is not touched" || bad "clean: untouched" "$(execs)"

# dirty workspace: saved as a patch BEFORE the reset, then the run goes ahead
fresh
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS=c1 STUB_DIRTY='diff --git a/t.py b/t.py' runit "$BIN/hermes-run" --clean 1 2>&1); rc=$?
p=$(ls "$W"/logs/sandbox-dirty-*.patch 2>/dev/null)
[ -n "$p" ] && grep -q '^diff --git a/t.py' "$p" && say "$out" | grep -q "saved uncommitted work" \
  && ok "clean: uncommitted sandbox work is saved to logs/sandbox-dirty-*.patch" || bad "clean: patch" "$(ls "$W/logs") $out"
grep -q '^docker ps -a --filter ancestor=stub' "$STUB_LOG" && ok "clean: the container is found by the configured sandbox image" || bad "clean: image filter" "$(grep '^docker ps' "$STUB_LOG")"
first=$(execs | grep -n 'git diff HEAD' | cut -d: -f1); reset=$(execs | grep -n 'origin/main' | cut -d: -f1)
[ -n "$first" ] && [ -n "$reset" ] && [ "$first" -lt "$reset" ] && execs | grep -q '/workspace/widgets' \
  && execs | grep 'origin/main' | grep -q 'clean -fd' \
  && ok "clean: the patch is taken before /workspace/<name> is reset to origin/main" || bad "clean: order" "$(execs)"
[ $rc -eq 0 ] && [ "$(chats)" = 1 ] && ok "clean: the run starts after a successful clean" || bad "clean: run after" "$rc $(chats)"

# clean workspace: no empty patch file left behind
fresh; STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS=c1 runit "$BIN/hermes-run" 1 --clean >/dev/null 2>&1
[ -z "$(ls "$W"/logs/sandbox-dirty-*.patch 2>/dev/null)" ] && execs | grep -q 'origin/main' \
  && ok "clean: a clean workspace leaves no patch file (flag after N works too)" || bad "clean: empty patch" "$(ls "$W/logs")"

# a stopped persistent container is started for the clean
fresh; STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS=c1 STUB_RUNNING=false runit "$BIN/hermes-run" --clean 1 >/dev/null 2>&1
grep -q '^docker start c1' "$STUB_LOG" && ok "clean: a stopped sandbox container is started first" || bad "clean: start" "$(cat "$STUB_LOG")"

# no workspace yet: nothing to reset, not an error
fresh
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS=c1 STUB_WS=0 runit "$BIN/hermes-run" --clean 1 2>&1); rc=$?
[ $rc -eq 0 ] && ! execs | grep -q 'origin/main' && say "$out" | grep -q 'clone it fresh' \
  && ok "clean: a missing workspace is reported and the run continues" || bad "clean: no workspace" "$rc $out"

# refusals: never guess which container, never run on a failed reset
for case_ in "none::0" "two:c1 c2:2"; do
  label=${case_%%:*}; rest=${case_#*:}; ids=${rest%:*}
  fresh; out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS="$ids" runit "$BIN/hermes-run" --clean 1 2>&1); rc=$?
  [ $rc -eq 2 ] && [ "$(chats)" = 0 ] && say "$out" | grep -q 'expected one sandbox container' && [ -z "$(execs)" ] \
    && ok "clean: $label matching containers -> exit 2, nothing reset, no run" || bad "clean: $label containers" "$rc $out"
done
fresh
out=$(STUB_FIXTURE="$FX/ok_done.log" STUB_CONTAINERS=c1 STUB_DIRTY='diff --git a/x b/x' STUB_RESET_RC=1 runit "$BIN/hermes-run" --clean 1 2>&1); rc=$?
[ $rc -eq 2 ] && [ "$(chats)" = 0 ] && [ -n "$(ls "$W"/logs/sandbox-dirty-*.patch 2>/dev/null)" ] \
  && ok "clean: a failed reset stops before any run, the patch is kept" || bad "clean: reset failure" "$rc $out"

# argument checks
fresh; out=$(runit "$BIN/hermes-run" --clena 2>&1); rc=$?
[ $rc -eq 2 ] && [ "$(chats)" = 0 ] && ok "hermes-run rejects an unknown argument" || bad "hermes-run bad arg" "$rc $out"

# hermes-launch passes --clean through
out=$(cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --clean --dry-run 2>&1)
say "$out" | grep -q "hermes-run' --clean 10" && ok "launch --clean passes the flag to hermes-run" || bad "launch --clean" "$out"
out=$(cd "$W" && GH_TOKEN=x "$BIN/hermes-launch" --help 2>&1)
say "$out" | grep -q -- '--clean' && ok "launch --help documents --clean" || bad "launch help --clean" "$out"
rm -rf "$W/logs"
