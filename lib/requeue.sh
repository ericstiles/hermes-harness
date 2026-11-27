# shellcheck shell=bash
# requeue.sh — sourced by bin/hermes-run: what the next run works, from the requeue chain (bead 35r)
# or the ready list without the issues a person must run (bead 66y). bash 3.2 compatible.
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

# The labels unattended runs never pick (HERMES_EXCLUDE_LABELS), comma separated; fails, saying why
# on stderr, when the setting is not a list of labels.
hh_exclude_labels() { _hh_requeue_py labels; }

# The pick when no chain applies. Sets HH_PICK (the first ready issue an unattended run may take;
# empty = none, or unknown) and HH_PICK_LOG ("PICK: ..." when the ready list could not be read).
hh_normal_pick() {
  local out last
  out=$(_hh_requeue_py normal)
  last=$(printf '%s\n' "$out" | tail -n 1)
  HH_PICK=""
  HH_PICK_LOG=$(printf '%s\n' "$out" | sed -n 's/^LOG /PICK: /p')
  case $last in
    "PICK "*) HH_PICK=${last#PICK } ;;
    NONE) ;;
    *) HH_PICK_LOG="PICK: could not read the ready list (requeue.py gave no answer): Hermes picks in step 1" ;;
  esac
}

# "PICK: skipping ..." naming the ready issues left for a person; nothing when there are none.
hh_waiting_line() { _hh_requeue_py waiting | sed -n 's/^LOG /PICK: /p'; }

# Sets HH_CHAIN_PICK (the issue the next run must work; empty = no chain applies) and
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
