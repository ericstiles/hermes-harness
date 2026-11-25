#!/usr/bin/env bash
# lib/busy.sh — sourced (after lib/common.sh) by hermes-launch, hermes-status and hermes-supervise:
# which processes mean "a Hermes run is active". One local model, so one run at a time across repos:
# the check is machine-wide on purpose. Not sourced by hermes-run, so it can change while loops run.
# bash 3.2 compatible.

# Processes of a tests/run_tests.sh run carry its temp dir name on their command line (hermes-run is
# started through a symlink in it; watchdog/tsfilter get --log paths in it; the stub hermes lives in
# it). They are not real runs and must not block a launch (bead 9kc).
HH_TEST_MARK='hermes-harness-test\.'

hh_active_procs() { # [ps -o columns, default command] -> one line per active run process, or nothing
  ps -axo "${1:-command}" 2>/dev/null | grep -E "$HH_ACTIVE_PATTERN" | grep -v grep | grep -vE "$HH_TEST_MARK" || true
}
