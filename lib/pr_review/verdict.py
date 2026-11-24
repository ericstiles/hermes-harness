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
    # True: the PR does not rebase onto main. Not a code rejection: it never counts
    # toward the two-strike escalation (see review._act).
    rebase_conflict: bool = False
    # Notes about other open beads that name a file this PR changes (overlap.py, bead
    # 9cv). Shown in the review comment only: never blocking, never filed or closed.
    related: tuple[str, ...] = ()

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
    if verdict.related:
        lines += [
            "",
            "Other open beads that name files this PR changes (not blocking; if this PR also "
            "fixes one, link them as AGENTS.md, Review-fix issues, step 3 says):",
        ]
        lines += [f"- {note}" for note in verdict.related]
    return "\n".join(lines) + "\n"


# The AGENTS.md issue template (description `-d`, `--design`, `--acceptance`): every bead
# hermes-review files fills each section (bead c0i).
ISSUE_SECTIONS = (
    "Goal", "Why", "Current state", "Repro", "In scope", "Expected to modify",
    "Out of scope / Forbidden", "Base branch", "Tests first",
)  # fmt: skip
DESIGN_SECTIONS = ("Approach", "Invariants", "Edge cases", "Produces for downstream")
GATE_CHECK = "[ ] the quality gate from AGENTS_LOCAL.md passes"
DIFF_CHECK = (
    "[ ] git diff --stat shows only the Expected-to-modify paths (or the PR body explains "
    "each other one)"
)


def template_text(names: tuple[str, ...], text: dict[str, str]) -> str:
    """`## <name>` sections in template order; every name must be filled, no others."""
    missing = [n for n in names if not text.get(n, "").strip()]
    unknown = sorted(set(text) - set(names))
    if missing or unknown:
        raise ValueError(f"issue template: missing {missing}, unknown {unknown}")
    return "\n\n".join(f"## {n}\n{text[n].strip()}" for n in names) + "\n"


def debt_issue_args(problem: Problem, bead: str, pr: int) -> list[str]:
    """`bd` arguments that file one tech-debt issue (the AGENTS.md template) for a problem."""
    where = problem.location() or "(see detail)"
    detail = problem.detail or problem.title
    body = template_text(ISSUE_SECTIONS, {
        "Goal": f"Fix: {problem.title} (at `{where}`).",
        "Why": f"The reviewer agent found this on PR #{pr} for {bead}, outside that PR's "
               "scope, so it was filed as tech debt instead of blocking the merge.",
        "Current state": f"`{where}`: {detail}\n\nThe review comment on PR #{pr} has the "
                         "observed behavior.",
        "Repro": "N/A: the reviewer found this by reading the code; the regression test "
                 "under Tests first is the repro.",
        "In scope": f"Only what resolves the problem above, at `{where}`.",
        "Expected to modify": f"`{problem.file or where}` and the test that covers it.",
        "Out of scope / Forbidden": "Unrelated files, public interfaces not named above, and "
                                    "existing tests (except to add the regression test). "
                                    "Anything larger needs its own bead.",
        "Base branch": "`main`",
        "Tests first": "Write a regression test that FAILS on the current code for the reason "
                       "above, then fix until it passes. Name it in the PR body and paste the "
                       "failing output from before the fix.",
    })  # fmt: skip
    design = template_text(DESIGN_SECTIONS, {
        "Approach": f"Keep the fix local to `{where}`, reusing the helpers already there.",
        "Invariants": "Existing tests keep passing.",
        "Edge cases": "N/A: none known beyond the problem above; the review comment may name "
                      "more.",
        "Produces for downstream": "N/A: a local fix with no new interface.",
    })  # fmt: skip
    acceptance = "\n".join((
        f"[ ] a regression test for '{problem.title}' at {where} fails on the current code "
        "and passes after the fix",
        GATE_CHECK,
        DIFF_CHECK,
    ))  # fmt: skip
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
        "--design",
        design,
        "--acceptance",
        acceptance,
        "--silent",
    ]
