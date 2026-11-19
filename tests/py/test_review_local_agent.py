"""Local (Ollama) reviewer backend for hermes-review."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pr_review import local_agent
from pr_review.agent import VERDICT_SCHEMA
from pr_review.shell import CommandError, Result
from pr_review.verdict import parse_verdict

HERMES_CONFIG = """\
model:
  default: qwen3.8:27b-mlx
  provider: ollama-launch
providers:
  ollama-launch:
    default_model: something-else
"""


def test_model_comes_from_hermes_config(tmp_path: Path) -> None:
    config = tmp_path / "config.yaml"
    config.write_text(HERMES_CONFIG)
    assert local_agent.hermes_model(config) == "qwen3.8:27b-mlx"


def test_missing_or_unrelated_hermes_config_gives_no_model(tmp_path: Path) -> None:
    assert local_agent.hermes_model(tmp_path / "nope.yaml") is None
    other = tmp_path / "c.yaml"
    other.write_text("agent:\n  default: x\n")
    assert local_agent.hermes_model(other) is None


def test_ask_sends_schema_without_streaming_and_returns_a_parseable_verdict() -> None:
    sent: list[tuple[str, dict[str, object]]] = []
    verdict = {"approve": True, "summary": "ok", "problems": []}

    def post(url: str, payload: dict[str, object], timeout: float) -> dict[str, object]:
        sent.append((url, payload))
        return {"message": {"content": json.dumps(verdict)}}

    raw = local_agent.ask(post, "http://localhost:11434", "qwen", "PROMPT")
    url, payload = sent[0]
    assert url == "http://localhost:11434/api/chat"
    assert payload["model"] == "qwen" and payload["stream"] is False
    assert payload["format"] == VERDICT_SCHEMA
    assert payload["messages"][-1] == {"role": "user", "content": "PROMPT"}
    assert parse_verdict(raw).approve is True


def test_ask_turns_transport_errors_into_command_error() -> None:
    def post(url: str, payload: dict[str, object], timeout: float) -> dict[str, object]:
        raise OSError("connection refused")

    with pytest.raises(CommandError, match="ollama"):
        local_agent.ask(post, "http://localhost:11434", "qwen", "p")


def test_changed_files_are_included_up_to_a_byte_limit(tmp_path: Path) -> None:
    (tmp_path / "a.py").write_text("A" * 30)
    (tmp_path / "b.py").write_text("B" * 30)

    def run(cmd, cwd=None, env=None, timeout=None):  # type: ignore[no-untyped-def]
        return Result(0, "a.py\nb.py\ngone.py\n", "")

    text = local_agent.changed_files(run, tmp_path, limit=40)
    assert "### a.py" in text and "A" * 30 in text
    assert "B" * 30 not in text and "b.py (omitted" in text
    assert "gone.py" not in text or "deleted" in text


def test_verdict_uses_the_local_model_with_changed_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from contextlib import contextmanager

    from pr_review import review
    from pr_review.checks import ReviewConfig
    from pr_review.services import PullRequest

    instructions = tmp_path / "R.md"
    instructions.write_text("INSTRUCTIONS")

    @contextmanager
    def checkout(run, repo, ref, rebase_onto_main):  # type: ignore[no-untyped-def]
        yield tmp_path

    asked: list[tuple[str, str]] = []

    def fake_ask(post, host, model, prompt):  # type: ignore[no-untyped-def]
        asked.append((model, prompt))
        return json.dumps({"result": json.dumps({"approve": True, "summary": "s", "problems": []})})

    monkeypatch.setattr(review, "checkout", checkout)
    monkeypatch.setattr(review, "run_gate", lambda run, tree, checks: {})
    monkeypatch.setattr(local_agent, "ask", fake_ask)
    monkeypatch.setattr(local_agent, "changed_files", lambda run, tree: "FILES")

    class Beads:
        def text(self, bead: str) -> str:
            return "TICKET"

    ctx = review.Context(
        run=lambda cmd, cwd=None, env=None, timeout=None: Result(0, "DIFF", ""),  # type: ignore[arg-type]
        repo=tmp_path, github=None, beads=Beads(),  # type: ignore[arg-type]
        config=ReviewConfig((), instructions), agent="ollama", model="qwen",
    )  # fmt: skip
    ctx._baseline["DIFF"] = {}
    pr = PullRequest(7, "fix(om-1): t", "BODY", "bd/om-1", "sha", "u")
    assert review._verdict(ctx, pr, "om-1", "ref").approve is True
    model, prompt = asked[0]
    assert model == "qwen"
    for part in ("INSTRUCTIONS", "TICKET", "BODY", "DIFF", "FILES"):
        assert part in prompt


def test_cli_local_agent_needs_a_model(monkeypatch: pytest.MonkeyPatch) -> None:
    from pr_review import __main__ as cli

    monkeypatch.delenv("REVIEWER_MODEL", raising=False)
    monkeypatch.setattr(local_agent, "hermes_model", lambda: None)
    assert cli.main(["--dry-run", "--agent", "ollama"]) == 2
    assert cli.resolve_model("claude", None) is None
    assert cli.resolve_model("ollama", "m") == "m"
