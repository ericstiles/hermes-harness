"""Review-fix issues: the beads ticket that sends a rejected PR back to Hermes (pure).

On a rejection the reviewer files ONE review-fix issue F for the PR. Hermes picks it up
like any ready issue, checks out the PR's existing branch, fixes every point and pushes;
the reviewer then re-reviews the new head and, on merge, closes the ticket and F.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from pr_review.verdict import (
    DESIGN_SECTIONS,
    DIFF_CHECK,
    GATE_CHECK,
    ISSUE_SECTIONS,
    Problem,
    Verdict,
    template_text,
)

if TYPE_CHECKING:  # services imports this module
    from pr_review.services import PullRequest

REVIEW_FIX_LABEL = "review-fix"
HUMAN_LABEL = "human"  # `bd human list` shows issues with this label
PR_HUMAN_LABEL = "needs-human"
REBASE_LABEL = "rebase-conflict"
HIGH_PRIORITY = 1
# Rebase-only fixes allowed per PR before a further conflict goes to a human.
MAX_REBASE_FIXES = 3
_SESSION = re.compile(r"^Hermes-Session:\s*(\S+)\s*$", re.MULTILINE)
_REBASE_TITLE = "Rebase PR #{n} onto main ({bead})"


FIXED_IN_PREFIX = "Fixed in PR "


def fixed_in_note(pr_url: str, fix_id: str) -> str:
    """The note Hermes adds to another open bead B that a review-fix PR also solves."""
    return f"{FIXED_IN_PREFIX}{pr_url} via review-fix {fix_id}"


def is_fixed_in(notes: str, pr_url: str) -> bool:
    """True when a notes line starts with `Fixed in PR <pr_url>` (exact URL, not a prefix)."""
    line = re.compile(rf"^{re.escape(FIXED_IN_PREFIX + pr_url)}(\s|$)", re.MULTILINE)
    return line.search(notes) is not None


def fix_title(bead: str, pr_number: int) -> str:
    return f"Review fixes for PR #{pr_number} ({bead})"


def rebase_title(bead: str, pr_number: int) -> str:
    return _REBASE_TITLE.format(n=pr_number, bead=bead)


def is_fix_for(title: str, pr_number: int) -> bool:
    """A review-fix or rebase-fix issue filed for PR #pr_number."""
    pattern = rf"(Review fixes for PR #{pr_number}|Rebase PR #{pr_number} onto main) \(.+\)"
    return re.fullmatch(pattern, title) is not None


def is_rebase_fix(row: dict[str, object]) -> bool:
    """A rebase-only fix (mechanical conflict), which is not a rejection strike."""
    return str(row.get("title", "")).startswith("Rebase PR #")


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
    files = sorted({p.file for p in problems if p.file})
    modify = ", ".join(f"`{f}`" for f in files) if files else "The files the review names"
    body = template_text(ISSUE_SECTIONS, {
        "Goal": f"Fix every point of the reviewer's checklist for PR #{pr.number} ({bead}) so "
                "it can be merged.",
        "Why": f"The reviewer rejected PR #{pr.number} ({pr.url}) for {bead}: "
               f"{verdict.summary or 'see the review comment on the PR.'}",
        "Current state": f"- PR: #{pr.number} {pr.url}\n- Branch: `{branch}` (existing; do not "
                         f"branch from main)\n- Original ticket: {bead}\n- Hermes-Session: "
                         f"{session}\n\nReview checklist:\n{checklist}",
        "Repro": f"N/A: the review comment (`gh pr view {pr.number} --comments`) gives the "
                 "observed behavior for each checklist item.",
        "In scope": "Only the checklist above. If a point needs a fix that another open bead "
                    "describes, follow AGENTS.md (Review-fix issues, step 3): claim it and note "
                    f"`{fixed_in_note(pr.url, '<this issue>')}` on it.",
        "Expected to modify": f"{modify}, and their tests.",
        "Out of scope / Forbidden": "Anything else in the PR, the PR title or its "
                                    f"`Bead: {bead}` line. Do NOT open a new PR. Do NOT "
                                    "force-push.",
        "Base branch": f"`{branch}`: `git fetch origin && git checkout -B {branch} "
                       f"origin/{branch}`",
        "Tests first": "For each bug in the checklist, a test that FAILS on the branch for that "
                       "reason, then the fix. Name the tests and paste the failing output in "
                       "a PR comment.",
    })  # fmt: skip
    design = template_text(DESIGN_SECTIONS, {
        "Approach": f"1. Read the review: `gh pr view {pr.number} --comments`.\n"
                    "2. Tests first for each bug (a failing test, then the fix).\n"
                    f"3. Commit and `git push origin {branch}`.\n"
                    f'4. `bd update <this issue> --append-notes "PR: {pr.url}"`. Do not close '
                    f"this issue or {bead}: the reviewer closes both when it merges.",
        "Invariants": f"PR #{pr.number} keeps its title and `Bead: {bead}` line; existing "
                      "tests keep passing.",
        "Edge cases": "N/A: the checklist items are the cases.",
        "Produces for downstream": f"N/A: the reviewer reviews PR #{pr.number} again.",
    })  # fmt: skip
    acceptance = "\n".join((
        f"[ ] every checklist item is fixed in new commits on {branch}",
        f"[ ] PR #{pr.number} is unchanged apart from those commits",
        GATE_CHECK,
        DIFF_CHECK,
    ))  # fmt: skip
    return [
        "create", fix_title(bead, pr.number),
        "-t", "bug", "-p", str(priority), "-l", REVIEW_FIX_LABEL,
        "--deps", f"discovered-from:{bead}",
        "-d", body, "--design", design, "--acceptance", acceptance, "--silent",
    ]  # fmt: skip


def rebase_issue_args(bead: str, pr: PullRequest, detail: str, priority: int) -> list[str]:
    """`bd` arguments for a rebase-only fix: the PR's branch conflicts with main."""
    branch = pr.branch
    body = template_text(ISSUE_SECTIONS, {
        "Goal": f"Rebase PR #{pr.number}'s branch `{branch}` onto origin/main so it can be "
                "merged again.",
        "Why": f"PR #{pr.number} ({pr.url}) for {bead} no longer rebases cleanly onto "
               "origin/main. This is a mechanical conflict, not a code review rejection.",
        "Current state": f"- PR: #{pr.number} {pr.url}\n- Branch: `{branch}` (existing)\n"
                         f"- Original ticket: {bead}\n\nThe rebase stopped with:\n"
                         f"```\n{detail.strip()[:2000]}\n```",
        "Repro": f"`git fetch origin && git checkout -B {branch} origin/{branch} && "
                 "git rebase origin/main`\n**Expected:** a clean rebase.\n"
                 "**Actual:** the conflict above.",
        "In scope": "Only resolve the conflicts, keeping the intent of both sides, then "
                    f"`git push --force-with-lease origin {branch}` (the only case where a "
                    "force-push is allowed, and only to this branch).",
        "Expected to modify": "Only the conflicted files the rebase names.",
        "Out of scope / Forbidden": "Anything else, the PR title or its "
                                    f"`Bead: {bead}` line. Do NOT open a new PR.",
        "Base branch": f"`{branch}` (existing), rebased onto `origin/main`.",
        "Tests first": "N/A: a mechanical rebase adds no behavior; the existing tests must "
                       "pass after it.",
    })  # fmt: skip
    design = template_text(DESIGN_SECTIONS, {
        "Approach": f"1. `git fetch origin && git checkout -B {branch} origin/{branch}`\n"
                    "2. `git rebase origin/main`; resolve each conflict, `git add`, "
                    "`git rebase --continue`.\n"
                    "3. Run the tests and lint.\n"
                    f"4. `git push --force-with-lease origin {branch}` (the only case where a "
                    "force-push is allowed, and only to this branch).\n"
                    f'5. `bd update <this issue> --append-notes "PR: {pr.url}"`. Do not close '
                    f"this issue or {bead}: the reviewer closes both when it merges.",
        "Invariants": "Both sides' intent is kept; existing tests keep passing.",
        "Edge cases": "A conflict that needs more than a mechanical rebase: mark this issue "
                      "blocked and say why, as AGENTS.md says for a blocker.",
        "Produces for downstream": f"N/A: the reviewer reviews PR #{pr.number} again.",
    })  # fmt: skip
    acceptance = "\n".join((
        f"[ ] {branch} is rebased onto the current origin/main with no conflict markers",
        f"[ ] PR #{pr.number} has no other changes",
        GATE_CHECK,
        "[ ] git diff --stat origin/main shows only the PR's own paths",
    ))  # fmt: skip
    return [
        "create", rebase_title(bead, pr.number),
        "-t", "bug", "-p", str(priority), "-l", f"{REVIEW_FIX_LABEL},{REBASE_LABEL}",
        "--deps", f"discovered-from:{bead}",
        "-d", body, "--design", design, "--acceptance", acceptance, "--silent",
    ]  # fmt: skip


def escalation_note(pr: PullRequest, fix_ids: list[str], conflict: bool = False) -> str:
    what = (
        f"PR #{pr.number} still does not rebase onto main after rebase fixes"
        if conflict
        else f"Reviewer rejected PR #{pr.number} again after review-fix"
    )
    return (
        f"{what} {', '.join(fix_ids)}. "
        f"Blocked for a human: read {pr.url}, then fix it yourself, or unblock this issue "
        "and file a clearer review-fix issue, or close the PR."
    )
