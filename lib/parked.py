#!/usr/bin/env python3
"""parked: after a run ends RUN_BLOCKED, make sure its issue is parked (bead yiv).

    parked.py snapshot FILE         # before a run: every issue's status, assignee, notes -> FILE
    parked.py park ID FILE LOGREF   # after RUN_BLOCKED -> ID <full id>, "LOG <explanation>"
                                    #   lines, CHANGED once beads were written, BRANCH <bd/...>,
                                    #   then PARKED <the reason> | NOT_PARKED <why>

Parked means: status blocked, nobody assigned, and a note line starting `BLOCKED:` that this run
added (told apart from older ones by the snapshot). Whatever the agent left undone is done here.

A claim may name a short id, so the issue is shown first and everything else uses its real id.
Only this run's issue is changed. Nothing is written when the issue was not open before the run, is
now closed or deferred, is open but assigned (the claim did not take), or when the snapshot is
missing or does not have it. An assignee it had before the run is kept when the run left the issue
blocked; one that is in_progress (this run's claim) is released. Writes are at most two
`bd update`s, status first (bd refuses to reassign another actor's in_progress issue), each pinned
with --if-status/--if-assignee to what was just read. The caller pushes. Each `bd` call is under
HERMES_BEADS_TIMEOUT (15s). Exits 0. Python 3.9+, stdlib only.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass

from requeue import REVIEW_FIX, BeadsError, bd_json, bd_run

PREFIX = "BLOCKED:"  # the start of the note line the workflow has the agent append
SHOWN_MAX = 300  # characters of a note quoted on a log line
PARKABLE = ("open", "in_progress", "blocked")


@dataclass(frozen=True)
class Before:
    """An issue as it was before the run."""

    status: str
    assignee: str
    notes: str


def clean(text: str) -> str:
    """A note line fit for a log: printable, and not endless."""
    shown = "".join(c for c in text if c.isprintable()).strip()
    return shown if len(shown) <= SHOWN_MAX else shown[: SHOWN_MAX - 3] + "..."


def snapshot(path: str) -> None:
    """Write every issue's status, assignee and notes to path; a failed read leaves no file."""
    if os.path.exists(path):
        os.remove(path)  # an older run's snapshot must never pass for this run's
    items = bd_json("list", "--all", "--limit", "0")
    try:
        found = {
            str(i["id"]): {
                "status": str(i["status"]),
                "assignee": str(i.get("assignee") or ""),
                "notes": str(i.get("notes") or ""),
            }
            for i in items
        }
    except (AttributeError, KeyError, TypeError):
        raise BeadsError("unexpected `bd list` JSON") from None
    with open(path, "w", encoding="utf-8") as out:
        json.dump(found, out)


def load_before(path: str, bead_id: str) -> Before | None:
    """The issue before the run; None when the snapshot is missing or does not have it."""
    try:
        with open(path, encoding="utf-8") as source:
            data = json.load(source)
        found = data[bead_id]
        return Before(found["status"], found["assignee"], found["notes"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def added_lines(old: str, new: str) -> list[str]:
    """The non-blank lines of `new` that `old` does not account for, in order."""
    unmatched = old.splitlines()
    added = []
    for line in new.splitlines():
        if line in unmatched:
            unmatched.remove(line)
        elif line.strip():
            added.append(line)
    return added


def blocked_lines(lines: list[str]) -> str:
    """The last `BLOCKED:` line, else an empty string."""
    found = [line for line in lines if line.startswith(PREFIX)]
    return found[-1] if found else ""


def host_note(before: Before, status: str, notes: str, logref: str) -> str:
    """The note the harness adds when the agent did not park the issue properly."""
    added = added_lines(before.notes, notes)
    if status == "blocked" and added:
        return (
            f"{PREFIX} run ended RUN_BLOCKED without a BLOCKED: note "
            f"(it wrote: {clean(added[-1])}); see {logref}"
        )
    return f"{PREFIX} run ended RUN_BLOCKED without parking the issue; see {logref}"


def show(bead_id: str) -> dict:
    data = bd_json("show", bead_id)
    if not data or not isinstance(data[0], dict):
        raise BeadsError(f"bd show {bead_id} failed (no such bead)")
    return data[0]


def wip_branch(bead_id: str, data: dict) -> str:
    """The branch the run worked on: a review fix pushes to its ticket's branch."""
    if REVIEW_FIX in (data.get("labels") or []):
        for dep in data.get("dependencies") or []:
            if dep.get("dependency_type") == "discovered-from":
                return f"bd/{dep['id']}"
    return f"bd/{bead_id}"


def refusal(bead_id: str, before: Before, status: str, assignee: str) -> str:
    """Why this issue is not this run's to change, else an empty string."""
    if before.status != "open":
        return f"{bead_id} was {before.status} before this run, so it is not this run's to change"
    if status not in PARKABLE:
        return f"{bead_id} is {status}; left as it is"
    if status == "open" and assignee:  # a claim that took leaves the issue in_progress
        return (
            f"{bead_id} is open and assigned to {assignee}: this run's claim did not take, "
            "so nothing is changed"
        )
    return ""


def parked_lines(bead_id: str, data: dict, reason: str) -> list[str]:
    return [f"BRANCH {wip_branch(bead_id, data)}", f"PARKED {clean(reason)}"]


def park_unknown(bead_id: str, data: dict) -> list[str]:
    """Without an earlier record nothing is written: only an already parked issue is accepted."""
    status = str(data.get("status"))
    reason = blocked_lines(str(data.get("notes") or "").splitlines())
    if status == "blocked" and reason:
        return [
            f"LOG no record of {bead_id} from before the run: taking its last BLOCKED: note as "
            "this run's, and changing nothing",
            *parked_lines(bead_id, data, reason),
        ]
    return [
        f"NOT_PARKED no record of {bead_id} from before the run, and it is {status} without "
        "being parked, so nothing is changed"
    ]


def updates(status: str, assignee: str, release: bool, note: str) -> list[tuple[str, ...]]:
    """The `bd update` arguments still needed, each pinned to the state it expects."""
    pin = ("--if-assignee", assignee)
    rest = (
        *(("--assignee", "") if release else ()),
        *(("--append-notes", note) if note else ()),
    )
    first = [("--if-status", status, *pin, "--status", "blocked")] if status != "blocked" else []
    return [*first, *([("--if-status", "blocked", *pin, *rest)] if rest else [])]


def park_known(bead_id: str, data: dict, before: Before, logref: str) -> list[str]:
    """Park an issue whose state before the run is on record."""
    status = str(data.get("status"))
    assignee = str(data.get("assignee") or "")
    notes = str(data.get("notes") or "")
    why_not = refusal(bead_id, before, status, assignee)
    if why_not:
        return [f"NOT_PARKED {why_not}"]
    # an assignee from before the run is kept unless the issue is in_progress (this run's claim)
    keep = bool(assignee) and assignee == before.assignee and status == "blocked"
    out = [f"LOG {bead_id} was assigned to {assignee} before this run: the assignee is kept"]
    out = out if keep else []
    reason = blocked_lines(added_lines(before.notes, notes))
    note = "" if reason and status == "blocked" else host_note(before, status, notes, logref)
    todo = updates(status, assignee, bool(assignee) and not keep, note)
    written: list[str] = []
    try:
        for args in todo:
            bd_run("update", bead_id, *args)
            written = ["CHANGED"]
        if todo:
            data = show(bead_id)
    except BeadsError as exc:
        return [*out, *written, f"NOT_PARKED could not park {bead_id} ({exc})"]
    left = str(data.get("assignee") or "")
    if data.get("status") != "blocked" or left not in ("", assignee if keep else ""):
        return [
            *out,
            *written,
            f"NOT_PARKED could not park {bead_id} (it is still {data.get('status')}, "
            f"assignee {left or 'none'})",
        ]
    return [*out, *written, *parked_lines(bead_id, data, reason or note)]


def park(claimed: str, snapshot_path: str, logref: str) -> list[str]:
    """The output lines of `parked.py park`."""
    data = show(claimed)
    bead_id = str(data["id"])  # a claim may use a short id; the snapshot is keyed by the real one
    before = load_before(snapshot_path, bead_id)
    if before is None:
        lines = park_unknown(bead_id, data)
    else:
        lines = park_known(bead_id, data, before, logref)
    return [f"ID {bead_id}", *lines]


def main(argv: list[str]) -> str:
    if len(argv) == 2 and argv[0] == "snapshot":
        try:
            snapshot(argv[1])
        except (BeadsError, OSError) as exc:
            raise SystemExit(f"parked.py: {exc}") from None
        return ""
    if len(argv) == 4 and argv[0] == "park":
        bead_id = argv[1]
        try:
            return "\n".join(park(bead_id, argv[2], argv[3]))
        except (BeadsError, AttributeError, KeyError, TypeError) as exc:
            return f"NOT_PARKED could not park {bead_id} ({exc})"
    raise SystemExit("usage: parked.py snapshot FILE | park ID FILE LOGREF")


if __name__ == "__main__":
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(__doc__)
        sys.exit(0)
    print(main(sys.argv[1:]))
