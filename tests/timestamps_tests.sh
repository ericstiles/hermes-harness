#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad/eq, $tmp, $ROOT).
# lib/tsfilter.py: timestamps Hermes output for the terminal and the timed log.
# A fake clock (HH_TS_FAKE_CLOCK: one epoch per input line) keeps these tests sleep-free.
TSF="$ROOT/lib/tsfilter.py"
tsf() { TZ=UTC python3 -u "$TSF" "$@"; } # -u exactly as bin/hermes-run calls it

# prefix on every line, stdout and log alike; CR from a pty stripped
printf 'hello\r\nworld\n' | HH_TS_FAKE_CLOCK="100 101" tsf --log "$tmp/ts1.log" > "$tmp/ts1.out" 2>"$tmp/ts1.err"; rc=$?
eq "timestamps: filter exits 0 at end of input" "$rc" 0
eq "timestamps: terminal and ts log lines start with [HH:MM:SS]" \
   "$(cat "$tmp/ts1.out")|$(cat "$tmp/ts1.log")" \
   "$(printf '[00:01:40] hello\n[00:01:41] world')|$(printf '[00:01:40] hello\n[00:01:41] world')"
grep -q $'\r' "$tmp/ts1.out" "$tmp/ts1.log" && bad "timestamps: CR from a pty is stripped" "$(od -c "$tmp/ts1.out" | head -3)" \
  || ok "timestamps: CR from a pty is stripped"

# a gap >= the minimum shows as (+N) before the next line; short gaps add nothing
printf '  ┊ 💻 preparing terminal…\nresult\n╭─ ⚕ Hermes ─╮\nquick\n' \
  | HH_TS_FAKE_CLOCK="100 138 263 264" tsf --log "$tmp/ts2.log" > "$tmp/ts2.out"
want=$(printf '[00:01:40]   ┊ 💻 preparing terminal…\n[00:02:18] (+38s)\n[00:02:18] result\n[00:04:23] (+2m05s)\n[00:04:23] ╭─ ⚕ Hermes ─╮\n[00:04:24] quick')
eq "timestamps: per-response elapsed uses the gap between lines" "$(cat "$tmp/ts2.out")" "$want"
eq "timestamps: elapsed lines are in the ts log too" "$(cat "$tmp/ts2.log")" "$want"
printf 'a\nb\n' | HH_TS_FAKE_CLOCK="0 3720" tsf --log "$tmp/ts3.log" | grep -q '^\[01:02:00\] (+1h02m)$' \
  && ok "timestamps: hour-long gaps read as +1h02m" || bad "timestamps: hour gap" "$(cat "$tmp/ts3.log")"
printf 'a\nb\n' | HERMES_TS_MIN_GAP=60 HH_TS_FAKE_CLOCK="0 30" tsf --log "$tmp/ts4.log" | grep -q '(+' \
  && bad "timestamps: HERMES_TS_MIN_GAP hides shorter gaps" "$(cat "$tmp/ts4.log")" || ok "timestamps: HERMES_TS_MIN_GAP hides shorter gaps"

# live: a line is shown while the producer is still running
rm -f "$tmp/ts.fifo"; mkfifo "$tmp/ts.fifo"
( printf 'first\n'; read -r _ < "$tmp/ts.fifo"; printf 'second\n' ) | tsf --log "$tmp/ts5.log" > "$tmp/ts5.out" &
tsp=$!; seen=no
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -q 'first' "$tmp/ts5.out" 2>/dev/null && { seen=yes; break; }; sleep 0.25
done
echo go > "$tmp/ts.fifo"; wait "$tsp"
eq "timestamps: lines are flushed immediately, not buffered until exit" "$seen" yes

# crash safety: the filter sits behind `tee raw.log`; dying early would cut the RAW log (EPIPE)
printf 'a\nb\nc\n' | HH_TS_FAKE_CLOCK="100 oops 101" tsf --log "$tmp/ts6.log" > "$tmp/ts6.out" 2>/dev/null; rc=$?
eq "timestamps: filter error falls back to raw passthrough" "$rc|$(cat "$tmp/ts6.out")" "0|$(printf '[00:01:40] a\nb\n[00:01:41] c')"
printf 'a\nb\n' | HH_TS_FAKE_CLOCK="100 101" tsf --log "$tmp/no/such/dir/x.log" > "$tmp/ts7.out" 2>"$tmp/ts7.err"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$tmp/ts7.out" | tr -d ' ')" = 2 ] && grep -q 'tsfilter' "$tmp/ts7.err" \
  && ok "timestamps: unwritable ts log still passes output through, with one warning" || bad "timestamps: unwritable log" "$rc $(cat "$tmp/ts7.out" "$tmp/ts7.err")"
printf 'ok \377 bad byte\n' | HH_TS_FAKE_CLOCK=100 tsf --log "$tmp/ts8.log" > "$tmp/ts8.out"; rc=$?
[ $rc -eq 0 ] && grep -q '^\[00:01:40\] ok .* bad byte$' "$tmp/ts8.out" && ok "timestamps: invalid UTF-8 does not stop the filter" || bad "timestamps: bad utf-8" "$rc $(cat "$tmp/ts8.out")"
# a closed terminal (stdout EPIPE) must not stop the ts log or the input drain
seq 1 5000 | HH_TS_FAKE_CLOCK=1 tsf --log "$tmp/ts9.log" 2>/dev/null | head -n 1 >/dev/null
eq "timestamps: a closed stdout keeps the ts log complete" "$(wc -l < "$tmp/ts9.log" | tr -d ' ')" 5000
# same, without -u (someone changing the call): still exit 0, not Python's 120 at shutdown
seq 1 5000 | HH_TS_FAKE_CLOCK=1 TZ=UTC python3 "$TSF" --log "$tmp/ts10.log" 2>/dev/null | head -n 1 >/dev/null
eq "timestamps: a closed stdout still exits 0 without -u" "${PIPESTATUS[1]}" 0
# hms/elapsed helpers: a backwards clock step never prints a negative elapsed
out=$(bash -c ". '$ROOT/lib/runtime.sh'; hh_elapsed -5; hh_elapsed 59; hh_elapsed 2472; hh_elapsed 7500; TZ=UTC hh_hms 0" 2>&1)
eq "timestamps: elapsed formats and clamps negatives" "$(echo $out)" "0s 59s 41m12s 2h05m 00:00:00"
