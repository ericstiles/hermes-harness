#!/usr/bin/env bash
# lib/sandbox.sh — sourced: reset the Hermes sandbox's copy of a repo (hermes-run --clean).
#
# Hermes runs its shell commands in ONE persistent Docker container (terminal.backend
# docker, container_persistent true) and clones the repo into /workspace/<name> there.
# A run that stops mid-issue leaves uncommitted work behind, which breaks the next run's
# `git checkout -B bd/<id> origin/main`. hh_sandbox_reset puts that clone back on
# origin/main, after saving anything uncommitted as a patch on the host.
# It never deletes the container, other /workspace dirs, or ignored files (.venv).
# bash 3.2 compatible.

hh_sandbox_container() { # <image> -> the one container built from <image>; 1 if not exactly one
  local ids n list
  ids=$(docker ps -a --filter "ancestor=$1" --format '{{.ID}}' 2>/dev/null)
  n=$(printf '%s' "$ids" | grep -c .)
  if [ "$n" != 1 ]; then
    list=$(printf '%s' "$ids" | tr '\n' ' ')
    [ -n "$list" ] && list=" ($list)"
    echo "clean: expected one sandbox container from image '$1', found $n$list; nothing reset" >&2
    return 1
  fi
  printf '%s\n' "$ids"
}

hh_sandbox_reset() { # <image> <repo-name> <log-dir> -> 0 reset (or nothing to reset), 2 failure
  local c ws patch branch
  c=$(hh_sandbox_container "$1") || return 2
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then
    docker start "$c" >/dev/null 2>&1 || { echo "clean: could not start sandbox container $c" >&2; return 2; }
  fi
  ws="/workspace/$2"
  if ! docker exec "$c" test -d "$ws/.git"; then
    echo "clean: $ws does not exist in sandbox $c; Hermes will clone it fresh"
    return 0
  fi
  branch=$(docker exec "$c" git -C "$ws" branch --show-current 2>/dev/null)
  # Save first: tracked changes and untracked files (intent-to-add makes them show in the diff).
  mkdir -p "$3"
  patch="$3/sandbox-dirty-$(date +%Y%m%d-%H%M%S).patch"
  if ! docker exec "$c" sh -c "cd '$ws' && git add -A --intent-to-add >/dev/null 2>&1; git diff HEAD --binary" > "$patch"; then
    rm -f "$patch"
    echo "clean: could not read the state of $ws in sandbox $c; nothing reset" >&2
    return 2
  fi
  if [ -s "$patch" ]; then
    echo "clean: saved uncommitted work from $c:$ws (branch ${branch:-unknown}) to $patch"
  else
    rm -f "$patch"
  fi
  if ! docker exec "$c" sh -c "cd '$ws' && git fetch -q origin && git checkout -q -f -B main origin/main && git clean -fdq"; then
    echo "clean: resetting $ws in sandbox $c to origin/main failed; not starting a run" >&2
    return 2
  fi
  echo "clean: $c:$ws is on origin/main with no local changes (was on ${branch:-unknown})"
}
