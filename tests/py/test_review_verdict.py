"""Tests for turning the reviewer's verdict into comments and debt issues."""

import json

import pytest

from pr_review.verdict import (
    MARKER_PREFIX,
    Problem,
    Verdict,
    debt_issue_args,
    parse_verdict,
    review_comment,
    with_checks,
)

GOOD = {"approve": True, "summary": "Matches the ticket.", "problems": []}
BAD = {
    "approve": False,
    "summary": "Out of scope edit.",
    "problems": [
        {"file": "src/a.py", "line": 12, "title": "Edits cli.py", "detail": "Ticket forbids it."}
    ],
}


def test_parse_verdict_from_structured_output() -> None:
    raw = json.dumps({"type": "result", "structured_output": BAD})
    verdict = parse_verdict(raw)
    assert verdict.approve is False
    assert verdict.problems == (Problem("src/a.py", 12, "Edits cli.py", "Ticket forbids it."),)


def test_parse_verdict_from_result_text() -> None:
    raw = json.dumps({"type": "result", "result": "```json\n" + json.dumps(GOOD) + "\n```"})
    assert parse_verdict(raw) == Verdict(True, "Matches the ticket.", ())


def test_parse_verdict_rejects_garbage() -> None:
    with pytest.raises(ValueError, match="verdict"):
        parse_verdict(json.dumps({"type": "result", "result": "looks fine to me"}))


def test_approval_with_problems_is_not_an_approval() -> None:
    raw = json.dumps({"structured_output": {**BAD, "approve": True}})
    assert parse_verdict(raw).approve is False


def test_checks_override_an_approval() -> None:
    found = [Problem("tests/test_b.py", None, "New test failure: x", "")]
    verdict = with_checks(Verdict(True, "ok", ()), found)
    assert verdict.approve is False
    assert verdict.problems == tuple(found)


def test_no_check_problems_keeps_the_verdict() -> None:
    assert with_checks(Verdict(True, "ok", ()), []) == Verdict(True, "ok", ())


def test_review_comment_carries_marker_and_problems() -> None:
    text = review_comment(Verdict(False, "Needs work.", (Problem("src/a.py", 3, "T", "D"),)), "abc")
    assert text.startswith(f"<!-- {MARKER_PREFIX}abc -->")
    assert "Needs work." in text
    assert "`src/a.py:3` T: D" in text


def test_approval_comment_has_no_reviewed_marker() -> None:
    assert MARKER_PREFIX not in review_comment(Verdict(True, "Good.", ()), "abc")


def test_debt_issue_args() -> None:
    args = debt_issue_args(Problem("src/a.py", 3, "Edits cli.py", "Forbidden."), "om-1", 7)
    assert args[:2] == ["create", "Tech debt from PR #7: Edits cli.py"]
    assert "discovered-from:om-1" in args
    assert args[args.index("-l") + 1] == "tech-debt"
    body = args[args.index("-d") + 1]
    assert "src/a.py:3" in body and "Forbidden." in body and "PR #7" in body
    assert args[args.index("--acceptance") + 1]


def test_debt_issue_has_all_eight_template_sections() -> None:
    args = debt_issue_args(Problem("src/a.py", 3, "T", "D"), "om-1", 7)
    body = args[args.index("-d") + 1]
    for section in (
        "## Problem", "## Repro", "## Fix scope", "Do NOT change", "## Base branch",
        "## Tests first", "## Acceptance", "## Constraints", "## Dependencies",
    ):  # fmt: skip
        assert section in body, section
