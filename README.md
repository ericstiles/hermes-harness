# hermes-harness

Host-side tooling for running the Hermes local agent over a repo's beads queue,
and for Claude Code to supervise it. One copy serves every repo: the scripts act
on the **current directory's git repo** (or `HERMES_REPO`), never on their own folder.

| Command | What it does |
|---|---|
| `hermes-run [N]` | Work up to N beads issues, one Hermes run each; classify every run; release stale claims after a timeout |
| `hermes-launch` | Start `hermes-run` in a herdr tab (tmux fallback); refuses if a run is active or `GH_TOKEN` is unset |
| `hermes-status [--tests]` | Read-only snapshot: origin/main, PRs, beads, active run, newest log |
| `hermes-supervise [log]` | Read-only diagnosis: `CLASS=`, `ACTION=`, `NEXT=` |

## Install (once)

```bash
# ~/.zshrc (or your dot-files repo)
export HERMES_HARNESS_HOME="$HOME/repo/harnesses/hermes-harness"
export PATH="$HERMES_HARNESS_HOME/bin:$PATH"
```
Symlinks onto PATH also work. Check with `which hermes-launch`.

## Per target repo
1. `.beads/` with a Dolt remote (`bd init`), so the sandbox can pull and push issues.
2. `AGENTS.md`: paste `templates/AGENTS_WORKFLOW.md` and fill in test/lint commands.
3. `.envrc.local` (git-ignored): `export GH_TOKEN=...` (fine-grained, that repo only); `direnv allow`.
4. Git-ignore `logs/` (run logs, lock and relaunch counters live there).
5. Optional: paste `templates/CLAUDE_SNIPPET.md` into `CLAUDE.md`, and allow
   `Bash(hermes-status:*)`, `Bash(hermes-supervise:*)`, `Bash(hermes-launch:*)` in
   `~/.claude/settings.json`.
6. Sandbox image with that project's language tools (Hermes `terminal.docker_image`).

```bash
cd /path/to/target-repo
hermes-launch --dry-run && hermes-launch
```

## Env
`GITHUB_REPO` (default: parsed from `origin`), `RUN_TIMEOUT` (90m),
`HERMES_RETRY_ON_TIMEOUT`, `HERMES_UNCLAIM_ON_TIMEOUT`, `HERMES_ARGS`,
`HERMES_REPO`, `HERMES_LOG_DIR`, `HERMES_TEST_CMD` (for `hermes-status --tests`).

## Limits
- One run at a time across all repos (one local model). The per-repo lock stops two runs in the same repo; the active-process check stops runs in different repos.
- Classes: OK_DONE QUEUE_EMPTY BLOCKED TIMEOUT MODEL_API_ERROR SANDBOX_DOWN AUTH_ERROR BEADS_SYNC_ERROR UNKNOWN (`lib/classify.sh`; patterns anchored to real log formats, with regression fixtures in `tests/fixtures`).

## Tests
`tests/run_tests.sh` builds a throwaway target repo with stubbed `hermes`/`bd`/`docker`. No network, no real agents.
