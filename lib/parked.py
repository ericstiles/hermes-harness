#!/usr/bin/env python3
"""parked: after a run ends RUN_BLOCKED, make sure its issue is parked (bead yiv).

    parked.py snapshot FILE         # before a run: every issue's status and notes -> FILE
    parked.py park ID FILE LOGREF   # after RUN_BLOCKED -> "LOG <explanation>" lines, CHANGED when
                                    #   beads were written, BRANCH <bd/...>, then
                                    #   PARKED <the reason> | NOT_PARKED <why>

Parked means: status blocked, nobody assigned, and a note line starting `BLOCKED:` that this run
added (told apart from older ones by the snapshot). Whatever the agent left undone is done here.
An issue that was not open before the run, or is now closed or deferred, is left as it is.
Writes only that one `bd update`; the caller pushes. Each `bd` call is under HERMES_BEADS_TIMEOUT
(15s). Exits 0. Python 3.9+, stdlib only.
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
    notes: str


def clean(text: str) -> str:
    """A note line fit for a log: printable, and not endless."""
    shown = "".join(c for c in text if c.isprintable()).strip()
    return shown if len(shown) <= SHOWN_MAX else shown[: SHOWN_MAX - 3] + "..."


def snapshot(path: str) -> None:
    """Write every issue's status and notes to path; a failed read leaves no file behind."""
    if os.path.exists(path):
        os.remove(path)  # an older run's snapshot must never pass for this run's
    items = bd_json("list", "--all", "--limit", "0")
    try:
        found = {
            str(i["id"]): {"status": str(i["status"]), "notes": str(i.get("notes") or "")}
            for i in items
        }
    except (AttributeError, KeyError, TypeError):
        raise BeadsError("unexpected `bd list` JSON") from None
    with open(path, "w", encoding="utf-8") as out:
        json.dump(found, out)


def load_before(path: str, bead_id: str) -> Before | None:
    """The issue before the run; None when that is unknown. An issue created since is empty."""
    try:
        with open(path, encoding="utf-8") as source:
            data = json.load(source)
        found = data.get(bead_id)
        return Before("open", "") if found is None else Before(found["status"], found["notes"])
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
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


def this_runs_reason(before: Before | None, status: str, notes: str) -> str:
    """The agent's last BLOCKED: line from this run, else an empty string. Without the snapshot an
    older line cannot be told apart, so it counts only when the issue is already blocked."""
    if before is None:
        lines = notes.splitlines() if status == "blocked" else []
    else:
        lines = added_lines(before.notes, notes)
    found = [line for line in lines if line.startswith(PREFIX)]
    return found[-1] if found else ""


def host_note(before: Before | None, status: str, notes: str, logref: str) -> str:
    """The note the harness adds when the agent did not park the issue properly."""
    added = added_lines(before.notes, notes) if before is not None else []
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


def park(bead_id: str, before: Before | None, logref: str) -> list[str]:
    """The output lines of `parked.py park`."""
    data = show(bead_id)
    status = str(data.get("status"))
    notes = str(data.get("notes") or "")
    if before is not None and before.status != "open":
        return [
            f"NOT_PARKED {bead_id} was {before.status} before this run, so it is not this "
            "run's to change"
        ]
    if status not in PARKABLE:
        return [f"NOT_PARKED {bead_id} is {status}; left as it is"]
    out = []
    if before is None:
        out.append(
            "LOG could not read the notes from before the run: a BLOCKED: note on a blocked "
            "issue is taken as this run's"
        )
    reason = this_runs_reason(before, status, notes)
    note = "" if reason and status == "blocked" else host_note(before, status, notes, logref)
    changes = [
        *(("--status", "blocked") if status != "blocked" else ()),
        *(("--assignee", "") if data.get("assignee") else ()),
        *(("--append-notes", note) if note else ()),
    ]
    if changes:
        try:
            bd_run("update", bead_id, *changes)
            data = show(bead_id)
        except BeadsError as exc:
            return [*out, "CHANGED", f"NOT_PARKED could not park {bead_id} ({exc})"]
        if data.get("status") != "blocked" or data.get("assignee"):
            return [
                *out,
                "CHANGED",
                f"NOT_PARKED could not park {bead_id} (it is still {data.get('status')}, "
                f"assignee {data.get('assignee') or 'none'})",
            ]
        out.append("CHANGED")
    return [*out, f"BRANCH {wip_branch(bead_id, data)}", f"PARKED {clean(reason or note)}"]


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
            return "\n".join(park(bead_id, load_before(argv[2], bead_id), argv[3]))
        except (BeadsError, AttributeError, KeyError, TypeError) as exc:
            return f"NOT_PARKED could not park {bead_id} ({exc})"
    raise SystemExit("usage: parked.py snapshot FILE | park ID FILE LOGREF")


if __name__ == "__main__":
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(__doc__)
        sys.exit(0)
    print(main(sys.argv[1:]))
