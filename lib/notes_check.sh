#!/usr/bin/env bash
# lib/notes_check.sh — sourced library: after an OK_DONE run, make sure the PR's beads carry the
# PR link hermes-review requires (ticket in_progress, PR URL in its notes), and that no other
# bead picked the link up during the run.
#
#   . "$HARNESS_HOME/lib/notes_check.sh"
#   hh_notes_check <logfile> [claimed-id] [run-start-epoch]
#
# Ticket T = the PR body's `Bead: <id>` line (gh pr view), else the claimed id. A claimed bead
# other than T is the review-fix bead F. Steps:
# 1. Repair: T or F in_progress without the URL gets `PR: <url>` appended by the harness itself
#    (`NOTES_FIX: ...`), then `bd dolt push`. Only when the PR's head branch is `bd/<T>`, so a
#    wrong URL from the log is never written. A status problem is never repaired.
# 2. Check: T in_progress with the URL, F with the URL.
# 3. Strays (needs run-start-epoch): any other bead updated since the run started whose notes
#    contain the URL, except a side bead B carrying the exact `Fixed in PR <url> via
#    review-fix <F>` line (AGENTS.md review-fix step 3). Never repaired: a human removes it.
# Prints one `NOTES_CHECK: ...` line per problem. Returns 0 intact, 1 lost (class NOTES_LOST),
# 2 could not check (prints `warning: ...`; the caller keeps its class).
# Incident 2026-11-19 (organize_music eac): a review-fix run replaced the ticket's notes.
# Incident 2026-11-24 (organize_music-225): the agent wrote the PR link on organize_music-b8p.25
# instead of organize_music-225: F lacked the URL and an unrelated bead carried it.

hh_pr_url() { # <logfile> -> last GitHub PR URL in the log, empty if none
  tr -d '\r' < "$1" | grep -oE 'https://github\.com/[^ /]+/[^ /]+/pull/[0-9]+' | tail -n 1
}

_nc_pr_bead() { # <pr-url> -> the PR body's `Bead: <id>`, empty if gh fails or there is none
  gh pr view "$1" --json body -q .body 2>/dev/null | tr -d '\r' \
    | sed -n 's/^Bead: *\([^ ]*\) *$/\1/p' | head -n 1
}

_nc_pr_head() { # <pr-url> -> the PR's head branch, empty if gh fails
  gh pr view "$1" --json headRefName -q .headRefName 2>/dev/null | tr -d '\r' | head -n 1
}

_nc_state() { # <id> <url> -> "<status> yes|no" (URL in notes?); non-zero if bd or its JSON fails
  local json
  json=$(bd show "$1" --json 2>/dev/null) || return 1
  printf '%s' "$json" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
has = re.search(re.escape(sys.argv[1]) + r"(?!\d)", str(d.get("notes") or ""))
print(d["status"], "yes" if has else "no")' "$2" 2>/dev/null
}

_nc_rfc3339() { # <epoch> -> UTC RFC3339, one minute early (clock skew between host and bd)
  local e=$(($1 - 60))
  if date --version >/dev/null 2>&1; then date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
  else date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ; fi
}

_nc_strays() { # <url> <since-epoch> <T> [F] -> ids of beads wrongly carrying the URL; non-zero on failure
  local json
  json=$(bd list --all --notes-contains "$1" --updated-after "$(_nc_rfc3339 "$2")" --json --limit 0 \
    2>/dev/null) || return 1
  printf '%s' "$json" | python3 -c '
import json, re, sys
url, t, f = sys.argv[1], sys.argv[2], sys.argv[3]
side = "Fixed in PR %s via review-fix %s" % (url, f) if f else None
has_url = re.compile(re.escape(url) + r"(?!\d)")  # pull/12 must not match pull/120
for d in json.loads(sys.stdin.read() or "[]"):
    notes = str(d.get("notes") or "")
    if d["id"] in (t, f) or not has_url.search(notes):
        continue
    if side and side in notes:
        continue
    print(d["id"])' "$1" "$3" "${4:-}"
}

_nc_repair() { # <id> <url> <state> -> appends `PR: <url>` when in_progress without it; prints NOTES_FIX
  case "$3" in in_progress\ no) ;; *) return 0 ;; esac
  bd update "$1" --append-notes "PR: $2" >/dev/null 2>&1 \
    || { echo "warning: could not append the PR line to $1"; return 0; }
  echo "NOTES_FIX: appended PR: $2 to $1 (the agent had not written it)"
}

_nc_try_repair() { # sets t_state/f_state again after appending the missing PR lines
  local head
  head=$(_nc_pr_head "$url")
  if [ "$head" != "bd/$ticket" ]; then
    echo "warning: no PR-line repair: $url head is '${head:-unknown}', not bd/$ticket"; return 0
  fi
  _nc_repair "$ticket" "$url" "$t_state"
  [ -n "$fix" ] && _nc_repair "$fix" "$url" "$f_state"
  bd dolt push >/dev/null 2>&1 || echo "warning: bd dolt push failed after the PR-line repair"
  t_state=$(_nc_state "$ticket" "$url") || t_state="unknown no"
  if [ -n "$fix" ]; then f_state=$(_nc_state "$fix" "$url") || f_state="unknown no"; fi
}

hh_notes_check() {
  local log=$1 claimed=${2:-} since=${3:-} url ticket fix="" t_state f_state="" lost=0 ids id
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
  case "$t_state|$f_state" in in_progress\ no\|*|*\|in_progress\ no) _nc_try_repair ;; esac
  case "$t_state" in in_progress\ *) ;; *) echo "NOTES_CHECK: $ticket status ${t_state% *}, expected in_progress"; lost=1 ;; esac
  case "$t_state" in *\ no) echo "NOTES_CHECK: $ticket missing $url in notes"; lost=1 ;; esac
  case "$f_state" in *\ no) echo "NOTES_CHECK: $fix missing $url in notes"; lost=1 ;; esac
  if [ -n "$since" ]; then
    if ids=$(_nc_strays "$url" "$since" "$ticket" "$fix" 2>/dev/null); then
      for id in $ids; do
        echo "NOTES_CHECK: $id has $url in notes but is not the PR's bead ($ticket${fix:+ or $fix})"; lost=1
      done
    else echo "warning: stray-bead check skipped: bd list failed"; fi
  fi
  [ "$lost" = 1 ] && return 1
  echo "NOTES_CHECK: ok $ticket${fix:+ $fix} carry $url"
  return 0
}
