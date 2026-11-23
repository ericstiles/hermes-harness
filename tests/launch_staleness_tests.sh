#!/usr/bin/env bash
# Sourced by tests/run_tests.sh after the launch tests (uses ok/bad/say, $tmp $W $ROOT; ps, herdr and
# tmux are already stubbed on PATH). Bead hermes-harness-svz: hermes-launch warns, before starting,
# when the harness checkout it runs from is behind origin/main, on another branch, or has
# uncommitted changes. It never pulls, and the launch result is unchanged.
# The harness under test is a throwaway clone of a local bare repo: no network.
# Fixture repos ignore the machine's git config (global hooks, templates) so they behave the same anywhere.
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main -c core.hooksPath=/dev/null \
      -c init.templateDir= "$@" 2>/dev/null; }
HB="$tmp/hh.git"; HS="$tmp/hh-seed"; HH="$tmp/hh"
G init -q --bare -b main "$HB"
G clone -q "$HB" "$HS" 2>/dev/null
cp -R "$ROOT/bin" "$ROOT/lib" "$HS/"
G -C "$HS" add -A; G -C "$HS" commit -q -m "harness"; G -C "$HS" push -q origin HEAD:main
G clone -q "$HB" "$HH" 2>/dev/null
fresh_launch() { # [env...] : dry-run launch from the cloned harness with the check on
  out=$(cd "$W" && env HERMES_FRESHNESS_CHECK=1 GH_TOKEN=x "$@" "$HH/bin/hermes-launch" --dry-run 2>&1); rc=$?
}

# --- up to date: silent ---
fresh_launch
[ $rc -eq 0 ] && ! say "$out" | grep -q 'warning:' && say "$out" | grep -q 'DRY RUN: would start' \
  && ok "launch: silent when the harness is up to date" || bad "launch: up to date" "rc=$rc $out"

# --- behind: one warning naming the count and the pull command; the launch continues ---
for n in 1 2; do echo "$n" > "$HS/change-$n"; G -C "$HS" add -A; G -C "$HS" commit -q -m "change $n"; done
G -C "$HS" push -q origin HEAD:main
head_before=$(G -C "$HH" rev-parse HEAD)
fresh_launch
[ "$(say "$out" | grep -c 'warning:')" = 1 ] \
  && say "$out" | grep -q "warning: hermes-harness is 2 commit(s) behind origin/main; run git -C '$HH' pull --ff-only first" \
  && ok "launch: warns when the harness is behind origin/main (2 commits named)" || bad "launch: behind warning" "$out"
[ $rc -eq 0 ] && say "$out" | grep -q 'DRY RUN: would start' && ok "launch: a behind harness still launches (exit 0)" \
  || bad "launch: behind continues" "rc=$rc $out"
[ "$(G -C "$HH" rev-parse HEAD)" = "$head_before" ] && ok "launch: never pulls the harness by itself" \
  || bad "launch: pulled" "$(G -C "$HH" log --oneline -3)"
G -C "$HH" pull -q --ff-only

# --- a failed fetch only warns and the launch continues ---
G -C "$HH" remote set-url origin "$tmp/no-such-remote.git"
fresh_launch
[ $rc -eq 0 ] && [ "$(say "$out" | grep -c 'warning:')" = 1 ] \
  && say "$out" | grep -q 'warning: could not fetch origin/main for hermes-harness' \
  && say "$out" | grep -q 'DRY RUN: would start' \
  && ok "launch: a failed fetch only warns and the launch continues" || bad "launch: fetch failure" "rc=$rc $out"
G -C "$HH" remote set-url origin "$HB"

# --- a dirty or non-main checkout is reported too ---
echo "local edit" >> "$HH/bin/hermes-launch.note"; G -C "$HH" add bin/hermes-launch.note
fresh_launch
say "$out" | grep -q 'warning: hermes-harness checkout has uncommitted changes' && [ $rc -eq 0 ] \
  && ok "launch: a dirty harness checkout is reported" || bad "launch: dirty" "rc=$rc $out"
G -C "$HH" rm -q -f bin/hermes-launch.note
G -C "$HH" switch -q -c topic
fresh_launch
say "$out" | grep -q "warning: hermes-harness checkout is on branch topic, not main" && [ $rc -eq 0 ] \
  && ok "launch: a harness on another branch is reported" || bad "launch: branch" "rc=$rc $out"
G -C "$HH" switch -q --detach main
fresh_launch
say "$out" | grep -q "warning: hermes-harness checkout is on a detached HEAD, not main" && [ $rc -eq 0 ] \
  && ok "launch: a detached harness HEAD is reported" || bad "launch: detached" "rc=$rc $out"
G -C "$HH" switch -q main

# --- off switch, and a harness that is not a git checkout is silent ---
G -C "$HH" remote set-url origin "$tmp/no-such-remote.git"
out0=$(cd "$W" && HERMES_FRESHNESS_CHECK=0 GH_TOKEN=x "$HH/bin/hermes-launch" --dry-run 2>&1)
! say "$out0" | grep -q 'warning:' && ok "launch: HERMES_FRESHNESS_CHECK=0 skips the check" || bad "launch: off switch" "$out0"
G -C "$HH" remote set-url origin "$HB"
NG="$tmp/hh-nogit"; mkdir -p "$NG"; cp -R "$ROOT/bin" "$ROOT/lib" "$NG/"
out=$(cd "$W" && HERMES_FRESHNESS_CHECK=1 GH_TOKEN=x "$NG/bin/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 0 ] && ! say "$out" | grep -q 'warning:' && ok "launch: a harness that is not a git checkout is not checked" \
  || bad "launch: no git" "rc=$rc $out"

# --- a real refusal is unchanged: the check never turns a refusal into a start or vice versa ---
out=$(cd "$W" && env -u GH_TOKEN HERMES_FRESHNESS_CHECK=1 "$HH/bin/hermes-launch" --dry-run 2>&1); rc=$?
[ $rc -eq 1 ] && say "$out" | grep -q 'GH_TOKEN is not set' && ok "launch: refusals are unchanged by the check" \
  || bad "launch: refusal" "rc=$rc $out"

# --- bead ckh: the fetch never waits on a credential or ssh host-key prompt ---
# Stub git: `fetch` records its prompt settings, then fails at once when terminal prompts are off
# (as real git does) or else "waits for an answer" (sleeps); every other git command is the real one.
REAL_GIT=$(command -v git); mkdir -p "$tmp/promptgit"
cat > "$tmp/promptgit/git" <<S
#!/bin/sh
case " \$* " in
  *" fetch "*)
    printf 'GIT_TERMINAL_PROMPT=%s GIT_SSH_COMMAND=%s\n' "\${GIT_TERMINAL_PROMPT:-}" "\${GIT_SSH_COMMAND:-}" > "$tmp/promptgit.env"
    [ "\${GIT_TERMINAL_PROMPT:-}" = 0 ] && { echo "fatal: could not read Username: terminal prompts disabled" >&2; exit 128; }
    sleep 30; exit 128 ;;
esac
exec "$REAL_GIT" "\$@"
S
chmod +x "$tmp/promptgit/git"
began=$(date +%s)
fresh_launch PATH="$tmp/promptgit:$PATH" GIT_SSH_COMMAND="ssh -o ConnectTimeout=5"
took=$(( $(date +%s) - began ))
[ $rc -eq 0 ] && [ "$took" -lt 5 ] && say "$out" | grep -q 'warning: could not fetch origin/main for hermes-harness (git fetch exit 128)' \
  && ok "launch: a fetch that would prompt fails at once with one warning (${took}s)" \
  || bad "launch: prompt fails fast" "rc=$rc took=${took}s $out"
grep -q 'GIT_TERMINAL_PROMPT=0 ' "$tmp/promptgit.env" && grep -q 'BatchMode=yes' "$tmp/promptgit.env" \
  && grep -q 'ConnectTimeout=5' "$tmp/promptgit.env" \
  && ok "launch: the fetch runs with prompts off and ssh BatchMode, keeping GIT_SSH_COMMAND's options" \
  || bad "launch: fetch prompt env" "$(cat "$tmp/promptgit.env" 2>/dev/null)"

# --- bead ckh: no python3 -> the warning names python3, not a git exit code ---
NOPY="$tmp/nopy"; mkdir -p "$NOPY"
for d in /usr/bin /bin "$(dirname "$REAL_GIT")"; do
  for f in "$d"/*; do
    n=${f##*/}; case $n in python*) continue ;; esac
    [ -e "$NOPY/$n" ] || ln -s "$f" "$NOPY/$n" 2>/dev/null
  done
done
fresh_launch PATH="$tmp/nohost:$NOPY"
[ $rc -eq 0 ] && say "$out" | grep -q 'warning: could not fetch origin/main for hermes-harness (python3 not found' \
  && ! say "$out" | grep -q 'exit 127' && say "$out" | grep -q 'DRY RUN: would start' \
  && ok "launch: without python3 the fetch warning names python3 and the launch continues" \
  || bad "launch: no python3" "rc=$rc $out"
unset -f G fresh_launch; unset HB HS HH NG NOPY REAL_GIT out0 head_before began took
