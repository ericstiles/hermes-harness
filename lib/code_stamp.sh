# shellcheck shell=bash
# code_stamp.sh — which harness files a hermes-run loop has loaded, and a checksum of them.
# Sourced by bin/hermes-run (stops the loop between runs when its code changed, bead eyx) and by
# bin/hermes-pull-check (is a pull safe, bead anq). bash 3.2 compatible; read-only.

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

hh_code_stamp() { # <harness> -> one "<cksum> <size> <path>" (or "missing <path>") line per loaded file
  local h=$1 kind f
  hh_loaded_files "$h" | while read -r kind f; do
    if [ -r "$h/$f" ]; then
      printf '%s %s\n' "$(cksum < "$h/$f" | awk '{print $1, $2}')" "$f"
    else
      echo "missing $f"
    fi
  done
}

hh_code_changes() { # <harness> <stamp taken earlier> -> changed paths, space separated; fails when none
  local new
  new=$(hh_code_stamp "$1")
  [ "$new" = "$2" ] && return 1
  # a changed, added or removed file shows up as a differing line; its path is the last field
  # diff exits 1 when the inputs differ; under the callers' pipefail that would read as "no change"
  { diff <(printf '%s\n' "$2") <(printf '%s\n' "$new") || true; } | sed -n 's/^[<>] .* \([^ ]*\)$/\1/p' | sort -u | paste -sd ' ' -
  return 0
}
