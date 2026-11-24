# shellcheck shell=bash
# pull_check.sh — is `git pull --ff-only` of the harness checkout safe right now? (bead anq)
# Sourced by bin/hermes-pull-check only; never by hermes-run, so it can change while a loop runs.
# Read-only: the only write is git fetch's update of origin/main (lib/freshness.sh hh_harness_fetch).
#
# A running hermes-run keeps executing the files it loaded, and bash reads a script as it runs it, so
# AGENTS_LOCAL.md forbids changing bin/hermes-run or anything it sources while a loop runs. The files
# it runs mid-loop (lib/*.py, the Hermes hooks) would mix old and new versions. The rule applies only
# to loops started from THIS checkout: a loop from another clone loads its own copy.
# bash 3.2 compatible.

hh_resolve() { # <path> -> its physical path, symlinks resolved; fails when it does not exist
  local s=$1 d
  [ -e "$s" ] || return 1
  while [ -h "$s" ]; do
    d=$(cd "$(dirname "$s")" && pwd -P); s=$(readlink "$s")
    case $s in /*) ;; *) s="$d/$s" ;; esac
  done
  printf '%s/%s\n' "$(cd "$(dirname "$s")" && pwd -P)" "$(basename "$s")"
}

hh_loaded_files() { # <harness> -> "sourced <path>" and "run <path>" lines, paths relative to it
  local h=$1 queue="bin/hermes-run" seen=" " f rel
  # Everything hermes-run sources, followed through the files it sources in turn.
  while [ -n "$queue" ]; do
    f=${queue%% *}; queue=${queue#"$f"}; queue=${queue# }
    case $seen in *" $f "*) continue ;; esac
    seen="$seen$f "
    echo "sourced $f"
    [ -r "$h/$f" ] || continue
    for rel in $(sed -nE 's#^[[:space:]]*(\.|source)[[:space:]]+"?\$\{?HARNESS_HOME\}?/([^" ]+)"?.*#\2#p' "$h/$f"); do
      queue="${queue:+$queue }$rel"
    done
  done
  # What they run mid-loop: lib/*.py named through $HARNESS_HOME, and the hooks Hermes calls.
  {
    for f in $seen; do
      grep -oE '\$\{?HARNESS_HOME\}?/lib/[A-Za-z0-9_./-]+\.py' "$h/$f" 2>/dev/null | sed -E 's#^\$\{?HARNESS_HOME\}?/##'
    done
    for f in "$h"/lib/hooks/*; do [ -f "$f" ] && echo "lib/hooks/${f##*/}"; done
  } | sort -u | sed 's/^/run /'
}

hh_loop_pids() { # <harness> -> pids of hermes-run processes started from this checkout, space-separated
  local want pid cmd w path pids=""
  want=$(hh_resolve "$1/bin/hermes-run") || return 0
  while read -r pid cmd; do
    for w in $cmd; do
      [ "${w##*/}" = hermes-run ] || continue
      case $w in */*) path=$w ;; *) path=$(command -v "$w" 2>/dev/null) || continue ;; esac
      [ "$(hh_resolve "$path" 2>/dev/null)" = "$want" ] && { pids="$pids $pid"; break; }
    done
  done < <(ps -axo pid=,command= 2>/dev/null | grep -E 'hermes-run' | grep -v grep)
  echo "${pids# }"
}

hh_pull_check() { # <harness> <fetch: 1|0> -> PULL=<verdict> and evidence; returns 0 UP_TO_DATE/SAFE, 1 WAIT, 2 CANNOT
  local h=$1 branch behind ahead changed loaded hits="" f kind pids
  cannot() { echo "PULL=CANNOT"; echo "evidence: $1"; echo "next: $2"; }
  if [ "$(git -C "$h" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$h" && pwd -P)" ]; then
    cannot "$h is not a git checkout" "nothing to pull"; return 2
  fi
  if [ "$2" = 1 ] && ! hh_harness_fetch "$h" "${HERMES_FRESHNESS_TIMEOUT:-10s}"; then
    echo "warning: could not fetch origin/main ($HH_FETCH_WHY); judging from the last fetched origin/main" >&2
  fi
  git -C "$h" rev-parse -q --verify origin/main >/dev/null || { cannot "no origin/main ref" "git -C '$h' fetch origin main"; return 2; }
  if ! branch=$(git -C "$h" symbolic-ref -q --short HEAD 2>/dev/null); then
    cannot "the checkout is on a detached HEAD, not main" "git -C '$h' switch main"; return 2
  fi
  [ "$branch" = main ] || { cannot "the checkout is on branch $branch, not main" "git -C '$h' switch main"; return 2; }
  if [ -n "$(git -C "$h" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    cannot "the checkout has uncommitted changes to tracked files" "commit or stash them first (git -C '$h' status)"; return 2
  fi
  behind=$(git -C "$h" rev-list --count HEAD..origin/main); ahead=$(git -C "$h" rev-list --count origin/main..HEAD)
  if [ "$ahead" -gt 0 ]; then
    cannot "main has diverged from origin/main ($ahead local commit(s), $behind behind)" "decide by hand: git -C '$h' log --oneline origin/main...HEAD"
    return 2
  fi
  [ "$behind" -eq 0 ] && { echo "PULL=UP_TO_DATE"; echo "evidence: main is at origin/main"; return 0; }
  changed=$(git -C "$h" diff --name-only HEAD origin/main)
  loaded=$(hh_loaded_files "$h") # the loaded set of the CURRENT checkout: what a running loop has
  while read -r f; do
    [ -n "$f" ] || continue
    kind=$(printf '%s\n' "$loaded" | awk -v f="$f" '$2 == f { print $1; exit }')
    [ -n "$kind" ] && hits="$hits  $f ($kind by hermes-run)
"
  done <<EOF
$changed
EOF
  pids=$(hh_loop_pids "$h")
  local n_changed; n_changed=$(printf '%s\n' "$changed" | grep -c .)
  if [ -n "$hits" ] && [ -n "$pids" ]; then
    echo "PULL=WAIT"
    echo "evidence: hermes-run loop(s) from this checkout running: $pids"
    echo "evidence: origin/main is $behind commit(s) ahead and changes file(s) those loops load:"
    printf '%s' "$hits"
    echo "next: wait until the loops finish (hermes-status), then: git -C '$h' pull --ff-only"
    return 1
  fi
  echo "PULL=SAFE"
  if [ -z "$pids" ]; then
    echo "evidence: origin/main is $behind commit(s) ahead ($n_changed file(s)); no hermes-run loop from this checkout is running"
  else
    echo "evidence: origin/main is $behind commit(s) ahead; none of its $n_changed changed file(s) is loaded by hermes-run (loops running: $pids)"
  fi
  echo "next: git -C '$h' pull --ff-only"
  return 0
}
