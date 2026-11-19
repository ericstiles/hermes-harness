"""CLI: review open Hermes PRs once, or keep watching.

hermes-review [--dry-run] [--skip-agent] [--watch SECONDS] [--pr N]   (bin/hermes-review)
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from pathlib import Path

from pr_review import local_agent
from pr_review.checks import ConfigError, load_config
from pr_review.review import Context, review_pr
from pr_review.services import Beads, GitHub
from pr_review.shell import CommandError, run
from pr_review.verdict import MARKER_PREFIX

log = logging.getLogger("pr_review")
# lib/pr_review/__main__.py -> harness root
HARNESS_HOME = Path(os.environ.get("HARNESS_HOME") or Path(__file__).resolve().parents[2])


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="hermes-review", description="Review and merge Hermes PRs.")
    p.add_argument("--dry-run", action="store_true", help="print actions; change nothing")
    p.add_argument("--skip-agent", action="store_true", help="no model call (needs --dry-run)")
    p.add_argument("--watch", type=int, default=0, metavar="SECONDS", help="poll interval")
    p.add_argument("--pr", type=int, default=None, help="only this PR number")
    p.add_argument(
        "--agent",
        choices=("ollama", "claude"),
        default=os.environ.get("REVIEWER_AGENT", "ollama"),
        help="reviewer: local Ollama model (default) or claude -p",
    )
    p.add_argument(
        "--model",
        default=os.environ.get("REVIEWER_MODEL"),
        help="reviewer model (default for ollama: Hermes's model.default)",
    )
    return p


def resolve_model(agent_name: str, explicit: str | None) -> str | None:
    """--model / REVIEWER_MODEL, else (local) the model Hermes is configured to use."""
    if explicit:
        return explicit
    return local_agent.hermes_model() if agent_name == "ollama" else None


def run_pass(ctx: Context, only: int | None) -> int:
    """One pass over the open bd/* PRs; returns the number of PRs that hit an error.

    An idle pass (no PR with an unreviewed head commit) costs one `gh pr list` plus one
    `gh pr view` per open PR; beads are pulled only when there is something to review.
    A dry run does not pull beads (it reads the local copy). It still fetches git refs and
    makes throwaway worktrees, which are scratch space and removed afterwards.
    """
    prs = [p for p in ctx.github.open_bead_prs() if only is None or p.number == only]
    todo = [p for p in prs if not ctx.github.has_marker(p, f"<!-- {MARKER_PREFIX}{p.head_sha} -->")]
    log.info("%d open bd/* PR(s), %d with an unreviewed head", len(prs), len(todo))
    if not todo:
        return 0  # idle: one gh call, no beads sync, no model
    if not ctx.dry_run:
        ctx.beads.pull()
    errors = 0
    for pr in todo:
        try:
            log.info("PR #%s: %s", pr.number, review_pr(ctx, pr))
        except (CommandError, ValueError) as exc:
            errors += 1
            log.error("PR #%s: %s", pr.number, exc)
    return errors


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stdout)
    if args.skip_agent and not args.dry_run:
        log.error("--skip-agent is only allowed with --dry-run")
        return 2
    model = resolve_model(args.agent, args.model)
    if args.agent == "ollama" and not model and not args.skip_agent:
        log.error("no local model: set REVIEWER_MODEL or model.default in ~/.hermes/config.yaml")
        return 2
    repo = Path(run(["git", "rev-parse", "--show-toplevel"]).out.strip() or ".")
    try:
        config = load_config(repo, HARNESS_HOME)
    except ConfigError as exc:
        log.error("%s", exc)
        return 2
    log.info("repo %s | reviewer: %s %s | checks: %s | instructions: %s", repo, args.agent,
             model or "(default)", ", ".join(c.name for c in config.checks) or "none",
             config.instructions)  # fmt: skip
    ctx = Context(
        run=run,
        repo=repo,
        github=GitHub(run, os.environ.get("REVIEWER_GH_TOKEN") or None),
        beads=Beads(run),
        config=config,
        dry_run=args.dry_run,
        skip_agent=args.skip_agent,
        agent=args.agent,
        model=model,
        ollama_host=os.environ.get("OLLAMA_HOST_URL", local_agent.DEFAULT_HOST),
    )
    while True:
        try:
            errors = run_pass(ctx, args.pr)
        except CommandError as exc:
            log.error("pass failed: %s", exc)
            errors = 1
        if args.watch <= 0:
            return 1 if errors else 0
        time.sleep(args.watch)


if __name__ == "__main__":
    sys.exit(main())
