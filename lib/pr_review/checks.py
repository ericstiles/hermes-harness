"""The target repo's quality-gate checks: which commands to run and how to diff their output.

Configured by an optional `hermes-review.json` at the target repo root:

    {"checks": [{"name": "pytest", "cmd": ["{python}", "-m", "pytest", "-q"],
                 "parser": "pytest"}],
     "instructions": "docs/REVIEWER_AGENT.md"}

`{python}` is the repo's `.venv/bin/python` when present, else `python3`. Without a config,
a repo with `pyproject.toml` gets pytest + ruff check + ruff format; any other repo gets no
mechanical checks (the reviewer agent still reviews the diff).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from pr_review.findings import new_failures, new_lines, new_ruff_findings, new_unformatted
from pr_review.verdict import PATH_LINE, Problem

CONFIG_FILE = "hermes-review.json"
PARSERS = ("pytest", "ruff", "ruff-format", "lines")
_PY = "{python}"
_DEFAULT_PYTHON_CHECKS = (
    ("pytest", (_PY, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-o", "addopts="), "pytest"),
    ("ruff", (_PY, "-m", "ruff", "check", "--no-cache", "--output-format", "concise", "."), "ruff"),
    (
        "ruff-format",
        (_PY, "-m", "ruff", "format", "--no-cache", "--check", "--output-format", "concise", "."),
        "ruff-format",
    ),
)


class ConfigError(ValueError):
    """hermes-review.json is invalid."""


@dataclass(frozen=True)
class Check:
    name: str
    cmd: tuple[str, ...]
    parser: str


@dataclass(frozen=True)
class ReviewConfig:
    checks: tuple[Check, ...]
    instructions: Path


def _check(raw: object, python: str) -> Check:
    if not isinstance(raw, dict):
        raise ConfigError(f"check must be an object: {raw!r}")
    name, cmd, parser = raw.get("name"), raw.get("cmd"), raw.get("parser", "lines")
    if not isinstance(name, str) or not name:
        raise ConfigError(f"check needs a name: {raw!r}")
    if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd):
        raise ConfigError(f"check {name!r} needs a non-empty cmd list of strings")
    if parser not in PARSERS:
        raise ConfigError(f"check {name!r}: parser must be one of {PARSERS}")
    return Check(name, tuple(python if c == _PY else c for c in cmd), parser)


def load_config(repo: Path, harness_home: Path) -> ReviewConfig:
    """Read hermes-review.json (optional) and fill in defaults."""
    path = repo / CONFIG_FILE
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    venv = repo / ".venv" / "bin" / "python"
    python = str(venv) if venv.exists() else "python3"
    if "checks" in data:
        checks = tuple(_check(c, python) for c in data["checks"])
    elif (repo / "pyproject.toml").is_file():
        checks = tuple(Check(n, tuple(python if c == _PY else c for c in cmd), p)
                       for n, cmd, p in _DEFAULT_PYTHON_CHECKS)  # fmt: skip
    else:
        checks = ()
    if data.get("instructions"):
        instructions = repo / str(data["instructions"])
    elif (repo / "docs" / "REVIEWER_AGENT.md").is_file():
        instructions = repo / "docs" / "REVIEWER_AGENT.md"
    else:
        instructions = harness_home / "templates" / "REVIEWER_AGENT.md"
    return ReviewConfig(checks, instructions)


def _ruff_problem(line: str) -> Problem:
    match = PATH_LINE.match(line)
    path, number = (match["path"], int(match["line"])) if match else ("", None)
    message = line.split(": ", 1)[1] if ": " in line else line
    return Problem(path, number, f"New ruff finding: {message}", "")


def new_problems(check: Check, main_text: str, pr_text: str) -> list[Problem]:
    """Problems the PR adds for one check, compared with the same check on main."""
    if check.parser == "pytest":
        return [
            Problem(n.split("::")[0], None, f"New test failure: {n}", "")
            for n in new_failures(main_text, pr_text)
        ]
    if check.parser == "ruff":
        return [_ruff_problem(line) for line in new_ruff_findings(main_text, pr_text)]
    if check.parser == "ruff-format":
        return [
            Problem(p, None, "File not formatted", "ruff format --check")
            for p in new_unformatted(main_text, pr_text)
        ]
    return [
        Problem("", None, f"New {check.name} output: {line}", "")
        for line in new_lines(main_text, pr_text)
    ]
