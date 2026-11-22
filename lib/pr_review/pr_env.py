"""The PR's own environment for its checks: a throwaway venv when the PR changes dependencies.

The checks normally run with the target repo's host `.venv/bin/python`, the baseline for main,
shared with the developer and never modified here. A PR that adds a dependency would always fail
there with ModuleNotFoundError (organize_music #32, yoyo-migrations, 2026-11-21). So when the PR's
diff against origin/main touches a dependency file, the checks run in `<worktree>/.gate-venv`:

- created by the host python (same Python version);
- a `.pth` file puts the host venv's site-packages on its path, so pytest, ruff and every
  dependency main already has stay importable and pip installs only what is new or changed;
- `pip install -e '.[dev]'` (when pyproject.toml declares a project) and `-r requirements*.txt`;
- removed with the worktree. Its own `.gitignore` (`*`) keeps it out of ruff and git.

A failed install is ONE environment problem naming the command and its error, and no checks run.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, replace
from pathlib import Path

from pr_review.checks import Check
from pr_review.shell import Runner
from pr_review.verdict import Problem

VENV_DIR = ".gate-venv"
HOST_PTH = "_hermes_review_host.pth"
INSTALL_TIMEOUT = 900.0
STEP_TIMEOUT = 120.0
ERROR_TAIL = 1500
SITE_PATHS = "import sysconfig; p = sysconfig.get_paths(); print(p['purelib']); print(p['platlib'])"
REQUIREMENT_FILES = ("requirements.txt", "requirements-dev.txt")
_DEPENDENCY_FILE = re.compile(
    r"(^|/)(pyproject\.toml|setup\.py|setup\.cfg|requirements[^/]*\.txt"
    r"|uv\.lock|poetry\.lock|Pipfile|Pipfile\.lock)$"
)
_PROJECT_TABLE = re.compile(r"^\[(project|build-system)\]", re.MULTILINE)
log = logging.getLogger("pr_review")


@dataclass(frozen=True)
class GateEnv:
    checks: tuple[Check, ...]
    problem: Problem | None = None


class _InstallError(RuntimeError):
    """A step of building the PR's environment failed; the message is the problem's detail."""


def is_dependency_file(path: str) -> bool:
    return bool(_DEPENDENCY_FILE.search(path))


def changed_dependency_files(run: Runner, tree: Path) -> list[str]:
    """Dependency files the PR changes; empty when the diff cannot be read (host venv then)."""
    result = run(["git", "diff", "--name-only", "origin/main...HEAD"], cwd=tree)
    if not result.ok:
        log.warning("PR environment: git diff failed (%s); using the host venv", result.code)
        return []
    return [p for p in result.out.splitlines() if is_dependency_file(p.strip())]


def install_args(tree: Path) -> list[str]:
    """pip install arguments for the repo: the project with its dev extra, and requirements."""
    args: list[str] = []
    pyproject = tree / "pyproject.toml"
    has_project = (tree / "setup.py").is_file() or (
        pyproject.is_file() and _PROJECT_TABLE.search(pyproject.read_text(encoding="utf-8"))
    )
    if has_project:
        args += ["-e", ".[dev]"]
    for name in REQUIREMENT_FILES:
        if (tree / name).is_file():
            args += ["-r", name]
    return args


def _site_paths(run: Runner, python: str, tree: Path) -> list[str]:
    cmd = [python, "-c", SITE_PATHS]
    result = run(cmd, cwd=tree, timeout=STEP_TIMEOUT)
    if not result.ok:
        raise _InstallError(_describe(cmd, result.err or result.out))
    return list(dict.fromkeys(p.strip() for p in result.out.splitlines() if p.strip()))


def _describe(cmd: list[str], output: str) -> str:
    return f"`{' '.join(cmd)}` failed:\n{output.strip()[-ERROR_TAIL:]}"


def _build_venv(run: Runner, tree: Path, host_python: str, args: list[str]) -> str:
    venv = tree / VENV_DIR
    venv_python = str(venv / "bin" / "python")
    host_paths = _site_paths(run, host_python, tree)
    # --upgrade-deps (Python 3.9+): a current pip; the host's bundled one may be too old for a
    # pyproject-only editable install (Apple's python3 3.9).
    create = [host_python, "-m", "venv", "--upgrade-deps", str(venv)]
    created = run(create, cwd=tree, timeout=STEP_TIMEOUT)
    if not created.ok:
        raise _InstallError(_describe(create, created.err or created.out))
    venv.mkdir(parents=True, exist_ok=True)
    (venv / ".gitignore").write_text("*\n", encoding="utf-8")
    site = Path(_site_paths(run, venv_python, tree)[0])
    site.mkdir(parents=True, exist_ok=True)
    (site / HOST_PTH).write_text("\n".join(host_paths) + "\n", encoding="utf-8")
    install = [venv_python, "-m", "pip", "install", "-q", "--disable-pip-version-check", *args]
    installed = run(install, cwd=tree, timeout=INSTALL_TIMEOUT)
    if not installed.ok:
        raise _InstallError(_describe(install, installed.err or installed.out))
    return venv_python


def pr_environment(run: Runner, tree: Path, checks: tuple[Check, ...], host_python: str) -> GateEnv:
    """The checks to run for this PR: unchanged, in a fresh venv, or none with one problem."""
    changed = changed_dependency_files(run, tree)
    args = install_args(tree) if changed else []
    if not args:
        return GateEnv(checks)
    log.info("PR environment: %s changed; installing into %s", ", ".join(changed), VENV_DIR)
    try:
        venv_python = _build_venv(run, tree, host_python, args)
    except (_InstallError, OSError) as exc:
        detail = str(exc)
        log.warning("PR environment: install failed: %s", detail.splitlines()[0])
        return GateEnv((), Problem("", None, "Could not install the PR's dependencies", detail))
    swapped = tuple(
        replace(
            check, cmd=tuple(venv_python if part == host_python else part for part in check.cmd)
        )
        for check in checks
    )
    return GateEnv(swapped)
