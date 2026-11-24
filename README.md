# hermes-harness

Host-side tooling for running the Hermes local agent over a repo's beads queue,
and for Claude Code to supervise it. One copy serves every repo: the scripts act
on the **current directory's git repo** (or `HERMES_REPO`), never on their own folder.

| Command | What it does |
|---|---|
| `hermes-run [N]` | Work up to N beads issues, one Hermes run each; classify every run; release stale claims after a timeout |
| `hermes-setup` | Copy the baseline files (shared `AGENTS.md`, `AGENTS_LOCAL.md` stub, `CLAUDE.md` block, `.gitignore` lines) into a target repo; `--check` reports drift. Never touches an existing `AGENTS_LOCAL.md` |
| `hermes-launch` | Start `hermes-run` in a herdr tab (tmux fallback); refuses if a run is active or `GH_TOKEN` is unset; warns (never pulls) when the harness checkout is behind `origin/main`, off `main` or dirty (`HERMES_FRESHNESS_CHECK=0` skips, `HERMES_FRESHNESS_TIMEOUT` 10s) |
| `hermes-status [--tests]` | Read-only snapshot: origin/main, PRs, beads, active run, newest log |
| `hermes-supervise [log]` | Read-only diagnosis: `CLASS=`, `ACTION=`, `NEXT=` |
| `hermes-pull-check [--no-fetch\|--list]` | Read-only: is `git pull --ff-only` of the harness safe now? `PULL=UP_TO_DATE\|SAFE\|WAIT\|CANNOT`; WAIT when a `hermes-run` loop from this checkout loads a file the pull changes |
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
     every open `review-fix` issue for the PR (`bd close --force`), `bd dolt push`. It also
     closes any open bead whose notes have a line `Fixed in PR <this PR's url>`: Hermes
     adds that line when a review-fix needs a fix another open bead already describes.
   - **First rejection** → a comment listing each problem, and ONE `review-fix` issue F
     (checklist of the in-scope problems, PR link, branch `bd/T`, `Hermes-Session`). Its
     priority is P1 when the reviewer says `fix_priority: high`, else T's own priority.
     Hermes picks F up next, pushes fixes to the same branch, and notes the PR on F; the
     reviewer waits for that note before re-reviewing.
   - **Does not rebase onto main** → not a rejection: a comment plus a rebase-only issue
     `Rebase PR #N onto main (T)` (labels `review-fix`, `rebase-conflict`; T's priority).
     Hermes rebases `bd/T` and pushes with `--force-with-lease`. These issues never count
     toward the second rejection; a conflict after 3 of them escalates as below.
   - **Second rejection** (of the code) → T is set `blocked` with the `human` label
     (`bd human list`), the PR gets the `needs-human` label, and a macOS notification fires once.
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
2. Baseline files: `hermes-setup <target-repo>`. Re-run it after every harness update;
   `hermes-setup --check <target-repo>` changes nothing and exits 1 if the repo has drifted.
   It never commits, pushes or deletes; review and commit the result in the target repo.

   | File | What `hermes-setup` does |
   |------|--------------------------|
   | `AGENTS.md` | always an identical copy of this repo's `AGENTS.md` (shared workflow) |
   | `AGENTS_LOCAL.md` | created from `templates/AGENTS_LOCAL.md` only if missing; an existing one is never touched. Fill in the quality gate, stack and repo rules here |
   | `CLAUDE.md` | a managed block between `HERMES-HARNESS` markers: `@AGENTS_LOCAL.md` plus `templates/CLAUDE_SNIPPET.md`; your text outside it is kept |
   | `.gitignore` | adds `logs/` (run logs, lock and relaunch counters) and `.envrc.local` if missing |
3. direnv files, from the commented samples:
   - `.envrc` (committed, no secrets) from [`templates/envrc.sample`](templates/envrc.sample):
     it loads `.envrc.local` and lists every optional setting, all commented out.
   - `.envrc.local` (git-ignored) from [`templates/envrc.local.sample`](templates/envrc.local.sample):
     `GH_TOKEN` (required; fine-grained, that repo only), optional `REVIEWER_GH_TOKEN` and
     the per-machine opt-ins.

   Then `direnv allow`.
4. Optional: allow `Bash(hermes-status:*)`, `Bash(hermes-supervise:*)`, `Bash(hermes-launch:*)`
   in `~/.claude/settings.json`.
5. Sandbox image with that project's language tools (Hermes `terminal.docker_image`).

```bash
hermes-setup /path/to/target-repo
cd /path/to/target-repo
hermes-launch --dry-run && hermes-launch
```

## Env
Each setting, with its default and what it does, is in [`templates/envrc.sample`](templates/envrc.sample)
(per repo) and [`templates/envrc.local.sample`](templates/envrc.local.sample) (secrets, per machine).

`GITHUB_REPO` (default: parsed from `origin`), `RUN_TIMEOUT` (90m), `HERMES_EXTEND` (20m, 0 = hard limit), `HERMES_EXTEND_CAP` (180m),
`HERMES_RETRY_ON_TIMEOUT`, `HERMES_WRAPUP_TIMEOUT` (15m, 0 disables), `HERMES_UNCLAIM_ON_TIMEOUT`, `HERMES_ARGS`,
`HERMES_REPO`, `HERMES_LOG_DIR`, `HERMES_TS_MIN_GAP` (2s), `HERMES_STALL_WARN` (10m; 0 = off), `HERMES_CONTEXT_TIMEOUT` (30s, the session export behind the `CONTEXT:` usage line), `HERMES_BASELINE_TIMEOUT` (15s, `hermes prompt-size` behind the `CONTEXT: baseline` line), `HERMES_BEADS_TIMEOUT` (15s, each `bd stats`/`bd ready` behind the `BEADS:` lines), `HERMES_CONTEXT_WINDOW` (context window for the usage line; looked up when unset, never guessed), `HERMES_TEST_CMD` (for `hermes-status --tests`),
`REVIEWER_GH_TOKEN`, `REVIEWER_AGENT`, `REVIEWER_MODEL`, `OLLAMA_HOST_URL`,
`HERMES_REVIEW_PYTHON` (for `hermes-review`).

The local reviewer and `hermes-run` share one Ollama. With the same model they share one
loaded copy; a different `REVIEWER_MODEL` needs memory for both.

## Notes guard hook (install once per machine)
`lib/hooks/bd_notes_guard.py` is a Hermes `pre_tool_call` hook. It blocks any terminal command
that runs `bd update ... --notes` (which replaces a bead's whole notes field, PR link included)
and tells the agent to use `--append-notes` and check with `bd show`. In `hermes-run` runs it
also blocks `bd update <id> --append-notes` on a bead the run has not claimed: claims
(`bd update <id> --claim`) are recorded in `$HERMES_HARNESS_CLAIMS`, a file `hermes-run` empties
per loop iteration (incident 2026-11-24: the PR link went to `b8p.25` instead of `225`).
Everything else passes.
Hermes runs hooks on the host, not in the sandbox; a broken hook fails open.

**Only in harness runs.** Hermes has one config per Hermes home (`~/.hermes`), not per repo, so
a hook there fires for every Hermes session on the machine. The guard therefore acts only when
`HERMES_HARNESS_RUN=1`, which `hermes-run` exports (Hermes passes its environment to hooks).
Interactive Hermes and anything else you use Hermes for are unaffected, in any repo.
To guard every Hermes session in one repo too, and to approve hooks without a separate step,
put both in that repo's `.envrc.local` (git-ignored; direnv loads it):
```bash
export HERMES_HARNESS_RUN=1    # the guard acts in this repo, interactive sessions included
export HERMES_ACCEPT_HOOKS=1   # each Hermes started here approves config hooks (all of them)
```
With `HERMES_ACCEPT_HOOKS=1` the first `hermes chat` there records the approval, and re-approves
after the script changes. It accepts every hook in `~/.hermes/config.yaml`, not only this one.
(Per-project Hermes settings are possible only through a separate Hermes home: a profile,
`hermes -p <name>`, or `HERMES_HOME`. That duplicates config, memory and skills; not used here.)

Add to `~/.hermes/config.yaml`:
```yaml
hooks:
  pre_tool_call:
    - matcher: terminal
      command: /absolute/path/to/hermes-harness/lib/hooks/bd_notes_guard.py
      timeout: 10
```
Then approve it once (unattended runs skip hooks that are not approved; not needed where
`.envrc.local` sets `HERMES_ACCEPT_HOOKS=1`), and check it.
Hermes records approvals only when an agent command starts (`chat`, `cron tick`, ...), not
on `hermes hooks ...`; `cron tick` is the cheap one (it also runs any due cron jobs):
```bash
HERMES_ACCEPT_HOOKS=1 hermes cron tick     # records the approval
hermes hooks doctor                        # must show it allowlisted
echo '{"args":{"command":"bd update x --notes y"}}' > /tmp/p.json
hermes hooks test pre_tool_call --payload-file /tmp/p.json   # must print a block
```
Editing the script changes its mtime; `hermes hooks doctor` then says to re-approve.

## Starting fresh (`--clean`)
Hermes runs its commands in one persistent Docker container and clones the repo into
`/workspace/<name>` there, so a run that stops mid-issue leaves its uncommitted work behind for
the next run. `hermes-launch --clean` (or `hermes-run --clean [N]`) resets that clone to
`origin/main` before the first run: `git checkout -f -B main origin/main && git clean -fd`.
Anything uncommitted (tracked changes and new files) is first saved on the host to
`logs/sandbox-dirty-<stamp>.patch`; restore it with `git apply` in a checkout of the branch it
came from (the message names it). The container is found by `terminal.docker_image`; if there is
not exactly one, nothing is reset and no run starts. The container itself, other repos'
workspaces and ignored files such as `.venv` are left alone.

## Run logs
Each run writes two files in `logs/`:
- `run-<stamp>.log`: the raw Hermes output plus a final `RUN_RESULT=` line. The classifier, `hermes-status` and `hermes-supervise` read only this file.
- `run-<stamp>.timed.txt`: the same output with `[HH:MM:SS]` on every line, a `(+38s)` line after any silence of `HERMES_TS_MIN_GAP` seconds or more (time since the previous output), a `no output for 10m (last: HH:MM:SS)` line after each `HERMES_STALL_WARN` of silence, and the run's `RUN_TIME`. The terminal shows this version. It is deliberately not a `*.log`, so nothing mistakes it for a run log.

After each run `hermes-run` prints `RUN_TIME start= end= elapsed= issue=`; at the end, `RUN_TIME total= ... runs=N` before `FINAL_RESULT=`.

## Limits
- One run at a time across all repos (one local model). The per-repo lock stops two runs in the same repo; the active-process check stops runs in different repos.
- Classes: OK_DONE QUEUE_EMPTY BLOCKED TIMEOUT MODEL_API_ERROR SANDBOX_DOWN AUTH_ERROR BEADS_SYNC_ERROR TURN_LIMIT AGENT_STOPPED AGENT_CRASHED NOTES_LOST UNKNOWN (`lib/classify.sh`; patterns anchored to real log formats, with regression fixtures in `tests/fixtures`).
- STOP_REASON: after each run `hermes-run` looks up the session's last `Turn ended:` line in `${HERMES_HOME:-~/.hermes}/logs/agent.log` (tail only, matched by session id, read-only) and writes `STOP_REASON: <reason> api_calls=<n>/<max>` to the run log before `RUN_RESULT`, e.g. `text_response(finish_reason=stop) api_calls=67/150`. `unknown` when there is no session id or no matching line (`lib/stop_reason.sh`; `HERMES_AGENT_LOG` overrides the path).
- TURN_LIMIT: no PR or sentinel, and the session used its whole tool-call budget (`STOP_REASON` says `max_iterations_reached`, `budget_exhausted` or `api_calls` n/n, or Hermes printed "Reached maximum iterations"). A "continue" or a longer timeout would hit the same limit, so `hermes-run` resumes the session only for the WIP wrap-up (as for TIMEOUT), releases the claim and stops; `hermes-supervise` says to split the issue.
- AGENT_STOPPED: the session ended cleanly but with no PR URL and no `RUN_BLOCKED`/`NO_READY_WORK`, typically because the model asked a question nobody will answer (in `-q` mode a reply without a tool call ends the session). `hermes-run` first asks GitHub whether `bd/<issue>` already has a PR (then it is OK_DONE), otherwise resumes the same session once with a "no human is present, continue" prompt (`HERMES_RESUME_ON_STOP=0` disables). The run prompt and `templates/AGENTS_WORKFLOW.md` both tell the agent no human is present.
- Time limit (`lib/watchdog.py`, in place of `timeout(1)`): at `RUN_TIMEOUT` the watchdog reads the raw log written since its last check. If that interval shows progress (a file written or patched outside `/tmp`, a `git commit`, or a `bd update <id> --append-notes "PROGRESS: ..."`, which the template asks for at milestones), the run gets `HERMES_EXTEND` (20m) more, checked again at the new limit, never past `HERMES_EXTEND_CAP` (180m) in total. Otherwise Hermes' process group is stopped (SIGTERM, SIGKILL after 30s) and the run is TIMEOUT (exit 124). Progress is judged over the whole interval, never "no output for N minutes": the log is silent while the model thinks, and one call can take 11 minutes. Each decision is a `WATCHDOG: EXTENDED / NO_PROGRESS / CAP_REACHED / TIME_LIMIT` line in both logs; `hermes-supervise` shows the last one. Hermes itself cannot be told anything mid-run in `-q` mode, so the harness watches instead. The wrap-up below is never extended.
- TIMEOUT and AGENT_CRASHED (Hermes died on an exception: a traceback, no session footer, exit not 124/130): neither leaves a PR, so `hermes-run` saves the work before releasing the claim. A killed or crashed Hermes prints no `Session:` footer, but its messages are already in Hermes' store, so `hermes-run` finds the session with `hermes sessions list` (the harness session that started with the run) and resumes it for `HERMES_WRAPUP_TIMEOUT` (15m) with a wrap-up prompt: push WIP to `bd/<id>`, `bd update <id> --append-notes "WIP: ..."`, `bd dolt push`, print `RUN_WIP_SAVED`. The wrap-up has its own log ending `WRAPUP_OF=<killed run's log>` and the killed run's `RUN_RESULT`; without `RUN_WIP_SAVED` it warns. The next run reads the `WIP:` note and continues on `origin/bd/<id>` (template step 3). `HERMES_RETRY_ON_TIMEOUT=1` resumes the killed session (it keeps its context and claim) instead of starting over, and wraps up only if the retry times out too. `hermes-supervise` reports `WIP_SAVED=yes|no`, and recommends splitting the issue at the first timeout when the run wrote no project file and made no commit (`lib/wrapup.sh`).
- NOTES_LOST: after an OK_DONE run, `hermes-run` pulls beads and checks the PR's bead (its `Bead:` line, else the claimed issue): it must be `in_progress` with the PR URL in its notes, as `hermes-review` requires; a review-fix issue the run claimed must have the URL too. A missing PR line on an `in_progress` bead is appended by the harness itself (`NOTES_FIX: ...`, then `bd dolt push`), but only when the PR's head branch is `bd/<Bead>`. Any other bead updated during the run whose notes now hold the PR URL is a stray (`NOTES_CHECK: <id> has <url> in notes but is not the PR's bead ...`), except a side bead with the exact `Fixed in PR <url> via review-fix <F>` line; strays are never edited. If anything is still wrong, the log gets `NOTES_CHECK: <id> missing <url> in notes` (or `status ...`, or the stray line), the run becomes NOTES_LOST and the loop stops; `hermes-supervise` prints the repair. If `gh`/`bd` cannot answer it warns and keeps OK_DONE (`lib/notes_check.sh`).

## Tests
`tests/run_tests.sh` builds a throwaway target repo with stubbed `hermes`/`bd`/`docker`. No network, no real agents.
It also runs the `hermes-review` unit tests in `tests/py` with pytest via `uv` (skipped if `uv` is missing).
