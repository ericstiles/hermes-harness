# shellcheck shell=bash
# parked.sh — sourced by bin/hermes-run: after RUN_BLOCKED, make sure the issue is parked so the
# loop can go on without picking it again (bead yiv, lib/parked.py). bash 3.2 compatible.

_hh_parked_py() { python3 "$HARNESS_HOME/lib/parked.py" "$@"; }

# Before a run: remember every issue's status, assignee and notes. On failure there is no file, and
# hh_park says so.
hh_notes_snapshot() { _hh_parked_py snapshot "$1" >/dev/null 2>&1 || rm -f "$1"; }

# Park <id>. Sets HH_PARKED (the reason; empty = not parked), HH_PARK_LOG ("PARK: ..." lines),
# HH_PARK_CHANGED (1 when beads were written and need a push) and HH_PARK_BRANCH (its WIP branch).
hh_park() { # <id> <snapshot file> <log reference for the note>
  local out last why
  out=$(_hh_parked_py park "$1" "$2" "$3")
  last=$(printf '%s\n' "$out" | tail -n 1)
  HH_PARKED=""
  why=$(printf '%s\n' "$out" | sed -n 's/^LOG /PARK: /p')
  HH_PARK_LOG=$why
  HH_PARK_BRANCH=$(printf '%s\n' "$out" | sed -n 's/^BRANCH //p')
  HH_PARK_CHANGED=0
  printf '%s\n' "$out" | grep -qx CHANGED && HH_PARK_CHANGED=1
  case $last in
    "PARKED "*) HH_PARKED=${last#PARKED }; return 0 ;;
    "NOT_PARKED "*) last="PARK: ${last#NOT_PARKED }" ;;
    *) last="PARK: could not park $1 (parked.py gave no answer)" ;;
  esac
  HH_PARK_LOG="${why:+$why
}$last"
}
