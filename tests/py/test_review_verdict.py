"""Tests for turning the reviewer's verdict into comments and debt issues."""

import json

import pytest

from pr_review.verdict import (
    MARKER_PREFIX,
    Problem,
    Verdict,
    debt_issue_args,
    parse_verdict,
    rebase_verdict,
    review_comment,
    with_checks,
)

GOOD = {"approve": True, "summary": "Matches the ticket.", "problems": []}
BAD = {
    "approve": False,
    "summary": "Out of scope edit.",
    "problems": [
        {
            "file": "src/a.py",
            "line": 12,
            "title": "Edits cli.py",
            "detail": "Ticket forbids it.",
        }
    ],
}


# The AGENTS.md issue template (bead c0i): description, design and acceptance sections.
TEMPLATE_SECTIONS = (
    "## Goal", "## Why", "## Current state", "## Repro", "## In scope", "## Expected to modify",
    "## Out of scope / Forbidden", "## Base branch", "## Tests first",
)  # fmt: skip
DESIGN_SECTIONS = ("## Approach", "## Invariants", "## Edge cases", "## Produces for downstream")
OLD_HEADINGS = ("## Problem", "## Fix scope", "## Constraints", "## Dependencies", "## Where")


def assert_follows_issue_template(args: list[str]) -> None:
    body = args[args.index("-d") + 1]
    for section in TEMPLATE_SECTIONS:
        assert section in body, section
    positions = [body.index(s) for s in TEMPLATE_SECTIONS]
    assert positions == sorted(positions), "sections out of template order"
    for old in OLD_HEADINGS:
        assert old not in body, old
    assert "<placeholder>" not in body
    design = args[args.index("--design") + 1]
    for section in DESIGN_SECTIONS:
        assert section in design, section
    acceptance = args[args.index("--acceptance") + 1].splitlines()
    assert acceptance and all(line.startswith("[ ] ") for line in acceptance), acceptance
    assert any("quality gate" in line for line in acceptance)
    assert any("git diff --stat" in line for line in acceptance)


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


def test_debt_issue_follows_the_agents_md_issue_template() -> None:
    assert_follows_issue_template(debt_issue_args(Problem("src/a.py", 3, "T", "D"), "om-1", 7))


def _wrap(payload: dict[str, object]) -> str:
    return json.dumps({"structured_output": payload})


def test_problems_are_in_scope_and_fix_priority_same_by_default() -> None:
    verdict = parse_verdict(_wrap(BAD))
    assert verdict.problems[0].in_scope is True
    assert verdict.fix_priority == "same"


def test_fix_priority_high_is_kept_and_unknown_values_fall_back() -> None:
    assert parse_verdict(_wrap({**BAD, "fix_priority": "high"})).fix_priority == "high"
    assert parse_verdict(_wrap({**BAD, "fix_priority": "urgent!"})).fix_priority == "same"


def test_only_out_of_scope_problems_do_not_block_approval() -> None:
    outside = {**BAD["problems"][0], "in_scope": False}  # type: ignore[index]
    verdict = parse_verdict(_wrap({"approve": True, "summary": "ok", "problems": [outside]}))
    assert verdict.approve is True
    assert verdict.problems[0].in_scope is False
    assert verdict.blocking() == ()
    assert verdict.debt() == verdict.problems


def test_gate_problems_are_in_scope_and_block() -> None:
    verdict = with_checks(Verdict(True, "ok", ()), [Problem("t.py", 1, "test fails", "")])
    assert verdict.approve is False and verdict.blocking() == verdict.problems


def test_review_comment_has_no_empty_code_span_for_rebase_conflict() -> None:
    # Bead 1cd: the rebase problem has no file:line, so its location span was rendered as ``.
    message = "Conflicted files: a.txt, b.txt\nerror: could not apply"
    verdict = rebase_verdict(message, ("a.txt", "b.txt"))
    assert verdict.rebase_conflict and not verdict.approve
    assert verdict.conflict_files == ("a.txt", "b.txt")
    text = review_comment(verdict, "abc")
    assert "``" not in text
    assert "- Does not rebase cleanly onto main: conflicts in a.txt, b.txt" in text
    no_files = review_comment(rebase_verdict("error: could not apply", ()), "abc")
    assert "``" not in no_files and "- Does not rebase cleanly onto main: error" in no_files
