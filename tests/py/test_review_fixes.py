"""Review-fix issues: what the reviewer files when it sends a PR back to Hermes (pure)."""

from __future__ import annotations

import pytest

from pr_review import fixes
from pr_review.services import PullRequest
from pr_review.verdict import Problem, Verdict

URL = "https://github.com/o/r/pull/7"
BODY = "Did the thing.\n\nBead: om-1\nHermes-Session: 20261119_101500_abc123\n"
PR = PullRequest(7, "fix(om-1): thing", BODY, "bd/om-1", "sha7", URL)
PROBLEMS = (Problem("a.py", 3, "Guard removed", "Restore _ensure_outside"),)


def _arg(args: list[str], flag: str) -> str:
    return args[args.index(flag) + 1]


def test_session_id_is_read_from_the_pr_body() -> None:
    assert fixes.session_id(BODY) == "20261119_101500_abc123"
    assert fixes.session_id("Bead: om-1") is None


@pytest.mark.parametrize(
    ("wanted", "ticket", "expected"),
    [("high", 2, 1), ("high", 3, 1), ("high", 0, 0), ("same", 2, 2), ("same", 4, 4)],
)
def test_fix_priority_follows_the_reviewer(wanted: str, ticket: int, expected: int) -> None:
    assert fixes.fix_priority(wanted, ticket) == expected


def test_fix_issue_names_the_pr_branch_session_and_checklist() -> None:
    verdict = Verdict(False, "Guard dropped.", PROBLEMS, fix_priority="high")
    args = fixes.fix_issue_args(verdict, PROBLEMS, "om-1", PR, priority=1)
    assert args[:2] == ["create", "Review fixes for PR #7 (om-1)"]
    assert _arg(args, "-l") == fixes.REVIEW_FIX_LABEL
    assert _arg(args, "-p") == "1"
    assert _arg(args, "--deps") == "discovered-from:om-1"
    body = _arg(args, "-d")
    for text in (URL, "bd/om-1", "20261119_101500_abc123", "- [ ] `a.py:3` Guard removed",
                 "gh pr view 7 --comments", "Do NOT open a new PR"):  # fmt: skip
        assert text in body
    assert "--acceptance" in args and args[-1] == "--silent"


def test_fix_title_matches_only_its_own_pr() -> None:
    assert fixes.is_fix_for("Review fixes for PR #7 (om-1)", 7)
    assert not fixes.is_fix_for("Review fixes for PR #70 (om-9)", 7)
    assert not fixes.is_fix_for("Tech debt from PR #7: x", 7)


def test_escalation_note_names_the_pr() -> None:
    assert "PR #7" in fixes.escalation_note(PR, ["om-f1"])
    assert "om-f1" in fixes.escalation_note(PR, ["om-f1"])
