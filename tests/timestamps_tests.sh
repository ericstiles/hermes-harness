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

# stall warning (8s7.3): short real wait; the producer pauses 2.5s with HERMES_STALL_WARN=1s.
# HERMES_TS_MIN_GAP=60 keeps the (+Ns) gap line out of the comparison.
( printf 'first\n'; sleep 2.5; printf 'second\n' ) | tee "$tmp/ts11.raw" \
  | HERMES_STALL_WARN=1s HERMES_TS_MIN_GAP=60 tsf --log "$tmp/ts11.log" > "$tmp/ts11.out" 2>"$tmp/ts11.err"
unstamp() { sed -E 's/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] //; s/\(last: [0-9]{2}:[0-9]{2}:[0-9]{2}\)/(last: T)/' "$1"; }
want=$(printf 'first\nno output for 1s (last: T)\nno output for 2s (last: T)\nsecond')
eq "timestamps: stall warning appears after HERMES_STALL_WARN with no output" "$(unstamp "$tmp/ts11.out")" "$want"
eq "timestamps: stall warning is in the ts log too" "$(unstamp "$tmp/ts11.log")" "$want"
grep -q 'no output' "$tmp/ts11.raw" && bad "timestamps: stall warning is not written to the raw log" "$(cat "$tmp/ts11.raw")" \
  || ok "timestamps: stall warning is not written to the raw log"
( printf 'a\n'; sleep 1.3; printf 'b\n' ) | HERMES_STALL_WARN=0 tsf > "$tmp/ts12.out" 2>&1
grep -q 'no output' "$tmp/ts12.out" && bad "timestamps: HERMES_STALL_WARN=0 disables the stall warning" "$(cat "$tmp/ts12.out")" \
  || ok "timestamps: HERMES_STALL_WARN=0 disables the stall warning"
# duration parsing like RUN_TIMEOUT (bare = seconds); a bad value warns and keeps the 10m default
out=$(cd "$ROOT/lib" && python3 -c '
import tsfilter as t
env = lambda v: t.stall_from_env({"HERMES_STALL_WARN": v} if v is not None else {})
print(env(None), env("90m"), env("30s"), env("2h"), env("45"), env("0"), env("soon"), t.fmt_stall(600), t.fmt_stall(90), t.fmt_stall(7200))
' 2>"$tmp/ts13.err")
eq "timestamps: HERMES_STALL_WARN parses Ns/Nm/Nh, default 10m" "$out" "600.0 5400.0 30.0 7200.0 45.0 0.0 600.0 10m 1m30s 2h"
grep -q "HERMES_STALL_WARN='soon'" "$tmp/ts13.err" && ok "timestamps: a bad HERMES_STALL_WARN warns once" \
  || bad "timestamps: a bad HERMES_STALL_WARN warns once" "$(cat "$tmp/ts13.err")"

# bead id in the stamp (mr4): [HH:MM:SS,<id>] from the claim line on; before it, just the time
printf 'a\n  ┊ 💻 $ bd update om-abc.1 --claim\nb\n' | HH_TS_FAKE_CLOCK="100 101 140" tsf --log "$tmp/ts14.log" > "$tmp/ts14.out"
want=$(printf '[00:01:40] a\n[00:01:41,om-abc.1]   ┊ 💻 $ bd update om-abc.1 --claim\n[00:02:20,om-abc.1] (+39s)\n[00:02:20,om-abc.1] b')
eq "timestamps: after a claim every line (and gap line) carries the bead id" "$(cat "$tmp/ts14.out")" "$want"
eq "timestamps: the bead id is in the ts log too" "$(cat "$tmp/ts14.log")" "$want"
printf 'a\n' | HH_TS_FAKE_CLOCK=100 tsf --id x-9 > "$tmp/ts15.out"
eq "timestamps: --id stamps the id from the first line (a resumed session)" "$(cat "$tmp/ts15.out")" "[00:01:40,x-9] a"
printf 'run bd update <id> --claim\nb\n' | HH_TS_FAKE_CLOCK="100 101" tsf > "$tmp/ts16.out"
eq "timestamps: a placeholder like <id> in prose is not an id" "$(cat "$tmp/ts16.out")" "$(printf '[00:01:40] run bd update <id> --claim\n[00:01:41] b')"
# The run's bead is its FIRST claim, as everywhere in hermes-run (RUN_TIME issue=, BEADS: worked, the
# wrap-up prompt): a review-fix run's later `bd update B --claim` marks a side bead, it does not
# switch the run to B (bead 97j). A resumed session's --id stays too.
printf 'bd update p-1 --claim\nbd update p-2 --claim\nc\n' | HH_TS_FAKE_CLOCK="100 101 101" tsf > "$tmp/ts17.out"
eq "timestamps: a later claim (a review-fix's side bead) does not replace the run's bead" \
  "$(cut -d' ' -f1 "$tmp/ts17.out" | tr '\n' ' ')" "[00:01:40,p-1] [00:01:41,p-1] [00:01:41,p-1] "
printf 'bd update p-2 --claim\n' | HH_TS_FAKE_CLOCK=100 tsf --id p-0 > "$tmp/ts17b.out"
eq "timestamps: a resumed session's --id is kept over a claim in it" "$(cut -d' ' -f1 "$tmp/ts17b.out")" "[00:01:40,p-0]"
# tsfilter.py and hermes-run's claimed_issue (hh_claimed_issue, lib/runtime.sh) read the same id
. "$ROOT/lib/runtime.sh"
agree=0; cases=0
while IFS='|' read -r line want; do
  cases=$((cases + 1))
  printf '%s\n' "$line" > "$tmp/claim.log"
  py=$(printf '%s\n' "$line" | HH_TS_FAKE_CLOCK=100 tsf | sed -nE 's/^\[[0-9:]{8},([^]]+)\].*/\1/p')
  sh=$(hh_claimed_issue "$tmp/claim.log")
  if [ "$py" = "$want" ] && [ "$sh" = "$want" ]; then agree=$((agree + 1))
  else bad "timestamps: claim id for '$line'" "tsfilter='$py' claimed_issue='$sh' want='$want'"; fi
done <<'CASES'
bd update a-1 --claim|a-1
  ┊ 💻 $ bd update om-abc.1 --claim --json|om-abc.1
xbd update b-2 --claim|
bd update c-3 --claimed|
run bd update <id> --claim|
bd update d-4 --claim; bd update e-5 --claim|d-4
bd update f-6 --claim-it|f-6
CASES
eq "timestamps: tsfilter.py and claimed_issue agree on the claimed id ($cases cases)" "$agree" "$cases"
( printf 'bd update s-1 --claim\n'; sleep 1.5; printf 'b\n' ) | HERMES_STALL_WARN=1s HERMES_TS_MIN_GAP=60 tsf > "$tmp/ts18.out"
grep -qE '^\[[0-9:]{8},s-1\] no output for 1s' "$tmp/ts18.out" && ok "timestamps: the stall warning carries the bead id" \
  || bad "timestamps: stall warning id" "$(cat "$tmp/ts18.out")"
out=$(bash -c ". '$ROOT/lib/runtime.sh'; hh_stamp_line 'R=1' om-2; hh_stamp_line 'R=2'; hh_stamp_line 'R=3' ''")
say "$out" | sed -E 's/[0-9]{2}:[0-9]{2}:[0-9]{2}/T/' | tr '\n' '|' | grep -qx '\[T,om-2\] R=1|\[T\] R=2|\[T\] R=3|' \
  && ok "timestamps: hh_stamp_line takes an optional bead id" || bad "timestamps: hh_stamp_line id" "$out"
