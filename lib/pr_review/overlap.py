"""Open beads that name a file this PR changes: a non-blocking note for a human (bead 9cv).

A PR (often a review-fix) can fix another open bead B without the `Fixed in PR <url>` note
on B that AGENTS.md asks for (Review-fix issues, step 3). This is a heuristic: it matches
file paths, not symbols, so it only ever adds a line to the review comment. It never
blocks, files or closes anything. Pure functions; review.with_related wires it in.
"""

from __future__ import annotations

import re
from collections.abc import Iterable

_DIFF_HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$", re.MULTILINE)
# A file name alone this common says nothing about which file a bead means; the full
# path still matches.
GENERIC_NAMES = frozenset({"__init__.py", "__main__.py", "README.md"})
TEXT_FIELDS = ("title", "description", "design", "acceptance_criteria")
MAX_NOTES = 10
# The AGENTS.md template's "Expected to modify" section (bold label or `##` heading), up to
# the next section: when a bead has it, only those files count, not files it mentions as
# context.
_EXPECTED = re.compile(
    r"Expected to modify\b(.*?)(?=Out of scope|^\s*(?:##|\*\*|\d+\. \*\*)|\Z)",
    re.DOTALL | re.MULTILINE,
)


def changed_paths(diff: str) -> tuple[str, ...]:
    """Paths a `git diff` touches, in order, each once (both sides of a rename)."""
    seen: dict[str, None] = {}
    for old, new in _DIFF_HEADER.findall(diff):
        seen[old] = None
        seen[new] = None
    return tuple(seen)


def _mentions(text: str, name: str) -> bool:
    # Not part of a longer name: no word/./- before it, no word/- or ".x" right after it.
    return re.search(rf"(?<![\w.-]){re.escape(name)}(?![\w-]|\.\w)", text) is not None


def names_path(text: str, path: str) -> bool:
    """True when text names path: in full, or by its file name unless that is generic."""
    if _mentions(text, path):
        return True
    name = path.rsplit("/", 1)[-1]
    return name != path and name not in GENERIC_NAMES and _mentions(text, name)


def _scope_text(row: dict[str, object]) -> str:
    """The bead text that says which files it changes: its Expected-to-modify section if
    it has one, else its whole text (older beads have no such section)."""
    text = "\n".join(str(row.get(f) or "") for f in TEXT_FIELDS)
    sections = _EXPECTED.findall(text)
    return "\n".join(sections) if sections else text


def related_notes(
    paths: Iterable[str], rows: Iterable[dict[str, object]], skip: set[str]
) -> tuple[str, ...]:
    """One note per open, non-epic bead (not in skip) whose text names a changed path."""
    paths = tuple(paths)
    notes = []
    for row in rows:
        bead = str(row.get("id", ""))
        if not bead or bead in skip or row.get("status") == "closed":
            continue
        if row.get("issue_type") == "epic":  # an epic lists its children's files
            continue
        text = _scope_text(row)
        hits = [p for p in paths if names_path(text, p)]
        if hits:
            files = ", ".join(f"`{p}`" for p in hits)
            notes.append(f"`{bead}` ({row.get('title', '')}): {files}")
    if len(notes) > MAX_NOTES:
        notes = [*notes[:MAX_NOTES], f"... and {len(notes) - MAX_NOTES} more"]
    return tuple(notes)
