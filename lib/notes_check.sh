#!/usr/bin/env bash
# lib/notes_check.sh — sourced library: after an OK_DONE run, check that the PR's bead still
# carries its PR link, which hermes-review requires (ticket in_progress, PR URL in its notes).
#
#   . "$HARNESS_HOME/lib/notes_check.sh"
#   hh_notes_check <logfile> [claimed-id]
#
# Ticket T = the PR body's `Bead: <id>` line (gh pr view), else the claimed id. T must be
# in_progress with the PR URL in its notes. A claimed bead other than T (a review-fix issue)
# must have the URL in its notes too. Prints one `NOTES_CHECK: ...` line per problem.
# Returns 0 intact, 1 lost (class NOTES_LOST), 2 could not check (prints `warning: ...`; the
# caller keeps its class). Read-only against beads: the only bd calls are dolt pull and show.
# Incident 2026-11-19 (organize_music eac): a review-fix run replaced the ticket's notes and
# was still classed OK_DONE; the reviewer refused the PR hours later.

hh_pr_url() { # <logfile> -> last GitHub PR URL in the log, empty if none
  tr -d '\r' < "$1" | grep -oE 'https://github\.com/[^ /]+/[^ /]+/pull/[0-9]+' | tail -n 1
}

_nc_pr_bead() { # <pr-url> -> the PR body's `Bead: <id>`, empty if gh fails or there is none
  gh pr view "$1" --json body -q .body 2>/dev/null | tr -d '\r' \
    | sed -n 's/^Bead: *\([^ ]*\) *$/\1/p' | head -n 1
}

_nc_state() { # <id> <url> -> "<status> yes|no" (URL in notes?); non-zero if bd or its JSON fails
  local json
  json=$(bd show "$1" --json 2>/dev/null) || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print(d["status"], "yes" if sys.argv[1] in str(d.get("notes") or "") else "no")' "$2" 2>/dev/null
}

hh_notes_check() {
  local log=$1 claimed=${2:-} url ticket fix="" t_state f_state="" lost=0
  url=$(hh_pr_url "$log")
  [ -n "$url" ] || { echo "warning: notes check skipped: no PR URL in $log"; return 2; }
  ticket=$(_nc_pr_bead "$url")
  [ -n "$ticket" ] || ticket=$claimed
  [ -n "$ticket" ] || { echo "warning: notes check skipped: $url has no Bead: line and the log has no claim"; return 2; }
  [ -n "$claimed" ] && [ "$claimed" != "$ticket" ] && fix=$claimed
  bd dolt pull >/dev/null 2>&1 || { echo "warning: notes check skipped: bd dolt pull failed"; return 2; }
  t_state=$(_nc_state "$ticket" "$url") \
    || { echo "warning: notes check skipped: bd show $ticket failed or returned no bead"; return 2; }
  if [ -n "$fix" ]; then
    f_state=$(_nc_state "$fix" "$url") \
      || { echo "warning: notes check skipped: bd show $fix failed or returned no bead"; return 2; }
  fi
  case "$t_state" in in_progress\ *) ;; *) echo "NOTES_CHECK: $ticket status ${t_state% *}, expected in_progress"; lost=1 ;; esac
  case "$t_state" in *\ no) echo "NOTES_CHECK: $ticket missing $url in notes"; lost=1 ;; esac
  case "$f_state" in *\ no) echo "NOTES_CHECK: $fix missing $url in notes"; lost=1 ;; esac
  [ "$lost" = 1 ] && return 1
  echo "NOTES_CHECK: ok $ticket${fix:+ $fix} carry $url"
  return 0
}
