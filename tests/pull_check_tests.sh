#!/usr/bin/env bash
# Sourced by tests/run_tests.sh after the launch tests (uses ok/bad/say, $tmp $ROOT; ps is stubbed on
# PATH to "no processes"). Bead hermes-harness-anq: hermes-pull-check says whether pulling the harness
# checkout is safe while hermes-run loops run from it. It never pulls.
# The harness under test is a throwaway clone of a local bare repo: no network.
PG() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main -c core.hooksPath=/dev/null \
       -c init.templateDir= "$@" 2>/dev/null; }
PB="$tmp/pc.git"; PSD="$tmp/pc-seed"; PH="$tmp/pc"
PG init -q --bare -b main "$PB"
PG clone -q "$PB" "$PSD"
cp -R "$ROOT/bin" "$ROOT/lib" "$PSD/"; echo readme > "$PSD/README.md"
PG -C "$PSD" add -A; PG -C "$PSD" commit -q -m "harness"; PG -C "$PSD" push -q origin HEAD:main
PG clone -q "$PB" "$PH"
pc() { # [env...] -- run the clone's hermes-pull-check; sets out, rc
  out=$(env "$@" "$PH/bin/hermes-pull-check" 2>&1 </dev/null); rc=$?
}
upstream() { # <file> : change a file in the seed and push it to origin/main
  echo "# change $RANDOM" >> "$PSD/$1"; PG -C "$PSD" add -A; PG -C "$PSD" commit -q -m "change $1"
  PG -C "$PSD" push -q origin HEAD:main
}
loops() { # <dir> <command line>... : a ps stub in <dir> that lists those hermes-run processes
  mkdir -p "$1"; local d=$1; shift
  { echo '#!/bin/sh'; local n=100 c; for c in "$@"; do n=$((n + 1)); printf "echo '%s %s'\n" "$n" "$c"; done; } > "$d/ps"
  chmod +x "$d/ps"
}
loops "$tmp/pc-busy" "bash $PH/bin/hermes-run 10 --clean"

pc PATH="$tmp/pc-busy:$PATH"
[ $rc -eq 0 ] && [ "$(say "$out" | head -n 1)" = PULL=UP_TO_DATE ] && ok "pull-check: up to date" \
  || bad "pull-check: up to date" "rc=$rc $out"

# --- behind, only files a loop does not load: SAFE even with a loop running ---
upstream README.md
head_before=$(PG -C "$PH" rev-parse HEAD)
pc PATH="$tmp/pc-busy:$PATH"
[ $rc -eq 0 ] && [ "$(say "$out" | head -n 1)" = PULL=SAFE ] && say "$out" | grep -q "git -C '$PH' pull --ff-only" \
  && ok "pull-check: behind with only unloaded files is SAFE while a loop runs" || bad "pull-check: unloaded SAFE" "rc=$rc $out"
[ "$(PG -C "$PH" rev-parse HEAD)" = "$head_before" ] && ok "pull-check: never pulls" \
  || bad "pull-check: pulled" "$(PG -C "$PH" log --oneline -2)"

# --- a sourced lib or a run .py changed, loop running: WAIT naming the file and the pid ---
upstream lib/runtime.sh; upstream lib/tsfilter.py
pc PATH="$tmp/pc-busy:$PATH"
[ $rc -eq 1 ] && [ "$(say "$out" | head -n 1)" = PULL=WAIT ] \
  && say "$out" | grep -q 'lib/runtime.sh (sourced by hermes-run)' && say "$out" | grep -q 'lib/tsfilter.py (run by hermes-run)' \
  && say "$out" | grep -q '101' && ! say "$out" | grep -q 'README.md (' \
  && ok "pull-check: a changed sourced lib and run .py with a loop running is WAIT (files and pid named)" \
  || bad "pull-check: WAIT" "rc=$rc $out"
out=$("$PH/bin/hermes-pull-check" --no-fetch 2>&1 </dev/null); rc=$?
[ $rc -eq 0 ] && [ "$(say "$out" | head -n 1)" = PULL=SAFE ] \
  && ok "pull-check: the same change with no loop running is SAFE" || bad "pull-check: no loop SAFE" "rc=$rc $out"

# --- which loops count: only a hermes-run that resolves into this checkout ---
mkdir -p "$tmp/pc-other/bin"; : > "$tmp/pc-other/bin/hermes-run"
loops "$tmp/pc-elsewhere" "bash $tmp/pc-other/bin/hermes-run 10" "hermes chat -q x"
pc PATH="$tmp/pc-elsewhere:$PATH"
[ $rc -eq 0 ] && [ "$(say "$out" | head -n 1)" = PULL=SAFE ] \
  && ok "pull-check: a loop from another checkout (and a bare hermes chat) does not block" || bad "pull-check: other checkout" "rc=$rc $out"
mkdir -p "$tmp/pc-linkbin"; ln -sf "$PH/bin/hermes-run" "$tmp/pc-linkbin/hermes-run"
loops "$tmp/pc-linked" "bash $tmp/pc-linkbin/hermes-run 10"
pc PATH="$tmp/pc-linked:$PATH"
[ $rc -eq 1 ] && [ "$(say "$out" | head -n 1)" = PULL=WAIT ] \
  && ok "pull-check: a loop started through a PATH symlink to this checkout counts" || bad "pull-check: symlink loop" "rc=$rc $out"

# --- cannot fast-forward: dirty, off main, diverged ---
echo dirty >> "$PH/README.md"
pc PATH="$tmp/pc-busy:$PATH"
[ $rc -eq 2 ] && [ "$(say "$out" | head -n 1)" = PULL=CANNOT ] && say "$out" | grep -q 'uncommitted' \
  && ok "pull-check: uncommitted changes are CANNOT" || bad "pull-check: dirty" "rc=$rc $out"
PG -C "$PH" checkout -q -- README.md
PG -C "$PH" switch -q -c side
pc PATH="$tmp/pc-busy:$PATH"
[ $rc -eq 2 ] && say "$out" | grep -q 'branch side' && ok "pull-check: off main is CANNOT" || bad "pull-check: off main" "rc=$rc $out"
PG -C "$PH" switch -q main
echo local > "$PH/local.txt"; PG -C "$PH" add -A; PG -C "$PH" commit -q -m local
pc PATH="$tmp/pc-busy:$PATH"
[ $rc -eq 2 ] && say "$out" | grep -q 'diverged' && ok "pull-check: a diverged main is CANNOT" || bad "pull-check: diverged" "rc=$rc $out"
PG -C "$PH" reset -q --hard origin/main

# --- a failed fetch warns and judges from the last fetched origin/main ---
PG -C "$PH" remote set-url origin "$tmp/no-such-remote.git"
pc PATH="$tmp/pc-busy:$PATH"
say "$out" | grep -q 'warning: could not fetch origin/main' && [ "$(say "$out" | grep -c '^PULL=')" = 1 ] \
  && ok "pull-check: a failed fetch warns and still gives one verdict" || bad "pull-check: fetch fails" "rc=$rc $out"
PG -C "$PH" remote set-url origin "$PB"

# --- --list: the loaded set comes from the real bin/hermes-run ---
out=$("$ROOT/bin/hermes-pull-check" --list 2>&1 </dev/null); rc=$?
ok_list=1
for want in "sourced bin/hermes-run" "sourced lib/common.sh" "sourced lib/runtime.sh" "sourced lib/epics.sh" \
            "run lib/watchdog.py" "run lib/tsfilter.py" "run lib/bead_stats.py" "run lib/context_usage.py" \
            "run lib/hooks/bd_notes_guard.py"; do
  say "$out" | grep -qx "$want" || ok_list=0
done
[ $rc -eq 0 ] && [ $ok_list = 1 ] && ! say "$out" | grep -q 'pr_review\|freshness' && ! say "$out" | grep -qE '^(sourced|run) *$' \
  && ok "pull-check: --list derives hermes-run's sourced and run files" || bad "pull-check: --list" "rc=$rc $out"
unset -f PG pc upstream loops; unset PB PSD PH head_before ok_list want
