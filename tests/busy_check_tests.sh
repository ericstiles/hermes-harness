#!/usr/bin/env bash
# Sourced by tests/run_tests.sh after the launch tests (uses ok/bad/eq/say, $tmp $W $BIN $ROOT; ps is
# stubbed on PATH). Bead 9kc: the "a run is active" check (lib/busy.sh hh_active_procs) is machine-wide
# on purpose (one local model), but processes of a test-suite run must not count: their command lines
# carry the suite's temp dir name (hermes-harness-test.*), so a gate run never blocks a real launch.
BC="$tmp/busy-check"; mkdir -p "$BC/test" "$BC/real" "$BC/both"
T="/var/folders/xx/T/hermes-harness-test.Ab12Cd"
printf '#!/bin/sh\ncat <<EOF\n101 00:05 bash %s/harness/bin/hermes-run 1\n102 00:05 python3 -u /h/lib/watchdog.py --limit 90m --log %s/target/logs/run-1.log -- hermes chat -q x\n103 00:05 /bin/sh %s/bin/hermes chat --pass-session-id -q x\nEOF\n' "$T" "$T" "$T" > "$BC/test/ps"
printf '#!/bin/sh\necho "201 01:00 bash /Users/me/hermes-harness/bin/hermes-run 10"\n' > "$BC/real/ps"
{ printf '#!/bin/sh\n'; sed -n '2,$p' "$BC/test/ps"; printf 'echo "202 00:30 hermes chat -q hi"\n'; } > "$BC/both/ps"
chmod +x "$BC"/*/ps

# the suite itself runs under a marked temp dir, through a marked harness path
case "$tmp" in */hermes-harness-test.*) ok "busy check: the suite's temp dir carries the test marker" ;; *) bad "busy check: temp dir marker" "$tmp" ;; esac
case "$BIN" in "$tmp"/*) ok "busy check: the suite runs the harness through its marked temp dir" ;; *) bad "busy check: BIN marker" "$BIN" ;; esac

# launch
out=$(cd "$W" && PATH="$BC/test:$PATH" GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 0 ] && ! say "$out" | grep -q 'already running' \
  && ok "busy check: launch is not blocked by a test suite's hermes-run / hermes chat" || bad "busy check: launch vs test run" "$rc $out"
out=$(cd "$W" && PATH="$BC/real:$PATH" GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && say "$out" | grep -q 'already running' \
  && ok "busy check: launch is still blocked by a real hermes-run" || bad "busy check: launch vs real run" "$rc $out"
out=$(cd "$W" && PATH="$BC/both:$PATH" GH_TOKEN=x "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && say "$out" | grep -q 'already running' \
  && ok "busy check: a real hermes chat next to a test run still blocks launch" || bad "busy check: launch vs both" "$rc $out"

# status
out=$(cd "$W" && PATH="$BC/test:$PATH" "$BIN/hermes-status" 2>&1)
say "$out" | grep -q '^no hermes-run / hermes chat process$' && ! say "$out" | grep -q '^RUNNING:' \
  && ok "busy check: status shows no active run for a test suite's processes" || bad "busy check: status vs test run" "$out"
out=$(cd "$W" && PATH="$BC/both:$PATH" "$BIN/hermes-status" 2>&1)
say "$out" | grep -q '^RUNNING:' && say "$out" | grep -q '^202 00:30 hermes chat' && ! say "$out" | grep -qE '^10[123] ' \
  && ok "busy check: status lists only the real process" || bad "busy check: status vs both" "$out"

# supervise
mkdir -p "$BC/logs"; cp "$FX/blocked.log" "$BC/logs/run-1.log"
out=$(cd "$W" && PATH="$BC/test:$PATH" HERMES_LOG_DIR="$BC/logs" "$BIN/hermes-supervise" 2>&1)
say "$out" | grep -q '^CLASS=BLOCKED$' && ok "busy check: supervise classifies the log, not RUNNING, during a test run" || bad "busy check: supervise vs test run" "$out"
out=$(cd "$W" && PATH="$BC/real:$PATH" HERMES_LOG_DIR="$BC/logs" "$BIN/hermes-supervise" 2>&1)
say "$out" | grep -q '^CLASS=RUNNING$' && ok "busy check: supervise still reports RUNNING for a real run" || bad "busy check: supervise vs real run" "$out"

# real ps: a live process started through the marked temp dir is not counted
mkdir -p "$BC/live"; printf '#!/bin/sh\nsleep 5\n' > "$BC/live/hermes-run"; chmod +x "$BC/live/hermes-run"
"$BC/live/hermes-run" & live=$!
sleep 0.3
# the helper must exist and run (a missing function would also print nothing), and the process must be live
real_ps=$(PATH=/bin:/usr/bin bash -c ". '$ROOT/lib/common.sh' && . '$ROOT/lib/busy.sh' && hh_active_procs pid,command"); helper_rc=$?
seen=$(PATH=/bin:/usr/bin ps -axo pid,command | grep -cE "^ *$live .*hermes-run")
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
[ "$helper_rc" -eq 0 ] && [ "$seen" -ge 1 ] && ! say "$real_ps" | grep -qE "^ *$live " && ok "busy check: a live test-suite process is not counted by the real ps" || bad "busy check: live process" "$real_ps"
