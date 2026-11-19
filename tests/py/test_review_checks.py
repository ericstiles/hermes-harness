"""Target-repo checks for hermes-review: config loading and per-parser problems."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pr_review.checks import CONFIG_FILE, Check, ConfigError, load_config, new_problems

HOME = Path("/harness")


def test_python_repo_gets_default_checks_with_its_venv(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text("")
    (tmp_path / ".venv" / "bin").mkdir(parents=True)
    (tmp_path / ".venv" / "bin" / "python").write_text("")
    config = load_config(tmp_path, HOME)
    assert [c.name for c in config.checks] == ["pytest", "ruff", "ruff-format"]
    assert config.checks[0].cmd[0] == str(tmp_path / ".venv" / "bin" / "python")


def test_repo_without_pyproject_or_config_has_no_checks(tmp_path: Path) -> None:
    assert load_config(tmp_path, HOME).checks == ()


def test_config_file_replaces_defaults(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text("")
    data = {"checks": [{"name": "unit", "cmd": ["{python}", "-m", "pytest"], "parser": "pytest"}]}
    (tmp_path / CONFIG_FILE).write_text(json.dumps(data))
    config = load_config(tmp_path, HOME)
    assert config.checks == (Check("unit", ("python3", "-m", "pytest"), "pytest"),)


@pytest.mark.parametrize(
    "check",
    [
        {"name": "x", "cmd": [], "parser": "pytest"},
        {"name": "x", "cmd": ["make"], "parser": "nope"},
        {"cmd": ["make"], "parser": "lines"},
    ],
)
def test_invalid_check_is_rejected(tmp_path: Path, check: dict[str, object]) -> None:
    (tmp_path / CONFIG_FILE).write_text(json.dumps({"checks": [check]}))
    with pytest.raises(ConfigError):
        load_config(tmp_path, HOME)


def test_instructions_prefer_config_then_repo_doc_then_template(tmp_path: Path) -> None:
    assert load_config(tmp_path, HOME).instructions == HOME / "templates" / "REVIEWER_AGENT.md"
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "REVIEWER_AGENT.md").write_text("x")
    assert load_config(tmp_path, HOME).instructions == tmp_path / "docs" / "REVIEWER_AGENT.md"
    (tmp_path / CONFIG_FILE).write_text(json.dumps({"instructions": "REVIEW.md"}))
    assert load_config(tmp_path, HOME).instructions == tmp_path / "REVIEW.md"


def test_new_problems_per_parser() -> None:
    pytest_check = Check("pytest", ("p",), "pytest")
    found = new_problems(pytest_check, "", "FAILED tests/t.py::test_x - E\n")
    assert [(p.file, p.title) for p in found] == [
        ("tests/t.py", "New test failure: tests/t.py::test_x")
    ]

    ruff = Check("ruff", ("r",), "ruff")
    found = new_problems(ruff, "", "src/a.py:3:1: F401 `os` imported but unused\n")
    assert [(p.file, p.line, p.title) for p in found] == [
        ("src/a.py", 3, "New ruff finding: F401 `os` imported but unused")
    ]

    fmt = Check("ruff-format", ("f",), "ruff-format")
    found = new_problems(fmt, "", "src/b.py:1:1: unformatted: File would be reformatted\n")
    assert [(p.file, p.title) for p in found] == [("src/b.py", "File not formatted")]

    lines = Check("eslint", ("e",), "lines")
    found = new_problems(lines, "old warning\n", "old warning\nnew warning\n")
    assert [(p.file, p.title) for p in found] == [("", "New eslint output: new warning")]
