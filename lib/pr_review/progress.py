"""Progress logging helpers: readable durations and timed steps."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager

log = logging.getLogger("pr_review")


def fmt_duration(seconds: float) -> str:
    """`42s`, `2m30s`: minutes appear once there is at least one."""
    minutes, secs = divmod(round(seconds), 60)
    return f"{minutes}m{secs:02d}s" if minutes else f"{secs}s"


@contextmanager
def step(
    label: str, detail: str = "", clock: Callable[[], float] = time.monotonic
) -> Iterator[None]:
    """Log `label ...` now and `label: done in <time>` (or FAILED) when the block ends."""
    start = clock()
    log.info("%s%s ...", label, f" {detail}" if detail else "")
    try:
        yield
    except KeyboardInterrupt:
        log.info("%s: interrupted after %s", label, fmt_duration(clock() - start))
        raise
    except Exception as exc:
        log.info(
            "%s: FAILED after %s (%s: %s)",
            label, fmt_duration(clock() - start), type(exc).__name__, exc,
        )  # fmt: skip
        raise
    log.info("%s: done in %s", label, fmt_duration(clock() - start))
