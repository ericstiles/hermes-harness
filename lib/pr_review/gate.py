"""Check out a PR (rebased on origin/main) and run the quality gate there and on main."""

from __future__ import annotations

import logging
import os
import shutil
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager, suppress
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
    """A throwaway detached worktree at `ref`, optionally rebased onto origin/main.

    On the way out the worktree, its registration and the mkdtemp parent are removed, also when
    `worktree add` or the body fails. Cleanup never raises; what it can't remove is logged.
    """
    parent = Path(tempfile.mkdtemp(prefix="pr-review-"))
    tree = parent / "tree"
    added = False
    try:
        must(run(["git", "worktree", "add", "--detach", str(tree), ref], cwd=repo), "worktree add")
        added = True
        if rebase_onto_main:
            rebased = run(["git", "rebase", "origin/main"], cwd=tree)
            if not rebased.ok:
                run(["git", "rebase", "--abort"], cwd=tree)
                raise RebaseConflict(rebased.err.strip()[:500] or rebased.out.strip()[:500])
        yield tree
    finally:
        _remove_checkout(run, repo, parent, tree, added)


def _remove_checkout(run: Runner, repo: Path, parent: Path, tree: Path, added: bool) -> None:
    """Remove the worktree and its temp parent; on failure log git's stderr, delete and prune.

    Never raises, so an exception from the `with` body is never masked: anything unexpected
    (one `shell.run` does not turn into a Result) is logged instead.
    """
    removed = False
    try:
        if added:
            # -f -f: also a locked worktree (it is ours alone: a fresh mkdtemp path).
            result = run(["git", "worktree", "remove", "--force", "--force", str(tree)], cwd=repo)
            removed = result.ok
            if not removed:
                detail = (result.err.strip() or result.out.strip()).splitlines()
                log.warning(
                    "worktree cleanup: git worktree remove failed (exit %s): %s; deleting %s",
                    result.code, detail[0][:300] if detail else "no output", tree,
                )  # fmt: skip
    except Exception as exc:  # cleanup must not mask the body's exception
        log.warning("worktree cleanup failed: %s: %s", type(exc).__name__, exc)
    _force_rmtree(parent)
    try:
        if not removed:
            run(["git", "worktree", "prune"], cwd=repo)
    except Exception as exc:  # same reason
        log.warning("worktree cleanup failed: %s: %s", type(exc).__name__, exc)
    if parent.exists():
        log.warning("worktree cleanup: could not delete %s; remove it by hand", parent)


def _force_rmtree(path: Path) -> None:
    """rm -rf that also clears read-only directories (a check may leave some). Never raises.

    Symlinks are never chmod-ed: os.walk lists a symlink to a directory under `dirs` and
    os.chmod would follow it to a directory outside the tree (rmtree only unlinks them).
    """
    try:
        shutil.rmtree(path)
    except FileNotFoundError:
        return
    except OSError:
        for root, dirs, _files in os.walk(path):
            for name in dirs:
                entry = os.path.join(root, name)
                if os.path.islink(entry):
                    continue
                with suppress(OSError):
                    os.chmod(entry, 0o700)
        with suppress(OSError):
            os.chmod(path, 0o700)
        shutil.rmtree(path, ignore_errors=True)


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
