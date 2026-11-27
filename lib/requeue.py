#!/usr/bin/env python3
"""requeue: reads the beads dependency graph for hermes-run's requeue chain (bead 35r).

    requeue.py check ID   # may the loop requeue ID? -> OK <blocker ids,> | REFUSED <why>
    requeue.py walk ID    # what to work on ID's chain -> PICK <id> | NONE | CLOSED
                          #   | CYCLE <a -> b -> a> | ERROR <why>

Blockers are the dependencies of type `blocks` that are not closed (parent-child and
discovered-from do not block). Read-only: it only runs `bd show` and `bd ready`, each under
HERMES_BEADS_TIMEOUT (15s). Prints exactly one line and exits 0. Python 3.9+, stdlib only.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass

DEFAULT_TIMEOUT = 15.0
UNITS = {"": 1, "s": 1, "m": 60, "h": 3600}


class BeadsError(RuntimeError):
    """`bd` failed, timed out or printed something unexpected."""


@dataclass(frozen=True)
class Bead:
    id: str
    status: str
    assignee: str
    blockers: tuple[str, ...]  # open ones, in priority then id order


Fetch = Callable[[str], Bead]


def parse_bead(data: object) -> Bead:
    """One item of `bd show <id> --json`."""
    try:
        open_deps = [
            d
            for d in data.get("dependencies") or []
            if d["dependency_type"] == "blocks" and d["status"] != "closed"
        ]
        ordered = sorted(open_deps, key=lambda d: (d.get("priority", 99), d["id"]))
        return Bead(
            str(data["id"]),
            str(data["status"]),
            str(data.get("assignee") or ""),
            tuple(str(d["id"]) for d in ordered),
        )
    except (AttributeError, KeyError, TypeError):
        raise BeadsError("unexpected bead JSON") from None


def find(root: str, fetch: Fetch, ready: frozenset[str]) -> tuple[str, str]:
    """Depth-first over root's open blockers: the first ready bead, deepest first.

    Returns ("PICK", id), ("CYCLE", "a -> b -> a") or ("NONE", "").
    """
    done: set[str] = set()

    def visit(bead_id: str, path: tuple[str, ...]) -> tuple[str, str]:
        if bead_id in path:
            cycle = (*path[path.index(bead_id) :], bead_id)
            return "CYCLE", " -> ".join(cycle)
        if bead_id in done:
            return "NONE", ""
        for blocker in fetch(bead_id).blockers:
            result = visit(blocker, (*path, bead_id))
            if result[0] != "NONE":
                return result
        done.add(bead_id)
        return ("PICK", bead_id) if bead_id in ready else ("NONE", "")

    return visit(root, ())


def check(root: str, fetch: Fetch) -> str:
    bead = fetch(root)
    if bead.status != "open":
        return f"REFUSED {root} is {bead.status}, not open"
    if bead.assignee:
        return f"REFUSED {root} is still assigned to {bead.assignee}"
    if not bead.blockers:
        return f"REFUSED {root} has no open blocker (bd dep add {root} <blocker>)"
    kind, detail = find(root, fetch, frozenset())
    if kind == "CYCLE":
        return f"REFUSED dependency cycle: {detail}"
    return "OK " + ",".join(bead.blockers)


def walk(root: str, fetch: Fetch, ready: Callable[[], frozenset[str]]) -> str:
    if fetch(root).status == "closed":
        return "CLOSED"
    kind, detail = find(root, fetch, ready())
    return f"{kind} {detail}".rstrip()


def _timeout() -> float:
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([smh]?)", os.environ.get("HERMES_BEADS_TIMEOUT", ""))
    return float(match[1]) * UNITS[match[2]] if match else DEFAULT_TIMEOUT


def _bd_json(*args: str) -> list:
    label = "bd " + " ".join(args[:2] if args[0] == "show" else args[:1])
    try:
        run = subprocess.run(
            ["bd", *args, "--json"], capture_output=True, text=True, timeout=_timeout()
        )
        if run.returncode != 0:
            raise BeadsError(f"{label} failed (exit {run.returncode})")
        data = json.loads(run.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        raise BeadsError(f"{label} failed ({type(exc).__name__})") from None
    if not isinstance(data, list):
        raise BeadsError(f"{label} failed (not a JSON list)")
    return data


def bd_fetch() -> Fetch:
    cache: dict[str, Bead] = {}

    def fetch(bead_id: str) -> Bead:
        if bead_id not in cache:
            data = _bd_json("show", bead_id)
            if not data:
                raise BeadsError(f"bd show {bead_id} failed (no such bead)")
            cache[bead_id] = parse_bead(data[0])
        return cache[bead_id]

    return fetch


def bd_ready() -> frozenset[str]:
    items = _bd_json("ready", "--exclude-type", "epic", "--limit", "0")
    return frozenset(str(i.get("id")) for i in items if isinstance(i, dict))


def main(argv: list[str]) -> str:
    if len(argv) == 2 and argv[0] == "check":
        try:
            return check(argv[1], bd_fetch())
        except BeadsError as exc:
            return f"REFUSED {exc}"
    if len(argv) == 2 and argv[0] == "walk":
        try:
            return walk(argv[1], bd_fetch(), bd_ready)
        except BeadsError as exc:
            return f"ERROR {exc}"
    raise SystemExit("usage: requeue.py check ID | walk ID")


if __name__ == "__main__":
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(__doc__)
        sys.exit(0)
    print(main(sys.argv[1:]))
