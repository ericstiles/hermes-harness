#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad/eq, $tmp $ROOT).
# templates/envrc.sample (a target repo's committed .envrc) and templates/envrc.local.sample
# (its git-ignored .envrc.local) document every setting the harness reads (bead c75).
ENVRC="$ROOT/templates/envrc.sample"
ENVRC_LOCAL="$ROOT/templates/envrc.local.sample"

# Environment variables the harness reads but that do not belong in either sample, with why.
ENVRC_EXCLUDED='
HERMES_REPO|names the target repo from outside it; inside the repo the current directory does
HERMES_HOME|Hermes'"'"' own setting (its config home), not the harness'"'"'s
OLLAMA_HOST|Ollama'"'"'s own setting; the context line falls back to it (OLLAMA_HOST_URL is the harness'"'"'s)
GIT_SSH|git'"'"'s own setting; the launch freshness check only keeps it
GIT_SSH_COMMAND|git'"'"'s own setting; the launch freshness check only keeps it
TMPDIR|the system temp directory
PYTHONPATH|set by the harness for its own Python
HARNESS_HOME|set by bin/hermes-review for its Python; worked out from the script path
HERDR_WORKSPACE_ID|set by herdr inside its workspaces
HH_TS_FAKE_CLOCK|test hook for lib/tsfilter.py
HH_AGENT_LOG_TAIL|test hook for lib/stop_reason.sh
MODEL|hermes-run internal: read from ~/.hermes/config.yaml
PROVIDER|hermes-run internal: read from ~/.hermes/config.yaml
HERMES_HARNESS_CLAIMS|hermes-run internal: per-iteration claims file for lib/hooks/bd_notes_guard.py
IMAGE|hermes-run internal: read from ~/.hermes/config.yaml
TO|hermes-launch internal: its --timeout value
WORKED|hermes-run internal: the beads this loop worked
'
# Read by Hermes itself, not the harness: allowed in the local sample only.
ENVRC_HERMES_OWN='HERMES_ACCEPT_HOOKS'

# Every variable the harness reads: ${VAR:-..}/${VAR-..}/${VAR:?..}/${VAR:+..} in shell,
# environ.get("VAR")/environ["VAR"]/getenv("VAR") and *_VAR = "VAR" constants in Python.
envrc_read_vars() {
  {
    grep -rhoE '\$\{[A-Z][A-Z0-9_]*:?[-=?+]' "$ROOT/bin" "$ROOT/lib" | sed -E 's/^\$\{([A-Z0-9_]+).*/\1/'
    grep -rhoE '(environ\.get\(|environ\[|getenv\()"[A-Z][A-Z0-9_]*"|_VAR = "[A-Z][A-Z0-9_]*"' \
      "$ROOT/bin" "$ROOT/lib" | grep -oE '"[A-Z0-9_]+"' | tr -d '"'
  } | sort -u
}
# Variables a sample sets or documents: `export VAR=` lines, commented out or not.
envrc_sample_vars() { grep -hoE '^#? *export [A-Z][A-Z0-9_]*=' "$@" | sed -E 's/.*export ([A-Z0-9_]+)=.*/\1/' | sort -u; }

if [ -f "$ENVRC" ] && [ -f "$ENVRC_LOCAL" ]; then
  ok "envrc samples: templates/envrc.sample and templates/envrc.local.sample exist"
  documented=$(envrc_sample_vars "$ENVRC" "$ENVRC_LOCAL")
  excluded=$(printf '%s\n' "$ENVRC_EXCLUDED" | sed -n 's/^\([A-Z0-9_]*\)|.*/\1/p' | sort -u)
  read_vars=$(envrc_read_vars)
  missing=$(comm -23 <(printf '%s\n' "$read_vars") <(printf '%s\n%s\n' "$documented" "$excluded" | sort -u) | tr '\n' ' ')
  eq "envrc samples: every variable the harness reads is in a sample or excluded with a reason" "$missing" ""
  stale=$(comm -23 <(printf '%s\n' "$excluded") <(printf '%s\n' "$read_vars") | tr '\n' ' ')
  eq "envrc samples: every exclusion is still read by the harness" "$stale" ""
  both=$(comm -12 <(printf '%s\n' "$excluded") <(printf '%s\n' "$documented") | tr '\n' ' ')
  eq "envrc samples: no variable is both documented and excluded" "$both" ""
  unknown=$(comm -23 <(printf '%s\n' "$documented") <(printf '%s\n%s\n' "$read_vars" "$ENVRC_HERMES_OWN" | sort -u) | tr '\n' ' ')
  eq "envrc samples: every documented variable is one the harness (or Hermes) reads" "$unknown" ""

  # .envrc (committed): loads .envrc.local, holds no secrets and no harness-run switches
  grep -qE '^source_env_if_exists \.envrc\.local$' "$ENVRC" \
    && ok "envrc samples: .envrc loads .envrc.local" || bad "envrc loads local" "$(head -n 20 "$ENVRC")"
  in_committed=$(envrc_sample_vars "$ENVRC" | grep -xE 'GH_TOKEN|REVIEWER_GH_TOKEN|HERMES_HARNESS_RUN|HERMES_ACCEPT_HOOKS' | tr '\n' ' ')
  eq "envrc samples: .envrc sets no token, HERMES_HARNESS_RUN or HERMES_ACCEPT_HOOKS" "$in_committed" ""
  grep -n 'HERMES_HARNESS_RUN' "$ENVRC" | grep -vq '^[0-9]*:#' \
    && bad "envrc HERMES_HARNESS_RUN only in comments" "$(grep -n HERMES_HARNESS_RUN "$ENVRC")" \
    || ok "envrc samples: .envrc mentions HERMES_HARNESS_RUN only in comments"
  # copied as is, the .envrc sample changes nothing: every setting is commented out
  set_vars=$(cd "$tmp" && env -i PATH="$PATH" bash -c 'source_env_if_exists() { :; }; . "$1" && env' _ "$ENVRC" \
    | sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' | grep -xvE 'PATH|PWD|SHLVL|_|OLDPWD' | tr '\n' ' ')
  eq "envrc samples: .envrc as shipped sets nothing (every setting commented out)" "$set_vars" ""

  # .envrc.local (git-ignored): GH_TOKEN required, placeholders only
  grep -qE '^export GH_TOKEN=' "$ENVRC_LOCAL" \
    && ok "envrc samples: .envrc.local sets GH_TOKEN" || bad "envrc.local GH_TOKEN" "$(cat "$ENVRC_LOCAL")"
  if grep -qE '(ghp_|gho_|ghs_|github_pat_)[A-Za-z0-9_]{20,}' "$ENVRC" "$ENVRC_LOCAL"; then
    bad "envrc samples: no real-looking token" "$(grep -nE '(ghp_|gho_|ghs_|github_pat_)[A-Za-z0-9_]{20,}' "$ENVRC" "$ENVRC_LOCAL")"
  else ok "envrc samples: no real-looking token"; fi
  for f in "$ENVRC" "$ENVRC_LOCAL"; do
    bash -n "$f" 2>/dev/null && ok "envrc samples: $(basename "$f") is valid bash" || bad "bash -n $f" "$(bash -n "$f" 2>&1)"
  done
  # every setting line carries a comment saying what it does
  bare=$(grep -hnE '^#? *export [A-Z][A-Z0-9_]*=' "$ENVRC" "$ENVRC_LOCAL" | grep -v ' # ' | tr '\n' ' ')
  eq "envrc samples: every setting line has a comment" "$bare" ""
else
  bad "envrc samples: templates/envrc.sample and templates/envrc.local.sample exist" "missing"
fi
for f in envrc.sample envrc.local.sample; do
  grep -q "templates/$f" "$ROOT/README.md" && ok "envrc samples: README links templates/$f" || bad "README links $f" "no link"
done
