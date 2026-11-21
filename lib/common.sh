#!/usr/bin/env bash
# lib/common.sh — sourced by every bin/ script.
#
# HARNESS_HOME is set by each bin/ script before sourcing this file.
# Separates two things the old in-repo scripts conflated:
#   HARNESS_HOME  where these scripts live (resolved through symlinks by bin/*)
#   REPO_ROOT     the TARGET repo the scripts act on: $HERMES_REPO, else the git
#                 toplevel of the current directory
# bash 3.2 compatible.

hh_help_requested() { # "$@" -> true when -h or --help is anywhere in the arguments
  local a
  for a in "$@"; do case $a in -h|--help) return 0 ;; esac; done
  return 1
}

hh_print_help() { # <script> -> its header comment (lines 2.. up to the first non-# line), "# " stripped
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

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

# GITHUB_REPO (owner/name): explicit env wins, else parsed from the origin remote
# (git@host:o/n.git, https://host/o/n.git, https://host/o/n). Returns 1 if unknown.
hh_github_repo() { # needs REPO_ROOT; exports GITHUB_REPO
  if [ -z "${GITHUB_REPO:-}" ]; then
    GITHUB_REPO=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')
  fi
  [ -n "$GITHUB_REPO" ] && export GITHUB_REPO
}
