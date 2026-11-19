"""The reviewer's verdict: parse it, add gate results, render comments and debt issues (pure)."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, replace

MARKER_PREFIX = "pr-review:"
REFUSED_PREFIX = "pr-review-refused:"
DEBT_LABEL = "tech-debt"
_FENCE = re.compile(r"```(?:json)?\s*(\{.*\})\s*```", re.DOTALL)
FIX_PRIORITIES = ("high", "same")
PATH_LINE = re.compile(r"^(?P<path>[^:\s]+):(?P<line>\d+):")


@dataclass(frozen=True)
class Problem:
    file: str
    line: int | None
    title: str
    detail: str
    # False: a real problem outside the ticket's scope. It becomes a tech-debt issue and
    # does not block the merge. Mechanical check regressions are always in scope.
    in_scope: bool = True

    def location(self) -> str:
        return self.file if self.line is None else f"{self.file}:{self.line}"


@dataclass(frozen=True)
class Verdict:
    approve: bool
    summary: str
    problems: tuple[Problem, ...]
    # Priority of the review-fix issue: "high" (P1) or "same" (the ticket's priority).
    fix_priority: str = "same"

    def blocking(self) -> tuple[Problem, ...]:
        """In-scope problems: fixed on the PR's branch before it can merge."""
        return tuple(p for p in self.problems if p.in_scope)

    def debt(self) -> tuple[Problem, ...]:
        """Out-of-scope problems: one tech-debt issue each, never blocking."""
        return tuple(p for p in self.problems if not p.in_scope)


def _payload(raw: str) -> dict[str, object]:
    envelope = json.loads(raw)
    structured = envelope.get("structured_output")
    if isinstance(structured, dict):
        return structured
    text = str(envelope.get("result", "")).strip()
    fenced = _FENCE.search(text)
    try:
        payload = json.loads(fenced.group(1) if fenced else text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"reviewer did not return a JSON verdict: {text[:200]!r}") from exc
    if not isinstance(payload, dict):
        raise ValueError("reviewer verdict is not a JSON object")
    return payload


def parse_verdict(raw: str) -> Verdict:
    """Parse `claude -p --output-format json` output into a Verdict."""
    payload = _payload(raw)
    problems = tuple(
        Problem(
            file=str(p.get("file", "")),
            line=int(p["line"]) if p.get("line") not in (None, "") else None,
            title=str(p.get("title", "")).strip(),
            detail=str(p.get("detail", "")).strip(),
            in_scope=p.get("in_scope") is not False,
        )
        for p in payload.get("problems", [])  # type: ignore[union-attr]
    )
    approve = bool(payload.get("approve")) and not any(p.in_scope for p in problems)
    wanted = str(payload.get("fix_priority", "same"))
    priority = wanted if wanted in FIX_PRIORITIES else "same"
    return Verdict(approve, str(payload.get("summary", "")).strip(), problems, priority)


def with_checks(verdict: Verdict, found: list[Problem]) -> Verdict:
    """Add mechanical gate regressions as problems; any of them blocks approval."""
    if not found:
        return verdict
    return replace(verdict, approve=False, problems=verdict.problems + tuple(found))


def review_comment(verdict: Verdict, head_sha: str) -> str:
    """Markdown review comment.

    Only a "changes needed" comment carries the hidden marker that stops the head commit
    being reviewed again; an approval does not, so a merge that fails is retried next pass
    (a merged PR is no longer open, so it is not reviewed twice).
    """
    status = "Approved, merging" if verdict.approve else "Changes needed, not merged"
    marker = [] if verdict.approve else [f"<!-- {MARKER_PREFIX}{head_sha} -->"]
    lines = [*marker, f"**Reviewer agent: {status}**", ""]
    lines.append(verdict.summary or "(no summary)")
    if verdict.problems:
        lines += ["", "Problems:"]
        for p in verdict.problems:
            suffix = f": {p.detail}" if p.detail else ""
            scope = "" if p.in_scope else " _(outside this PR's scope: filed as tech debt)_"
            lines.append(f"- `{p.location()}` {p.title}{suffix}{scope}")
    return "\n".join(lines) + "\n"


def debt_issue_args(problem: Problem, bead: str, pr: int) -> list[str]:
    """`bd` arguments that file one tech-debt issue (all 8 AGENTS.md sections) for a problem."""
    where = problem.location() or "(see detail)"
    acceptance = (
        f"A regression test for '{problem.title}' at {where} fails on the current code and "
        "passes after the fix; the repo's quality gate passes."
    )
    body = (
        f"## Problem\n{problem.title}\n\nWhere: `{where}`\n\n{problem.detail or problem.title}\n\n"
        f"Found by the reviewer agent on PR #{pr} for {bead}.\n\n"
        f"## Repro\nCheck out PR #{pr} (or `main` once merged) and inspect `{where}`; "
        "the review comment on the PR has the observed behaviour.\n\n"
        "## Fix scope\nOnly what is needed to resolve the problem above.\n"
        "Do NOT change: unrelated files, public interfaces not named above, existing tests "
        "(except to add the regression test).\n\n"
        "## Base branch\n`main`\n\n"
        "## Tests first (TDD)\nWrite a regression test that FAILS on the current code for the "
        "reason above, then fix until it passes. Paste the failing output in the PR body.\n\n"
        f"## Acceptance\n{acceptance}\n\n"
        "## Constraints\nThe repo's quality gate and conventions (see AGENTS.md); existing "
        "tests keep passing; conventional commits.\n\n"
        f"## Dependencies\ndiscovered-from: {bead}\n"
    )
    return [
        "create",
        f"Tech debt from PR #{pr}: {problem.title}"[:200],
        "-t",
        "bug",
        "-p",
        "2",
        "-l",
        DEBT_LABEL,
        "--deps",
        f"discovered-from:{bead}",
        "-d",
        body,
        "--acceptance",
        acceptance,
        "--silent",
    ]
