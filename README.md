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
| `hermes-review [--dry-run] [--watch N]` | Reviewer agent: review each open `bd/*` PR, rebase-merge and close its bead, or comment and file `tech-debt` beads |

## Reviewer agent (`hermes-review`)

Runs on the host next to `hermes-run`. For each open, non-draft `bd/<id>` PR:

1. **Identify:** branch `bd/<id>`, title `type(<id>):` and body `Bead: <id>` must agree, and
   the bead must be `in_progress` with the PR link in its notes. Otherwise it comments once
   and re-checks on the next pass.
2. **Check:** rebases the PR onto `origin/main` in a throwaway worktree and runs the repo's
   checks there and on `main`; only problems the PR adds count.
3. **Review:** a **local** model reviews the diff against the ticket, using
   `templates/REVIEWER_AGENT.md` or the repo's `docs/REVIEWER_AGENT.md`. By default it is the
   Ollama model Hermes uses (`model.default` in `~/.hermes/config.yaml`; override with
   `--model` / `REVIEWER_MODEL`). It gets the instructions, ticket, PR description, check
   results, diff and the full text of the changed files, has no tools, and must answer with
   the JSON verdict (Ollama `format` schema). `--agent claude` uses `claude -p` instead
   (read-only Read/Grep/Glob, run outside the PR checkout so the PR's `CLAUDE.md` is never
   loaded).
4. **Act** (the loop is drawn in `templates/AGENTS_WORKFLOW.md`, "Ticket lifecycle"):
   - **Approve** → `gh pr merge --rebase --match-head-commit`, then close the ticket T and
     every open `review-fix` issue for the PR (`bd close --force`), `bd dolt push`.
   - **First rejection** → a comment listing each problem, and ONE `review-fix` issue F
     (checklist of the in-scope problems, PR link, branch `bd/T`, `Hermes-Session`). Its
     priority is P1 when the reviewer says `fix_priority: high`, else T's own priority.
     Hermes picks F up next, pushes fixes to the same branch, and notes the PR on F; the
     reviewer waits for that note before re-reviewing.
   - **Second rejection** → T is set `blocked` with the `human` label (`bd human list`),
     the PR gets the `needs-human` label, and a macOS notification fires once.
   - Problems the reviewer marks out of scope never block: each becomes a `tech-debt` issue.

A hidden `<!-- pr-review:<sha> -->` marker makes it review each head commit once.

**Running it next to Hermes:** `cd <target repo> && hermes-review --watch 120` in its own
herdr/tmux tab. Between passes it sleeps; an idle pass is one `gh pr list` plus one
`gh pr view` per open PR, with no beads sync and no model call.

**Human escalations:** you are told by a desktop notification, the `needs-human` PR label
and `bd human list`. Then fix the PR yourself, or unblock T and file a clearer review-fix
issue, or close the PR.

**Checks** come from `hermes-review.json` at the target repo root (optional):

```json
{"checks": [{"name": "pytest", "cmd": ["{python}", "-m", "pytest", "-q"], "parser": "pytest"},
            {"name": "lint", "cmd": ["npm", "run", "lint"], "parser": "lines"}],
 "instructions": "docs/REVIEWER_AGENT.md"}
```

`{python}` is the repo's `.venv/bin/python` (else `python3`). Parsers: `pytest`, `ruff`
(`--output-format concise`), `ruff-format`, `lines` (any new output line). Without the
file, a repo with `pyproject.toml` gets pytest + ruff check + ruff format.

**Approvals:** GitHub refuses an approval from the account that opened the PR. Set
`REVIEWER_GH_TOKEN` to a token of a separate identity (machine user or GitHub App) to
approve / request changes; without it the agent records its review as a comment. Branch
protection that requires one approval then makes the reviewer a real gate.

**Trust:** it runs the PR's checks on the host, outside the Hermes sandbox.

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
`HERMES_REPO`, `HERMES_LOG_DIR`, `HERMES_TS_MIN_GAP` (2s), `HERMES_TEST_CMD` (for `hermes-status --tests`),
`REVIEWER_GH_TOKEN`, `REVIEWER_AGENT`, `REVIEWER_MODEL`, `OLLAMA_HOST_URL`,
`HERMES_REVIEW_PYTHON` (for `hermes-review`).

The local reviewer and `hermes-run` share one Ollama. With the same model they share one
loaded copy; a different `REVIEWER_MODEL` needs memory for both.

## Run logs
Each run writes two files in `logs/`:
- `run-<stamp>.log`: the raw Hermes output plus a final `RUN_RESULT=` line. The classifier, `hermes-status` and `hermes-supervise` read only this file.
- `run-<stamp>.timed.txt`: the same output with `[HH:MM:SS]` on every line, a `(+38s)` line after any silence of `HERMES_TS_MIN_GAP` seconds or more (time since the previous output), and the run's `RUN_TIME`. The terminal shows this version. It is deliberately not a `*.log`, so nothing mistakes it for a run log.

After each run `hermes-run` prints `RUN_TIME start= end= elapsed= issue=`; at the end, `RUN_TIME total= ... runs=N` before `FINAL_RESULT=`.

## Limits
- One run at a time across all repos (one local model). The per-repo lock stops two runs in the same repo; the active-process check stops runs in different repos.
- Classes: OK_DONE QUEUE_EMPTY BLOCKED TIMEOUT MODEL_API_ERROR SANDBOX_DOWN AUTH_ERROR BEADS_SYNC_ERROR UNKNOWN (`lib/classify.sh`; patterns anchored to real log formats, with regression fixtures in `tests/fixtures`).

## Tests
`tests/run_tests.sh` builds a throwaway target repo with stubbed `hermes`/`bd`/`docker`. No network, no real agents.
It also runs the `hermes-review` unit tests in `tests/py` with pytest via `uv` (skipped if `uv` is missing).
