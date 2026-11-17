#!/usr/bin/env bash
# lib/common.sh — sourced by every bin/ script.
#
# HARNESS_HOME is set by each bin/ script before sourcing this file.
# Separates two things the old in-repo scripts conflated:
#   HARNESS_HOME  where these scripts live (resolved through symlinks by bin/*)
#   REPO_ROOT     the TARGET repo the scripts act on: $HERMES_REPO, else the git
#                 toplevel of the current directory
# bash 3.2 compatible.

hh_repo() { # -> sets REPO_ROOT and LOG_DIR; returns 2 when no target repo
  if [ -n "${HERMES_REPO:-}" ]; then
    REPO_ROOT=$(cd "$HERMES_REPO" 2>/dev/null && pwd) || { echo "HERMES_REPO=$HERMES_REPO is not a directory" >&2; return 2; }
  else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
      echo "not inside a git repo: cd into the target repo or set HERMES_REPO=/path/to/repo" >&2; return 2; }
  fi
  LOG_DIR=${HERMES_LOG_DIR:-$REPO_ROOT/logs}
}

# Processes that mean "a Hermes run is active" (one local model: one run at a time, across repos).
HH_ACTIVE_PATTERN='hermes-run|hermes chat'
