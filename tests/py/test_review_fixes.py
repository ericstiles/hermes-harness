"""Review-fix issues: what the reviewer files when it sends a PR back to Hermes (pure)."""

from __future__ import annotations

import pytest

from pr_review import fixes
from pr_review.services import PullRequest
from pr_review.verdict import Problem, Verdict
from test_review_verdict import assert_follows_issue_template  # the AGENTS.md template check

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
    # an explicit destination: a local branch that tracks main must never push to main
    assert "git push origin bd/om-1:refs/heads/bd/om-1" in _arg(args, "--design")


def test_fix_title_matches_only_its_own_pr() -> None:
    assert fixes.is_fix_for("Review fixes for PR #7 (om-1)", 7)
    assert not fixes.is_fix_for("Review fixes for PR #70 (om-9)", 7)
    assert not fixes.is_fix_for("Tech debt from PR #7: x", 7)


def test_escalation_note_names_the_pr() -> None:
    assert "PR #7" in fixes.escalation_note(PR, ["om-f1"])
    assert "om-f1" in fixes.escalation_note(PR, ["om-f1"])


def test_rebase_issue_asks_for_a_rebase_only_with_force_with_lease() -> None:
    args = fixes.rebase_issue_args("om-1", PR, "CONFLICT (content): a.py", priority=2)
    assert args[:2] == ["create", "Rebase PR #7 onto main (om-1)"]
    labels = [args[i + 1] for i, a in enumerate(args) if a == "-l"]
    assert labels == [f"{fixes.REVIEW_FIX_LABEL},{fixes.REBASE_LABEL}"]
    assert _arg(args, "-p") == "2"
    body = _arg(args, "-d")
    push = "git push --force-with-lease origin bd/om-1:refs/heads/bd/om-1"
    for text in (URL, "git rebase origin/main", push,
                 "CONFLICT (content): a.py", "Do NOT open a new PR"):  # fmt: skip
        assert text in body
    assert push in _arg(args, "--design")


def test_rebase_issue_title_is_found_as_a_fix_for_its_pr() -> None:
    assert fixes.is_fix_for("Rebase PR #7 onto main (om-1)", 7)
    assert not fixes.is_fix_for("Rebase PR #70 onto main (om-1)", 7)
    assert fixes.is_rebase_fix({"title": "Rebase PR #7 onto main (om-1)"})
    assert not fixes.is_rebase_fix({"title": "Review fixes for PR #7 (om-1)"})
    assert not fixes.is_rebase_fix({"id": "om-f1"})


def test_conflict_escalation_note_says_it_is_a_conflict() -> None:
    note = fixes.escalation_note(PR, ["om-r1", "om-r2", "om-r3"], conflict=True)
    assert "rebase" in note and "om-r3" in note and "PR #7" in note


def test_fixed_in_note_marks_a_bead_solved_by_a_pr() -> None:
    assert fixes.fixed_in_note(URL, "om-f1") == f"Fixed in PR {URL} via review-fix om-f1"
    assert fixes.is_fixed_in(f"PR: x\nFixed in PR {URL} via review-fix om-f1\n", URL)
    assert fixes.is_fixed_in(f"Fixed in PR {URL}", URL)


@pytest.mark.parametrize(
    "notes",
    [
        f"PR: {URL}",  # its own PR link, not a fix by another PR
        f"See {URL}; Fixed in PR {URL} maybe",  # mentioned mid-line
        f"Fixed in PR {URL}0 via review-fix om-f9",  # PR #70, not #7
        "",
    ],
)
def test_fixed_in_ignores_other_mentions_of_the_pr(notes: str) -> None:
    assert not fixes.is_fixed_in(notes, URL)


def test_fix_issue_follows_the_agents_md_issue_template() -> None:
    verdict = Verdict(False, "Guard dropped.", PROBLEMS)
    assert_follows_issue_template(fixes.fix_issue_args(verdict, PROBLEMS, "om-1", PR, priority=1))


def test_rebase_issue_follows_the_agents_md_issue_template() -> None:
    args = fixes.rebase_issue_args("om-1", PR, "CONFLICT (content): a.py", priority=2)
    assert_follows_issue_template(args)


def test_rebase_issue_expected_to_modify_names_files() -> None:
    # Bead 1cd: "Expected to modify" lists each conflicted file, not "the files the rebase names".
    files = ("a.txt", "b.txt")
    args = fixes.rebase_issue_args("om-1", PR, "Conflicted files: a.txt, b.txt", 2, files)
    body = _arg(args, "-d")
    section = body.split("## Expected to modify", 1)[1].split("##", 1)[0]
    assert "`a.txt`" in section and "`b.txt`" in section
    assert "the rebase names" not in section
    unknown = _arg(fixes.rebase_issue_args("om-1", PR, "error: x", 2), "-d")
    assert "the rebase names" in unknown.split("## Expected to modify", 1)[1].split("##", 1)[0]


def test_rebase_issue_caps_the_file_list_at_50() -> None:
    files = tuple(f"f{i:02}.txt" for i in range(53))
    body = _arg(fixes.rebase_issue_args("om-1", PR, "error: x", 2, files), "-d")
    section = body.split("## Expected to modify", 1)[1].split("##", 1)[0]
    assert "- `f49.txt`" in section and "f50.txt" not in section
    assert "- and 3 more" in section
