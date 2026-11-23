#!/usr/bin/env bash
# Sourced by bin/hermes-run. Bash 3.2.
#
#   hh_close_eligible_epics  -> prints "EPICS_CLOSED: <ids>" when it closed any epic, else nothing
#
# Hermes never works or closes epics (AGENTS.md: epics are closed by their children), and nothing
# else did. A finished epic left open can block every remaining issue, so the agent finds nothing
# ready and the loop stops QUEUE_EMPTY although work exists (bead hermes-harness-xw2). Before the
# loop stops on QUEUE_EMPTY, this closes every epic whose children are all complete. It repeats,
# because closing a child epic can make its parent eligible (bd 1.3.4 closes one level per call),
# up to HH_EPIC_ROUNDS rounds. It never fails the run: a bd error just ends the rounds.

HH_EPIC_ROUNDS=10
HH_EPIC_REASON="All children completed (hermes-run, before stopping on QUEUE_EMPTY)"

_hh_epic_ids() { # stdin: bd epic close-eligible --json -> space-separated closed ids; fails on bad JSON
  python3 -c 'import json, sys
d = json.load(sys.stdin)
print(" ".join(str(i) for i in d["closed"]))' 2>/dev/null
}

hh_close_eligible_epics() {
  local round=0 json ids closed=""
  while [ "$round" -lt "$HH_EPIC_ROUNDS" ]; do
    round=$((round + 1))
    json=$(bd epic close-eligible --json --reason "$HH_EPIC_REASON" 2>/dev/null) || break
    ids=$(printf '%s' "$json" | _hh_epic_ids) || break
    [ -n "$ids" ] || break
    closed="${closed:+$closed }$ids"
  done
  [ -n "$closed" ] || return 0
  echo "EPICS_CLOSED: $closed"
  bd dolt push >/dev/null 2>&1 || echo "warning: bd dolt push failed after closing epics; they are closed locally"
  return 0
}
