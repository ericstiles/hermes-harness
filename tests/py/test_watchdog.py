"""Unit tests for lib/watchdog.py (progress-aware time limit, bead hermes-harness-7zi)."""

import subprocess
import sys
import time
from pathlib import Path

import pytest

import watchdog as wd

WATCHDOG = Path(__file__).resolve().parents[2] / "lib" / "watchdog.py"


@pytest.mark.parametrize(
    ("text", "seconds"),
    [("90m", 5400), ("30s", 30), ("1h", 3600), ("45", 45), ("0", 0), ("1.5s", 1.5)],
)
def test_parse_duration_accepts_timeout_style_values(text: str, seconds: float) -> None:
    assert wd.parse_duration(text) == seconds


@pytest.mark.parametrize("text", ["", "m", "90x", "-5m", "ninety"])
def test_parse_duration_rejects_garbage(text: str) -> None:
    with pytest.raises(ValueError, match="not a duration"):
        wd.parse_duration(text)


def test_count_progress_counts_project_writes_commits_and_progress_notes() -> None:
    log = "\n".join(
        [
            "  ┊ ✍️  write     /workspace/repo/src/db.py  0.4s",
            "  ┊ 🔧 patch     /workspace/repo/tests/test_db.py  0.3s",
            "  ┊ 💻 $         cd /workspace/repo && git commit -m 'wip'  0.5s",
            '  ┊ 💻 $         bd update x-1 --append-notes "PROGRESS: tests written"  0.3s',
        ]
    )
    assert wd.count_progress(log) == 4


def test_count_progress_ignores_tmp_scratch_files_reads_and_narration() -> None:
    log = "\n".join(
        [
            "  ┊ ✍️  write     /tmp/probe.py  0.4s",
            "  ┊ 🔧 patch     /tmp/probe.py  0.3s",
            "  ┊ 💻 $         python /tmp/probe.py  0.4s",
            "  ┊ 📖 read      /workspace/repo/src/db.py  0.1s",
            "I will write the file and git commit it later.",
            "PROGRESS: mentioned in prose only",
        ]
    )
    assert wd.count_progress(log) == 0


def test_decide_extends_when_there_was_progress() -> None:
    d = wd.decide(progress=3, now=1000, start=0, since=0, extend=1200, cap=10800)
    assert d.deadline == 2200
    assert d.message.startswith("WATCHDOG: EXTENDED +20m: 3 progress lines since ")


def test_decide_stops_without_progress() -> None:
    d = wd.decide(progress=0, now=5400, start=0, since=0, extend=1200, cap=10800)
    assert d.deadline is None
    assert d.message.startswith("WATCHDOG: NO_PROGRESS since ")


def test_decide_never_extends_past_the_cap() -> None:
    partial = wd.decide(progress=1, now=10000, start=0, since=9000, extend=1200, cap=10800)
    assert partial.deadline == 10800 and "EXTENDED +800s" in partial.message
    full = wd.decide(progress=1, now=10800, start=0, since=10000, extend=1200, cap=10800)
    assert full.deadline is None and full.message.startswith("WATCHDOG: CAP_REACHED (180m)")


def test_decide_with_extend_zero_is_a_plain_time_limit() -> None:
    d = wd.decide(progress=5, now=5400, start=0, since=0, extend=0, cap=10800)
    assert d.deadline is None and d.message == "WATCHDOG: TIME_LIMIT (90m); stopping"


def test_log_tail_returns_only_new_text(tmp_path: Path) -> None:
    log = tmp_path / "raw.log"
    tail = wd.LogTail(str(log))
    assert tail.read_new() == ""  # missing file is not an error
    log.write_text("one\n")
    assert tail.read_new() == "one\n"
    with log.open("a") as f:
        f.write("two\n")
    assert tail.read_new() == "two\n"


def _run(tmp_path: Path, *args: str, script: str) -> "subprocess.CompletedProcess[str]":
    log = tmp_path / "raw.log"
    cmd = [
        sys.executable,
        str(WATCHDOG),
        *args,
        "--log",
        str(log),
        "--grace",
        "1s",
        "--",
        "sh",
        "-c",
        script + f" >> {log}",
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def test_command_exit_status_passes_through(tmp_path: Path) -> None:
    r = _run(tmp_path, "--limit", "10s", script="exit 3")
    assert r.returncode == 3 and "WATCHDOG" not in r.stdout


def test_stalled_command_is_stopped_with_124(tmp_path: Path) -> None:
    t0 = time.time()
    r = _run(
        tmp_path,
        "--limit",
        "1s",
        "--extend",
        "1s",
        "--cap",
        "10s",
        script="echo '  ┊ ✍️  write /tmp/x.py'; sleep 20",
    )
    assert r.returncode == 124
    assert "WATCHDOG: NO_PROGRESS" in r.stdout
    assert time.time() - t0 < 8  # the sleeping child was killed, not waited for


def test_progressing_command_is_extended_until_it_finishes(tmp_path: Path) -> None:
    script = "for i in 1 2 3 4 5 6; do echo '  ┊ ✍️  write /w/src/a.py'; sleep 0.4; done"
    r = _run(tmp_path, "--limit", "1s", "--extend", "1s", "--cap", "10s", script=script)
    assert r.returncode == 0
    assert "WATCHDOG: EXTENDED" in r.stdout


def test_progress_never_runs_past_the_cap(tmp_path: Path) -> None:
    t0 = time.time()
    script = "while :; do echo '  ┊ ✍️  write /w/src/a.py'; sleep 0.3; done"
    r = _run(tmp_path, "--limit", "1s", "--extend", "1s", "--cap", "3s", script=script)
    assert r.returncode == 124
    assert "WATCHDOG: CAP_REACHED" in r.stdout
    assert time.time() - t0 < 7


def test_missing_command_is_a_usage_error(tmp_path: Path) -> None:
    r = subprocess.run(
        [sys.executable, str(WATCHDOG), "--limit", "1s", "--log", "x"],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 2 and "no command given" in r.stderr
