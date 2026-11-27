#!/usr/bin/env python3
"""requeue: reads beads to choose what hermes-run's next run works (beads 35r, 66y).

    requeue.py check ID   # may the loop requeue ID? -> OK <blocker,ids> [UNNOTED] | REFUSED <why>
    requeue.py pick       # what the next run should work -> "LOG <explanation>" lines, then
                          #   PICK <id> | NONE
    requeue.py normal     # the first ready issue when no chain applies -> the same lines
    requeue.py waiting    # "LOG ..." naming the ready issues unattended runs skip, else nothing
    requeue.py labels     # the skipped labels, comma separated (exit 1 if the setting is invalid)

Issues labelled in HERMES_EXCLUDE_LABELS (default owner-present; empty skips nothing) are for a
person to run: no pick here ever names one.

The chain is rebuilt from beads every time, so it survives launches: every open issue with a
`REQUEUED: blocked by` note and a `blocks` dependency. Order: a requeued issue whose blockers are
all closed; else, per requeued issue (priority, then id), depth-first over its open blockers, the
first ready one, or the ready review fix of one that is not ready. Blockers are dependencies of
type `blocks` that are not closed (parent-child and discovered-from do not block). Read-only: only
`bd show`, `bd ready` and `bd list`, each under HERMES_BEADS_TIMEOUT (15s). Exits 0. Python 3.9+,
stdlib only.
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
DEFAULT_EXCLUDED = "owner-present"
# a label goes into the run prompt's shell command, so only characters that need no quoting
LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")
UNITS = {"": 1, "s": 1, "m": 60, "h": 3600}
NOTE = "REQUEUED: blocked by"  # the start of the note line the workflow has the agent append
REVIEW_FIX = "review-fix"


class BeadsError(RuntimeError):
    """`bd` failed, timed out or printed something unexpected."""


@dataclass(frozen=True)
class Bead:
    id: str
    status: str
    assignee: str
    blockers: tuple[str, ...]  # open ones, in priority then id order
    noted: bool  # has the REQUEUED note
    labels: tuple[str, ...] = ()


@dataclass(frozen=True)
class Queue:
    ready: frozenset[str]
    fixes: dict[str, tuple[str, ...]]  # ticket id -> its ready review-fix issues


Fetch = Callable[[str], Bead]


def has_note(data: dict) -> bool:
    return any(line.startswith(NOTE) for line in str(data.get("notes") or "").splitlines())


def _rank(item: dict, key: str = "id") -> tuple:
    return item.get("priority", 99), item[key]


def excluded_labels() -> tuple[str, ...]:
    """HERMES_EXCLUDE_LABELS as a tuple (unset: owner-present; empty: none)."""
    raw = os.environ.get("HERMES_EXCLUDE_LABELS", DEFAULT_EXCLUDED)
    labels = tuple(part.strip() for part in raw.split(",") if part.strip())
    if not all(LABEL.fullmatch(label) for label in labels):
        raise ValueError(
            f"HERMES_EXCLUDE_LABELS='{raw}' is not a comma separated list of labels "
            "(letters, digits and . _ : / - only)"
        )
    return labels


def ready_args(excluded: tuple[str, ...]) -> tuple[str, ...]:
    """The `bd ready` arguments that list what an unattended run may take."""
    skip = ("--exclude-label", ",".join(excluded)) if excluded else ()
    return ("ready", "--exclude-type", "epic", *skip)


def parse_bead(data: object) -> Bead:
    """One item of `bd show <id> --json`."""
    try:
        open_deps = [
            d
            for d in data.get("dependencies") or []
            if d["dependency_type"] == "blocks" and d["status"] != "closed"
        ]
        return Bead(
            str(data["id"]),
            str(data["status"]),
            str(data.get("assignee") or ""),
            tuple(str(d["id"]) for d in sorted(open_deps, key=_rank)),
            has_note(data),
            tuple(str(label) for label in data.get("labels") or []),
        )
    except (AttributeError, KeyError, TypeError):
        raise BeadsError("unexpected bead JSON") from None


def parse_queue(items: list) -> Queue:
    """`bd ready --json`: the ready ids, and the ready review fixes by the ticket they fix."""
    try:
        fixes: dict[str, tuple[str, ...]] = {}
        for item in sorted(items, key=_rank):
            if REVIEW_FIX not in (item.get("labels") or []):
                continue
            for dep in item.get("dependencies") or []:
                if dep["type"] == "discovered-from":
                    ticket = str(dep["depends_on_id"])
                    fixes[ticket] = (*fixes.get(ticket, ()), str(item["id"]))
        return Queue(frozenset(str(i["id"]) for i in items), fixes)
    except (AttributeError, KeyError, TypeError):
        raise BeadsError("unexpected `bd ready` JSON") from None


def parse_requeued(items: list) -> list[str]:
    """`bd list` output -> the requeued issues: the note line and a `blocks` edge, best first."""
    try:
        found = [
            i
            for i in items
            if has_note(i) and any(d["type"] == "blocks" for d in i.get("dependencies") or [])
        ]
        return [str(i["id"]) for i in sorted(found, key=_rank)]
    except (AttributeError, KeyError, TypeError):
        raise BeadsError("unexpected `bd list` JSON") from None


def find_cycle(root: str, fetch: Fetch) -> str:
    """Return the cycle in root's open blockers as `a -> b -> a`, else an empty string."""
    done: set[str] = set()

    def visit(bead_id: str, path: tuple[str, ...]) -> str:
        if bead_id in path:
            return " -> ".join((*path[path.index(bead_id) :], bead_id))
        if bead_id in done:
            return ""
        for blocker in fetch(bead_id).blockers:
            cycle = visit(blocker, (*path, bead_id))
            if cycle:
                return cycle
        done.add(bead_id)
        return ""

    return visit(root, ())


def check(root: str, fetch: Fetch) -> str:
    bead = fetch(root)
    if bead.status != "open":
        return f"REFUSED {root} is {bead.status}, not open"
    if bead.assignee:
        return f"REFUSED {root} is still assigned to {bead.assignee}"
    if not bead.blockers:
        return f"REFUSED {root} has no open blocker (bd dep add {root} <blocker>)"
    cycle = find_cycle(root, fetch)
    if cycle:
        return f"REFUSED dependency cycle: {cycle}"
    return "OK " + ",".join(bead.blockers) + ("" if bead.noted else " UNNOTED")


def describe(bead: Bead, excluded: tuple[str, ...] = ()) -> str:
    """Why a chain member with nothing under it cannot be worked now."""
    held = [label for label in bead.labels if label in excluded]
    if bead.status == "open" and held:
        return f"is open but labelled {','.join(held)}: a person must run it"
    if bead.status == "in_progress":
        who = f", claimed by {bead.assignee}" if bead.assignee else ""
        return f"is in_progress{who} (being worked, or its PR waits for review)"
    if bead.status == "blocked":
        return f"is blocked: needs a human (bd show {bead.id})"
    if bead.status == "open":
        return "is open but bd ready does not list it (deferred, or its epic is blocked)"
    return f"is {bead.status}"


def pick(
    requeued: list[str], fetch: Fetch, queue: Queue, excluded: tuple[str, ...] = ()
) -> tuple[list[str], str]:
    """The explanation lines and the id to work next ("" = no chain applies)."""
    if not requeued:
        return [], ""
    log = [f"{len(requeued)} requeued issue(s) still to be finished: {' '.join(requeued)}"]
    for root in requeued:
        if root in queue.ready:
            log.append(f"next pick: {root} (it was requeued and its blockers are closed)")
            return log, root
    seen: set[str] = set()

    def follow(bead_id: str, path: tuple[str, ...]) -> str:
        chain = " -> ".join((*path, bead_id))
        if bead_id in path:
            cycle = " -> ".join((*path[path.index(bead_id) :], bead_id))
            log.append(f"dependency cycle {cycle}: needs a human (bd dep remove); chain skipped")
            return ""
        if bead_id in seen:
            return ""
        seen.add(bead_id)
        bead = fetch(bead_id)
        for blocker in bead.blockers:
            log.append(f"{bead_id} waits on {blocker}")
            found = follow(blocker, (*path, bead_id))
            if found:
                return found
        if path and bead_id in queue.ready:
            log.append(f"next pick: {bead_id} (a ready blocker; chain {chain})")
            return bead_id
        for fix in queue.fixes.get(bead_id, ()):
            log.append(f"next pick: {fix} (a review fix of {bead_id}; chain {chain} -> {fix})")
            return fix
        if not bead.blockers:
            log.append(f"{bead_id} {describe(bead, excluded)}")
        return ""

    for root in requeued:
        found = follow(root, ())
        if found:
            return log, found
    log.append(
        "nothing on these chains is ready: picking as usual. A requeued issue is taken first "
        "once its blockers are closed (a blocker closes when its PR is merged)"
    )
    return log, ""


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
        data = json.loads(run.stdout.strip() or "[]")  # no output: nothing found
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


def next_pick() -> list[str]:
    """The output lines of `requeue.py pick`."""
    try:
        listed = _bd_json("list", "--status=open", "--notes-contains", NOTE, "--limit", "0")
        requeued = parse_requeued(listed)
        if not requeued:
            return ["NONE"]
        excluded = excluded_labels()
        queue = parse_queue(_bd_json(*ready_args(excluded), "--limit", "0"))
        log, chosen = pick(requeued, bd_fetch(), queue, excluded)
    except BeadsError as exc:
        log, chosen = [f"could not read the requeue chain ({exc}): picking as usual"], ""
    return [*(f"LOG {line}" for line in log), f"PICK {chosen}" if chosen else "NONE"]


def _ids(items: list) -> list[str]:
    try:
        return [str(item["id"]) for item in items]
    except (KeyError, TypeError):
        raise BeadsError("unexpected `bd ready` JSON") from None


def normal_pick() -> list[str]:
    """The output lines of `requeue.py normal`: the issue step 1 of the workflow would take."""
    try:
        args = ready_args(excluded_labels())
        ids = _ids(_bd_json(*args, "--sort", "priority", "--limit", "1"))
    except BeadsError as exc:
        return [f"LOG could not read the ready list ({exc}): Hermes picks in step 1", "NONE"]
    return [f"PICK {ids[0]}" if ids else "NONE"]


def waiting() -> list[str]:
    """The output lines of `requeue.py waiting`."""
    labels = ",".join(excluded_labels())
    if not labels:
        return []
    args = ("ready", "--exclude-type", "epic", "--label-any", labels)
    try:
        ids = _ids(_bd_json(*args, "--sort", "priority", "--limit", "0"))
    except BeadsError as exc:
        return [f"LOG could not list the {labels} issues ({exc})"]
    if not ids:
        return []
    return [f"LOG skipping {labels} issues: {' '.join(ids)} (a person must run them)"]


def main(argv: list[str]) -> str:
    if len(argv) == 2 and argv[0] == "check":
        try:
            return check(argv[1], bd_fetch())
        except BeadsError as exc:
            return f"REFUSED {exc}"
    commands = {"pick": next_pick, "normal": normal_pick, "waiting": waiting}
    try:
        if argv == ["labels"]:
            return ",".join(excluded_labels())
        if len(argv) == 1 and argv[0] in commands:
            return "\n".join(commands[argv[0]]())
    except ValueError as exc:
        raise SystemExit(str(exc)) from None
    raise SystemExit("usage: requeue.py check ID | pick | normal | waiting | labels")


if __name__ == "__main__":
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(__doc__)
        sys.exit(0)
    print(main(sys.argv[1:]))
