# Project-Specific Agent Rules (hermes-harness)

`AGENTS.md` holds the general workflow and is identical in every repository
that uses this harness; this repository is its source of truth. This file
holds the rules that only apply here. Where the two conflict, this file wins.

## Shared AGENTS.md

- Edit `AGENTS.md` here, then copy it unchanged to each target repository
  (e.g. `cp AGENTS.md ../../organize_music/AGENTS.md`) in the same change, so
  the copies never drift. Never put repository-specific rules in it.
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
