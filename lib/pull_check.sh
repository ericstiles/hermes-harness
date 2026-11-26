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

# hh_loaded_files (the files a running hermes-run has loaded) is in lib/code_stamp.sh, which
# hermes-pull-check sources first; hermes-run uses it too, to notice its own code changing (bead eyx).

hh_script_word() { # <argv...> -> the script a process runs: argv[0], or a shell's first non-option argument
  case ${1##*/} in
    bash | sh | -bash | -sh)
      shift
      while [ $# -gt 0 ]; do case $1 in -*) shift ;; *) break ;; esac; done
      ;;
  esac
  printf '%s\n' "${1:-}"
}

hh_loop_pids() { # <harness> -> pids of hermes-run processes started from this checkout, space-separated
  local want pid cmd w script pids="" words
  want=$(hh_resolve "$1/bin/hermes-run") || return 0
  # -ax -o pid=,command= works with macOS ps and with Linux procps (which accepts the BSD options).
  while read -r pid cmd; do
    read -r -a words <<<"$cmd" # split on spaces without expanding globs
    script=$(hh_script_word "${words[@]}")
    for w in "${words[@]}"; do
      [ "${w##*/}" = hermes-run ] || continue
      case $w in
        /*) [ "$(hh_resolve "$w" 2>/dev/null)" = "$want" ] || continue ;;
        # A relative path or bare name: hermes-run cds into the target repo, so nothing says which
        # file it meant. If it is the script being run, count the loop (fail safe, bead jbi).
        *) [ "$w" = "$script" ] || continue ;;
      esac
      pids="$pids $pid"
      break
    done
  done < <(ps -axo pid=,command= 2>/dev/null | grep -E 'hermes-run' | grep -v grep)
  echo "${pids# }"
}

hh_untracked_in_way() { # <harness> <paths the pull changes> -> untracked, not ignored files it would overwrite
  # A file in the way: the same path, a file where a folder is needed, or a folder where a file goes.
  # Ignored files are left out: git overwrites those on a fast-forward.
  awk 'NR == FNR { changed[$0] = 1; next }
       { for (c in changed) if ($0 == c || index($0, c "/") == 1 || index(c, $0 "/") == 1) { print; next } }' \
    <(printf '%s\n' "$2") <(git -C "$1" -c core.quotePath=false ls-files --others --exclude-standard)
}

hh_cannot() { # <why> <what to do next> -> the CANNOT verdict
  echo "PULL=CANNOT"
  echo "evidence: $1"
  echo "next: $2"
}

hh_pull_check() { # <harness> <fetch: 1|0> -> PULL=<verdict> and evidence; returns 0 UP_TO_DATE/SAFE, 1 WAIT, 2 CANNOT
  local h=$1 branch behind ahead changed loaded hits="" f kind pids blocked
  if [ "$(git -C "$h" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$h" && pwd -P)" ]; then
    hh_cannot "$h is not a git checkout" "nothing to pull"; return 2
  fi
  if [ "$2" = 1 ] && ! hh_harness_fetch "$h" "${HERMES_FRESHNESS_TIMEOUT:-10s}"; then
    echo "warning: could not fetch origin/main ($HH_FETCH_WHY); judging from the last fetched origin/main" >&2
  fi
  git -C "$h" rev-parse -q --verify origin/main >/dev/null || { hh_cannot "no origin/main ref" "git -C '$h' fetch origin main"; return 2; }
  if ! branch=$(git -C "$h" symbolic-ref -q --short HEAD 2>/dev/null); then
    hh_cannot "the checkout is on a detached HEAD, not main" "git -C '$h' switch main"; return 2
  fi
  [ "$branch" = main ] || { hh_cannot "the checkout is on branch $branch, not main" "git -C '$h' switch main"; return 2; }
  if [ -n "$(git -C "$h" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    hh_cannot "the checkout has uncommitted changes to tracked files" "commit or stash them first (git -C '$h' status)"; return 2
  fi
  behind=$(git -C "$h" rev-list --count HEAD..origin/main); ahead=$(git -C "$h" rev-list --count origin/main..HEAD)
  if [ "$ahead" -gt 0 ]; then
    hh_cannot "main has diverged from origin/main ($ahead local commit(s), $behind behind)" "decide by hand: git -C '$h' log --oneline origin/main...HEAD"
    return 2
  fi
  [ "$behind" -eq 0 ] && { echo "PULL=UP_TO_DATE"; echo "evidence: main is at origin/main"; return 0; }
  changed=$(git -C "$h" -c core.quotePath=false diff --name-only HEAD origin/main)
  blocked=$(hh_untracked_in_way "$h" "$changed" | paste -sd ' ' -)
  if [ -n "$blocked" ]; then
    hh_cannot "untracked file(s) the pull would overwrite: $blocked" "move or delete them first (git -C '$h' status)"
    return 2
  fi
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
