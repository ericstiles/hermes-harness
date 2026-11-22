"""hermes-review: a PR that changes its dependencies is checked in a throwaway venv (bead c6m)."""

from __future__ import annotations

from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path

import pytest

from pr_review import pr_env
from pr_review.checks import Check, ReviewConfig, load_config
from pr_review.shell import Result

HOST = "/repo/.venv/bin/python"
CHECKS = (
    Check("pytest", (HOST, "-m", "pytest", "-q"), "pytest"),
    Check("lint", ("make", "lint"), "lines"),
)


class StubRunner:
    """Records every command; answers git diff, sysconfig queries, venv and pip."""

    def __init__(self, tree: Path, changed: str, pip: Result | None = None) -> None:
        self.tree, self.changed, self.calls = tree, changed, []
        self.pip = pip or Result(0, "", "")

    def __call__(
        self,
        cmd: Sequence[str],
        cwd: Path | None = None,
        env: Mapping[str, str] | None = None,
        timeout: float | None = None,
    ) -> Result:
        cmd = list(cmd)
        self.calls.append(cmd)
        if cmd[:3] == ["git", "diff", "--name-only"]:
            return Result(0, self.changed, "")
        if cmd[1:3] == ["-c", pr_env.SITE_PATHS]:
            where = "host" if cmd[0] == HOST else "venv"
            return Result(0, f"{self.tree}/{where}-site\n{self.tree}/{where}-site\n", "")
        if cmd[1:3] == ["-m", "venv"]:
            return Result(0, "", "")
        if cmd[1:4] == ["-m", "pip", "install"]:
            return self.pip
        return Result(1, "", f"unexpected command {cmd}")

    def pip_calls(self) -> list[list[str]]:
        return [c for c in self.calls if c[1:4] == ["-m", "pip", "install"]]


def _project(tree: Path, extras: bool = True, requirements: bool = True) -> None:
    body = '[project]\nname = "x"\n' + (
        '[project.optional-dependencies]\ndev = ["pytest"]\n' if extras else ""
    )
    (tree / "pyproject.toml").write_text(body)
    if requirements:
        (tree / "requirements-dev.txt").write_text("yoyo-migrations==9.0.0\n")


def test_gate_uses_fresh_venv_when_dependency_files_change(tmp_path: Path) -> None:
    _project(tmp_path)
    run = StubRunner(tmp_path, "src/db.py\nrequirements-dev.txt\n")
    env = pr_env.pr_environment(run, tmp_path, CHECKS, HOST)
    venv_python = str(tmp_path / ".gate-venv" / "bin" / "python")
    assert env.problem is None
    assert env.checks[0].cmd == (venv_python, "-m", "pytest", "-q")
    assert env.checks[1] == CHECKS[1]  # a check that does not use {python} is unchanged
    # --upgrade-deps: the host python's bundled pip may be too old for a pyproject-only
    # editable install (Apple's python3 3.9; found in the real repro, 2026-11-21)
    assert [HOST, "-m", "venv", "--upgrade-deps", str(tmp_path / ".gate-venv")] in run.calls
    (pip,) = run.pip_calls()
    assert pip[0] == venv_python
    assert pip[1:4] == ["-m", "pip", "install"]
    assert pip[-4:] == ["-e", ".[dev]", "-r", "requirements-dev.txt"]
    pth = (tmp_path / "venv-site" / pr_env.HOST_PTH).read_text()
    assert pth.splitlines() == [f"{tmp_path}/host-site"]  # host packages stay importable
    assert (tmp_path / ".gate-venv" / ".gitignore").read_text() == "*\n"


def test_gate_uses_host_venv_when_dependency_files_unchanged(tmp_path: Path) -> None:
    _project(tmp_path)
    run = StubRunner(tmp_path, "src/db.py\ntests/test_db.py\n")
    env = pr_env.pr_environment(run, tmp_path, CHECKS, HOST)
    assert env == pr_env.GateEnv(CHECKS)
    assert run.pip_calls() == []
    assert not any(c[1:3] == ["-m", "venv"] for c in run.calls)


def test_dependency_install_failure_is_one_environment_problem(tmp_path: Path) -> None:
    _project(tmp_path)
    err = "ERROR: No matching distribution found for yoyo-migrations==99.0.0\n"
    run = StubRunner(tmp_path, "pyproject.toml\n", pip=Result(1, "", err))
    env = pr_env.pr_environment(run, tmp_path, CHECKS, HOST)
    assert env.checks == ()
    assert env.problem is not None
    assert env.problem.title == "Could not install the PR's dependencies"
    assert "pip install" in env.problem.detail
    assert "No matching distribution found for yoyo-migrations==99.0.0" in env.problem.detail
    assert env.problem.in_scope


@pytest.mark.parametrize(
    ("path", "dependency"),
    [
        ("pyproject.toml", True), ("sub/pyproject.toml", True), ("requirements.txt", True),
        ("requirements-dev.txt", True), ("setup.py", True), ("setup.cfg", True),
        ("uv.lock", True), ("poetry.lock", True), ("Pipfile.lock", True),
        ("src/pyproject_tools.py", False), ("docs/requirements.md", False), ("README.md", False),
    ],
)  # fmt: skip
def test_which_files_count_as_dependency_files(path: str, dependency: bool) -> None:
    assert pr_env.is_dependency_file(path) is dependency


def test_tool_only_pyproject_installs_requirements_only(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text("[tool.ruff]\nline-length = 100\n")
    (tmp_path / "requirements.txt").write_text("requests\n")
    assert pr_env.install_args(tmp_path) == ["-r", "requirements.txt"]


def test_nothing_installable_keeps_host_venv(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text("[tool.ruff]\nline-length = 100\n")
    run = StubRunner(tmp_path, "pyproject.toml\n")
    assert pr_env.pr_environment(run, tmp_path, CHECKS, HOST) == pr_env.GateEnv(CHECKS)
    assert run.pip_calls() == []


def test_failed_diff_keeps_host_venv(tmp_path: Path) -> None:
    def broken(cmd: Sequence[str], cwd: Path | None = None, env: object = None,
               timeout: float | None = None) -> Result:  # fmt: skip
        return Result(128, "", "fatal: bad revision")

    assert pr_env.pr_environment(broken, tmp_path, CHECKS, HOST) == pr_env.GateEnv(CHECKS)


def test_review_config_records_the_host_python(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text("")
    (tmp_path / ".venv" / "bin").mkdir(parents=True)
    (tmp_path / ".venv" / "bin" / "python").write_text("")
    assert load_config(tmp_path, Path("/h")).python == str(tmp_path / ".venv" / "bin" / "python")
    assert ReviewConfig((), Path("i.md")).python == "python3"


# --- wiring: review._verdict runs the checks in the PR's environment ---


def _verdict_ctx(monkeypatch: pytest.MonkeyPatch, tree: Path, env: pr_env.GateEnv) -> dict:
    from contextlib import contextmanager

    from pr_review import review

    seen: dict[str, object] = {}

    @contextmanager
    def fake_checkout(run: object, repo: Path, ref: str, rebase_onto_main: bool) -> Iterator[Path]:
        yield tree

    def fake_gate(run: object, where: Path, checks: tuple[Check, ...]) -> dict[str, str]:
        seen["checks"] = checks
        return {}

    def fake_env(
        run: object, where: Path, checks: tuple[Check, ...], python: str
    ) -> pr_env.GateEnv:
        seen["env_args"] = (checks, python)
        return env

    monkeypatch.setattr(review, "checkout", fake_checkout)
    monkeypatch.setattr(review, "run_gate", fake_gate)
    monkeypatch.setattr(review, "pr_environment", fake_env)
    ctx = review.Context(
        run=lambda cmd, cwd=None, env=None, timeout=None: Result(0, "diff --git a/x b/x\n", ""),
        repo=tree, github=None, beads=None,  # type: ignore[arg-type]
        config=ReviewConfig(CHECKS, Path("i.md"), HOST), skip_agent=True,
    )  # fmt: skip
    monkeypatch.setattr(ctx, "baseline", dict)
    from pr_review.services import PullRequest

    pr = PullRequest(7, "t", "Bead: om-1", "bd/om-1", "sha7", "https://github.com/o/r/pull/7")
    seen["verdict"] = review._verdict(ctx, pr, "om-1", "ref")
    return seen


def test_verdict_runs_the_checks_in_the_prs_environment(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    swapped = (Check("pytest", ("/tree/.gate-venv/bin/python", "-m", "pytest"), "pytest"),)
    seen = _verdict_ctx(monkeypatch, tmp_path, pr_env.GateEnv(swapped))
    assert seen["env_args"] == (CHECKS, HOST)
    assert seen["checks"] == swapped


def test_verdict_with_a_failed_install_runs_no_checks_and_reports_one_problem(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from pr_review.verdict import Problem

    problem = Problem("", None, "Could not install the PR's dependencies", "pip failed")
    seen = _verdict_ctx(monkeypatch, tmp_path, pr_env.GateEnv((), problem))
    assert "checks" not in seen
    verdict = seen["verdict"]
    assert not verdict.approve  # type: ignore[attr-defined]
    assert [p.title for p in verdict.problems] == [problem.title]  # type: ignore[attr-defined]
