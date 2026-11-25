#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq/say, runit, $tmp $W $FX $BIN
# $STUB_LOG $STUB_COUNT; stub hermes prints STUB_FIXTURE). Bead 3q0: the model server ran out of memory
# (MLX "insufficient memory ... during prefill"). A relaunch would hit the same OOM, so it is its own
# class, MODEL_OOM: hermes-run stops with the fixes, hermes-supervise asks the human.
OOM="$FX/model_oom.log"
eq "classify model_oom" "$(hermes_classify "$OOM")" MODEL_OOM
eq "model_oom: other API failures stay MODEL_API_ERROR" "$(hermes_classify "$FX/model_api_error.log")" MODEL_API_ERROR
eq "model_oom: 'insufficient memory' in a run that did work is not MODEL_OOM" "$(hermes_classify "$FX/trap_oom_in_prose.log")" OK_DONE

# hermes-run: stops with the remediation, the log ends RUN_RESULT=MODEL_OOM
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
out=$(STUB_FIXTURE="$OOM" runit "$BIN/hermes-run" 3 2>&1); rc=$?
[ $rc -eq 1 ] && say "$out" | grep -q '^FINAL_RESULT=MODEL_OOM$' && [ "$(grep -c '^hermes chat' "$STUB_LOG")" = 1 ] \
  && ok "model_oom: hermes-run stops the loop after one run" || bad "model_oom: hermes-run stops" "$rc $(grep -c '^hermes chat' "$STUB_LOG") $(echo "$out" | tail -4)"
grep -q '^RUN_RESULT=MODEL_OOM$' "$W"/logs/run-*.log && ok "model_oom: the run log records RUN_RESULT=MODEL_OOM" || bad "model_oom: RUN_RESULT" "$(tail -2 "$W"/logs/run-*.log)"
for fix in 'free memory' 'restart the model server' 'context' 'q8'; do
  say "$out" | grep -i 'out of memory' | grep -qi -- "$fix" && ok "model_oom: hermes-run names the fix: $fix" || bad "model_oom: fix $fix" "$(say "$out" | grep -i 'memory')"
done

# hermes-supervise: a human, never AUTO_RELAUNCH
out=$(HERMES_LOG_DIR="$W/logs" runit "$BIN/hermes-supervise" "$(ls "$W"/logs/run-*.log | head -n 1)")
say "$out" | grep -q '^CLASS=MODEL_OOM$' && say "$out" | grep -q '^ACTION=ASK_HUMAN$' && ! say "$out" | grep -q '^NEXT=' \
  && say "$out" | grep -q '^WHY=.*out of memory' \
  && ok "model_oom: supervise asks the human, no relaunch" || bad "model_oom: supervise" "$out"

# documented where the classes are listed
grep -q 'MODEL_OOM' "$ROOT/lib/classify.sh" && grep -q 'MODEL_OOM' "$ROOT/README.md" && grep -q 'MODEL_OOM' "$ROOT/bin/hermes-supervise" \
  && grep -q 'MODEL_OOM' "$ROOT/bin/hermes-launch" \
  && ok "model_oom: documented in classify.sh, README, supervise and launch help" || bad "model_oom: docs" "missing"
