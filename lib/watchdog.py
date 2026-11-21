#!/usr/bin/env python3
"""watchdog: run a command under a progress-aware time limit (replaces timeout(1) in hermes-run).

    watchdog.py --limit 90m --extend 20m --cap 180m --log raw.log -- hermes chat ...

At each deadline the watchdog reads the part of --log written since its previous check (the
raw log `tee` writes downstream). If that interval shows progress -- a file written or patched
outside /tmp, a git commit, or a `--append-notes "PROGRESS: ..."` note -- the deadline moves by
--extend, never past start + --cap. Otherwise the command's process group gets SIGTERM, then
SIGKILL after --grace, and the watchdog exits 124 like timeout(1), so the run classifies as
TIMEOUT. Every decision is printed as a `WATCHDOG:` line, which lands in the raw and timed logs.

Progress is judged over the WHOLE interval since the last check, never as "no output for N
minutes": the log is silent while the model thinks, and one call can take 11 minutes.
--extend 0 is a plain time limit. Exit status: the command's own (128+N if killed by signal N),
or 124 when stopped by the watchdog. Python 3.9+, standard library only.
"""

# hermes-run starts this with whatever python3 is on PATH (3.9 on stock macOS): keep the
# `X | None` / `list[str]` annotations unevaluated
from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from typing import NamedTuple

TIMED_OUT = 124
_DURATION = re.compile(r"^(\d+(?:\.\d+)?)([smhd]?)$")
_UNIT = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
# Hermes tool lines: "  ┊ ✍️  write     /path  0.4s", "  ┊ 🔧 patch  /path", "  ┊ 💻 $  cmd"
_WRITE = re.compile(r"┊ \S+\s+(?:write|patch)\s+(\S+)")
_COMMIT = re.compile(r"┊ \S+\s+\$ .*\bgit commit\b")
_NOTE = re.compile(r"--append-notes\s+[\"']?PROGRESS:")


def parse_duration(text: str) -> float:
    """'90m' / '30s' / '1h' / '45' (seconds, like timeout(1)) -> seconds."""
    m = _DURATION.match(text.strip())
    if not m:
        raise ValueError(f"not a duration: {text!r} (use e.g. 90m, 30s, 1h)")
    return float(m.group(1)) * _UNIT[m.group(2)]


def fmt_duration(seconds: float) -> str:
    s = round(seconds)
    return f"{s // 60}m" if s >= 60 and s % 60 == 0 else f"{s}s"


def count_progress(text: str) -> int:
    """Progress lines in a log excerpt: project writes/patches (not /tmp), commits, PROGRESS:."""
    n = 0
    for line in text.splitlines():
        w = _WRITE.search(line)
        if (w and not w.group(1).startswith("/tmp/")) or _COMMIT.search(line) or _NOTE.search(line):
            n += 1
    return n


class Decision(NamedTuple):
    deadline: float | None  # None = stop the command now
    message: str


def decide(
    progress: int, now: float, start: float, since: float, extend: float, cap: float
) -> Decision:
    """What to do at a deadline, given the progress seen since `since`. Pure, for tests."""
    since_s = time.strftime("%H:%M:%S", time.localtime(since))
    if extend <= 0:
        return Decision(None, f"WATCHDOG: TIME_LIMIT ({fmt_duration(now - start)}); stopping")
    if progress == 0:
        return Decision(None, f"WATCHDOG: NO_PROGRESS since {since_s}; stopping")
    new = min(now + extend, start + cap)
    if new - now < 1:
        return Decision(
            None,
            f"WATCHDOG: CAP_REACHED ({fmt_duration(cap)}) with {progress} "
            f"progress lines since {since_s}; stopping",
        )
    until = time.strftime("%H:%M:%S", time.localtime(new))
    return Decision(
        new,
        f"WATCHDOG: EXTENDED +{fmt_duration(new - now)}: {progress} progress "
        f"lines since {since_s}; new limit {until}",
    )


class LogTail:
    """Reads only what was appended to a file since the previous read."""

    def __init__(self, path: str) -> None:
        self.path, self.offset = path, 0

    def read_new(self) -> str:
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read()
        except OSError:
            return ""
        self.offset += len(data)
        return data.decode("utf-8", errors="replace")


def say(message: str) -> None:
    try:
        sys.stdout.write(message + "\n")
        sys.stdout.flush()
    except OSError:
        pass  # a closed pipe must not stop the watchdog from stopping the command


def stop(proc: subprocess.Popen[bytes], grace: float) -> None:
    """SIGTERM the command's process group (Hermes and its tools), SIGKILL after `grace`."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            proc.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def run(cmd: list[str], limit: float, extend: float, cap: float, log: str, grace: float) -> int:
    start = time.time()
    cap = max(cap, limit)
    # Own process group, so stopping it also stops the tool processes Hermes started. Like GNU
    # timeout(1): setpgid only, not a new session, so the command keeps the controlling terminal.
    # (Popen's process_group= needs Python 3.11; this must run on 3.9.)
    proc = subprocess.Popen(cmd, preexec_fn=os.setpgrp)

    def forward(signum: int, _frame: object) -> None:  # Ctrl-C / kill of hermes-run
        stop(proc, grace)
        sys.exit(128 + signum)

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    tail, deadline, since = LogTail(log), start + limit, start
    while True:
        try:
            rc = proc.wait(timeout=max(0.05, min(1.0, deadline - time.time())))
            return rc if rc >= 0 else 128 - rc
        except subprocess.TimeoutExpired:
            pass
        now = time.time()
        if now < deadline:
            continue
        d = decide(count_progress(tail.read_new()), now, start, since, extend, cap)
        say(d.message)
        if d.deadline is None:
            stop(proc, grace)
            return TIMED_OUT
        deadline, since = d.deadline, now


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--limit", required=True, help="first deadline, e.g. 90m")
    p.add_argument("--extend", default="0", help="extension per check with progress; 0 = none")
    p.add_argument("--cap", default="0", help="total limit for all extensions (default: --limit)")
    p.add_argument("--log", required=True, help="raw log the command's output is written to")
    p.add_argument("--grace", default="30s", help="SIGTERM to SIGKILL delay")
    p.add_argument("cmd", nargs=argparse.REMAINDER)
    a = p.parse_args(argv)
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        p.error("no command given (put it after --)")
    try:
        limit, extend = parse_duration(a.limit), parse_duration(a.extend)
        cap, grace = parse_duration(a.cap), parse_duration(a.grace)
    except ValueError as e:
        p.error(str(e))
    return run(cmd, limit, extend, cap, a.log, grace)


if __name__ == "__main__":
    sys.exit(main())
