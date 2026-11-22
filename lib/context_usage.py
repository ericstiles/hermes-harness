#!/usr/bin/env python3
"""context_usage: a Hermes session's token usage as one CONTEXT: line for the run log.

    hermes sessions export --session-id <ID> - > /tmp/export.json
    python3 lib/context_usage.py [--window N] [--model M] < /tmp/export.json

Reads ONE `hermes sessions export` JSON line on stdin and prints exactly one line:

    CONTEXT: used cumulative in=I out=O cache_read=C api_calls=A model=M
      (summed over all API calls; no peak available, so no %) [window: W (source)]
    CONTEXT: unavailable (<reason>)

Why cumulative and no percentage (verified 2026-11-21 against Hermes' ~/.hermes/state.db):
the export's input/output/cache_read token counts are SUMS over every API call of the
session, and Hermes stores no per-call or peak prompt size (messages.token_count is null
on every message; the real per-call `last_prompt_tokens` lives only in Hermes' memory).
A sum over many calls divided by the context window means nothing, so no % is printed.

The window is shown for reference, from the first source that knows it: --window, Hermes
config model.context_length, Hermes' own ~/.hermes/context_length_cache.yaml (the size
Hermes compresses against), then Ollama /api/ps (a loaded model's context_length). No
guessed numbers: when none knows, the line says why.

Never prints message content, the system prompt or a title, and always exits 0: logging
must not change a run's result. Every CONTEXT: line starts with `CONTEXT:`, which no
lib/classify.sh pattern matches. Python 3.9+, stdlib only.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import subprocess
import sys
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

PREFIX = "CONTEXT:"
FIELDS = (
    ("input_tokens", "in"),
    ("output_tokens", "out"),
    ("cache_read_tokens", "cache_read"),
    ("api_call_count", "api_calls"),
)
SAFE_MODEL = re.compile(r"[A-Za-z0-9._:/@+-]{1,120}")
CACHE_LINE = re.compile(r"^\s+(?P<key>\S+?)@\S+:\s*(?P<value>[0-9]+)\s*$")
LOOKUP_TIMEOUT = 5.0
DEFAULT_OLLAMA = "http://127.0.0.1:11434"
# A window lookup that fails in any of these ways just means "this source does not know".
LOOKUP_ERRORS = (
    OSError, ValueError, TypeError, KeyError, AttributeError,
    subprocess.SubprocessError, http.client.HTTPException,
)  # fmt: skip
USAGE = """usage: context_usage.py [--window N] [--model M] < SESSION_EXPORT_JSON
       context_usage.py --baseline < PROMPT_SIZE_JSON   (hermes prompt-size --json)
  --baseline   print the fixed prompt budget of a fresh session (chars/bytes, not tokens)
  --window N   context window in tokens (otherwise looked up; never guessed)
  --model M    model name for the window lookup (default: the export's model)
  -h, --help   show this help and exit
"""


@dataclass(frozen=True)
class Usage:
    model: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    api_call_count: int


@dataclass(frozen=True)
class Window:
    tokens: int | None
    source: str  # where the size came from, or "unknown (<why>)"


def _count(record: dict[str, object], field: str) -> int:
    if field not in record:
        raise ValueError(f"{field} is missing")
    value = record[field]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{field} is not a non-negative integer")
    return value


def parse_export(text: str) -> Usage:
    """Usage from the first non-empty line of `hermes sessions export` output.

    Error messages never quote the input: it may hold message content."""
    line = next((ln for ln in text.splitlines() if ln.strip()), "")
    if not line:
        raise ValueError("empty input")
    try:
        record = json.loads(line)
    except ValueError:
        raise ValueError("not JSON") from None
    if not isinstance(record, dict):
        raise ValueError("not a JSON object")
    counts = {field: _count(record, field) for field, _ in FIELDS}
    model = record.get("model")
    safe = model if isinstance(model, str) and SAFE_MODEL.fullmatch(model) else "unknown"
    return Usage(model=safe, **counts)


@dataclass(frozen=True)
class Baseline:
    """The fixed prompt budget of a fresh session, from `hermes prompt-size --json`.

    Hermes reports characters and bytes here, not tokens; no tokenizer count exists."""

    system_prompt: int
    tools: int
    tools_bytes: int
    memory: int
    skills_index: int
    context_files: int


def _field(record: dict[str, object], path: str) -> int:
    value: object = record
    for key in path.split("."):
        value = value.get(key) if isinstance(value, dict) else None
    if value is None:
        raise ValueError(f"{path} is missing")
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{path} is not a non-negative integer")
    return value


def _context_files(record: dict[str, object]) -> int:
    """Chars of the `context (AGENTS.md/cwd files)` section ([name, chars, bytes])."""
    sections = record.get("sections")
    for section in sections if isinstance(sections, list) else []:
        if isinstance(section, list) and section and str(section[0]).startswith("context"):
            return _field({"context": {"chars": section[1] if len(section) > 1 else None}},
                          "context.chars")  # fmt: skip
    raise ValueError("no context section")


def parse_prompt_size(text: str) -> Baseline:
    """Baseline from the whole `hermes prompt-size --json` output (pretty-printed JSON)."""
    if not text.strip():
        raise ValueError("empty input")
    try:
        record = json.loads(text)
    except ValueError:
        raise ValueError("not JSON") from None
    if not isinstance(record, dict):
        raise ValueError("not a JSON object")
    return Baseline(
        system_prompt=_field(record, "system_prompt.chars"),
        tools=_field(record, "tools.count"),
        tools_bytes=_field(record, "tools.json_bytes"),
        memory=_field(record, "memory.chars"),
        skills_index=_field(record, "skills_index.chars"),
        context_files=_context_files(record),
    )


def baseline_line(baseline: Baseline) -> str:
    return (
        f"{PREFIX} baseline system_prompt={baseline.system_prompt} chars "
        f"tools={baseline.tools} ({baseline.tools_bytes} B schema) memory={baseline.memory} "
        f"skills_index={baseline.skills_index} context_files={baseline.context_files} "
        "(chars and bytes; Hermes reports no token count)"
    )


def _positive(text: str | None) -> int | None:
    value = (text or "").strip()
    # ASCII only: str.isdigit() accepts '²', which int() rejects
    return int(value) if value.isascii() and value.isdigit() and int(value) > 0 else None


def window_from_cache(text: str, model: str) -> int | None:
    """The model's size in Hermes' context_length_cache.yaml (keys are model@base_url).

    None when the model is absent or listed with different sizes (no guessing)."""
    sizes = {
        int(m["value"])
        for m in map(CACHE_LINE.match, text.splitlines())
        if m and m["key"] == model and int(m["value"]) > 0
    }
    return sizes.pop() if len(sizes) == 1 else None


def resolve_window(
    explicit: str | None,
    model: str,
    *,
    config_lookup: Callable[[], str | None],
    cache_text: str | None,
    ollama_lookup: Callable[[str], int | None],
) -> Window:
    """The first source that knows the context window; never a guess."""
    reasons = []
    if explicit is not None:
        size = _positive(explicit)
        if size:
            return Window(size, "explicit --window")
        reasons.append("--window is not a positive integer")
    else:
        reasons.append("no --window")
    try:
        size = _positive(config_lookup())
    except LOOKUP_ERRORS:
        size = None
    if size:
        return Window(size, "hermes config model.context_length")
    reasons.append("model.context_length not set")
    size = window_from_cache(cache_text, model) if cache_text else None
    if size:
        return Window(size, "hermes context_length_cache")
    reasons.append("no context_length_cache entry")
    try:
        size = ollama_lookup(model) if model != "unknown" else None
    except LOOKUP_ERRORS:
        size = None
    if size:
        return Window(size, "ollama /api/ps")
    reasons.append("ollama has no context_length for the model")
    return Window(None, "unknown (" + "; ".join(reasons) + ")")


def context_line(usage: Usage, window: Window) -> str:
    counts = " ".join(f"{label}={getattr(usage, field)}" for field, label in FIELDS)
    shown = f"{window.tokens} ({window.source})" if window.tokens else window.source
    return (
        f"{PREFIX} used cumulative {counts} model={usage.model} "
        f"(summed over all API calls; no peak available, so no %) [window: {shown}]"
    )


def hermes_config_context_length() -> str | None:
    done = subprocess.run(
        ["hermes", "config", "get", "model.context_length"],
        capture_output=True, text=True, timeout=LOOKUP_TIMEOUT, check=False,
    )  # fmt: skip
    return done.stdout.strip() if done.returncode == 0 else None


def read_cache(environ: dict[str, str]) -> str | None:
    home = Path(environ.get("HERMES_HOME") or Path.home() / ".hermes")
    try:
        return (home / "context_length_cache.yaml").read_text(encoding="utf-8")
    except OSError:
        return None


def ollama_ps_context_length(model: str, host: str) -> int | None:
    """context_length of a LOADED model from Ollama /api/ps (local, read-only)."""
    with urllib.request.urlopen(f"{host.rstrip('/')}/api/ps", timeout=LOOKUP_TIMEOUT) as resp:
        data = json.load(resp)
    models = data.get("models") if isinstance(data, dict) else None
    for entry in models if isinstance(models, list) else []:
        if isinstance(entry, dict) and model in (entry.get("name"), entry.get("model")):
            return _positive(str(entry.get("context_length", "")))
    return None


def _arg(argv: list[str], name: str) -> str | None:
    """The flag's value; '' when the flag is last with no value; None when absent."""
    for i, item in enumerate(argv):
        if item == name:
            return argv[i + 1] if i + 1 < len(argv) else ""
        if item.startswith(name + "="):
            return item[len(name) + 1 :]
    return None


def main_baseline(stdin: TextIO, stdout: TextIO) -> int:
    try:
        stdout.write(baseline_line(parse_prompt_size(stdin.read())) + "\n")
    except UnicodeDecodeError:
        stdout.write(f"{PREFIX} baseline unavailable (not UTF-8)\n")
    except ValueError as exc:
        stdout.write(f"{PREFIX} baseline unavailable ({exc})\n")
    return 0


def main(argv: list[str], stdin: TextIO, stdout: TextIO, environ: dict[str, str]) -> int:
    if "--baseline" in argv:
        return main_baseline(stdin, stdout)
    try:
        usage = parse_export(stdin.read())
    except UnicodeDecodeError:  # its message quotes input bytes: use a fixed reason
        stdout.write(f"{PREFIX} unavailable (not UTF-8)\n")
        return 0
    except ValueError as exc:
        stdout.write(f"{PREFIX} unavailable ({exc})\n")
        return 0
    model = _arg(argv, "--model") or usage.model
    host = environ.get("OLLAMA_HOST") or DEFAULT_OLLAMA
    host = host if host.startswith("http") else f"http://{host}"
    window = resolve_window(
        _arg(argv, "--window"),
        model,
        config_lookup=hermes_config_context_length,
        cache_text=read_cache(environ),
        ollama_lookup=lambda m: ollama_ps_context_length(m, host),
    )
    stdout.write(context_line(usage, window) + "\n")
    return 0


if __name__ == "__main__":
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(USAGE + "\n" + (__doc__ or ""))
        sys.exit(0)
    try:
        sys.exit(main(sys.argv[1:], sys.stdin, sys.stdout, dict(os.environ)))
    except Exception as exc:  # last resort: logging must never change a run's result
        print(f"{PREFIX} unavailable (internal error: {type(exc).__name__})")
        sys.exit(0)
