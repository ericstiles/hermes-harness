#!/usr/bin/env bash
# lib/wrapup.sh — sourced library: what hermes-run and hermes-supervise need to save the work of a
# run that ended without a PR (TIMEOUT, AGENT_CRASHED). bash 3.2 compatible; read-only.
#
#   hh_find_session <YYYYMMDD_HHMMSS>  -> id of the first harness session started at or after it
#   hh_project_writes <log>            -> number of project files written/patched + git commits
#   hh_wip_saved <log>                 -> exit 0 if the wrap-up printed RUN_WIP_SAVED
#
# A killed or crashed Hermes never prints its "Session:" footer, but the session and its
# messages are already in Hermes' store (checked 2026-11-20: the 90m b8p.37 run had 124 saved
# messages), so it can still be resumed once its id is known.

# Harness sessions are recognised by the run prompt, which `hermes sessions list` shows as the
# preview. Session ids start with the local start time, so the first one at or after the run's
# start time is that run's session.
hh_find_session() {
  local start=$1
  hermes sessions list --source cli --limit 20 2>/dev/null | tr -d '\r' \
    | grep 'Follow AGENTS.md "Autonomous' | awk '{print $NF}' \
    | grep -E '^[0-9]{8}_[0-9]{6}_' | awk -v s="$start" 'substr($0, 1, 15) >= s' \
    | sort | head -n 1
}

# Files the agent wrote or patched outside /tmp, plus git commits: zero means the run only
# explored (probe scripts in /tmp, reading, installing) and left nothing to build on.
hh_project_writes() {
  local f=$1 writes commits
  writes=$(tr -d '\r' < "$f" | sed -nE 's/.*┊ [^ ]+ +(write|patch) +([^ ]+).*/\2/p' | grep -cv '^/tmp/')
  commits=$(tr -d '\r' < "$f" | grep -cE '┊ [^ ]+ +\$ .*git commit')
  echo $((writes + commits))
}

hh_wip_saved() { tr -d '\r' < "$1" | grep -qE '^RUN_WIP_SAVED$'; }
