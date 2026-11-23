# shellcheck shell=bash
# freshness.sh — is the hermes-harness checkout a launch runs from up to date? (bead svz)
# Sourced by bin/hermes-launch only; never by hermes-run, so it can change while a loop runs.
#
# hh_harness_freshness <harness-dir>: fetch origin main (time-limited by lib/watchdog.py), then print
# a "warning: ..." line on stderr for each of: behind origin/main (with the pull command), a failed
# fetch, not on branch main, uncommitted changes to tracked files. Prints nothing when all is well,
# or when the harness is not a git checkout. Never pulls (another loop may be running from the same
# checkout) and always returns 0: a warning never changes the launch. The fetch never prompts
# (GIT_TERMINAL_PROMPT=0, ssh BatchMode=yes added to GIT_SSH_COMMAND or core.sshCommand; a GIT_SSH
# wrapper is left alone, and an explicit -o BatchMode=no already there wins, as ssh keeps the first
# value) and a missing python3 is named in the warning.
# HERMES_FRESHNESS_CHECK=0 skips it; HERMES_FRESHNESS_TIMEOUT (default 10s) limits the fetch.

hh_harness_freshness() {
  local h=$1 limit=${HERMES_FRESHNESS_TIMEOUT:-10s} branch behind rc
  [ "${HERMES_FRESHNESS_CHECK:-1}" = 0 ] && return 0
  [ "$(git -C "$h" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$h" && pwd -P)" ] || return 0
  local why=""
  if ! command -v python3 >/dev/null 2>&1; then
    rc=127; why="python3 not found; it runs the fetch's time limit"
  else
    # Never wait on a credential or ssh host-key prompt: fail at once instead (bead ckh).
    # GIT_SSH_COMMAND outranks core.sshCommand and GIT_SSH, so build on what the user set instead
    # of replacing it; with only GIT_SSH (a wrapper program) set, leave ssh alone.
    local -a fetch_env=(GIT_TERMINAL_PROMPT=0) ssh_cmd
    if [ -n "${GIT_SSH_COMMAND:-}" ] || [ -z "${GIT_SSH:-}" ]; then
      ssh_cmd=${GIT_SSH_COMMAND:-$(git -C "$h" config core.sshCommand 2>/dev/null)}
      fetch_env+=("GIT_SSH_COMMAND=${ssh_cmd:-ssh} -o BatchMode=yes")
    fi
    env "${fetch_env[@]}" \
      python3 "$h/lib/watchdog.py" --limit "$limit" --extend 0 --grace 2s --log /dev/null -- \
      git -C "$h" fetch -q origin main >/dev/null 2>&1 </dev/null; rc=$?
  fi
  if [ "$rc" != 0 ]; then
    [ -n "$why" ] || why="git fetch exit $rc"; [ "$rc" = 124 ] && why="timed out after $limit"
    echo "warning: could not fetch origin/main for hermes-harness ($why); its checkout may be out of date" >&2
  elif behind=$(git -C "$h" rev-list --count HEAD..origin/main 2>/dev/null) && [ "${behind:-0}" -gt 0 ]; then
    echo "warning: hermes-harness is $behind commit(s) behind origin/main; run git -C '$h' pull --ff-only first" >&2
  fi
  if branch=$(git -C "$h" symbolic-ref -q --short HEAD 2>/dev/null); then
    [ "$branch" = main ] || echo "warning: hermes-harness checkout is on branch $branch, not main" >&2
  else
    echo "warning: hermes-harness checkout is on a detached HEAD, not main" >&2
  fi
  [ -z "$(git -C "$h" status --porcelain --untracked-files=no 2>/dev/null)" ] \
    || echo "warning: hermes-harness checkout has uncommitted changes" >&2
  return 0
}
