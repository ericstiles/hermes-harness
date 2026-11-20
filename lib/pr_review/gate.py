"""Check out a PR (rebased on origin/main) and run the quality gate there and on main."""

from __future__ import annotations

import logging
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from pr_review.checks import Check
from pr_review.progress import fmt_duration
from pr_review.shell import Runner, must

GATE_TIMEOUT = 900.0
log = logging.getLogger("pr_review")
GateOutput = dict[str, str]  # check name -> combined output


class RebaseConflict(RuntimeError):
    """The PR does not rebase cleanly onto origin/main."""


@contextmanager
def checkout(run: Runner, repo: Path, ref: str, rebase_onto_main: bool) -> Iterator[Path]:
    """A throwaway detached worktree at `ref`, optionally rebased onto origin/main."""
    parent = Path(tempfile.mkdtemp(prefix="pr-review-"))
    tree = parent / "tree"
    must(run(["git", "worktree", "add", "--detach", str(tree), ref], cwd=repo), "worktree add")
    try:
        if rebase_onto_main:
            rebased = run(["git", "rebase", "origin/main"], cwd=tree)
            if not rebased.ok:
                run(["git", "rebase", "--abort"], cwd=tree)
                raise RebaseConflict(rebased.err.strip()[:500] or rebased.out.strip()[:500])
        yield tree
    finally:
        run(["git", "worktree", "remove", "--force", str(tree)], cwd=repo)


def fetch(run: Runner, repo: Path, number: int) -> str:
    """Fetch origin/main and the PR head; return the local ref for the PR head."""
    ref = f"refs/pr-review/{number}"
    must(run(["git", "fetch", "-q", "origin", "main"], cwd=repo), "git fetch main")
    must(
        run(["git", "fetch", "-q", "--force", "origin", f"pull/{number}/head:{ref}"], cwd=repo),
        "git fetch PR",
    )
    return ref


def run_gate(run: Runner, tree: Path, checks: tuple[Check, ...]) -> GateOutput:
    """Run every check in `tree`; output is kept (stdout + stderr), exit codes are not."""
    outputs = {}
    for check in checks:
        log.info("check %s: running ...", check.name)
        began = time.monotonic()
        result = run(list(check.cmd), cwd=tree, timeout=GATE_TIMEOUT)
        outputs[check.name] = result.out + result.err
        log.info(
            "check %s: exit %s in %s",
            check.name,
            result.code,
            fmt_duration(time.monotonic() - began),
        )
    return outputs
