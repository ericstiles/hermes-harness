"""Identify the beads issue a Hermes PR belongs to (pure)."""

from __future__ import annotations

import re

BRANCH_PREFIX = "bd/"
_TITLE = re.compile(r"^\w+\(([^)\s]+)\)!?:")
_BODY = re.compile(r"^Bead:\s*(\S+)\s*$", re.MULTILINE)


class BeadMismatch(ValueError):
    """The branch, PR title and PR body do not name the same bead."""


def resolve_bead(branch: str, title: str, body: str) -> str:
    """Return the bead id when branch `bd/<id>`, title `type(<id>):` and `Bead: <id>` agree."""
    if not branch.startswith(BRANCH_PREFIX) or len(branch) == len(BRANCH_PREFIX):
        raise BeadMismatch(f"branch {branch!r} is not bd/<id>")
    from_branch = branch[len(BRANCH_PREFIX) :]
    title_match = _TITLE.match(title)
    if title_match is None:
        raise BeadMismatch(f"title {title!r} does not start with type(<id>):")
    body_match = _BODY.search(body)
    if body_match is None:
        raise BeadMismatch("body has no 'Bead: <id>' line")
    return _same_bead(from_branch, title_match.group(1), body_match.group(1))


def _same_bead(*ids: str) -> str:
    """The one bead the ids name, as its full id; BeadMismatch when they name different ones.

    A bead id is `<prefix>-<id part>`; the prefix may contain hyphens, the id part never does.
    An agent sometimes writes only the id part (`b8p.14` for `myrepo-b8p.14`), so a short id
    (no hyphen) matches a full id whose part after the last hyphen equals it. Full ids must be
    identical: a different prefix is a different bead.
    """
    full = {i for i in ids if "-" in i}
    if len(full) > 1:
        raise BeadMismatch(f"branch, title and body disagree: {sorted(set(ids))}")
    canonical = full.pop() if full else ids[0]
    short_form = canonical.rsplit("-", 1)[-1]
    if any(i not in (canonical, short_form) for i in ids):
        raise BeadMismatch(f"branch, title and body disagree: {sorted(set(ids))}")
    return canonical
