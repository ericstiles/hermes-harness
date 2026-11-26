"""Review one Hermes PR end to end: identify, gate, ask the reviewer, then act."""

from __future__ import annotations

import hashlib
import logging
from collections.abc import Callable
from contextlib import ExitStack
from dataclasses import dataclass, field, replace
from pathlib import Path

from pr_review import agent, fixes, local_agent, overlap
from pr_review.checks import ReviewConfig, new_problems
from pr_review.gate import GateOutput, RebaseConflict, checkout, fetch, run_gate
from pr_review.meta import BeadMismatch, resolve_bead
from pr_review.pr_env import pr_environment
from pr_review.progress import step
from pr_review.services import REFUSED_NOTE, Beads, GitHub, PullRequest, desktop_notify
from pr_review.shell import Runner, must, run
from pr_review.verdict import (
    MARKER_PREFIX,
    REFUSED_PREFIX,
    Problem,
    Verdict,
    debt_issue_args,
    parse_verdict,
    rebase_verdict,
    review_comment,
    with_checks,
)

log = logging.getLogger("pr_review")
TAIL_LINES = 15
Notify = Callable[[str, str], None]
DEFAULT_PRIORITY = 2


def _desktop(title: str, text: str) -> None:
    desktop_notify(run, title, text)


@dataclass
class Context:
    run: Runner
    repo: Path
    github: GitHub
    beads: Beads
    config: ReviewConfig | None = None
    dry_run: bool = False
    skip_agent: bool = False
    agent: str = "ollama"  # ollama (local, default) | claude
    model: str | None = None
    ollama_host: str = local_agent.DEFAULT_HOST
    post: local_agent.Post = local_agent.http_post
    notify: Notify = _desktop
    _baseline: dict[str, GateOutput] = field(default_factory=dict)

    def baseline(self) -> GateOutput:
        """Check output on origin/main, computed once per main commit."""
        sha = must(self.run(["git", "rev-parse", "origin/main"], cwd=self.repo), "rev-parse").out
        if sha not in self._baseline:
            with (
                step("checks on origin/main (baseline, once per main commit)"),
                checkout(self.run, self.repo, "origin/main", rebase_onto_main=False) as tree,
            ):
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
        ctx.github.post_review(pr, f"{marker}\n{REFUSED_NOTE} {reason}\n", False)
        # Same once-per-head-and-reason rule as the comment: a refused PR no longer sits
        # unnoticed while it is re-checked every pass (gbd).
        ctx.notify("hermes-review: PR refused", f"PR #{pr.number}: {reason}")
    return "refused"


def refused_lines(github: GitHub) -> list[str]:
    """One line per open bd/* PR that hermes-review refused at its current head commit."""
    lines = []
    for pr in github.open_bead_prs():
        reason = github.refusal_at_head(pr)
        if reason is not None:
            lines.append(f"PR #{pr.number} ({pr.branch}) refused at {pr.head_sha[:7]}: {reason}")
    return lines


def _checks_report(ctx: Context, base: GateOutput, gate: GateOutput) -> tuple[list[Problem], str]:
    found: list[Problem] = []
    lines = []
    for check in ctx.config.checks:
        problems = new_problems(check, base.get(check.name, ""), gate.get(check.name, ""))
        found += problems
        tail = "\n".join(gate.get(check.name, "").strip().splitlines()[-TAIL_LINES:])
        lines.append(f"### {check.name}: {len(problems)} new problem(s)\n{tail}")
    return found, "\n\n".join(lines) or "No mechanical checks configured for this repo."


def _ask(ctx: Context, tree: Path, bead: str, pr: PullRequest, diff: str, report: str) -> str:
    """Raw verdict from the configured reviewer: the local Ollama model, or claude -p."""
    prompt = agent.build_prompt(
        ctx.config.instructions.read_text(encoding="utf-8"),
        ctx.beads.text(bead), pr.body, diff, report,
    )  # fmt: skip
    label = f"PR #{pr.number}: asking {ctx.model or ctx.agent}"
    if ctx.agent == "claude":
        with step(label, f"(prompt {len(prompt)} chars)"):
            return agent.ask(ctx.run, tree, prompt, ctx.model)
    files = local_agent.changed_files(ctx.run, tree)
    prompt += "\n\n## Changed files (full text after the PR)\n" + files
    with step(label, f"(prompt {len(prompt)} chars)"):
        return local_agent.ask(ctx.post, ctx.ollama_host, ctx.model or "", prompt)


def with_related(ctx: Context, pr: PullRequest, bead: str, verdict: Verdict, diff: str) -> Verdict:
    """Add a note for each other open bead that names a file the PR changes (bead 9cv).
    Only verdict.related changes; a failure is logged and the verdict returned as is."""
    try:
        skip = {bead, *(str(r["id"]) for r in ctx.beads.review_fixes(pr.number))}
        skip |= set(ctx.beads.fixed_in(pr))  # already linked: they close with the PR
        notes = overlap.related_notes(overlap.changed_paths(diff), ctx.beads.open_issues(), skip)
    except Exception as exc:  # a heuristic note must never break a review
        log.warning("PR #%s: related-beads check failed: %s: %s", pr.number,
                    type(exc).__name__, exc)  # fmt: skip
        return verdict
    if notes:
        log.info("PR #%s: %d other open bead(s) name files it changes", pr.number, len(notes))
    return replace(verdict, related=notes)


def _verdict(ctx: Context, pr: PullRequest, bead: str, ref: str) -> Verdict:
    base = ctx.baseline()
    tag = f"PR #{pr.number}"
    try:
        with ExitStack() as stack:
            with step(f"{tag}: rebase onto origin/main"):
                tree = stack.enter_context(checkout(ctx.run, ctx.repo, ref, rebase_onto_main=True))
            with step(f"{tag}: preparing the PR's environment"):
                env = pr_environment(ctx.run, tree, ctx.config.checks, ctx.config.python)
            gate_output: GateOutput = {}
            if env.problem is None:
                with step(f"{tag}: running checks"):
                    gate_output = run_gate(ctx.run, tree, env.checks)
            found, report = _checks_report(ctx, base, gate_output)
            if env.problem is not None:  # one environment problem instead of per-test failures
                found = [env.problem, *found]
                report = f"### environment: {env.problem.title}\n{env.problem.detail}\n\n{report}"
            log.info("%s: checks found %d new problem(s)", tag, len(found))
            with step(f"{tag}: building the diff"):
                diff = must(
                    ctx.run(["git", "diff", "origin/main...HEAD"], cwd=tree), "git diff"
                ).out
            if ctx.skip_agent:
                verdict = Verdict(False, "Reviewer agent skipped (--skip-agent).", ())
            else:
                verdict = parse_verdict(_ask(ctx, tree, bead, pr, diff, report))
            verdict = with_related(ctx, pr, bead, with_checks(verdict, found), diff)
            log.info(
                "%s: reviewer verdict: %s, %d problem(s)",
                tag, "approve" if verdict.approve else "changes needed", len(verdict.problems),
            )  # fmt: skip
            return verdict
    except RebaseConflict as exc:
        log.info("%s: does not rebase onto origin/main", tag)
        return rebase_verdict(str(exc), exc.files)


def _open(rows: list[dict[str, object]]) -> list[str]:
    return [str(r["id"]) for r in rows if r.get("status") != "closed"]


def _file_debt(ctx: Context, verdict: Verdict, bead: str, pr: PullRequest) -> list[str]:
    return [ctx.beads.create(debt_issue_args(p, bead, pr.number)) for p in verdict.debt()]


def _merge(ctx: Context, pr: PullRequest, bead: str, verdict: Verdict, fix_ids: list[str]) -> str:
    # Beads a review-fix also solved (notes line `Fixed in PR <url>`) close with the PR.
    to_close = list(dict.fromkeys([bead, *fix_ids, *ctx.beads.fixed_in(pr)]))
    _say(ctx, pr, f"approve, rebase-merge, close {' '.join(to_close)}")
    if not ctx.dry_run:
        ctx.github.post_review(pr, review_comment(verdict, pr.head_sha), approve=True)
        ctx.github.merge(pr)
        _file_debt(ctx, verdict, bead, pr)
        for issue in to_close:
            ctx.beads.close(issue, pr)
        # A merge can finish an epic's last child: close such epics (and parents that become
        # eligible) now, so a done epic never blocks the queue (xw2.1). One push carries both.
        ctx.beads.close_eligible_epics(pr)
        ctx.beads.push()
    return "merged"


def _escalate(
    ctx: Context, pr: PullRequest, bead: str, verdict: Verdict, fix_ids: list[str]
) -> str:
    """Second rejection (or too many conflicts): stop the loop and hand T to a human."""
    conflict = verdict.rebase_conflict
    why = (
        f"still conflicts with main after {len(fix_ids)} rebase fixes"
        if conflict
        else "rejected twice"
    )
    _say(ctx, pr, f"{why} ({', '.join(fix_ids)}): block {bead} for a human")
    if not ctx.dry_run:
        ctx.github.post_review(pr, review_comment(verdict, pr.head_sha), approve=False)
        _file_debt(ctx, verdict, bead, pr)
        ctx.beads.escalate(bead, fixes.escalation_note(pr, fix_ids, conflict=conflict))
        ctx.github.add_label(pr, fixes.PR_HUMAN_LABEL)
        ctx.notify("hermes-review: needs you", f"PR #{pr.number} ({bead}) {why}")
        ctx.beads.push()
    return "escalated"


def _send_rebase(
    ctx: Context, pr: PullRequest, bead: str, info: dict[str, object], verdict: Verdict
) -> str:
    """Mechanical conflict with main: a rebase-only fix issue, never a rejection strike."""
    priority = int(info.get("priority", DEFAULT_PRIORITY))  # type: ignore[call-overload]
    _say(ctx, pr, f"does not rebase onto main: rebase-fix P{priority} (not a rejection)")
    if not ctx.dry_run:
        ctx.github.post_review(pr, review_comment(verdict, pr.head_sha), approve=False)
        detail = verdict.problems[0].detail if verdict.problems else ""
        fix = ctx.beads.create(
            fixes.rebase_issue_args(bead, pr, detail, priority, verdict.conflict_files)
        )
        ctx.beads.note(bead, f"PR #{pr.number} conflicts with main; rebase-fix {fix}")
        ctx.beads.push()
    return "rebase-needed"


def _send_back(
    ctx: Context, pr: PullRequest, bead: str, info: dict[str, object], verdict: Verdict
) -> str:
    """First rejection: one review-fix issue for Hermes, tech debt for out-of-scope problems."""
    priority = fixes.fix_priority(verdict.fix_priority, int(info.get("priority", DEFAULT_PRIORITY)))  # type: ignore[call-overload]
    _say(
        ctx,
        pr,
        f"changes needed: review-fix P{priority}, {len(verdict.debt())} tech-debt",
    )
    for problem in verdict.problems:
        _say(ctx, pr, f"  - {problem.location()} {problem.title}")
    if not ctx.dry_run:
        ctx.github.post_review(pr, review_comment(verdict, pr.head_sha), approve=False)
        args = fixes.fix_issue_args(verdict, verdict.blocking(), bead, pr, priority)
        fix = ctx.beads.create(args)
        debt = _file_debt(ctx, verdict, bead, pr)
        ctx.beads.note(
            bead,
            f"Review of PR #{pr.number}: changes needed; review-fix {fix}; tech-debt {debt}",
        )
        ctx.beads.push()
    return "changes-needed"


def _act(
    ctx: Context, pr: PullRequest, bead: str, info: dict[str, object], verdict: Verdict
) -> str:
    previous = ctx.beads.review_fixes(pr.number)
    if verdict.approve:
        return _merge(ctx, pr, bead, verdict, _open(previous))
    rebases = [str(r["id"]) for r in previous if fixes.is_rebase_fix(r)]
    strikes = [str(r["id"]) for r in previous if not fixes.is_rebase_fix(r)]
    if verdict.rebase_conflict:
        if len(rebases) >= fixes.MAX_REBASE_FIXES:
            return _escalate(ctx, pr, bead, verdict, rebases)
        return _send_rebase(ctx, pr, bead, info, verdict)
    if strikes:
        return _escalate(ctx, pr, bead, verdict, strikes)
    return _send_back(ctx, pr, bead, info, verdict)


def _unfinished_fixes(ctx: Context, pr: PullRequest) -> list[str]:
    """Open review-fix issues Hermes has not finished (no PR link in their notes yet)."""
    ids = _open(ctx.beads.review_fixes(pr.number))
    return [i for i in ids if pr.url not in str(ctx.beads.show(i).get("notes") or "")]


def review_pr(ctx: Context, pr: PullRequest) -> str:
    """Review one PR; returns refused | skipped | waiting | escalated | merged |
    changes-needed | rebase-needed."""
    if ctx.github.has_marker(pr, f"<!-- {MARKER_PREFIX}{pr.head_sha} -->"):
        return "skipped"
    try:
        bead = resolve_bead(pr.branch, pr.title, pr.body)
    except BeadMismatch as exc:
        return _refuse(ctx, pr, f"cannot identify the bead: {exc}")
    info = ctx.beads.show(bead)
    if info.get("status") == "blocked" and fixes.HUMAN_LABEL in (info.get("labels") or []):  # type: ignore[operator]
        return "escalated"  # a human owns it now; stay quiet
    if info.get("status") != "in_progress" or pr.url not in str(info.get("notes") or ""):
        return _refuse(ctx, pr, f"{bead} is not in_progress with this PR's link in its notes")
    unfinished = _unfinished_fixes(ctx, pr)
    if unfinished:
        _say(ctx, pr, f"waiting: Hermes has not finished {', '.join(unfinished)}")
        return "waiting"
    _say(ctx, pr, f"reviewing {bead}")
    ref = fetch(ctx.run, ctx.repo, pr.number)
    return _act(ctx, pr, bead, info, _verdict(ctx, pr, bead, ref))
