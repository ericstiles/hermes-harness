#!/usr/bin/env bash
# lib/classify.sh — sourced library: classify one Hermes run log.
#
#   . "$HARNESS_HOME/lib/classify.sh"
#   hermes_classify <logfile> [exit_code]   -> prints ONE class name
#
# Classes: OK_DONE QUEUE_EMPTY BLOCKED TIMEOUT MODEL_API_ERROR SANDBOX_DOWN
#          AUTH_ERROR BEADS_SYNC_ERROR AGENT_STOPPED AGENT_CRASHED NOTES_LOST UNKNOWN
# NOTES_LOST is never inferred from Hermes output: hermes-run writes RUN_RESULT=NOTES_LOST
# when an OK_DONE run's bead lost its PR link (lib/notes_check.sh), and step 1 reads it back.
# Patterns are anchored to the formats seen in real logs so agent narration or
# test output (e.g. "assert status == 404", "Request timed out" from the title
# generator) cannot trigger a false match. bash 3.2 compatible; read-only.

_hc_tool_calls() { # last "(N user, M tool calls)" -> M, empty if no footer
  sed -n 's/.*([0-9]* user, \([0-9]*\) tool calls).*/\1/p' "$1" | tail -n 1
}

hermes_classify() {
  local f=$1 ec=${2:-} tail30 tail60 tools prev
  [ -r "$f" ] || { echo UNKNOWN; return 0; }

  # 1. An explicit result line written by hermes-run wins.
  prev=$(tr -d '\r' < "$f" | grep -E '^RUN_RESULT=[A-Z_]+$' | tail -n 1 | cut -d= -f2)
  if [ -n "$prev" ]; then echo "$prev"; return 0; fi

  # 2. timeout(1) exit status.
  if [ "$ec" = "124" ]; then echo TIMEOUT; return 0; fi

  # Logs are tee'd from a pty: strip CR so whole-line sentinels match.
  tail30=$(tail -n 30 "$f" | tr -d '\r'); tail60=$(tail -n 60 "$f" | tr -d '\r')
  tools=$(_hc_tool_calls "$f")

  if printf '%s\n' "$tail60" | grep -qiE 'Cannot connect to the Docker daemon|Docker daemon not running'; then
    echo SANDBOX_DOWN; return 0
  fi
  # Model/API failure: Hermes' own retry banner, and no real work done.
  if grep -qE 'API call failed \(attempt [0-9]+/[0-9]+\)' "$f" && { [ -z "$tools" ] || [ "$tools" = "0" ]; }; then
    echo MODEL_API_ERROR; return 0
  fi
  # Sentinels must be a whole line (the prompt/AGENTS text mentions them inline).
  if printf '%s\n' "$tail30" | grep -qE '^RUN_BLOCKED$'; then echo BLOCKED; return 0; fi
  if printf '%s\n' "$tail30" | grep -qE '^NO_READY_WORK$'; then echo QUEUE_EMPTY; return 0; fi
  # Hermes itself died on an exception: its traceback, no session footer, and an exit that is
  # neither the timeout kill (124, caught above) nor Ctrl-C (130). Before AGENT_CRASHED existed
  # this fell through to TIMEOUT below.
  if [ -n "$ec" ] && [ "$ec" != 0 ] && [ "$ec" != 130 ] && ! grep -q '^Resume this session with:' "$f" \
     && printf '%s\n' "$tail60" | grep -qE '^Traceback \(most recent call last\):$'; then
    echo AGENT_CRASHED; return 0
  fi
  # A killed run never prints Hermes' session footer.
  if ! grep -q '^Resume this session with:' "$f"; then echo TIMEOUT; return 0; fi
  # Sync failure = git/dolt's own rejection line, not agent prose that merely
  # mentions it (a real run recovered from one and still opened its PR).
  if printf '%s\n' "$tail60" | grep -qE '^ *! \[rejected\].*non-fast-forward|^error: failed to push some refs|^hint: Updates were rejected'; then
    echo BEADS_SYNC_ERROR; return 0
  fi
  # A PR URL in a clean run means push/auth worked: success wins over any
  # earlier narrated error text.
  if grep -qE 'https://github\.com/[^ ]+/pull/[0-9]+' "$f" && [ "${ec:-0}" = "0" ]; then
    echo OK_DONE; return 0
  fi
  if printf '%s\n' "$tail60" | grep -qE 'Bad credentials|could not read Username|[Aa]uthentication failed|HTTP 40[13]\b|\((401|403)\)'; then
    echo AUTH_ERROR; return 0
  fi
  # The session ended cleanly (footer, exit 0) yet produced no PR, no sentinel and
  # no known error: the agent ended its turn mid-issue, e.g. by asking a question
  # nobody will answer (2026-11-19 incident). hermes-run resumes such a session once.
  if [ "${ec:-0}" = "0" ]; then echo AGENT_STOPPED; return 0; fi
  echo UNKNOWN
}
