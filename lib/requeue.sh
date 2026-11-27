# shellcheck shell=bash
# requeue.sh — sourced by bin/hermes-run: the requeue chain (bead 35r). bash 3.2 compatible.
#
# A run that finds its issue blocked by another bead adds the edge, releases its claim, notes
# "REQUEUED: blocked by ..." and prints RUN_REQUEUED. Before every run hermes-run asks which issue
# that chain needs next. The chain is read from beads each time (lib/requeue.py), so a later launch
# still finishes the requeued issue; only the once-per-launch history is a file.

_hh_requeue_py() { python3 "$HARNESS_HOME/lib/requeue.py" "$@"; }

# May the loop requeue <id>? On yes: records it, prints "<blocker,ids>" (plus " UNNOTED" when the
# agent wrote no REQUEUED note) and returns 0. On no: prints why and returns 1. An id is requeued at
# most once per launch (no ping-pong).
hh_requeue_accept() { # <history file> <id>
  local history=$1 id=$2 line
  [ -n "$id" ] || { echo "the run has no claimed issue to requeue"; return 1; }
  if grep -qxF -- "$id" "$history" 2>/dev/null; then
    echo "$id was already requeued in this launch"; return 1
  fi
  line=$(_hh_requeue_py check "$id" | tail -n 1)
  case $line in
    "OK "*) echo "$id" >> "$history"; echo "${line#OK }"; return 0 ;;
    "REFUSED "*) echo "${line#REFUSED }"; return 1 ;;
    *) echo "requeue.py gave no answer for $id"; return 1 ;;
  esac
}

# Sets HH_CHAIN_PICK (the issue the next run must work; empty = the agent's normal pick) and
# HH_CHAIN_LOG ("REQUEUE CHAIN: ..." lines saying why; empty when nothing is requeued).
hh_chain_pick() {
  local out last
  out=$(_hh_requeue_py pick)
  last=$(printf '%s\n' "$out" | tail -n 1)
  HH_CHAIN_PICK=""
  HH_CHAIN_LOG=$(printf '%s\n' "$out" | sed -n 's/^LOG /REQUEUE CHAIN: /p')
  case $last in
    "PICK "*) HH_CHAIN_PICK=${last#PICK } ;;
    NONE) ;;
    *) HH_CHAIN_LOG="REQUEUE CHAIN: could not read the requeue chain (requeue.py gave no answer): picking as usual" ;;
  esac
}
