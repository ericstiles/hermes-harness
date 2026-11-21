#!/usr/bin/env python3
"""Hermes pre_tool_call hook: block `bd update ... --notes` in terminal commands.

`--notes` replaces a bead's whole notes field and takes a literal string (it does not read
@file). On 2026-11-19 Hermes ran `bd update <id> --notes @/tmp/f`, which wiped the PR link
hermes-review needs, and the queue stalled. Agents must use `--append-notes` instead.

Wire protocol (~/.hermes/hermes-agent/agent/shell_hooks.py): Hermes pipes
{"tool_name": ..., "tool_input": {"command": ...}, ...} on stdin; printing
{"decision": "block", "reason": ...} blocks the call. Anything else (no output, exit 0)
allows it. Malformed input fails open with a log line on stderr.
Only active when HERMES_HARNESS_RUN=1 (exported by bin/hermes-run); Hermes passes its own
environment to hooks, so interactive and other Hermes sessions are never affected.
Python 3.9 compatible (the macOS system python3).
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

REASON = (
    "Blocked: `bd update --notes` replaces the whole notes field and does not read @file. "
    'Use `bd update <id> --append-notes "<line>"`, then `bd show <id>` to verify.'
)
GATE_VAR = "HERMES_HARNESS_RUN"  # set to 1 by bin/hermes-run; otherwise the hook allows all
_OPERATORS = {";", "&&", "||", "|", "&", "\n"}
_NOTES = re.compile(r"--notes(=|$)")
_ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
_PREFIXES = {"command", "env", "exec", "sudo", "nohup", "time"}
# Fallback when the command cannot be tokenized (unbalanced quotes).
_FALLBACK = re.compile(r"\bbd\s[^;&|\n]*\bupdate\b[^;&|\n]*(?<![\w-])--notes(?=[\s=]|$)")


def _tokens(command: str) -> list[str]:
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
    lex.whitespace = " \t\r"  # newline separates commands, so it is an operator here
    lex.whitespace_split = True
    return list(lex)


def _segments(tokens: list[str]) -> list[list[str]]:
    out: list[list[str]] = [[]]
    for tok in tokens:
        if tok in _OPERATORS or set(tok) <= set(";&|"):
            out.append([])
        else:
            out[-1].append(tok)
    return [s for s in out if s]


def _program(seg: list[str]) -> int:
    """Index of the program word, skipping `VAR=value` and command/env/exec/sudo prefixes."""
    i = 0
    while i < len(seg) - 1 and (_ASSIGN.match(seg[i]) or seg[i] in _PREFIXES):
        i += 1
    return i


def _segment_blocked(seg: list[str]) -> bool:
    start = _program(seg)
    is_bd = os.path.basename(seg[start]) == "bd"
    seg = seg[start:]
    skip_next = False
    has_update = False
    has_notes = False
    for tok in seg[1:]:
        if skip_next:  # the value of --append-notes, whatever it says
            skip_next = False
            continue
        if tok == "--append-notes":
            skip_next = True
        elif tok == "update":
            has_update = True
        elif _NOTES.match(tok):
            has_notes = True
        elif any(c.isspace() for c in tok) and blocked(tok):  # bash -c '...'
            return True
    return is_bd and has_update and has_notes


def blocked(command: str) -> bool:
    """True when the shell command runs `bd update` with `--notes` / `--notes=`."""
    try:
        tokens = _tokens(command)
    except ValueError:
        return _FALLBACK.search(command) is not None
    return any(_segment_blocked(seg) for seg in _segments(tokens))


USAGE = """Usage: bd_notes_guard.py < HOOK_PAYLOAD_JSON
  Takes no arguments: Hermes runs it as a pre_tool_call hook (~/.hermes/config.yaml)
  and pipes the tool call as JSON on stdin.
  -h, --help   show this help and exit
"""


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if "-h" in args or "--help" in args:
        print(USAGE + "\n" + (__doc__ or ""))
        return 0
    # The hook lives in the machine-wide ~/.hermes/config.yaml, so it fires for every Hermes
    # session; it only acts in unattended hermes-run sessions, which export this variable.
    if os.environ.get(GATE_VAR) != "1":
        return 0
    try:
        payload = json.loads(sys.stdin.read())
        if payload.get("tool_name") != "terminal":
            return 0
        command = (payload.get("tool_input") or {}).get("command")
        if isinstance(command, str) and blocked(command):
            print(json.dumps({"decision": "block", "reason": REASON}))
    except Exception as exc:  # fail open: a broken hook must never stop the agent
        print(f"bd_notes_guard: ignoring malformed payload: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
