# shellcheck shell=bash
# requeue.sh — sourced by bin/hermes-run: the requeue chain (bead 35r). bash 3.2 compatible.
#
# A run that finds its issue blocked by another bead adds the edge, releases its claim and prints
# RUN_REQUEUED. hermes-run keeps those ids in a per-launch stack file (one per line, newest last)
# and works the newest one's blocker chain, deepest ready blocker first, before returning to it.
# lib/requeue.py reads the dependency graph; this file only reads and writes the stack files.

_hh_requeue_py() { python3 "$HARNESS_HOME/lib/requeue.py" "$@" 2>/dev/null | tail -n 1; }

_hh_requeue_pop() { # <stack file>: drop the newest entry
  local rest
  rest=$(sed '$d' "$1")
  if [ -n "$rest" ]; then printf '%s\n' "$rest" > "$1"; else : > "$1"; fi
}

# May the loop requeue <id>? On yes: pushes it, prints the open blockers (comma separated), returns 0.
# On no: prints why and returns 1. An id is requeued at most once per launch (no ping-pong).
hh_requeue_accept() { # <stack file> <history file> <id>
  local stack=$1 history=$2 id=$3 line
  [ -n "$id" ] || { echo "the run has no claimed issue to requeue"; return 1; }
  if grep -qxF -- "$id" "$history" 2>/dev/null; then
    echo "$id was already requeued in this launch"; return 1
  fi
  line=$(_hh_requeue_py check "$id")
  case $line in
    "OK "*) echo "$id" >> "$stack"; echo "$id" >> "$history"; echo "${line#OK }"; return 0 ;;
    "REFUSED "*) echo "${line#REFUSED }"; return 1 ;;
    *) echo "requeue.py gave no answer for $id"; return 1 ;;
  esac
}

# The issue the next run must work: prints its id, or nothing (= the agent's normal pick; the stack
# is kept). A picked or closed stack top leaves the stack. Returns 2, printing the cycle, when the
# chain loops back on itself. A bd failure warns on stderr and falls back to the normal pick.
hh_chain_pick() { # <stack file>
  local stack=$1 top line
  while top=$(tail -n 1 "$stack" 2>/dev/null) && [ -n "$top" ]; do
    line=$(_hh_requeue_py walk "$top")
    case $line in
      "PICK $top") _hh_requeue_pop "$stack"; echo "$top"; return 0 ;;
      "PICK "*) echo "${line#PICK }"; return 0 ;;
      CLOSED) _hh_requeue_pop "$stack" ;;
      "CYCLE "*) echo "${line#CYCLE }"; return 2 ;;
      NONE) return 0 ;;
      *) echo "warning: could not walk the blocker chain of $top (${line:-no answer}); using the normal pick" >&2
         return 0 ;;
    esac
  done
  return 0
}
