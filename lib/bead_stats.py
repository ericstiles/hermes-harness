#!/usr/bin/env python3
"""bead_stats: the bead about to be worked and the queue's numbers, as one BEADS: line.

    bead_stats.py start   STATS_JSON READY_JSON     # at the start of a run
    bead_stats.py summary STATS_JSON [ID ...] [--requeued ID->BLOCKERS ...]   # at the loop's end

STATS_JSON is `bd stats --json`; READY_JSON is
`bd ready --json --exclude-type epic --sort priority --limit 1`, the agent's own pick
command (AGENTS.md step 1), so `next` is the bead the agent is expected to claim. IDs are
the beads the loop's runs claimed. Prints exactly one line:

    BEADS: next <id> "<title>" (P<n>) | ready R in_progress I blocked B | open O closed C of T
      | epics ready to close E
    BEADS: loop worked N issue(s): <ids> [| requeued <id> -> <blockers>; ...] | closed C of T
      | still to do: ready R, open O, blocked B
    BEADS: unavailable (<reason>)

Always exits 0: it must never change a run's result. The `BEADS:` prefix matches no
lib/classify.sh pattern. Python 3.9+, stdlib only.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from enum import Enum

PREFIX = "BEADS:"
TITLE_MAX = 60
FIELDS = (
    "ready_issues",
    "in_progress_issues",
    "blocked_issues",
    "open_issues",
    "closed_issues",
    "total_issues",
    "epics_eligible_for_closure",
)
USAGE = """usage: bead_stats.py start STATS_JSON READY_JSON
       bead_stats.py summary STATS_JSON [ID ...] [--requeued ID->BLOCKERS ...]
  STATS_JSON   output of `bd stats --json`
  READY_JSON   output of `bd ready --json --exclude-type epic --sort priority --limit 1`;
               "" when it failed (prints "next unavailable", not "next none")
  -h, --help   show this help and exit
"""


@dataclass(frozen=True)
class Stats:
    ready: int
    in_progress: int
    blocked: int
    open: int
    closed: int
    total: int
    epics_ready: int


@dataclass(frozen=True)
class Next:
    id: str
    title: str
    priority: object


def _load(text: str) -> object:
    if not text.strip():
        raise ValueError("empty input")
    try:
        return json.loads(text)
    except ValueError:
        raise ValueError("not JSON") from None


def parse_stats(text: str) -> Stats:
    data = _load(text)
    summary = data.get("summary") if isinstance(data, dict) else None
    if not isinstance(summary, dict):
        raise ValueError("summary is missing")
    values = []
    for field in FIELDS:
        value = summary.get(field, 0)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{field} is not a non-negative integer")
        values.append(value)
    return Stats(*values)


def parse_next(text: str) -> Next | None:
    data = _load(text)
    if not isinstance(data, list):
        raise ValueError("ready list is not a JSON list")
    if not data or not isinstance(data[0], dict):
        return None
    first = data[0]
    title = " ".join(str(first.get("title", "")).replace('"', "'").split())
    if len(title) > TITLE_MAX:
        title = title[: TITLE_MAX - 3] + "..."
    return Next(str(first.get("id", "?")), title, first.get("priority", "?"))


class _Unavailable(Enum):
    """`bd ready` failed: the next bead is unknown, which is not an empty queue."""

    UNAVAILABLE = "unavailable"


NEXT_UNAVAILABLE = _Unavailable.UNAVAILABLE


def start_line(stats: Stats, nxt: Next | _Unavailable | None) -> str:
    if isinstance(nxt, Next):
        head = f'next {nxt.id} "{nxt.title}" (P{nxt.priority})'
    elif nxt is NEXT_UNAVAILABLE:
        head = "next unavailable"
    elif nxt is None:
        head = "next none"
    else:
        raise TypeError(f"next must be Next, NEXT_UNAVAILABLE or None, not {nxt!r}")
    return (
        f"{PREFIX} {head} | ready {stats.ready} in_progress {stats.in_progress} "
        f"blocked {stats.blocked} | open {stats.open} closed {stats.closed} of {stats.total} "
        f"| epics ready to close {stats.epics_ready}"
    )


def summary_line(stats: Stats, worked: list[str], requeued: list[str] | None = None) -> str:
    unique = list(dict.fromkeys(i for i in worked if i))
    ids = " ".join(unique) if unique else "none"
    pairs = "; ".join(p.replace("->", " -> ") for p in requeued or [])
    moved = f"requeued {pairs} | " if pairs else ""
    return (
        f"{PREFIX} loop worked {len(unique)} issue(s): {ids} | {moved}closed {stats.closed} of "
        f"{stats.total} | still to do: ready {stats.ready}, open {stats.open}, "
        f"blocked {stats.blocked}"
    )


def main(argv: list[str]) -> str:
    if len(argv) >= 3 and argv[0] == "start":
        # READY_JSON "" = `bd ready` failed or timed out (hermes-run passes "[]" for an empty list)
        nxt = parse_next(argv[2]) if argv[2] else NEXT_UNAVAILABLE
        return start_line(parse_stats(argv[1]), nxt)
    if len(argv) >= 2 and argv[0] == "summary":
        rest = argv[2:]
        cut = rest.index("--requeued") if "--requeued" in rest else len(rest)
        return summary_line(parse_stats(argv[1]), rest[:cut], rest[cut + 1 :])
    raise ValueError("usage: start STATS READY | summary STATS [ID ...]")


if __name__ == "__main__":
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(USAGE + "\n" + (__doc__ or ""))
        sys.exit(0)
    try:
        print(main(sys.argv[1:]))
    except ValueError as exc:
        print(f"{PREFIX} unavailable ({exc})")
    except Exception as exc:  # last resort: never change a run's result
        print(f"{PREFIX} unavailable (internal error: {type(exc).__name__})")
    sys.exit(0)
