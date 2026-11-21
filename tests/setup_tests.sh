#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad/eq, $tmp $BIN $ROOT).
# bin/hermes-setup lays down the baseline files a target repo needs from the harness:
# AGENTS.md (identical copy), AGENTS_LOCAL.md (stub only if missing, never modified),
# a managed block in CLAUDE.md, and the logs/ + .envrc.local lines in .gitignore.
SR="$tmp/setup-target"; mkdir -p "$SR"; git -C "$SR" init -q -b main
setup() { "$BIN/hermes-setup" "$@" 2>&1; }
digest() { (cd "$SR" && cat AGENTS.md AGENTS_LOCAL.md CLAUDE.md .gitignore 2>/dev/null) | shasum | cut -c1-40; }

# --- fresh repo gets every baseline file ---
out=$(setup "$SR"); rc=$?
eq "setup: fresh repo exits 0" "$rc" 0
cmp -s "$ROOT/AGENTS.md" "$SR/AGENTS.md" && ok "setup: AGENTS.md is an identical copy" || bad "setup AGENTS.md" "differs"
cmp -s "$ROOT/templates/AGENTS_LOCAL.md" "$SR/AGENTS_LOCAL.md" && ok "setup: AGENTS_LOCAL.md seeded from the template" \
  || bad "setup AGENTS_LOCAL seed" "$(ls "$SR")"
grep -q '^@AGENTS_LOCAL.md\|@AGENTS_LOCAL.md' "$SR/CLAUDE.md" && grep -q 'hermes-status' "$SR/CLAUDE.md" \
  && ok "setup: CLAUDE.md block points at AGENTS_LOCAL.md and has the snippet" || bad "setup CLAUDE.md" "$(cat "$SR/CLAUDE.md")"
eq "setup: .gitignore has logs/ once" "$(grep -cx 'logs/' "$SR/.gitignore")" 1
eq "setup: .gitignore has .envrc.local once" "$(grep -cx '.envrc.local' "$SR/.gitignore")" 1
echo "$out" | grep -q '^created  *AGENTS.md' && ok "setup: reports created files" || bad "setup report" "$out"

# --- second run is a no-op ---
before=$(digest); out=$(setup "$SR"); rc=$?
eq "setup: second run exits 0" "$rc" 0
eq "setup: second run changes nothing" "$(digest)" "$before"
[ -z "$(echo "$out" | grep -Ev '^(unchanged|kept) |^hermes-setup: ')" ] && ok "setup: second run reports only unchanged/kept" || bad "setup rerun report" "$out"

# --- AGENTS_LOCAL.md is never modified; AGENTS.md drift is restored ---
printf '# my rules\nquality gate: make test\n' > "$SR/AGENTS_LOCAL.md"; local_sum=$(shasum < "$SR/AGENTS_LOCAL.md")
echo "local edit" >> "$SR/AGENTS.md"
out=$(setup "$SR")
eq "setup: existing AGENTS_LOCAL.md untouched" "$(shasum < "$SR/AGENTS_LOCAL.md")" "$local_sum"
cmp -s "$ROOT/AGENTS.md" "$SR/AGENTS.md" && ok "setup: drifted AGENTS.md restored" || bad "setup restore" "differs"
echo "$out" | grep -q '^updated  *AGENTS.md' && ok "setup: reports updated AGENTS.md" || bad "setup update report" "$out"
echo "$out" | grep -q '^kept  *AGENTS_LOCAL.md' && ok "setup: reports kept AGENTS_LOCAL.md" || bad "setup kept report" "$out"

# --- CLAUDE.md: user text outside the block survives; the block is replaced, not duplicated ---
{ echo "# My project"; echo "own text"; cat "$SR/CLAUDE.md"; echo "trailing text"; } > "$SR/c.tmp" && mv "$SR/c.tmp" "$SR/CLAUDE.md"
sed -i.bak 's/hermes-status/hermes-STALE/' "$SR/CLAUDE.md" && rm -f "$SR/CLAUDE.md.bak"
setup "$SR" >/dev/null
grep -q '^own text$' "$SR/CLAUDE.md" && grep -q '^trailing text$' "$SR/CLAUDE.md" \
  && ok "setup: CLAUDE.md text outside the block is kept" || bad "setup CLAUDE keep" "$(cat "$SR/CLAUDE.md")"
eq "setup: CLAUDE.md has one managed block" "$(grep -c 'BEGIN HERMES-HARNESS' "$SR/CLAUDE.md")" 1
! grep -q 'hermes-STALE' "$SR/CLAUDE.md" && ok "setup: stale block content replaced" || bad "setup CLAUDE stale" "still stale"

# --- --check: reports drift, writes nothing ---
out=$(setup --check "$SR"); rc=$?
eq "setup --check: in sync exits 0" "$rc" 0
echo "drift" >> "$SR/AGENTS.md"; rm "$SR/.gitignore"; before=$(digest)
out=$(setup --check "$SR"); rc=$?
eq "setup --check: drift exits 1" "$rc" 1
eq "setup --check: writes nothing" "$(digest)" "$before"
echo "$out" | grep -q '^would update  *AGENTS.md' && echo "$out" | grep -q '^would create  *.gitignore' \
  && ok "setup --check: names each drifted file" || bad "setup check report" "$out"

# --- refusals ---
mkdir -p "$tmp/not-a-repo"
out=$(setup "$tmp/not-a-repo"); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'not a git repository' && ok "setup: non-git dest -> exit 2" || bad "setup non-git" "$rc $out"
out=$(setup "$tmp/missing-dir"); rc=$?
[ $rc -eq 2 ] && ok "setup: missing dest -> exit 2" || bad "setup missing" "$rc $out"
out=$(setup "$ROOT"); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'harness itself' && ok "setup: refuses the harness repo" || bad "setup self" "$rc $out"
out=$(setup); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'usage' && ok "setup: no args -> usage, exit 2" || bad "setup usage" "$rc $out"
out=$("$BIN/hermes-setup" --help 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'AGENTS_LOCAL.md' && ok "setup --help" || bad "setup help" "$rc $out"
