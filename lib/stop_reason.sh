#!/usr/bin/env bash
# lib/stop_reason.sh — sourced library: why did a Hermes session stop?
#
#   . "$HARNESS_HOME/lib/stop_reason.sh"
#   hh_stop_reason <session id>   -> "<reason> api_calls=<n>/<max>", or "unknown"
#
# Hermes writes one line per finished turn to ${HERMES_HOME:-~/.hermes}/logs/agent.log:
#   ... Turn ended: reason=text_response(finish_reason=stop) model=... api_calls=67/150 ... session=<id>
# The run log itself never says why the session ended (2026-11-19, organize_music run
# 20261119_120608), so hermes-run copies this as a `STOP_REASON:` line before RUN_RESULT and
# lib/classify.sh reads it (a used-up budget is TURN_LIMIT). Reasons seen in Hermes source:
# text_response(...), interrupted_during_api_call, max_iterations_reached(n/max),
# budget_exhausted, all_retries_exhausted_no_response, ...
# Read-only. agent.log is large and shared by every session, so only its tail is read and the
# line must name this exact session. HERMES_AGENT_LOG overrides the path (tests).
# bash 3.2 compatible.

HH_AGENT_LOG_TAIL=${HH_AGENT_LOG_TAIL:-5000}

hh_agent_log() { printf '%s' "${HERMES_AGENT_LOG:-${HERMES_HOME:-$HOME/.hermes}/logs/agent.log}"; }

hh_stop_reason() { # <session id>
  local sid=${1:-} f line reason calls
  f=$(hh_agent_log)
  if [ -z "$sid" ] || [ ! -r "$f" ]; then echo unknown; return 0; fi
  line=$(tail -n "$HH_AGENT_LOG_TAIL" "$f" | tr -d '\r' \
    | awk -v s="session=$sid" 'index($0, "Turn ended: reason=") && $NF == s { l = $0 } END { print l }')
  reason=$(printf '%s\n' "$line" | sed -n 's/.*Turn ended: reason=\([^ ]*\).*/\1/p')
  calls=$(printf '%s\n' "$line" | sed -n 's/.* api_calls=\([0-9]*\/[0-9]*\).*/\1/p')
  if [ -z "$reason" ]; then echo unknown; return 0; fi
  echo "$reason${calls:+ api_calls=$calls}"
}
