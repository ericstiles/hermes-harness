#!/usr/bin/env python3
"""tsfilter: timestamp a line stream for the terminal and a timed log.

    hermes chat ... 2>&1 | tee raw.log | python3 -u tsfilter.py --log run.timed.txt

Each input line is written to stdout and to --log as "[HH:MM:SS] line", with
any CR (logs come from a pty) stripped. When a line arrives after a gap of at
least HERMES_TS_MIN_GAP seconds (default 2), a "[HH:MM:SS] (+38s)" line is
written before it: the time since the previous output. After a tool step
(┊ ...) that is roughly the tool's run time; before a "Hermes" box it is the
time the response took. Best effort: Hermes does not say when work ends.

Crash safety matters more than formatting. This filter sits behind
`tee raw.log`; if it exited early, tee would get EPIPE and could stop writing
the RAW log that classification depends on. So the filter never exits before
its input ends: a line it cannot format is passed through raw, a closed
stdout or an unwritable log is tolerated, and it always exits 0.

Test hook: HH_TS_FAKE_CLOCK="t1 t2 ..." supplies one epoch second per input
line (the last value repeats), so tests need no sleeping. Python 3.9+.
"""
import os
import sys
import time
from typing import BinaryIO, Callable, List, Mapping, Optional

Clock = Callable[[], float]

DEFAULT_MIN_GAP = 2.0


def fmt_clock(epoch: float) -> str:
    return time.strftime("%H:%M:%S", time.localtime(epoch))


def fmt_elapsed(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return "+%ds" % s
    if s < 3600:
        return "+%dm%02ds" % (s // 60, s % 60)
    return "+%dh%02dm" % (s // 3600, (s % 3600) // 60)


def min_gap_from_env(environ: Mapping[str, str]) -> float:
    raw = environ.get("HERMES_TS_MIN_GAP", "")
    try:
        value = float(raw) if raw else DEFAULT_MIN_GAP
    except ValueError:
        warn("HERMES_TS_MIN_GAP=%r is not a number; using %gs" % (raw, DEFAULT_MIN_GAP))
        return DEFAULT_MIN_GAP
    return max(value, 0.0)


def make_clock(environ: Mapping[str, str]) -> Clock:
    """Return a zero-arg clock. The fake clock yields raw strings so a bad
    value fails at format time, per line, exercising the raw fallback."""
    fake = environ.get("HH_TS_FAKE_CLOCK")
    if fake is None:
        return time.time
    values = fake.split() or ["0"]
    state = {"i": 0}

    def fake_clock() -> float:
        value = values[min(state["i"], len(values) - 1)]
        state["i"] += 1
        return float(value)

    return fake_clock


def warn(message: str) -> None:
    try:
        sys.stderr.write("tsfilter: %s\n" % message)
        sys.stderr.flush()
    except OSError:
        pass


def silence_stdout() -> None:
    """Point fd 1 at /dev/null so Python's exit-time flush of a closed pipe
    cannot fail (it would otherwise exit 120 when run without -u)."""
    try:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        os.close(devnull)
    except (OSError, ValueError):
        pass


class Sink:
    """A byte stream that disables itself after the first write error."""

    def __init__(self, stream: Optional[BinaryIO], name: str, is_stdout: bool = False) -> None:
        self.stream = stream
        self.name = name
        self.is_stdout = is_stdout

    def write(self, text: str) -> None:
        if self.stream is None:
            return
        data = memoryview(text.encode("utf-8"))
        try:
            while data:  # under -u stdout is raw FileIO: write() may be partial
                written = self.stream.write(data)
                data = data[written if written is not None else len(data):]
            self.stream.flush()
        except (OSError, ValueError) as err:
            warn("cannot write %s (%s); continuing without it" % (self.name, err))
            self.stream = None
            if self.is_stdout:
                silence_stdout()


def open_log(path: Optional[str]) -> Sink:
    if not path:
        return Sink(None, "log")
    try:
        return Sink(open(path, "ab"), path)
    except OSError as err:
        warn("cannot open %s (%s); terminal output only" % (path, err))
        return Sink(None, path)


def format_line(line: str, now: float, prev: Optional[float], min_gap: float) -> List[str]:
    """Lines to emit for one input line (without trailing newlines)."""
    stamp = "[%s]" % fmt_clock(now)
    out = []
    if prev is not None and now - prev >= min_gap:
        out.append("%s (%s)" % (stamp, fmt_elapsed(now - prev)))
    out.append("%s %s" % (stamp, line))
    return out


def run(stdin: BinaryIO, sinks: List[Sink], clock: Clock, min_gap: float) -> None:
    prev = None
    while True:
        raw = stdin.readline()
        if not raw:
            return
        line = raw.decode("utf-8", errors="replace").rstrip("\n").replace("\r", "")
        try:
            now = clock()
            emitted = format_line(line, now, prev, min_gap)
            prev = now
        except Exception as err:  # never lose a line: pass it through raw
            warn("could not timestamp a line (%s); passing it through" % err)
            emitted = [line]
        text = "".join(item + "\n" for item in emitted)
        for sink in sinks:
            sink.write(text)


def parse_args(argv: List[str]) -> Optional[str]:
    log_path = None
    i = 0
    while i < len(argv):
        if argv[i] == "--log" and i + 1 < len(argv):
            log_path = argv[i + 1]
            i += 2
        elif argv[i].startswith("--log="):
            log_path = argv[i][len("--log="):]
            i += 1
        else:
            warn("ignoring unknown argument %r" % argv[i])
            i += 1
    return log_path


def main(argv: List[str]) -> int:
    log_path = parse_args(argv)
    sinks = [Sink(sys.stdout.buffer, "stdout", is_stdout=True), open_log(log_path)]
    try:
        run(sys.stdin.buffer, sinks, make_clock(os.environ), min_gap_from_env(os.environ))
    except Exception as err:  # last resort: drain input raw so tee never sees EPIPE
        warn("unexpected error (%s); passing the rest through raw" % err)
        for raw in iter(sys.stdin.buffer.readline, b""):
            for sink in sinks:
                sink.write(raw.decode("utf-8", errors="replace").replace("\r", ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
