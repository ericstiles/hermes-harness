"""gate.checkout cleanup (bead 38m): no pr-review-* worktree or temp dir outlives a pass, and a
failed `git worktree remove` is logged with its stderr instead of ignored."""

from __future__ import annotations

import subprocess
import tempfile
from collections.abc import Sequence
from pathlib import Path

import pytest

from pr_review import gate
from pr_review.shell import CommandError, Result
from pr_review.shell import run as real_run


@pytest.fixture
def tmpdir_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """mkdtemp parents go under tmp_path, so the test can see what is left behind."""
    root = tmp_path / "tmp"
    root.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(root))
    return root


@pytest.fixture
def repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A real one-commit repo with origin/main, isolated from the machine's git config/hooks."""
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", "/dev/null")
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    for key in ("AUTHOR", "COMMITTER"):
        monkeypatch.setenv(f"GIT_{key}_NAME", "t")
        monkeypatch.setenv(f"GIT_{key}_EMAIL", "t@example.invalid")
    r = tmp_path / "repo"
    subprocess.run(["git", "init", "-q", "-b", "main", str(r)], check=True)
    (r / "a.txt").write_text("a\n")
    subprocess.run(["git", "add", "a.txt"], cwd=r, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "a"], cwd=r, check=True)
    subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], cwd=r, check=True)
    return r


def _worktrees(repo: Path) -> list[str]:
    out = subprocess.run(
        ["git", "worktree", "list", "--porcelain"], cwd=repo, capture_output=True, text=True
    ).stdout
    return [line.split(" ", 1)[1] for line in out.splitlines() if line.startswith("worktree ")]


class FailingRemove:
    """Stub git: `worktree add` makes the dir, `worktree remove` fails, everything else is ok."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def __call__(
        self, cmd: Sequence[str], cwd: Path | None = None, env: object = None,
        timeout: float | None = None,
    ) -> Result:  # fmt: skip
        self.calls.append(list(cmd))
        if cmd[:3] == ["git", "worktree", "add"]:
            Path(cmd[-2]).mkdir(parents=True)
        if cmd[:3] == ["git", "worktree", "remove"]:
            return Result(255, "", "error: failed to delete 'tree': Permission denied\n")
        return Result(0, "", "")


def test_failed_remove_is_logged_with_stderr_and_does_not_raise(
    tmpdir_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    run = FailingRemove()
    with (
        caplog.at_level("WARNING", logger="pr_review"),
        gate.checkout(run, Path("/repo"), "ref", rebase_onto_main=False) as tree,
    ):
        (tree / "f").write_text("x")
    assert "git worktree remove failed (exit 255)" in caplog.text
    assert "Permission denied" in caplog.text
    assert ["git", "worktree", "prune"] in run.calls  # stale registration dropped
    assert list(tmpdir_root.iterdir()) == []  # the mkdtemp parent (and tree) are gone


def test_clean_pass_leaves_no_worktree_and_no_temp_dir(
    repo: Path, tmpdir_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    with (
        caplog.at_level("WARNING", logger="pr_review"),
        gate.checkout(real_run, repo, "origin/main", rebase_onto_main=True) as tree,
    ):
        assert (tree / "a.txt").exists()
    assert len(_worktrees(repo)) == 1
    assert list(tmpdir_root.iterdir()) == []
    assert caplog.text == ""


def test_read_only_dir_left_by_the_gate_is_still_cleaned_up(
    repo: Path, tmpdir_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    # Reproduced cause: a check that leaves a read-only directory makes
    # `git worktree remove --force` fail with "Permission denied" (exit 255).
    with (
        caplog.at_level("WARNING", logger="pr_review"),
        gate.checkout(real_run, repo, "origin/main", rebase_onto_main=False) as tree,
    ):
        ro = tree / "cache"
        ro.mkdir()
        (ro / "f").write_text("x")
        ro.chmod(0o555)
    assert len(_worktrees(repo)) == 1
    assert list(tmpdir_root.iterdir()) == []
    assert "git worktree remove failed" in caplog.text


def test_locked_worktree_is_still_removed(repo: Path, tmpdir_root: Path) -> None:
    # Reproduced cause: a locked worktree makes a single --force remove fail (exit 128).
    with gate.checkout(real_run, repo, "origin/main", rebase_onto_main=False) as tree:
        subprocess.run(["git", "worktree", "lock", str(tree)], cwd=repo, check=True)
    assert len(_worktrees(repo)) == 1
    assert list(tmpdir_root.iterdir()) == []


def test_exception_in_the_body_still_cleans_up(repo: Path, tmpdir_root: Path) -> None:
    with (
        pytest.raises(RuntimeError, match="boom"),
        gate.checkout(real_run, repo, "origin/main", rebase_onto_main=False),
    ):
        raise RuntimeError("boom")
    assert len(_worktrees(repo)) == 1
    assert list(tmpdir_root.iterdir()) == []


def test_failed_worktree_add_raises_and_removes_the_temp_dir(repo: Path, tmpdir_root: Path) -> None:
    with (
        pytest.raises(CommandError),
        gate.checkout(real_run, repo, "no-such-ref", rebase_onto_main=False),
    ):
        pass  # pragma: no cover
    assert len(_worktrees(repo)) == 1
    assert list(tmpdir_root.iterdir()) == []
