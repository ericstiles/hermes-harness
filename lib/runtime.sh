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

hh_stamp_line() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; } # a line for the timed twin
