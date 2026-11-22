"""hermes-review closes epics whose children are all done after a merge (bead xw2.1).

The stub replays `bd epic close-eligible --json` output captured from bd 1.3.4 on a
nested chain: round 1 closes the child epic, round 2 its parent, round 3 nothing.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping, Sequence
from pathlib import Path

import pytest

from pr_review.services import MAX_EPIC_ROUNDS, Beads, PullRequest
from pr_review.shell import Result

PR = PullRequest(
    7, "fix(om-1): thing", "Bead: om-1", "bd/om-1", "sha7", "https://github.com/o/r/pull/7"
)


def _round(closed: list[str]) -> Result:
    payload = {"closed": closed, "count": len(closed), "reason": "x", "schema_version": 1}
    return Result(0, json.dumps(payload, indent=2), "")


class StubBd:
    """Answers `bd epic close-eligible` from a list of results; records every command."""

    def __init__(self, results: list[Result]) -> None:
        self.results, self.calls = list(results), []

    def __call__(
        self,
        cmd: Sequence[str],
        cwd: Path | None = None,
        env: Mapping[str, str] | None = None,
        timeout: float | None = None,
    ) -> Result:
        self.calls.append(list(cmd))
        return self.results.pop(0) if self.results else _round([])


def test_merge_closes_eligible_parent_epics(caplog: pytest.LogCaptureFixture) -> None:
    run = StubBd([_round(["om-e.1"]), _round(["om-e"]), _round([])])
    with caplog.at_level(logging.INFO, logger="pr_review"):
        closed = Beads(run).close_eligible_epics(PR)
    assert closed == ["om-e.1", "om-e"]
    assert len(run.calls) == 3
    assert run.calls[0][:5] == ["bd", "epic", "close-eligible", "--json", "--reason"]
    assert "PR #7" in run.calls[0][5]
    assert "om-e.1" in caplog.text and "om-e" in caplog.text


def test_no_eligible_epics_is_a_no_op(caplog: pytest.LogCaptureFixture) -> None:
    run = StubBd([_round([])])
    with caplog.at_level(logging.INFO, logger="pr_review"):
        assert Beads(run).close_eligible_epics(PR) == []
    assert len(run.calls) == 1
    assert "closed epic" not in caplog.text


@pytest.mark.parametrize(
    "result",
    [Result(1, "", "bd: database locked"), Result(0, "not json", ""), Result(0, "[1, 2]", "")],
)
def test_close_eligible_failure_does_not_undo_the_merge(
    result: Result, caplog: pytest.LogCaptureFixture
) -> None:
    with caplog.at_level(logging.WARNING, logger="pr_review"):
        assert Beads(StubBd([result])).close_eligible_epics(PR) == []
    assert "close-eligible" in caplog.text


def test_rounds_are_capped() -> None:
    endless = StubBd([_round([f"om-e{i}"]) for i in range(MAX_EPIC_ROUNDS + 5)])
    closed = Beads(endless).close_eligible_epics(PR)
    assert len(endless.calls) == MAX_EPIC_ROUNDS
    assert len(closed) == MAX_EPIC_ROUNDS
