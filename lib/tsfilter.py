#!/usr/bin/env python3
"""tsfilter: timestamp a line stream for the terminal and a timed log.

    hermes chat ... 2>&1 | tee raw.log | python3 -u tsfilter.py --log run.timed.txt

Each input line is written to stdout and to --log as "[HH:MM:SS] line", with
any CR (logs come from a pty) stripped. When a line arrives after a gap of at
least HERMES_TS_MIN_GAP seconds (default 2), a "[HH:MM:SS] (+38s)" line is
written before it: the time since the previous output. After a tool step
(┊ ...) that is roughly the tool's run time; before a "Hermes" box it is the
time the response took. Best effort: Hermes does not say when work ends.

Stall warning: when no input arrives for HERMES_STALL_WARN (default 10m;
Ns/Nm/Nh, bare = seconds; 0 disables) a "[HH:MM:SS] no output for 10m (last:
HH:MM:SS)" line goes to stdout and --log, repeating each further interval.
It never reaches the raw log: this filter sits after `tee raw.log`.

Crash safety matters more than formatting. This filter sits behind
`tee raw.log`; if it exited early, tee would get EPIPE and could stop writing
the RAW log that classification depends on. So the filter never exits before
its input ends: a line it cannot format is passed through raw, a closed
stdout or an unwritable log is tolerated, and it always exits 0.

Bead id (--id ID, and `bd update <id> --claim` in the stream): once the run's
bead is known every stamp reads "[HH:MM:SS,<id>]"; before that, "[HH:MM:SS]".
A later claim replaces the id; a placeholder such as <id> is not an id.

Test hook: HH_TS_FAKE_CLOCK="t1 t2 ..." supplies one epoch second per input
line (the last value repeats), so tests need no sleeping. Python 3.9+.
"""
import os
import re
import select
import sys
import time
from typing import BinaryIO, Callable, Dict, List, Mapping, Optional, Tuple

Clock = Callable[[], float]

DEFAULT_MIN_GAP = 2.0
DEFAULT_STALL = 600.0
READ_CHUNK = 65536
_DURATION = re.compile(r"^(\d+(?:\.\d+)?)([smhd]?)$")
_UNIT = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
# same pattern as lib/runtime.sh's hh_claimed_issue (bin/hermes-run's claimed_issue); a test
# checks they agree
_CLAIM = re.compile(r"\bbd update ([A-Za-z0-9][A-Za-z0-9._-]*) --claim\b")


def fmt_clock(epoch: float) -> str:
    return time.strftime("%H:%M:%S", time.localtime(epoch))


def fmt_stamp(epoch: float, bead: Optional[str] = None) -> str:
    """[HH:MM:SS], or [HH:MM:SS,<id>] once the bead is known."""
    clock = fmt_clock(epoch)
    return "[%s,%s]" % (clock, bead) if bead else "[%s]" % clock


def claimed_bead(line: str, current: Optional[str]) -> Optional[str]:
    """The run's bead: `current` once known, else the first id this line claims.

    The first claim is the run's bead, as everywhere in hermes-run (RUN_TIME issue=, BEADS: worked,
    the wrap-up prompt). A later claim (a review-fix run marking a side bead B) does not switch it.
    """
    if current:
        return current
    found = _CLAIM.findall(line)
    return found[0] if found else None


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


def stall_from_env(environ: Mapping[str, str]) -> float:
    """HERMES_STALL_WARN in seconds, parsed like RUN_TIMEOUT (90m, 30s, 2h, 45); 0 = off."""
    raw = environ.get("HERMES_STALL_WARN", "").strip()
    match = _DURATION.match(raw) if raw else None
    if raw and not match:
        warn("HERMES_STALL_WARN=%r is not a duration like 10m; using 10m" % raw)
    if not match:
        return DEFAULT_STALL
    return float(match.group(1)) * _UNIT[match.group(2)]


def fmt_stall(seconds: float) -> str:
    """10m, 1m30s, 2h, 2h05m, 45s: the style HERMES_STALL_WARN is written in."""
    s = int(round(seconds))
    hours, minutes, secs = s // 3600, (s % 3600) // 60, s % 60
    if hours:
        return "%dh" % hours + ("%02dm" % minutes if minutes else "")
    if minutes:
        return "%dm" % minutes + ("%02ds" % secs if secs else "")
    return "%ds" % secs


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


def format_line(
    line: str, now: float, prev: Optional[float], min_gap: float, bead: Optional[str] = None
) -> List[str]:
    """Lines to emit for one input line (without trailing newlines)."""
    stamp = fmt_stamp(now, bead)
    out = []
    if prev is not None and now - prev >= min_gap:
        out.append("%s (%s)" % (stamp, fmt_elapsed(now - prev)))
    out.append("%s %s" % (stamp, line))
    return out


def wait_readable(fd: int, timeout: float) -> bool:
    """True when fd has input (or select fails: fall back to a blocking read)."""
    try:
        ready, _, _ = select.select([fd], [], [], timeout)
    except (OSError, ValueError):
        return True
    return bool(ready)


class LineReader:
    """Lines from a file descriptor, with a timeout. Reads the fd directly so
    no input can sit in a Python buffer while select() reports a stall."""

    def __init__(self, fd: int) -> None:
        self.fd = fd
        self.pending = b""
        self.eof = False

    def next_line(self, timeout: Optional[float] = None) -> Optional[bytes]:
        """The next line; b"" at end of input; None if `timeout` passed with no input."""
        while True:
            end = self.pending.find(b"\n")
            if end >= 0:
                line, self.pending = self.pending[: end + 1], self.pending[end + 1 :]
                return line
            if self.eof:
                line, self.pending = self.pending, b""
                return line
            if timeout is not None and not wait_readable(self.fd, timeout):
                return None
            chunk = os.read(self.fd, READ_CHUNK)
            if chunk:
                self.pending += chunk
            else:
                self.eof = True


def stall_line(waited: float, last: float, any_output: bool, bead: Optional[str] = None) -> str:
    since = ("last: %s" if any_output else "started: %s") % fmt_clock(last)
    return "%s no output for %s (%s)\n" % (fmt_stamp(time.time(), bead), fmt_stall(waited), since)


def run(
    reader: LineReader,
    sinks: List[Sink],
    clock: Clock,
    min_gap: float,
    stall: float = 0.0,
    bead: Optional[str] = None,
) -> None:
    prev = None
    quiet_since, last_wall, any_output, warned = time.monotonic(), time.time(), False, 0
    while True:
        timeout = None
        if stall > 0:
            timeout = max(stall * (warned + 1) - (time.monotonic() - quiet_since), 0.0)
        raw = reader.next_line(timeout)
        if raw is None:
            warned += 1
            for sink in sinks:
                sink.write(stall_line(stall * warned, last_wall, any_output, bead))
            continue
        if not raw:
            return
        quiet_since, last_wall, any_output, warned = time.monotonic(), time.time(), True, 0
        line = raw.decode("utf-8", errors="replace").rstrip("\n").replace("\r", "")
        bead = claimed_bead(line, bead)
        try:
            now = clock()
            emitted = format_line(line, now, prev, min_gap, bead)
            prev = now
        except Exception as err:  # never lose a line: pass it through raw
            warn("could not timestamp a line (%s); passing it through" % err)
            emitted = [line]
        text = "".join(item + "\n" for item in emitted)
        for sink in sinks:
            sink.write(text)


def parse_args(argv: List[str]) -> Tuple[Optional[str], Optional[str]]:
    """(--log path, --id bead); either may be None. An empty --id means unknown."""
    values: Dict[str, Optional[str]] = {"--log": None, "--id": None}
    i = 0
    while i < len(argv):
        name, eq, value = argv[i].partition("=")
        if name in values and eq:
            values[name] = value
            i += 1
        elif argv[i] in values and i + 1 < len(argv):
            values[argv[i]] = argv[i + 1]
            i += 2
        else:
            warn("ignoring unknown argument %r" % argv[i])
            i += 1
    return values["--log"], values["--id"] or None


USAGE = """Usage: tsfilter.py [--log FILE] < STREAM
  --log FILE   also write each timestamped line to FILE (hermes-run: run-<stamp>.timed.txt)
  --id BEAD    stamp [HH:MM:SS,BEAD] from the first line (a resumed run's claimed bead)
  HERMES_STALL_WARN=10m  warn after this long with no input (Ns/Nm/Nh; 0 = off)
  -h, --help   show this help and exit
"""


def main(argv: List[str]) -> int:
    if "-h" in argv or "--help" in argv:
        print(USAGE + "\n" + (__doc__ or ""))
        return 0
    log_path, bead = parse_args(argv)
    sinks = [Sink(sys.stdout.buffer, "stdout", is_stdout=True), open_log(log_path)]
    reader = LineReader(sys.stdin.fileno())
    try:
        clock, min_gap = make_clock(os.environ), min_gap_from_env(os.environ)
        run(reader, sinks, clock, min_gap, stall_from_env(os.environ), bead)
    except Exception as err:  # last resort: drain input raw so tee never sees EPIPE
        warn("unexpected error (%s); passing the rest through raw" % err)
        for raw in iter(reader.next_line, b""):
            for sink in sinks:
                sink.write(raw.decode("utf-8", errors="replace").replace("\r", ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
