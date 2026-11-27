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
 bd ready --exclude-type epic --exclude-label owner-present --sort priority → take the FIRST item
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
        │                              T stays in_progress (needs a human? → RUN_BLOCKED;
        │                              needs another bead? → RUN_REQUEUED, T open again)
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
        ├── does not rebase onto main ──► rebase-fix issue F (labels review-fix +
        │                                 rebase-conflict); NOT a rejection strike
        │                                 (after 3 rebase fixes → human, as below)
        │
        └── 2nd reject of the same T ──► T blocked + label human (`bd human list`),
                                         PR labelled needs-human → the owner decides
```

- Start with `bd prime`. Use `bd` for all tracking; no markdown TODOs.
- **Never replace notes** (`bd update --notes` is blocked: it erases the PR
  link). Only `bd update <id> --append-notes "<line>"`. To tick a checklist
  item, append `- [x] <item>: <evidence>`; never rewrite old lines. Pass
  no `@file` to a bd flag unless `bd <cmd> --help` says it reads files.
  After every bd write, verify with `bd show <id>`; if it did not land, fix it
  or print `RUN_BLOCKED`.
- **No human is present.** These runs are unattended: nobody reads your
  messages until the run is over and nobody will answer a question. Never ask
  a question, offer options, or wait for confirmation. A reply without a tool
  call ENDS the session, so only reply without a tool call when you are done:
  the PR URL is printed (step 4), or you printed `RUN_BLOCKED` or
  `RUN_REQUEUED` (step 5), or
  `NO_READY_WORK`. If you are unsure, decide yourself and note the decision in
  the PR body; if you truly cannot continue, that is step 5 (blocked).
- The git steps in the Beads blocks and in any "Session Completion" section
  (`git pull --rebase`, a bare `git push`) are for interactive sessions. They
  do not apply to these runs: use only the git commands in this workflow.
- Do exactly ONE issue per session:
  1. `bd ready --json --exclude-type epic --exclude-label owner-present --sort priority`
     and take the FIRST item (issues labelled `owner-present` are for a person
     to run). If your prompt gives another pick command, use that one. If your
     prompt says `Work issue <id>`, take that issue instead (`hermes-run` chose
     it). If empty, print `NO_READY_WORK` and stop.
  2. `bd update <id> --claim --json`, then `bd dolt push` (so the host sees the
     claim at once), then `bd show <id>`. If the issue has the label
     `review-fix`, follow "Review-fix issues" below instead of steps 3-4.
  3. `git fetch origin`. If the issue's notes have a `WIP:` line (an earlier run
     ran out of time or crashed and saved its work), read it first. Then:
     - `bd/<id>` exists, in this clone or as `origin/bd/<id>`: continue on it
       with `git switch bd/<id>`, then, if `origin/bd/<id>` exists,
       `git pull --ff-only origin bd/<id>`. Never reset it: it may hold commits
       that were never pushed. If either command fails (for example the two
       copies have diverged), do not commit, reset or push: run
       `bd update <id> --status blocked --append-notes "<the git error>"`,
       print `RUN_BLOCKED`, and stop.
     - It exists in neither place: create it untracked (a branch that tracks
       `main` can push to `main`): `git switch --no-track -c bd/<id> origin/main`.

     Implement, run tests and lint.
     At each milestone (tests written, tests pass) run
     `bd update <id> --append-notes "PROGRESS: <milestone>"`: the harness's time
     limit is extended while files are written, commits made or such notes added.
     Scratch files in `/tmp` do not count.
  4. If tests pass: commit, push with
     `git push -u origin bd/<id>:refs/heads/bd/<id>`, open a PR with `gh pr create`
     (base `main`) titled `<type>(<id>): <summary>` with these lines in the
     body: `Bead: <id>` and `Hermes-Session: <your session id>` (from your
     system prompt). Then `bd update <id> --append-notes "PR: <url>"` and
     verify with `bd show <id>` that the `PR:` line is there. Do NOT
     close the issue: it stays `in_progress` so its dependents stay blocked
     until the PR is merged; the reviewer (`hermes-review`) closes it on merge.
     Print the full PR URL on its own line in your final message.
  5. If you cannot do the issue yet, decide which kind of blocker it is.
     - **Another bead must be finished first** (an existing one, or a bug or
       gap you file as one): requeue, do not block.
       1. No bead for the blocker yet: file it with `bd create` as below, with
          `--deps discovered-from:<id>`.
       2. `bd dep add <id> <blocker>` (`<id>` is your issue; one command per
          blocker). If bd says the dependency `already exists with type` another
          one: `bd dep remove <id> <blocker>`, run the add again, and name the
          old type in the note of step 4. If bd refuses for any other reason (a
          cycle, or the blocker is your issue's parent epic), this is a
          needs-a-human blocker instead.
       3. Leave nothing uncommitted: the next run works in this same clone.
          Delete your scratch files first.
          - Changes but no `bd/<id>` branch yet:
            `git switch --no-track -c bd/<id> origin/main` (your changes come
            along).
          - No `bd/<id>` branch and no changes: go to step 4.
          - On the branch, if `git status --porcelain` lists anything:
            `git add -A && git commit -m "wip(<id>): <summary>"`.
          - Then, if `git log origin/main..bd/<id>` lists commits:
            `git push -u origin bd/<id>:refs/heads/bd/<id>`, and
            `bd update <id> --append-notes "WIP: bd/<id> - <what is done>"`.
          - If it lists none: delete the empty branch
            (`git checkout --detach origin/main && git branch -d bd/<id>`).
       4. `bd update <id> --append-notes "REQUEUED: blocked by <blocker>: <why>"`
          (name the pushed branch, if any; `hermes-run` finds the issue again by
          this line, so start it exactly like that).
       5. `bd unclaim <id>` (status goes back to open), `bd dolt push`, verify
          with `bd show <id>`, and check that `git status --porcelain` prints
          nothing. Then print `RUN_REQUEUED`. Stop. Do not start the blocker:
          `hermes-run` gives it to a later run.
     - **Only a human can unblock it** (unclear requirements, missing access, a
       command the sandbox denies): commit WIP to the branch, push it with
       `git push -u origin bd/<id>:refs/heads/bd/<id>` (on a review-fix issue,
       `git push origin bd/<T>:refs/heads/bd/<T>`), run
       `bd update <id> --status blocked --append-notes "<why>"`, and print
       `RUN_BLOCKED`. Stop. Don't guess at requirements.
  6. If `hermes-run` resumes you to say the time limit was reached or Hermes
     crashed, do only what that message asks (push WIP, append a `WIP:` note,
     `bd dolt push`, print `RUN_WIP_SAVED`). Do not keep implementing.
- **Review-fix issues** (label `review-fix`, created by `hermes-review` when it
  rejects a PR). The issue names the PR number `N`, the branch `bd/<T>` and the
  original issue `T`.
  1. Check out the EXISTING branch without resetting it:
     `git fetch origin && git switch bd/<T> && git pull --ff-only origin bd/<T>`
     (this creates the branch if the clone lacks it, updates an older copy and
     keeps commits that were never pushed). Never branch from main. If it fails
     (for example the two copies have diverged), do not commit, reset or push:
     run `bd update <F> --status blocked --append-notes "<the git error>"`,
     print `RUN_BLOCKED`, and stop.
  2. Read the review: `gh pr view <N> --comments` and the issue's checklist.
  3. If a point can only be fixed by fixing what another open bead B describes
     (`bd list` / `bd search`; e.g. a coverage gap caused by B's bug), fix B
     here too, and mark it so no later run redoes it: `bd update B --claim`,
     then `bd update B --append-notes "Fixed in PR <url> via review-fix <F>"`
     (that exact line; the reviewer closes B when it merges the PR, so do NOT
     close B). Name B in the commit message and in a PR comment
     (`gh pr comment <N> --body "Also fixes B: <why>"`). If B is already
     claimed by someone else, do not touch it: requeue F behind it (step 5,
     "Another bead must be finished first": `<id>` is F, `<blocker>` is B). In
     place of its step 3, commit and push anything uncommitted to `bd/<T>`, never
     delete that branch (`git push origin bd/<T>:refs/heads/bd/<T>`), note `WIP: bd/<T> - <what is done>` on F if you pushed,
     and leave `git status --porcelain` empty. Name B and its assignee in the
     REQUEUED note, and stop.
  4. Fix every point. Tests first for each bug, as in the issue sections below.
     Run tests and lint.
  5. Commit and `git push origin bd/<T>:refs/heads/bd/<T>`. Do NOT open a new PR, do NOT
     force-push, do NOT touch the PR title or the `Bead: <T>` line.
  6. `bd update <F> --append-notes "PR: <url>"`, then verify with `bd show <F>`
     and `bd show <T>` that both still have their `PR:` line. Do NOT close F or T: the
     reviewer closes both when it merges the PR. Print the PR URL on its own
     line.
  7. A point you cannot fix in this PR's scope: file it as a new issue (rules
     below) and say so in a PR comment (`gh pr comment <N>`).
  - **Rebase fixes** (labels `review-fix` and `rebase-conflict`, title
    `Rebase PR #N onto main (T)`): the PR only conflicts with main. After step 1,
    run `git rebase origin/main`, resolve each conflict keeping the intent of
    both sides, then run tests and lint. Push with
    `git push --force-with-lease origin bd/<T>:refs/heads/bd/<T>`: the ONLY case where a
    force-push is allowed, and only to that branch. Change nothing else. Then
    step 6.
- You ARE allowed and expected to create new beads issues. Do not ask first.
  File one with `bd create "<title>" -t bug|task -p <0-4> --deps discovered-from:<id> -d "<self-contained description>" --acceptance "<checks a test can assert>" --silent`
  whenever you:
  - find a bug or gap outside your issue's scope (do not fix it in this PR);
  - resolve a spec conflict by guessing, e.g. an existing test contradicts the
    issue text and you change the test (file it, and say so in the PR body);
  - defer a follow-up, TODO or missing edge case.
  Create at most 3 new issues per run. A new issue does not block your current
  one unless it is a real blocker (step 5); otherwise finish your issue first.
  Never close or edit issues you did not claim.
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
- Never write real host names, IP addresses, usernames or home or library paths
  into notes, PR text, commit messages or files: name the environment variable
  `AGENTS_LOCAL.md` gives for them (e.g. `$PI_HOST`).
- Sync beads before finishing (`bd dolt push`).

### Commits inside the sandbox

The host commit wrappers (for example a local commit-wrapper directory) do
not exist in the container. Use plain `git commit` with a conventional-commit
message (`feat:`, `fix:`, `docs:`, `chore:`, `test:` ...).
