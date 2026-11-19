"""Review one Hermes PR end to end: identify, gate, ask the reviewer, then act."""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass, field
from pathlib import Path

from pr_review import agent
from pr_review.checks import ReviewConfig, new_problems
from pr_review.gate import GateOutput, RebaseConflict, checkout, fetch, run_gate
from pr_review.meta import BeadMismatch, resolve_bead
from pr_review.services import Beads, GitHub, PullRequest
from pr_review.shell import Runner, must
from pr_review.verdict import (
    MARKER_PREFIX,
    REFUSED_PREFIX,
    Problem,
    Verdict,
    debt_issue_args,
    parse_verdict,
    review_comment,
    with_checks,
)

log = logging.getLogger("pr_review")
TAIL_LINES = 15


@dataclass
class Context:
    run: Runner
    repo: Path
    github: GitHub
    beads: Beads
    config: ReviewConfig | None = None
    dry_run: bool = False
    skip_agent: bool = False
    model: str | None = None
    _baseline: dict[str, GateOutput] = field(default_factory=dict)

    def baseline(self) -> GateOutput:
        """Check output on origin/main, computed once per main commit."""
        sha = must(self.run(["git", "rev-parse", "origin/main"], cwd=self.repo), "rev-parse").out
        if sha not in self._baseline:
            with checkout(self.run, self.repo, "origin/main", rebase_onto_main=False) as tree:
                self._baseline[sha] = run_gate(self.run, tree, self.config.checks)
        return self._baseline[sha]


def _say(ctx: Context, pr: PullRequest, action: str) -> None:
    log.info("%sPR #%s: %s", "[dry-run] " if ctx.dry_run else "", pr.number, action)


def _refuse(ctx: Context, pr: PullRequest, reason: str) -> str:
    """Say once (per head commit and reason) why the PR can't be handled; re-checked each pass."""
    _say(ctx, pr, f"not reviewing: {reason}")
    digest = hashlib.sha1(reason.encode()).hexdigest()[:10]
    marker = f"<!-- {REFUSED_PREFIX}{pr.head_sha}:{digest} -->"
    if not ctx.dry_run and not ctx.github.has_marker(pr, marker):
        ctx.github.post_review(pr, f"{marker}\n**Reviewer agent: not reviewed.** {reason}\n", False)
    return "refused"


def _checks_report(ctx: Context, base: GateOutput, gate: GateOutput) -> tuple[list[Problem], str]:
    found: list[Problem] = []
    lines = []
    for check in ctx.config.checks:
        problems = new_problems(check, base.get(check.name, ""), gate.get(check.name, ""))
        found += problems
        tail = "\n".join(gate.get(check.name, "").strip().splitlines()[-TAIL_LINES:])
        lines.append(f"### {check.name}: {len(problems)} new problem(s)\n{tail}")
    return found, "\n\n".join(lines) or "No mechanical checks configured for this repo."


def _verdict(ctx: Context, pr: PullRequest, bead: str, ref: str) -> Verdict:
    base = ctx.baseline()
    try:
        with checkout(ctx.run, ctx.repo, ref, rebase_onto_main=True) as tree:
            found, report = _checks_report(ctx, base, run_gate(ctx.run, tree, ctx.config.checks))
            diff = must(ctx.run(["git", "diff", "origin/main...HEAD"], cwd=tree), "git diff").out
            if ctx.skip_agent:
                verdict = Verdict(False, "Reviewer agent skipped (--skip-agent).", ())
            else:
                prompt = agent.build_prompt(
                    ctx.config.instructions.read_text(encoding="utf-8"),
                    ctx.beads.text(bead), pr.body, diff, report,
                )  # fmt: skip
                verdict = parse_verdict(agent.ask(ctx.run, tree, prompt, ctx.model))
            return with_checks(verdict, found)
    except RebaseConflict as exc:
        problem = Problem("", None, "Does not rebase cleanly onto main", str(exc))
        return Verdict(False, "Rebase onto origin/main failed.", (problem,))


def _act(ctx: Context, pr: PullRequest, bead: str, verdict: Verdict) -> str:
    comment = review_comment(verdict, pr.head_sha)
    if verdict.approve:
        _say(ctx, pr, f"approve, rebase-merge, close {bead}")
        if not ctx.dry_run:
            ctx.github.post_review(pr, comment, approve=True)
            ctx.github.merge(pr)
            ctx.beads.close(bead, pr)
            ctx.beads.push()
        return "merged"
    _say(ctx, pr, f"changes needed, {len(verdict.problems)} tech-debt issue(s)")
    for problem in verdict.problems:
        _say(ctx, pr, f"  - {problem.location()} {problem.title}")
    if not ctx.dry_run:
        ctx.github.post_review(pr, comment, approve=False)
        ids = [ctx.beads.create(debt_issue_args(p, bead, pr.number)) for p in verdict.problems]
        ctx.beads.note(bead, f"Review of PR #{pr.number}: changes needed; tech-debt {ids}")
        ctx.beads.push()
    return "changes-needed"


def review_pr(ctx: Context, pr: PullRequest) -> str:
    """Review one PR; returns refused | skipped | merged | changes-needed."""
    if ctx.github.has_marker(pr, f"<!-- {MARKER_PREFIX}{pr.head_sha} -->"):
        return "skipped"
    try:
        bead = resolve_bead(pr.branch, pr.title, pr.body)
    except BeadMismatch as exc:
        return _refuse(ctx, pr, f"cannot identify the bead: {exc}")
    info = ctx.beads.show(bead)
    if info.get("status") != "in_progress" or pr.url not in str(info.get("notes") or ""):
        return _refuse(ctx, pr, f"{bead} is not in_progress with this PR's link in its notes")
    _say(ctx, pr, f"reviewing {bead}")
    ref = fetch(ctx.run, ctx.repo, pr.number)
    return _act(ctx, pr, bead, _verdict(ctx, pr, bead, ref))
