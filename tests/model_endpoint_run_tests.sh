#!/usr/bin/env bash
# Sourced by tests/run_tests.sh inside the hermes-run block (uses ok/bad/eq, runit, $W $BIN $STUB_LOG
# $STUB_COUNT). Bead b80: every run log records the run's effective provider (RUN_PROVIDER:), so
# hermes-supervise can check that provider's endpoint after a MODEL_API_ERROR.
mr_log() { ls "$W"/logs/run-*.log 2>/dev/null | head -n 1; }

rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
runit "$BIN/hermes-run" 1 >/dev/null 2>&1
eq "run provider: the run log records the configured provider (stub config: 'stub')" \
  "$(grep -c '^RUN_PROVIDER: stub$' "$(mr_log)")" 1
rm -rf "$W/logs"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
(export HERMES_ARGS="--provider mtplx"; runit "$BIN/hermes-run" 1 >/dev/null 2>&1)
eq "run provider: a HERMES_ARGS --provider override is what the run log records" \
  "$(grep '^RUN_PROVIDER: ' "$(mr_log)")" "RUN_PROVIDER: mtplx"
grep -q '^hermes chat .*--provider mtplx' "$STUB_LOG" \
  && ok "run provider: the override still reaches hermes chat" || bad "run provider: override passed" "$(grep '^hermes chat' "$STUB_LOG")"
