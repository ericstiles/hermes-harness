"""Review-fix issues: the beads ticket that sends a rejected PR back to Hermes (pure).

On a rejection the reviewer files ONE review-fix issue F for the PR. Hermes picks it up
like any ready issue, checks out the PR's existing branch, fixes every point and pushes;
the reviewer then re-reviews the new head and, on merge, closes the ticket and F.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from pr_review.verdict import Problem, Verdict

if TYPE_CHECKING:  # services imports this module
    from pr_review.services import PullRequest

REVIEW_FIX_LABEL = "review-fix"
HUMAN_LABEL = "human"  # `bd human list` shows issues with this label
PR_HUMAN_LABEL = "needs-human"
HIGH_PRIORITY = 1
_SESSION = re.compile(r"^Hermes-Session:\s*(\S+)\s*$", re.MULTILINE)


def fix_title(bead: str, pr_number: int) -> str:
    return f"Review fixes for PR #{pr_number} ({bead})"


def is_fix_for(title: str, pr_number: int) -> bool:
    return re.fullmatch(rf"Review fixes for PR #{pr_number} \(.+\)", title) is not None


def session_id(body: str) -> str | None:
    """The `Hermes-Session: <id>` line Hermes writes in the PR body, if any."""
    found = _SESSION.search(body)
    return found.group(1) if found else None


def fix_priority(wanted: str, ticket_priority: int) -> int:
    """'high' -> P1 (never lowers a P0 ticket); 'same' -> the ticket's own priority."""
    return min(HIGH_PRIORITY, ticket_priority) if wanted == "high" else ticket_priority


def fix_issue_args(
    verdict: Verdict,
    problems: tuple[Problem, ...],
    bead: str,
    pr: PullRequest,
    priority: int,
) -> list[str]:
    """`bd` arguments for the review-fix issue of a rejected PR."""
    branch = pr.branch
    session = session_id(pr.body) or "(none recorded)"
    checklist = (
        "\n".join(
            f"- [ ] `{p.location()}` {p.title}" + (f": {p.detail}" if p.detail else "")
            for p in problems
        )
        or f"- [ ] {verdict.summary or 'See the review comment on the PR.'}"
    )
    acceptance = (
        f"Every checklist item is fixed in new commits on {branch}; the repo's quality gate "
        f"passes; PR #{pr.number} is unchanged apart from those commits."
    )
    body = (
        f"## Problem\nThe reviewer rejected PR #{pr.number} ({pr.url}) for {bead}.\n\n"
        f"{verdict.summary}\n\n## Review checklist\n{checklist}\n\n"
        f"## Where\n- PR: #{pr.number} {pr.url}\n- Branch: `{branch}` (existing; do not "
        f"branch from main)\n- Original ticket: {bead}\n- Hermes-Session: {session}\n\n"
        "## Fix scope\nOnly the checklist above. Do NOT change: anything else in the PR, the "
        f"PR title or its `Bead: {bead}` line.\n\n"
        f"## Base branch\n`{branch}`: `git fetch origin && git checkout -B {branch} "
        f"origin/{branch}`\n\n"
        f"## How\n1. Read the review: `gh pr view {pr.number} --comments`.\n"
        "2. Tests first for each bug (a failing test, then the fix).\n"
        f"3. Commit and `git push origin {branch}`. Do NOT open a new PR. Do NOT force-push.\n"
        f'4. `bd update <this issue> --append-notes "PR: {pr.url}"`. Do not close this '
        f"issue or {bead}: the reviewer closes both when it merges.\n\n"
        f"## Acceptance\n{acceptance}\n\n"
        "## Constraints\nThe repo's AGENTS.md rules; existing tests keep passing.\n\n"
        f"## Dependencies\ndiscovered-from: {bead}\n"
    )
    return [
        "create", fix_title(bead, pr.number),
        "-t", "bug", "-p", str(priority), "-l", REVIEW_FIX_LABEL,
        "--deps", f"discovered-from:{bead}",
        "-d", body, "--acceptance", acceptance, "--silent",
    ]  # fmt: skip


def escalation_note(pr: PullRequest, fix_ids: list[str]) -> str:
    return (
        f"Reviewer rejected PR #{pr.number} again after review-fix {', '.join(fix_ids)}. "
        f"Blocked for a human: read {pr.url}, then fix it yourself, or unblock this issue "
        "and file a clearer review-fix issue, or close the PR."
    )
