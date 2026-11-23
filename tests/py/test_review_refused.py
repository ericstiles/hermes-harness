"""hermes-review --list-refused: open bd/* PRs refused at their current head (bead gbd)."""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from pathlib import Path

from pr_review.review import refused_lines
from pr_review.services import GitHub
from pr_review.shell import Result
from pr_review.verdict import REFUSED_PREFIX

PRS = [
    {"number": 47, "title": "feat(b8p.14): x", "body": "", "headRefName": "bd/r-b8p.14",
     "headRefOid": "head47", "url": "u47", "isDraft": False},
    {"number": 48, "title": "fix(r-c1): y", "body": "", "headRefName": "bd/r-c1",
     "headRefOid": "head48new", "url": "u48", "isDraft": False},
    {"number": 49, "title": "fix(r-d2): z", "body": "", "headRefName": "bd/r-d2",
     "headRefOid": "head49", "url": "u49", "isDraft": False},
]  # fmt: skip


def _refusal(sha: str, reason: str) -> dict[str, str]:
    body = (
        f"<!-- {REFUSED_PREFIX}{sha}:abc1234567 -->\n**Reviewer agent: not reviewed.** {reason}\n"
    )
    return {"body": body}


THREADS = {
    "47": {"comments": [_refusal("head47", "cannot identify the bead: titles disagree")],
           "reviews": []},
    "48": {"comments": [_refusal("head48old", "old reason")], "reviews": []},  # head moved on
    "49": {"comments": [{"body": "looks good"}], "reviews": []},
}  # fmt: skip


def stub_gh(
    cmd: Sequence[str],
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: float | None = None,
) -> Result:
    if list(cmd[:3]) == ["gh", "pr", "list"]:
        return Result(0, json.dumps(PRS), "")
    if list(cmd[:3]) == ["gh", "pr", "view"]:
        return Result(0, json.dumps(THREADS[cmd[3]]), "")
    return Result(1, "", "unexpected")


def test_list_refused_reports_refusals_at_the_current_head_only() -> None:
    assert refused_lines(GitHub(stub_gh)) == [
        "PR #47 (bd/r-b8p.14) refused at head47: cannot identify the bead: titles disagree"
    ]


def test_list_refused_with_nothing_refused_is_empty() -> None:
    def quiet(cmd: Sequence[str], cwd: Path | None = None, env: object = None,
              timeout: float | None = None) -> Result:  # fmt: skip
        if list(cmd[:3]) == ["gh", "pr", "list"]:
            return Result(0, json.dumps(PRS[2:]), "")
        return Result(0, json.dumps(THREADS["49"]), "")

    assert refused_lines(GitHub(quiet)) == []


def test_latest_refusal_is_by_time_across_comments_and_reviews() -> None:
    def threads(cmd: Sequence[str], cwd: Path | None = None, env: object = None,
                timeout: float | None = None) -> Result:  # fmt: skip
        if list(cmd[:3]) == ["gh", "pr", "list"]:
            return Result(0, json.dumps(PRS[:1]), "")
        newer = {**_refusal("head47", "newer reason"), "createdAt": "2026-11-22T10:00:00Z"}
        older = {**_refusal("head47", "older reason"), "submittedAt": "2026-11-22T09:00:00Z"}
        return Result(0, json.dumps({"comments": [newer], "reviews": [older]}), "")

    assert refused_lines(GitHub(threads)) == [
        "PR #47 (bd/r-b8p.14) refused at head47: newer reason"
    ]


def test_cli_list_refused_needs_no_model(monkeypatch: object, capsys: object) -> None:
    import pr_review.__main__ as cli

    monkeypatch.setattr(cli, "run", stub_gh)  # type: ignore[attr-defined]
    monkeypatch.setattr(cli, "resolve_model", lambda agent, model: None)  # type: ignore[attr-defined]
    assert cli.main(["--list-refused"]) == 0
    out = capsys.readouterr().out  # type: ignore[attr-defined]
    assert "PR #47 (bd/r-b8p.14) refused at head47" in out
