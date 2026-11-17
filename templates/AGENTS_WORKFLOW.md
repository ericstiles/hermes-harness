<!-- Paste into the target repo's AGENTS.md. Hermes reads it inside the sandbox. -->
<!-- Edit the test/lint commands and the commit-wrapper note for the target repo. -->

## Autonomous Beads workflow

Applies to unattended runs started by `run-beads.sh` (inside the Hermes Docker
sandbox). It is an explicit opt-in to branch, commit, push and open PRs, and
overrides the global "do not commit or push" default for this workflow only.

- Start with `bd prime`. Use `bd` for all tracking; no markdown TODOs.
- Do exactly ONE issue per session:
  1. `bd ready --json`. If empty, print `NO_READY_WORK` and stop.
  2. `bd update <id> --claim --json`, then `bd show <id>`.
  3. Branch `bd/<id>` from latest main. Implement, run tests and lint.
  4. If tests pass: commit, push the branch, open a PR with `gh pr create`,
     `bd close <id> --reason "<summary + PR link>" --json`.
  5. If you hit a blocker: commit WIP to the branch, push it, run
     `bd update <id> --status blocked --append-notes "<why>"`, and print
     `RUN_BLOCKED`. Stop. Don't guess at requirements.
- You ARE allowed and expected to create new beads issues. Do not ask first.
  File one with `bd create "<title>" -t bug|task -p <0-4> --deps discovered-from:<id> -d "<self-contained description>" --acceptance "<checks a test can assert>" --silent`
  whenever you:
  - find a bug or gap outside your issue's scope (do not fix it in this PR);
  - resolve a spec conflict by guessing, e.g. an existing test contradicts the
    issue text and you change the test (file it, and say so in the PR body);
  - defer a follow-up, TODO or missing edge case.
  Create at most 3 new issues per run. New issues do not block your current
  PR; finish your issue first. Never close or edit issues you did not claim.
  List the new ids in the PR body and in your final message. Before creating,
  run `bd list --all` and do not file a duplicate.

  **Every issue you create must contain these sections** (a later agent sees
  only the issue text plus this file, so nothing may be implied):
  1. **Problem**: what is wrong or missing, and where (file and function).
  2. **Repro** (bugs): the exact command(s) or a short script, with the
     observed output and the expected output. No repro, no issue.
  3. **Fix scope**: what to change, and a "Do NOT change" list. It must fit one
     PR in one run; if it does not, split it into several issues.
  4. **Base branch**: `main`, or the exact branch/PR it must be based on.
  5. **Tests first (TDD, mandatory)**: name each regression test to write
     (file and test function name). The implementer must write these first,
     run them and see each FAIL on the current code for the stated reason,
     then implement until they PASS. The PR body must list the test names and
     paste the failing output from before the fix. Do not weaken or delete an
     existing test to make it pass; if an existing test contradicts the issue,
     say which one and file it per the spec-conflict rule above.
  6. **Acceptance** (`--acceptance`): checks a test can assert (exact status
     codes, exact output, exact exit codes), one test per check.
  7. **Constraints**: stack and dependency limits, files not to touch, coverage
     and test commands (for example `<your test command>`), existing tests must
     keep passing, and conventional commit messages.
  8. **Dependencies**: `--deps blocked-by:<id>` for anything that must land
     first; only `discovered-from:<id>` for issues you found while working.
  Set priority by impact: data loss or security is P1, wrong behavior is P2,
  polish or docs is P3.
- Never push to main, never merge, never edit CI/secrets config.
- Sync beads before finishing (`bd dolt push`).

### Commits inside the sandbox

The host commit wrappers (for example a local commit-wrapper directory) do
not exist in the container. Use plain `git commit` with a conventional-commit
message (`feat:`, `fix:`, `docs:`, `chore:`, `test:` ...).
