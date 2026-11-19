"""Progress logging of the PR reviewer: watch heartbeat, review steps, timings."""

from __future__ import annotations

import logging
from contextlib import contextmanager
from pathlib import Path

import pytest

from pr_review import __main__ as cli
from pr_review import gate, progress, review
from pr_review.checks import Check, ReviewConfig
from pr_review.services import PullRequest
from pr_review.shell import Result
from pr_review.verdict import Problem, Verdict

URL = "https://github.com/o/r/pull/7"
PR = PullRequest(7, "fix(om-1): thing", "Bead: om-1", "bd/om-1", "sha7", URL)


def _messages(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.getMessage() for r in caplog.records]


@pytest.mark.parametrize(
    ("seconds", "text"),
    [(0, "0s"), (5, "5s"), (60, "1m00s"), (61, "1m01s"), (150, "2m30s"), (3725, "62m05s")],
)
def test_duration_is_minutes_and_seconds(seconds: int, text: str) -> None:
    assert progress.fmt_duration(seconds) == text


def test_step_logs_start_and_elapsed_time(caplog: pytest.LogCaptureFixture) -> None:
    ticks = iter([100.0, 142.0])
    with caplog.at_level(logging.INFO, logger="pr_review"):
        with progress.step("running checks", clock=lambda: next(ticks)):
            pass
    assert _messages(caplog) == ["running checks ...", "running checks: done in 42s"]


def test_step_logs_failure_with_elapsed_time(caplog: pytest.LogCaptureFixture) -> None:
    ticks = iter([0.0, 7.0])
    with caplog.at_level(logging.INFO, logger="pr_review"):
        with pytest.raises(RuntimeError):
            with progress.step("asking model", clock=lambda: next(ticks)):
                raise RuntimeError("boom")
    assert _messages(caplog)[-1] == "asking model: FAILED after 7s (RuntimeError: boom)"


def test_watch_wait_logs_the_next_check_then_a_heartbeat_every_minute(
    caplog: pytest.LogCaptureFixture,
) -> None:
    slept: list[float] = []
    with caplog.at_level(logging.INFO, logger="pr_review"):
        cli.wait_for_next_pass(150, sleep=slept.append, now=lambda: 0.0)
    assert slept == [60, 60, 30]
    msgs = _messages(caplog)
    assert msgs[0].startswith("next check in 2m30s (at ")
    assert msgs[1:] == ["waiting: next check in 1m30s", "waiting: next check in 30s"]


def test_watch_wait_shorter_than_a_minute_logs_only_the_announcement(
    caplog: pytest.LogCaptureFixture,
) -> None:
    slept: list[float] = []
    with caplog.at_level(logging.INFO, logger="pr_review"):
        cli.wait_for_next_pass(45, sleep=slept.append, now=lambda: 0.0)
    assert slept == [45]
    assert len(_messages(caplog)) == 1


def test_gate_logs_each_check_with_exit_code_and_time(caplog: pytest.LogCaptureFixture) -> None:
    def fake_run(cmd: list[str], cwd: Path | None = None, timeout: float | None = None) -> Result:
        return Result(1 if cmd[0] == "pytest" else 0, "", "")

    checks = (Check("unit", ("pytest", "-q"), "pytest"), Check("lint", ("ruff",), "ruff"))
    with caplog.at_level(logging.INFO, logger="pr_review"):
        gate.run_gate(fake_run, Path("."), checks)  # type: ignore[arg-type]
    msgs = _messages(caplog)
    assert any(m.startswith("check unit: exit 1 in ") for m in msgs)
    assert any(m.startswith("check lint: exit 0 in ") for m in msgs)


def _ctx(instructions: Path = Path("instructions.md")) -> review.Context:
    def fake_run(cmd: list[str], cwd: Path | None = None, timeout: float | None = None) -> Result:
        return Result(0, "diff text", "")

    ctx = review.Context(
        run=fake_run,  # type: ignore[arg-type]
        repo=Path("."),
        github=None,  # type: ignore[arg-type]
        beads=None,  # type: ignore[arg-type]
        config=ReviewConfig((), instructions),
        model="gemma4:31b-mlx",
    )
    ctx.baseline = lambda: {}  # type: ignore[method-assign]
    return ctx


def test_verdict_logs_every_review_step(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    @contextmanager
    def fake_checkout(run: object, repo: Path, ref: str, rebase_onto_main: bool):  # type: ignore[no-untyped-def]
        yield Path(".")

    monkeypatch.setattr(review, "checkout", fake_checkout)
    monkeypatch.setattr(review, "run_gate", lambda run, tree, checks: {})
    monkeypatch.setattr(review, "_ask", lambda *a, **k: "raw")
    monkeypatch.setattr(
        review, "parse_verdict", lambda raw: Verdict(False, "no", (Problem("a.py", 1, "A", ""),))
    )
    with caplog.at_level(logging.INFO, logger="pr_review"):
        verdict = review._verdict(_ctx(), PR, "om-1", "ref")
    assert not verdict.approve
    text = "\n".join(_messages(caplog))
    for expected in (
        "PR #7: rebase onto origin/main ...",
        "PR #7: rebase onto origin/main: done in",
        "PR #7: running checks ...",
        "PR #7: running checks: done in",
        "PR #7: building the diff",
        "PR #7: reviewer verdict: changes needed, 1 problem(s)",
    ):
        assert expected in text, f"missing {expected!r} in:\n{text}"


def test_ask_logs_the_model_call_with_prompt_size_and_time(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture, tmp_path: Path
) -> None:
    class Beads:
        def text(self, bead: str) -> str:
            return "ticket"

    instructions = tmp_path / "instructions.md"
    instructions.write_text("be strict", encoding="utf-8")
    ctx = _ctx(instructions)
    ctx.beads = Beads()  # type: ignore[assignment]
    monkeypatch.setattr(review.local_agent, "changed_files", lambda run, tree: "files")
    monkeypatch.setattr(review.local_agent, "ask", lambda post, host, model, prompt: "raw")
    with caplog.at_level(logging.INFO, logger="pr_review"):
        assert review._ask(ctx, Path("."), "om-1", PR, "diff", "report") == "raw"
    text = "\n".join(_messages(caplog))
    assert "PR #7: asking gemma4:31b-mlx (prompt " in text
    assert " chars) ..." in text
    assert "PR #7: asking gemma4:31b-mlx: done in" in text


def test_run_pass_logs_outcome_with_total_review_time(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    class GH:
        def open_bead_prs(self) -> list[PullRequest]:
            return [PR]

        def has_marker(self, pr: PullRequest, marker: str) -> bool:
            return False

    class Beads:
        def pull(self) -> None:
            pass

    ctx = _ctx()
    ctx.github, ctx.beads = GH(), Beads()  # type: ignore[assignment]
    monkeypatch.setattr(cli, "review_pr", lambda c, pr: "merged")
    with caplog.at_level(logging.INFO, logger="pr_review"):
        assert cli.run_pass(ctx, None) == 0
    assert any(m.startswith("PR #7: merged in ") for m in _messages(caplog))
    assert any("starting review of 1 PR(s)" in m for m in _messages(caplog))


# --- Ctrl-C: a clean shutdown, not an error -------------------------------------------


def test_step_logs_an_interrupt_and_lets_it_propagate(caplog: pytest.LogCaptureFixture) -> None:
    ticks = iter([0.0, 9.0])
    with caplog.at_level(logging.INFO, logger="pr_review"):
        with pytest.raises(KeyboardInterrupt):
            with progress.step("asking model", clock=lambda: next(ticks)):
                raise KeyboardInterrupt
    assert _messages(caplog)[-1] == "asking model: interrupted after 9s"


def test_run_pass_names_the_pr_being_reviewed_when_interrupted(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    class GH:
        def open_bead_prs(self) -> list[PullRequest]:
            return [PR]

        def has_marker(self, pr: PullRequest, marker: str) -> bool:
            return False

    class Beads:
        def pull(self) -> None:
            pass

    def interrupted(ctx: review.Context, pr: PullRequest) -> str:
        raise KeyboardInterrupt

    ctx = _ctx()
    ctx.github, ctx.beads = GH(), Beads()  # type: ignore[assignment]
    monkeypatch.setattr(cli, "review_pr", interrupted)
    with caplog.at_level(logging.INFO, logger="pr_review"):
        with pytest.raises(KeyboardInterrupt):
            cli.run_pass(ctx, None)
    assert "interrupted while reviewing PR #7" in _messages(caplog)


@pytest.fixture
def ready_cli(monkeypatch: pytest.MonkeyPatch) -> None:
    """main() gets past setup without a real repo, model or GitHub."""
    monkeypatch.setattr(cli, "resolve_model", lambda agent, model: "m")
    monkeypatch.setattr(cli, "run", lambda cmd, **k: Result(0, "/tmp\n", ""))
    monkeypatch.setattr(cli, "load_config", lambda repo, home: ReviewConfig((), Path("i.md")))


def test_ctrl_c_during_a_review_exits_130_with_a_calm_message(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture, ready_cli: None
) -> None:
    def interrupted(ctx: review.Context, only: int | None) -> int:
        raise KeyboardInterrupt

    monkeypatch.setattr(cli, "run_pass", interrupted)
    with caplog.at_level(logging.INFO, logger="pr_review"):
        assert cli.main(["--dry-run", "--watch", "60"]) == cli.INTERRUPTED_EXIT == 130
    msgs = _messages(caplog)
    assert any("interrupted (Ctrl-C): shutting down" in m for m in msgs)
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]


def test_ctrl_c_while_waiting_in_watch_mode_is_a_normal_stop(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture, ready_cli: None
) -> None:
    def interrupted(seconds: int) -> None:
        raise KeyboardInterrupt

    monkeypatch.setattr(cli, "run_pass", lambda ctx, only: 0)
    monkeypatch.setattr(cli, "wait_for_next_pass", interrupted)
    with caplog.at_level(logging.INFO, logger="pr_review"):
        assert cli.main(["--dry-run", "--watch", "60"]) == 0
    assert any("stopped (Ctrl-C) while idle" in m for m in _messages(caplog))
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]
