"""A PR that touches files another open bead names: a non-blocking note (bead 9cv)."""

from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from pr_review import overlap, review
from pr_review.services import Beads, PullRequest
from pr_review.shell import Result
from pr_review.verdict import Problem, Verdict, review_comment

URL = "https://github.com/o/r/pull/7"
PR = PullRequest(7, "fix(om-1): thing", "Bead: om-1", "bd/om-1", "sha7", URL)
DIFF = (
    "diff --git a/src/naming.py b/src/naming.py\n"
    "index 1..2 100644\n--- a/src/naming.py\n+++ b/src/naming.py\n@@ -1 +1 @@\n-a\n+b\n"
    "diff --git a/old/x.sh b/new/y.sh\nsimilarity index 90%\nrename from old/x.sh\n"
    "rename to new/y.sh\n"
)
B = {"id": "om-b", "title": "Names break", "status": "open", "issue_type": "bug",
     "description": "render_name in naming.py drops the suffix."}  # fmt: skip


class OpenBeads:
    """The read-only part of Beads that the overlap step uses, plus a call log."""

    def __init__(self, rows: list[dict[str, object]], fixed: list[str] | None = None) -> None:
        self.rows = rows
        self.fixed = fixed or []
        self.calls: list[str] = []

    def open_issues(self) -> list[dict[str, object]]:
        self.calls.append("open_issues")
        return self.rows

    def review_fixes(self, pr_number: int) -> list[dict[str, object]]:
        return [{"id": "om-f1", "title": f"Review fixes for PR #{pr_number} (om-1)"}]

    def fixed_in(self, pr: PullRequest) -> list[str]:
        return self.fixed

    def close(self, bead: str, pr: PullRequest) -> None:  # must never be called
        self.calls.append(f"close {bead}")


def _ctx(beads: object) -> review.Context:
    return review.Context(run=None, repo=Path("."), github=None, beads=beads)  # type: ignore[arg-type]


def test_changed_paths_reads_both_sides_of_a_rename() -> None:
    assert overlap.changed_paths(DIFF) == ("src/naming.py", "old/x.sh", "new/y.sh")
    assert overlap.changed_paths("") == ()


@pytest.mark.parametrize(
    ("text", "path", "named"),
    [
        ("fix naming.py", "src/naming.py", True),
        ("see src/naming.py:12.", "src/naming.py", True),
        ("(`naming.py`)", "src/naming.py", True),
        ("renaming.py is different", "src/naming.py", False),
        ("naming.pyc is a cache", "src/naming.py", False),
        ("lib/pr_review/__init__.py", "lib/pr_review/__init__.py", True),
        ("add an __init__.py", "lib/pr_review/__init__.py", False),  # too generic alone
        ("nothing here", "src/naming.py", False),
    ],
)
def test_names_path(text: str, path: str, named: bool) -> None:
    assert overlap.names_path(text, path) is named


def test_bead_naming_a_changed_file_gets_one_note() -> None:
    notes = overlap.related_notes(overlap.changed_paths(DIFF), [B], skip=set())
    assert len(notes) == 1
    assert "om-b" in notes[0] and "Names break" in notes[0] and "src/naming.py" in notes[0]


def test_own_bead_skipped_ids_closed_and_epics_get_no_note() -> None:
    rows = [
        {**B, "id": "om-1"},
        {**B, "id": "om-f1"},
        {**B, "id": "om-c", "status": "closed"},
        {**B, "id": "om-e", "issue_type": "epic"},
        {**B, "id": "om-d", "description": "unrelated", "acceptance_criteria": "naming.py ok"},
    ]
    notes = overlap.related_notes(("src/naming.py",), rows, skip={"om-1", "om-f1"})
    assert [n.split()[0] for n in notes] == ["`om-d`"]  # acceptance text counts too


def test_expected_to_modify_section_is_what_counts_when_a_bead_has_one() -> None:
    context_only = {**B, "id": "om-g", "description": (
        "**Current state:** naming.py calls helpers.py.\n"
        "**Expected to modify:** `src/helpers.py`, tests/test_helpers.py\n"
        "**Out of scope / Forbidden:** naming.py"
    )}  # fmt: skip
    assert overlap.related_notes(("src/naming.py",), [context_only], skip=set()) == ()
    notes = overlap.related_notes(("src/helpers.py",), [context_only], skip=set())
    assert notes == ("`om-g` (Names break): `src/helpers.py`",)
    heading = {
        **context_only,
        "description": "## Expected to modify\nsrc/naming.py\n\n## Base branch\nmain",
    }
    assert len(overlap.related_notes(("src/naming.py",), [heading], skip=set())) == 1


def test_with_related_adds_the_note_and_changes_nothing_else() -> None:
    beads = OpenBeads([B, {**B, "id": "om-1"}, {**B, "id": "om-f1"}, {**B, "id": "om-x"}],
                      fixed=["om-x"])  # fmt: skip
    for approve in (True, False):
        verdict = Verdict(approve, "s", (Problem("a.py", 1, "A", ""),))
        out = review.with_related(_ctx(beads), PR, "om-1", verdict, DIFF)
        assert out.approve is approve
        assert out.problems == verdict.problems and out.debt() == verdict.debt()
        assert len(out.related) == 1 and "om-b" in out.related[0]
    assert not [c for c in beads.calls if c.startswith("close")]


def test_with_related_never_breaks_a_review(caplog: pytest.LogCaptureFixture) -> None:
    class Broken(OpenBeads):
        def open_issues(self) -> list[dict[str, object]]:
            raise RuntimeError("bd down")

    verdict = Verdict(True, "s", ())
    with caplog.at_level(logging.WARNING, logger="pr_review"):
        assert review.with_related(_ctx(Broken([])), PR, "om-1", verdict, DIFF) == verdict
    assert "bd down" in caplog.text


def test_review_comment_lists_related_beads_as_not_blocking() -> None:
    verdict = Verdict(True, "Good.", (), related=("`om-b` note",))
    text = review_comment(verdict, "abc")
    assert "`om-b` note" in text and "not blocking" in text
    assert "Other open beads" not in review_comment(Verdict(True, "Good.", ()), "abc")


def test_open_issues_lists_non_closed_beads() -> None:
    calls: list[list[str]] = []

    def fake(cmd: list[str], **_: object) -> Result:
        calls.append(list(cmd))
        return Result(0, json.dumps([B]), "")

    assert Beads(fake).open_issues() == [B]  # type: ignore[arg-type]
    assert calls == [["bd", "list", "--json", "--limit", "0"]]
