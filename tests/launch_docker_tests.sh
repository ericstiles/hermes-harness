#!/usr/bin/env bash
# Sourced by tests/run_tests.sh after the launch tests (uses ok/bad/say, $tmp $W $BIN; ps, herdr, tmux
# and docker are already stubbed on PATH in $tmp/nohost). Bead hermes-harness-5qy: hermes-launch
# refuses to start when Docker does not answer, before it opens a tab or records a launch.
# bare: a PATH holding the system tools but neither docker nor colima, plus the host stubs
BARE="$tmp/dk-bare"; mkdir -p "$BARE"
for f in /bin/* /usr/bin/*; do
  case ${f##*/} in docker | colima) ;; *) [ -e "$BARE/${f##*/}" ] || ln -s "$f" "$BARE/${f##*/}" ;; esac
done
for c in ps herdr tmux; do rm -f "$BARE/$c"; cp "$tmp/nohost/$c" "$BARE/$c"; done
dkstub() { # <dir> <name> <shell body>
  mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
DOWN="$tmp/dk-down"; dkstub "$DOWN" docker 'echo "Cannot connect to the Docker daemon" >&2; exit 1'
HANG="$tmp/dk-hang"; dkstub "$HANG" docker 'exec sleep 30'
COL="$tmp/dk-colima"; dkstub "$COL" colima "echo \"colima \$*\" >> '$tmp/dk-colima.log'"
UP="$tmp/dk-up"; dkstub "$UP" docker "echo \"docker \$*\" >> '$tmp/dk-up.log'"
dk() { # <PATH> [env args / flags...] : a launch from the target repo; sets out, rc
  local path=$1; shift
  rm -rf "$W/logs" "$tmp/host_calls.log"
  out=$(cd "$W" && PATH="$path" GH_TOKEN=x env "$@" 2>&1); rc=$?
}
untouched() { [ ! -e "$W/logs/.relaunches" ] && [ ! -e "$tmp/host_calls.log" ]; }

# --- daemon not answering: refused before anything happens, with the fix ---
dk "$DOWN:$COL:$BARE" "$BIN/hermes-launch"
[ $rc -eq 1 ] && say "$out" | grep -q "Docker is not answering ('docker info' failed)" && say "$out" | grep -q 'Fix: colima start' \
  && untouched && [ ! -e "$tmp/dk-colima.log" ] \
  && ok "launch docker: daemon down is refused: no tab, no relaunch record, colima never started" \
  || bad "launch docker: daemon down" "rc=$rc $out $(cat "$tmp/host_calls.log" "$tmp/dk-colima.log" 2>/dev/null)"
dk "$DOWN:$BARE" "$BIN/hermes-launch" --dry-run
[ $rc -eq 1 ] && say "$out" | grep -q 'start your container runtime' && ! say "$out" | grep -q 'colima start' \
  && ! say "$out" | grep -q 'DRY RUN' \
  && ok "launch docker: daemon down fails --dry-run; no colima hint without colima" || bad "launch docker: dry-run down" "rc=$rc $out"
# --- docker not on PATH ---
for kind in real dry; do
  if [ $kind = dry ]; then dk "$BARE" "$BIN/hermes-launch" --dry-run; else dk "$BARE" "$BIN/hermes-launch"; fi
  [ $rc -eq 1 ] && say "$out" | grep -q 'docker command not found' && ! say "$out" | grep -q 'not answering' && untouched \
    && ok "launch docker: no docker command is its own problem ($kind run)" || bad "launch docker: missing ($kind)" "rc=$rc $out"
done
# --- a hanging docker info ends at the time limit ---
start=$(date +%s)
dk "$HANG:$COL:$BARE" HERMES_DOCKER_TIMEOUT=1s "$BIN/hermes-launch"
took=$(($(date +%s) - start))
[ $rc -eq 1 ] && say "$out" | grep -q "'docker info' gave no answer within 1s" && say "$out" | grep -q 'colima restart' \
  && [ $took -lt 15 ] && untouched \
  && ok "launch docker: a hanging docker info counts as not running after the time limit" || bad "launch docker: hang" "rc=$rc ${took}s $out"
# --- listed together with the other problems ---
out=$(cd "$W" && env -u GH_TOKEN PATH="$DOWN:$BARE" "$BIN/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && say "$out" | grep -q 'GH_TOKEN is not set' && say "$out" | grep -q 'Docker is not answering' \
  && ok "launch docker: reported together with a missing GH_TOKEN" || bad "launch docker: together" "rc=$rc $out"
# --- daemon up: the launch goes on as before ---
dk "$UP:$BARE" "$BIN/hermes-launch" --dry-run
[ $rc -eq 0 ] && say "$out" | grep -q 'DRY RUN: would start' && grep -qx 'docker info' "$tmp/dk-up.log" \
  && ok "launch docker: a running daemon changes nothing" || bad "launch docker: up" "rc=$rc $out"
# --- without python3 (it runs the time limit) the check is skipped, and says so; no false refusal ---
NOPY5="$tmp/dk-nopy"; mkdir -p "$NOPY5"
for f in "$BARE"/*; do case ${f##*/} in python*) ;; *) ln -s "$f" "$NOPY5/${f##*/}" ;; esac; done
dk "$UP:$NOPY5" "$BIN/hermes-launch" --dry-run
[ $rc -eq 0 ] && say "$out" | grep -q 'warning: python3 is missing or does not run.*Docker was not checked' && ! say "$out" | grep -q 'not answering' \
  && ok "launch docker: without python3 the check is skipped with a warning" || bad "launch docker: no python3" "rc=$rc $out"
unset NOPY5
# --- review of PR #48: a problem of our own must never be reported as Docker being down ---
BROKEN="$tmp/dk-brokenpy"; dkstub "$BROKEN" python3 'exit 127'
dk "$BROKEN:$UP:$BARE" "$BIN/hermes-launch" --dry-run
[ $rc -eq 0 ] && say "$out" | grep -q 'python3 is missing or does not run.*Docker was not checked' && ! say "$out" | grep -q 'not answering' \
  && ok "launch docker: a python3 that does not run is named, not blamed on Docker" || bad "launch docker: broken python3" "rc=$rc $out"
wrong=""
for v in 30sec 1m30s '15 s' abc -5 .5s; do
  dk "$UP:$COL:$BARE" HERMES_DOCKER_TIMEOUT="$v" "$BIN/hermes-launch" --dry-run
  [ $rc -eq 1 ] && say "$out" | grep -qF "HERMES_DOCKER_TIMEOUT='$v' is not a duration" && say "$out" | grep -q 'e.g. 15s or 2m' \
    && ! say "$out" | grep -q 'not answering\|colima' || wrong="$wrong [$v: rc=$rc $out]"
done
[ -z "$wrong" ] && ok "launch docker: a bad time limit names the variable and the accepted form" || bad "launch docker: bad limit" "$wrong"
# 0 turns the check off, as 0 does for the harness's other time settings; the stub is slow on purpose
SLOW="$tmp/dk-slow"; dkstub "$SLOW" docker "echo called >> '$tmp/dk-slow.log'; sleep 1; exit 0"
wrong=""
for v in 0 0s 0m 0.0s; do
  dk "$SLOW:$COL:$BARE" HERMES_DOCKER_TIMEOUT="$v" "$BIN/hermes-launch" --dry-run
  [ $rc -eq 0 ] && say "$out" | grep -qF "warning: HERMES_DOCKER_TIMEOUT=$v: Docker was not checked" \
    && [ ! -e "$tmp/dk-slow.log" ] || wrong="$wrong [$v: rc=$rc $out]"
done
[ -z "$wrong" ] && ok "launch docker: a time limit of 0 skips the check with a warning" || bad "launch docker: zero limit" "$wrong"
wrong=""
for v in 15 2m 1.5s 1h; do
  dk "$UP:$BARE" HERMES_DOCKER_TIMEOUT="$v" "$BIN/hermes-launch" --dry-run
  [ $rc -eq 0 ] && ! say "$out" | grep -q 'Docker was not checked' || wrong="$wrong [$v: rc=$rc $out]"
done
[ -z "$wrong" ] && ok "launch docker: seconds and unit forms are accepted" || bad "launch docker: good limits" "$wrong"
unset BROKEN SLOW wrong v
# --- docker's own words (bead e43): "permission denied" must not read as just "start colima" ---
DENIED="$tmp/dk-denied"; dkstub "$DENIED" docker \
  'printf "Client:\n Version: 1\n"; printf "\npermission denied on the docker socket\nsecond detail line\n" >&2; exit 1'
dk "$DENIED:$COL:$BARE" "$BIN/hermes-launch" --dry-run
[ $rc -eq 1 ] && say "$out" | grep -q 'docker says: permission denied on the docker socket' \
  && ! say "$out" | grep -q 'second detail line\|Client:' && say "$out" | grep -q 'Fix: colima start' \
  && ok "launch docker: the first line of docker's error is shown" || bad "launch docker: docker's words" "rc=$rc $out"
MUTE="$tmp/dk-mute"; dkstub "$MUTE" docker 'exit 1'
dk "$MUTE:$BARE" "$BIN/hermes-launch" --dry-run
[ $rc -eq 1 ] && say "$out" | grep -q 'Docker is not answering' && ! say "$out" | grep -q 'docker says' \
  && ok "launch docker: a silent failure adds no empty error line" || bad "launch docker: mute" "rc=$rc $out"
# --- a hang says the limit can be raised, and what the suggested restart costs ---
dk "$HANG:$COL:$BARE" HERMES_DOCKER_TIMEOUT=1s "$BIN/hermes-launch" --dry-run
[ $rc -eq 1 ] && say "$out" | grep -q 'raise HERMES_DOCKER_TIMEOUT' \
  && say "$out" | grep -q 'Fix: colima restart (this stops running containers)' \
  && ok "launch docker: a hang names the time limit and warns that a restart stops containers" \
  || bad "launch docker: hang wording" "rc=$rc $out"
# a child of docker that outlives the limit and keeps its stderr open must not hold the launch
ORPHAN="$tmp/dk-orphan"; dkstub "$ORPHAN" docker "(trap '' TERM; exec sleep 20) & exec sleep 30"
start=$(date +%s)
dk "$ORPHAN:$BARE" HERMES_DOCKER_TIMEOUT=1s "$BIN/hermes-launch" --dry-run
took=$(($(date +%s) - start))
[ $rc -eq 1 ] && [ $took -lt 15 ] && say "$out" | grep -q 'gave no answer within 1s' \
  && ok "launch docker: a leftover child of docker does not hold the launch" || bad "launch docker: orphan" "rc=$rc ${took}s $out"
# --- a bad time limit and no docker command: both are listed (bead a7v) ---
dk "$BARE" HERMES_DOCKER_TIMEOUT=abc "$BIN/hermes-launch" --dry-run
[ $rc -eq 1 ] && say "$out" | grep -q '^  - Docker is not installed' \
  && say "$out" | grep -q "^  - HERMES_DOCKER_TIMEOUT='abc' is not a duration" \
  && ok "launch docker: a bad time limit and a missing docker are both listed" || bad "launch docker: both" "rc=$rc $out"
unset DENIED MUTE ORPHAN
# --- help ---
out=$("$BIN/hermes-launch" --help 2>&1)
say "$out" | grep -q 'Docker does not answer' && say "$out" | grep -q 'HERMES_DOCKER_TIMEOUT.*0 skips' \
  && say "$out" | sed -n '/^EXIT STATUS/,/^EXAMPLES/p' | grep -q 'Docker' \
  && say "$out" | sed -n '/^EXIT STATUS/,/^EXAMPLES/p' | grep -q 'HERMES_DOCKER_TIMEOUT is not a duration' \
  && ok "launch docker: --help lists the check, its time limit and the exit status" || bad "launch docker: help" "$out"
unset -f dkstub dk untouched; unset BARE DOWN HANG COL UP start took kind
