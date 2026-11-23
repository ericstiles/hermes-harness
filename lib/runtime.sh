#!/usr/bin/env bash
# lib/runtime.sh — sourced: wall-clock helpers for hermes-run's RUN_TIME lines.
# bash 3.2 compatible; works with BSD (macOS) and GNU date.

# GNU date has --version; BSD date does not. Decide once: on GNU, `date -r N`
# would read the mtime of a FILE named N instead of formatting epoch N.
if date --version >/dev/null 2>&1; then HH_DATE_GNU=1; else HH_DATE_GNU=0; fi

hh_hms() { # <epoch> -> HH:MM:SS (local time)
  if [ "$HH_DATE_GNU" = 1 ]; then date -d "@$1" +%H:%M:%S; else date -r "$1" +%H:%M:%S; fi
}

hh_elapsed() { # <seconds> -> 38s | 41m12s | 2h05m (same style as lib/tsfilter.py)
  local s=$1
  [ "$s" -lt 0 ] && s=0 # a backwards clock step (NTP) must not print "-5s"
  if [ "$s" -lt 60 ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds\n' $((s / 60)) $((s % 60))
  else printf '%dh%02dm\n' $((s / 3600)) $((s % 3600 / 60)); fi
}

# A claim command, with the same word boundaries as lib/tsfilter.py's _CLAIM (\b...\b): not
# "xbd update", not "--claimed", and only bead-id characters (not a "<id>" placeholder).
HH_CLAIM_ERE='(^|[^A-Za-z0-9_])bd update [A-Za-z0-9][A-Za-z0-9._-]* --claim([^A-Za-z0-9_]|$)'
hh_claimed_issue() { # <logfile> -> the run's bead: the FIRST id it claimed, empty if none
  # First, not last: a review-fix run's later `bd update B --claim` marks a side bead (bead 97j).
  [ -r "$1" ] || return 0 # a missing log: no id, and no shell error (2>/dev/null can't hide it)
  tr -d '\r' < "$1" | grep -oE "$HH_CLAIM_ERE" | head -n 1 \
    | sed -E 's/.*bd update ([A-Za-z0-9][A-Za-z0-9._-]*) --claim.*/\1/'
}

hh_stamp_line() { # <line> [bead id] -> "[HH:MM:SS] line", or "[HH:MM:SS,<id>] line" (the timed twin)
  printf '[%s%s] %s\n' "$(date +%H:%M:%S)" "${2:+,$2}" "$1"
}
