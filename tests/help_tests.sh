#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad, $tmp $BIN $ROOT).
# Every runnable script answers -h and --help with its purpose and arguments: exit 0, a
# "Usage:" line naming the script, at least one documented option or argument, and no side
# effects. Run outside any git repo with stdin closed, so a script that ignored the flag and
# went on to do its job would fail (no repo), hang (stdin) or print no usage.
# The lib/*.sh files are sourced libraries, not commands, and are not listed here.
HELP_DIR="$tmp/help-cwd"; mkdir -p "$HELP_DIR"
HELP_SCRIPTS=(
  "$BIN/hermes-launch" "$BIN/hermes-review" "$BIN/hermes-run" "$BIN/hermes-setup"
  "$BIN/hermes-status" "$BIN/hermes-supervise"
  "$ROOT/lib/watchdog.py" "$ROOT/lib/tsfilter.py" "$ROOT/lib/context_usage.py" "$ROOT/lib/hooks/bd_notes_guard.py"
)
for script in "${HELP_SCRIPTS[@]}"; do
  name=$(basename "$script")
  for flag in -h --help; do
    before=$(ls -A "$HELP_DIR")
    # .py files run via python3, as hermes-run and Hermes call them.
    case $script in *.py) runner=(python3 "$script") ;; *) runner=("$script") ;; esac
    out=$(cd "$HELP_DIR" && "${runner[@]}" "$flag" 2>&1 </dev/null); rc=$?
    if [ "$rc" -eq 0 ] && say "$out" | grep -qi "usage:.*${name%.*}" \
       && say "$out" | grep -qE -- '(-h, --help|--help)' && [ "$(ls -A "$HELP_DIR")" = "$before" ]; then
      ok "help: $name $flag"
    else
      bad "help: $name $flag" "rc=$rc $(echo "$out" | head -n 3)"
    fi
  done
done
# The flag is honoured anywhere on the command line, not only first.
out=$(cd "$HELP_DIR" && "$BIN/hermes-review" --dry-run --help 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && say "$out" | grep -qi 'usage:' && ok "help: hermes-review --dry-run --help" \
  || bad "help: hermes-review flag not first" "rc=$rc $(echo "$out" | head -n 2)"
out=$(cd "$HELP_DIR" && "$BIN/hermes-run" --clean --help 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && say "$out" | grep -qi 'usage:' && ok "help: hermes-run --clean --help" \
  || bad "help: hermes-run flag not first" "rc=$rc $(echo "$out" | head -n 2)"
