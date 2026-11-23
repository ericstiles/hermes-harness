"""Unit tests for lib/bead_stats.py (bead + queue statistics as BEADS: lines, bead 9jj)."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

import bead_stats as bs

SCRIPT = Path(__file__).resolve().parents[2] / "lib" / "bead_stats.py"
STATS = json.dumps(
    {
        "schema_version": 1,
        "summary": {  # real field names from `bd stats --json` (bd 1.3.4)
            "blocked_issues": 5,
            "closed_issues": 35,
            "epics_eligible_for_closure": 1,
            "in_progress_issues": 1,
            "open_issues": 29,
            "ready_issues": 24,
            "total_issues": 64,
        },
    }
)
READY = json.dumps([{"id": "r-ab1.2", "title": "Fix the thing", "priority": 1, "status": "open"}])


def test_stats_json_becomes_the_start_line() -> None:
    assert bs.start_line(bs.parse_stats(STATS), bs.parse_next(READY)) == (
        'BEADS: next r-ab1.2 "Fix the thing" (P1) | ready 24 in_progress 1 blocked 5 '
        "| open 29 closed 35 of 64 | epics ready to close 1"
    )


def test_empty_queue_says_next_none() -> None:
    line = bs.start_line(bs.parse_stats(STATS), bs.parse_next("[]"))
    assert line.startswith("BEADS: next none | ready 24 ")


def test_loop_summary_line() -> None:
    assert bs.summary_line(bs.parse_stats(STATS), ["r-ab1.2", "r-c3", "r-ab1.2"]) == (
        "BEADS: loop worked 2 issue(s): r-ab1.2 r-c3 | closed 35 of 64 "
        "| still to do: ready 24, open 29, blocked 5"
    )
    empty = bs.summary_line(bs.parse_stats(STATS), [])
    assert empty.startswith("BEADS: loop worked 0 issue(s): none")


def test_title_is_shortened_and_quotes_are_safe() -> None:
    long = json.dumps([{"id": "r-x", "title": 'a "quoted"\nline ' + "x" * 200, "priority": 2}])
    nxt = bs.parse_next(long)
    assert nxt is not None
    assert "\n" not in nxt.title and '"' not in nxt.title and len(nxt.title) <= 60


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("", "empty input"),
        ("nope", "not JSON"),
        ('{"summary": {"open_issues": "many"}}', "open_issues is not a non-negative integer"),
        ('{"other": 1}', "summary is missing"),
    ],
)
def test_malformed_stats_is_rejected_with_a_reason(text: str, reason: str) -> None:
    with pytest.raises(ValueError, match=reason):
        bs.parse_stats(text)


@pytest.mark.parametrize("argv", [["start", "", "[]"], ["start", "nope", READY], ["summary", "{}"]])
def test_malformed_stats_is_unavailable_exit_0(argv: list[str]) -> None:
    done = subprocess.run(
        [sys.executable, str(SCRIPT), *argv],
        capture_output=True, text=True, timeout=30, check=False,
    )  # fmt: skip
    assert done.returncode == 0
    assert done.stdout.startswith("BEADS: unavailable (")
    assert done.stdout.count("\n") == 1


def test_cli_start_and_summary() -> None:
    start = subprocess.run(
        [sys.executable, str(SCRIPT), "start", STATS, READY],
        capture_output=True, text=True, timeout=30, check=False,
    )  # fmt: skip
    assert start.stdout.startswith('BEADS: next r-ab1.2 "Fix the thing" (P1)')
    summary = subprocess.run(
        [sys.executable, str(SCRIPT), "summary", STATS, "r-ab1.2", "r-c3"],
        capture_output=True, text=True, timeout=30, check=False,
    )  # fmt: skip
    assert summary.stdout.startswith("BEADS: loop worked 2 issue(s): r-ab1.2 r-c3")
