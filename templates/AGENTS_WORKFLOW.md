<!-- Paste into the target repo's AGENTS.md. Hermes reads it inside the sandbox. -->
<!-- Edit the test/lint commands and the commit-wrapper note for the target repo. -->

## Autonomous Beads workflow

Applies to unattended runs started by `hermes-run` (inside the Hermes Docker
sandbox). It is an explicit opt-in to branch, commit, push and open PRs, and
overrides the global "do not commit or push" default for this workflow only.

### Ticket lifecycle

```
 hermes-run (one Hermes session = one issue)
        │
        ▼
 bd ready --exclude-type epic --sort priority → take the FIRST item
        │                                        (empty → NO_READY_WORK)
        ├─────────────── normal issue T ─────────────────┐
        │                                                ▼
        │                              claim T, branch bd/T from origin/main
        │                              tests first → code → tests + lint
        │                              push, open PR #N:
        │                                title  <type>(T): <summary>
        │                                body   Bead: T
        │                                       Hermes-Session: <id>
        │                              notes on T: "PR: <url>"
        │                              T stays in_progress (blocked? → RUN_BLOCKED)
        │                                                │
        └──── review-fix issue F ────┐                   │
                                     ▼                   │
              claim F, check out the EXISTING branch bd/T│
              read `gh pr view N --comments`             │
              fix every point, push new commits to bd/T  │
              (no new PR, no force-push)                 │
              notes on F: "PR: <url>"; F stays in_progress
                                     │                   │
                                     └─────────┬─────────┘
                                               ▼
 hermes-review (host): new head commit on PR #N → checks + local reviewer model
        │
        ├── approve ──► rebase-merge PR #N
        │               close T and every open review-fix issue for PR #N
        │               → T's dependents become ready
        │
        ├── reject ───► comment on PR #N (each problem, file:line)
        │               create review-fix issue F (label review-fix,
        │                 discovered-from T, links PR #N, branch bd/T,
        │                 Hermes-Session, review checklist)
        │               problems outside the PR's scope → separate tech-debt issues
        │               → next hermes-run picks F
        │
        └── 2nd reject of the same T ──► T blocked + label human (`bd human list`),
                                         PR labelled needs-human → the owner decides
```

- Start with `bd prime`. Use `bd` for all tracking; no markdown TODOs.
- **No human is present.** These runs are unattended: nobody reads your
  messages until the run is over and nobody will answer a question. Never ask
  a question, offer options, or wait for confirmation. A reply without a tool
  call ENDS the session, so only reply without a tool call when you are done:
  the PR URL is printed (step 4), or you printed `RUN_BLOCKED` (step 5), or
  `NO_READY_WORK`. If you are unsure, decide yourself and note the decision in
  the PR body; if you truly cannot continue, that is step 5 (blocked).
- Do exactly ONE issue per session:
  1. `bd ready --json --exclude-type epic --sort priority` and take the FIRST
     item. If empty, print `NO_READY_WORK` and stop.
  2. `bd update <id> --claim --json`, then `bd show <id>`. If the issue has the
     label `review-fix`, follow "Review-fix issues" below instead of steps 3-4.
  3. `git fetch origin`, then branch `bd/<id>` from `origin/main`. Implement,
     run tests and lint.
  4. If tests pass: commit, push the branch, open a PR with `gh pr create`
     (base `main`) titled `<type>(<id>): <summary>` with these lines in the
     body: `Bead: <id>` and `Hermes-Session: <your session id>` (from your
     system prompt). Then `bd update <id> --append-notes "PR: <url>"`. Do NOT
     close the issue: it stays `in_progress` so its dependents stay blocked
     until the PR is merged; the reviewer (`hermes-review`) closes it on merge.
     Print the full PR URL on its own line in your final message.
  5. If you hit a blocker: commit WIP to the branch, push it, run
     `bd update <id> --status blocked --append-notes "<why>"`, and print
     `RUN_BLOCKED`. Stop. Don't guess at requirements.
- **Review-fix issues** (label `review-fix`, created by `hermes-review` when it
  rejects a PR). The issue names the PR number `N`, the branch `bd/<T>` and the
  original issue `T`.
  1. `git fetch origin`, then check out the EXISTING branch:
     `git checkout -B bd/<T> origin/bd/<T>`. Never branch from main.
  2. Read the review: `gh pr view <N> --comments` and the issue's checklist.
  3. Fix every point. Tests first for each bug, as in the issue sections below.
     Run tests and lint.
  4. Commit and `git push origin bd/<T>`. Do NOT open a new PR, do NOT
     force-push, do NOT touch the PR title or the `Bead: <T>` line.
  5. `bd update <F> --append-notes "PR: <url>"`. Do NOT close F or T: the
     reviewer closes both when it merges the PR. Print the PR URL on its own
     line.
  6. A point you cannot fix in this PR's scope: file it as a new issue (rules
     below) and say so in a PR comment (`gh pr comment <N>`).
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
