<!-- Paste into the target repo's CLAUDE.md (Claude Code only; Hermes does not read it). -->
## Supervising the Hermes agent

Tools come from the hermes-harness repo (on PATH). Run them from this repo.

- To check Hermes status (latest run, PRs, beads state, active runs) ALWAYS run
  `hermes-status` (add `--tests` to also test `origin/main` in a throwaway
  worktree). Do not hand-assemble git/gh/bd/log commands for this.
- To diagnose a failed or finished run run `hermes-supervise`. It prints
  `CLASS=`, `ACTION=` and `NEXT=`. Follow `ACTION=AUTO_RELAUNCH` by running the
  `NEXT=` command without asking. Stop and ask the user only for `ASK_HUMAN`
  (AUTH_ERROR, BLOCKED, UNKNOWN, a second timeout on the same issue, or the 3
  relaunches/issue/day limit). Never force-push, merge PRs or commit unless the
  user asks.
- Start runs only via `hermes-launch` (opens the herdr tab `hermes-run`;
  refuses if a run is active or `GH_TOKEN` is unset).
- While a run is active, re-check no sooner than every 20-30 minutes.
- When you file beads for Hermes, follow the issue template and standing rules
  in `AGENTS.md` ("Every issue you create follows this template").
