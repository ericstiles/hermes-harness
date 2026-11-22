"""Decision flow of the PR reviewer agent with fake GitHub and beads services."""

from __future__ import annotations

from pathlib import Path

import pytest

from pr_review import review
from pr_review.services import PullRequest
from pr_review.verdict import Problem, Verdict

URL = "https://github.com/o/r/pull/7"
PR = PullRequest(7, "fix(om-1): thing", "Bead: om-1\nHermes-Session: s1", "bd/om-1", "sha7", URL)
INSIDE = Problem("a.py", 1, "A", "")
OUTSIDE = Problem("z.py", 9, "Z", "", in_scope=False)


class FakeGitHub:
    """Remembers posted comments so marker checks behave like the real PR thread."""

    def __init__(self, reviewed: bool = False) -> None:
        self.posted: list[str] = [f"<!-- pr-review:{PR.head_sha} -->"] if reviewed else []
        self.calls: list[tuple[str, object]] = []

    def has_marker(self, pr: PullRequest, marker: str) -> bool:
        return any(marker in text for text in self.posted)

    def post_review(self, pr: PullRequest, text: str, approve: bool) -> None:
        self.posted.append(text)
        self.calls.append(("review", approve))

    def merge(self, pr: PullRequest) -> None:
        self.calls.append(("merge", pr.number))

    def add_label(self, pr: PullRequest, label: str) -> None:
        self.calls.append(("label", label))


class FakeBeads:
    def __init__(
        self,
        status: str = "in_progress",
        notes: str = f"PR: {URL}",
        fixes: list[dict[str, object]] | None = None,
        labels: list[str] | None = None,
        others: list[dict[str, object]] | None = None,
        eligible: list[str] | None = None,
    ) -> None:
        self.info: dict[str, object] = {
            "status": status, "notes": notes, "priority": 2, "labels": labels or [],
        }  # fmt: skip
        self.fixes = fixes or []
        self.others = others or []
        self.eligible = eligible or []
        self.calls: list[tuple[str, object]] = []

    def show(self, bead: str) -> dict[str, object]:
        for fix in self.fixes:
            if fix["id"] == bead:
                return fix
        return self.info

    def review_fixes(self, pr_number: int) -> list[dict[str, object]]:
        return self.fixes

    def fixed_in(self, pr: PullRequest) -> list[str]:
        return [str(r["id"]) for r in self.others]

    def close(self, bead: str, pr: PullRequest) -> None:
        self.calls.append(("close", bead))

    def create(self, args: list[str]) -> str:
        self.calls.append(("create", args[1]))
        return f"om-new{len(self.calls)}"

    def note(self, bead: str, text: str) -> None:
        self.calls.append(("note", bead))

    def escalate(self, bead: str, text: str) -> None:
        self.calls.append(("escalate", bead))

    def close_eligible_epics(self, pr: PullRequest) -> list[str]:
        self.calls.append(("epics", pr.number))
        return self.eligible

    def push(self) -> None:
        self.calls.append(("push", None))


def _ctx(gh: FakeGitHub, bd: FakeBeads, dry_run: bool = False) -> review.Context:
    ctx = review.Context(run=None, repo=Path("."), github=gh, beads=bd, dry_run=dry_run)  # type: ignore[arg-type]
    ctx.notified = []  # type: ignore[attr-defined]
    ctx.notify = lambda title, text: ctx.notified.append(text)  # type: ignore[attr-defined]
    return ctx


@pytest.fixture
def verdict(monkeypatch: pytest.MonkeyPatch) -> list[Verdict]:
    holder = [Verdict(True, "ok", ())]
    monkeypatch.setattr(review, "fetch", lambda run, repo, number: "ref")
    monkeypatch.setattr(review, "_verdict", lambda ctx, pr, bead, ref: holder[0])
    return holder


def test_good_pr_is_approved_merged_and_closed(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(), FakeBeads()
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert gh.calls == [("review", True), ("merge", 7)]
    assert bd.calls == [("close", "om-1"), ("epics", 7), ("push", None)]


def test_merge_closes_the_ticket_and_its_open_review_fixes_only(
    verdict: list[Verdict],
) -> None:
    fixes = [
        {"id": "om-f1", "status": "closed", "notes": ""},
        {"id": "om-f2", "status": "in_progress", "notes": f"PR: {URL}"},
    ]
    gh, bd = FakeGitHub(), FakeBeads(fixes=fixes)
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert bd.calls == [("close", "om-1"), ("close", "om-f2"), ("epics", 7), ("push", None)]


def test_merge_also_closes_beads_noted_as_fixed_in_this_pr(verdict: list[Verdict]) -> None:
    fixes = [{"id": "om-f2", "status": "in_progress", "notes": f"PR: {URL}"}]
    gh, bd = FakeGitHub(), FakeBeads(fixes=fixes, others=[{"id": "om-b"}, {"id": "om-f2"}])
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert bd.calls == [
        ("close", "om-1"), ("close", "om-f2"), ("close", "om-b"), ("epics", 7), ("push", None)
    ]  # fmt: skip


def test_rejection_leaves_beads_fixed_in_this_pr_open(verdict: list[Verdict]) -> None:
    verdict[0] = Verdict(False, "no", (INSIDE,))
    gh, bd = FakeGitHub(), FakeBeads(others=[{"id": "om-b"}])
    assert review.review_pr(_ctx(gh, bd), PR) == "changes-needed"
    assert ("close", "om-b") not in bd.calls


def test_approval_with_out_of_scope_problems_files_debt_and_merges(
    verdict: list[Verdict],
) -> None:
    verdict[0] = Verdict(True, "ok", (OUTSIDE,))
    gh, bd = FakeGitHub(), FakeBeads()
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert ("merge", 7) in gh.calls
    assert [c[0] for c in bd.calls] == ["create", "close", "epics", "push"]
    assert bd.calls[0][1].startswith("Tech debt from PR #7")  # type: ignore[union-attr]


def test_first_rejection_files_one_review_fix_plus_debt_for_out_of_scope(
    verdict: list[Verdict],
) -> None:
    verdict[0] = Verdict(False, "no", (INSIDE, Problem("b.py", 2, "B", ""), OUTSIDE))
    gh, bd = FakeGitHub(), FakeBeads()
    assert review.review_pr(_ctx(gh, bd), PR) == "changes-needed"
    assert gh.calls == [("review", False)]
    assert bd.calls[0] == ("create", "Review fixes for PR #7 (om-1)")
    assert bd.calls[1][0] == "create" and "Tech debt" in str(bd.calls[1][1])
    assert [c[0] for c in bd.calls[2:]] == ["note", "push"]


def test_second_rejection_escalates_to_the_human_once(verdict: list[Verdict]) -> None:
    verdict[0] = Verdict(False, "still wrong", (INSIDE,))
    fixes = [{"id": "om-f1", "status": "in_progress", "notes": f"PR: {URL}"}]
    gh, bd = FakeGitHub(), FakeBeads(fixes=fixes)
    ctx = _ctx(gh, bd)
    assert review.review_pr(ctx, PR) == "escalated"
    assert gh.calls == [("review", False), ("label", "needs-human")]
    assert bd.calls == [("escalate", "om-1"), ("push", None)]  # no new review-fix
    assert len(ctx.notified) == 1 and "PR #7" in ctx.notified[0]  # type: ignore[attr-defined]


def test_new_commits_wait_until_hermes_notes_the_review_fix(
    verdict: list[Verdict],
) -> None:
    fixes = [{"id": "om-f1", "status": "in_progress", "notes": ""}]
    gh, bd = FakeGitHub(), FakeBeads(fixes=fixes)
    assert review.review_pr(_ctx(gh, bd), PR) == "waiting"
    assert gh.calls == [] and bd.calls == []


def test_escalated_ticket_is_left_to_the_human(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(), FakeBeads(status="blocked", labels=["human"])
    assert review.review_pr(_ctx(gh, bd), PR) == "escalated"
    assert gh.calls == [] and bd.calls == []


def test_failed_merge_is_retried_on_the_next_pass(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(), FakeBeads()

    def broken_merge(pr: PullRequest) -> None:
        raise RuntimeError("merge failed")

    working_merge = gh.merge
    gh.merge = broken_merge  # type: ignore[method-assign]
    with pytest.raises(RuntimeError):
        review.review_pr(_ctx(gh, bd), PR)
    # The approval comment must not mark the head as reviewed, or it is never retried.
    gh.merge = working_merge  # type: ignore[method-assign]
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert ("merge", 7) in gh.calls


def test_dry_run_changes_nothing(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(), FakeBeads()
    assert review.review_pr(_ctx(gh, bd, dry_run=True), PR) == "merged"
    verdict[0] = Verdict(False, "no", (INSIDE,))
    assert review.review_pr(_ctx(gh, bd, dry_run=True), PR) == "changes-needed"
    assert gh.calls == [] and bd.calls == []


def test_mismatched_bead_is_refused_with_a_comment(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(), FakeBeads()
    bad = PullRequest(8, "fix(om-2): x", "Bead: om-1", "bd/om-1", "sha8", URL)
    assert review.review_pr(_ctx(gh, bd), bad) == "refused"
    assert gh.calls == [("review", False)] and bd.calls == []


@pytest.mark.parametrize(("status", "notes"), [("closed", f"PR: {URL}"), ("in_progress", "")])
def test_bead_must_be_in_progress_with_pr_link(
    verdict: list[Verdict], status: str, notes: str
) -> None:
    gh, bd = FakeGitHub(), FakeBeads(status, notes)
    assert review.review_pr(_ctx(gh, bd), PR) == "refused"
    assert ("merge", 7) not in gh.calls


def test_already_reviewed_head_is_skipped(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(reviewed=True), FakeBeads()
    assert review.review_pr(_ctx(gh, bd), PR) == "skipped"
    assert gh.calls == [] and bd.calls == []


def test_refusal_is_posted_once_but_rechecked_until_fixed(
    verdict: list[Verdict],
) -> None:
    gh, bd = FakeGitHub(), FakeBeads(notes="")
    assert review.review_pr(_ctx(gh, bd), PR) == "refused"
    assert review.review_pr(_ctx(gh, bd), PR) == "refused"
    assert gh.calls == [("review", False)]  # the same refusal is not repeated
    bd.info["notes"] = f"PR: {URL}"  # Hermes adds the PR link; same head commit
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert ("merge", 7) in gh.calls


CONFLICT = Verdict(
    False, "Rebase onto origin/main failed.",
    (Problem("", None, "Does not rebase cleanly onto main", "CONFLICT a.py"),),
    rebase_conflict=True,
)  # fmt: skip


def _rebase_fix(n: int) -> dict[str, object]:
    return {"id": f"om-r{n}", "status": "closed", "title": "Rebase PR #7 onto main (om-1)",
            "notes": f"PR: {URL}"}  # fmt: skip


def test_conflict_after_a_code_rejection_is_not_a_second_strike(
    verdict: list[Verdict],
) -> None:
    verdict[0] = CONFLICT
    fixes = [{"id": "om-f1", "status": "closed", "title": "Review fixes for PR #7 (om-1)",
              "notes": f"PR: {URL}"}]  # fmt: skip
    gh, bd = FakeGitHub(), FakeBeads(fixes=fixes)
    ctx = _ctx(gh, bd)
    assert review.review_pr(ctx, PR) == "rebase-needed"
    assert gh.calls == [("review", False)]
    assert bd.calls[0] == ("create", "Rebase PR #7 onto main (om-1)")
    assert [c[0] for c in bd.calls[1:]] == ["note", "push"]
    assert ctx.notified == []  # type: ignore[attr-defined]


def test_code_rejection_after_a_rebase_fix_is_still_the_first_strike(
    verdict: list[Verdict],
) -> None:
    verdict[0] = Verdict(False, "no", (INSIDE,))
    gh, bd = FakeGitHub(), FakeBeads(fixes=[_rebase_fix(1)])
    assert review.review_pr(_ctx(gh, bd), PR) == "changes-needed"
    assert bd.calls[0] == ("create", "Review fixes for PR #7 (om-1)")


def test_second_code_rejection_still_escalates_despite_rebase_fixes(
    verdict: list[Verdict],
) -> None:
    verdict[0] = Verdict(False, "no", (INSIDE,))
    code = {"id": "om-f1", "status": "closed", "title": "Review fixes for PR #7 (om-1)",
            "notes": f"PR: {URL}"}  # fmt: skip
    gh, bd = FakeGitHub(), FakeBeads(fixes=[_rebase_fix(1), code])
    assert review.review_pr(_ctx(gh, bd), PR) == "escalated"
    assert bd.calls == [("escalate", "om-1"), ("push", None)]


def test_repeated_conflicts_escalate_as_a_conflict(verdict: list[Verdict]) -> None:
    verdict[0] = CONFLICT
    rebases = [_rebase_fix(n) for n in range(1, review.fixes.MAX_REBASE_FIXES + 1)]
    gh, bd = FakeGitHub(), FakeBeads(fixes=rebases)
    ctx = _ctx(gh, bd)
    assert review.review_pr(ctx, PR) == "escalated"
    assert bd.calls == [("escalate", "om-1"), ("push", None)]
    assert "conflict" in ctx.notified[0]  # type: ignore[attr-defined]


def test_merge_also_closes_open_rebase_fixes(verdict: list[Verdict]) -> None:
    fix = {**_rebase_fix(1), "status": "in_progress"}
    gh, bd = FakeGitHub(), FakeBeads(fixes=[fix])
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert bd.calls == [("close", "om-1"), ("close", "om-r1"), ("epics", 7), ("push", None)]


def test_verdict_turns_a_rebase_failure_into_a_conflict_verdict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def conflict(*args: object, **kwargs: object) -> object:
        raise review.RebaseConflict("CONFLICT (content): a.py")

    ctx = _ctx(FakeGitHub(), FakeBeads())
    monkeypatch.setattr(ctx, "baseline", dict)
    monkeypatch.setattr(review, "checkout", conflict)
    result = review._verdict(ctx, PR, "om-1", "ref")
    assert result.rebase_conflict and not result.approve
    assert "CONFLICT (content): a.py" in result.problems[0].detail


def test_merge_closes_eligible_epics_before_the_single_push(verdict: list[Verdict]) -> None:
    gh, bd = FakeGitHub(), FakeBeads(eligible=["om-e.1", "om-e"])
    assert review.review_pr(_ctx(gh, bd), PR) == "merged"
    assert bd.calls[-2:] == [("epics", 7), ("push", None)]


def test_dry_run_closes_no_epics(verdict: list[Verdict]) -> None:
    bd = FakeBeads(eligible=["om-e"])
    review.review_pr(_ctx(FakeGitHub(), bd, dry_run=True), PR)
    assert ("epics", 7) not in bd.calls
