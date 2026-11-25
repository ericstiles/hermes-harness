# Project-Specific Agent Rules (hermes-harness)

`AGENTS.md` holds the general workflow and is identical in every repository
that uses this harness; this repository is its source of truth. This file
holds the rules that only apply here. Where the two conflict, this file wins.

## Shared AGENTS.md

- Edit `AGENTS.md` here, then run `bin/hermes-setup <target-repo>` for each
  target repository (e.g. `bin/hermes-setup ../../organize_music`) and commit
  the result there, so the copies never drift. `bin/hermes-setup --check` shows
  drift without writing. Never put repository-specific rules in `AGENTS.md`.
- Files every target repository gets are listed in `bin/hermes-setup`; it never
  modifies an existing `AGENTS_LOCAL.md`.
- A target repository's own rules (quality gate, stack, environment variables,
  verified library facts) go in that repository's `AGENTS_LOCAL.md`.

## Environment and quality gate

- Bash scripts in `bin/` and `lib/`; the `hermes-review` code is Python >= 3.10
  in `lib/pr_review` with tests in `tests/py`.
- Quality gate (must pass before every commit): `tests/run_tests.sh`. It runs
  the shell tests against a throwaway target repo with stubbed
  `hermes`/`bd`/`docker` (no network, no real agents), ruff with `ruff.toml`,
  and the `tests/py` unit tests via `uv`.

## Editing the harness

- Never edit `bin/hermes-run` or anything it sources while a `hermes-run` loop
  is running (check with `hermes-status`). Bash reads scripts as it executes
  them, so a rewrite mid-run makes the running loop execute the wrong bytes.

## Review nits

- Every review that lists nits gets its own new beads issue, whoever reviewed
  (pr-reviewer, `/code-review`, a human): type task, priority P4 (below the work
  it came from), label `review-nits`, `--deps discovered-from:<the PR's bead>`,
  one line per nit with its `file[:line]`. Never add nits as a comment to an
  existing bead. `.claude/agents/pr-reviewer.md` step 7 does this for its reviews.
