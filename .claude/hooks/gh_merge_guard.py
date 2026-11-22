#!/usr/bin/env python3
"""Claude Code PreToolUse hook: the only PR merge allowed here is `gh pr merge <N> --rebase`.

Registered in .claude/settings.json for the Bash tool. Reads the hook JSON on stdin
({"tool_name": ..., "tool_input": {"command": ...}}). Each shell segment (split on
&&, ||, ;, | and newlines; $(...) and `...` bodies are checked as commands too) that
RUNS a PR merge must be exactly `gh pr merge <N> --rebase` or `gh pr merge --rebase <N>`.
A segment runs a merge when it mentions `pr merge` and starts with `gh` (any path),
a wrapper (env, bash -c, eval, xargs, sudo, ...) or a VAR=value prefix. Anything else
in such a segment (short or combined flags, --admin, --auto, --squash, no method,
extra arguments) exits 2: Claude Code refuses the command and shows the reason.
Text that only mentions a merge (echo, git commit -m, bd note) is not a merge.

The wildcard deny rules in settings.json stay as a second layer; the Main ruleset on
GitHub (rebase only, no bypass) is the last one. Unreadable hook input fails closed
when it mentions a merge, open otherwise. Python 3.9+.
"""

from __future__ import annotations

import json
import re
import sys

BLOCK = 2
ALLOWED = (re.compile(r"gh pr merge [0-9]+ --rebase"), re.compile(r"gh pr merge --rebase [0-9]+"))
MERGE = re.compile(r"\bpr\s+merge\b")
SEGMENT_SPLIT = re.compile(r"&&|\|\||[;|\n]")
SUBSHELL_BODY = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = frozenset(
    {"env", "command", "exec", "eval", "sudo", "xargs"}
    | {"bash", "sh", "zsh", "nohup", "time", "nice"}
)
REASON = (
    "gh_merge_guard: only `gh pr merge <N> --rebase` (or `gh pr merge --rebase <N>`) may run "
    "in this repo, as its own command. Blocked: %s"
)


def segment_allowed(segment: str) -> bool:
    """False when this shell segment runs a PR merge other than the allowed form."""
    normalized = " ".join(segment.split()).lstrip("({ ").rstrip(")} ")
    if not MERGE.search(normalized):
        return True
    first = normalized.split()[0]
    if ASSIGNMENT.match(first):
        return False
    name = first.rsplit("/", 1)[-1]
    if name in WRAPPERS:
        return False
    if name != "gh":
        return True  # only mentions a merge (echo, git commit -m, bd note, ...)
    return any(pattern.fullmatch(normalized) for pattern in ALLOWED)


def is_allowed(command: str) -> bool:
    if not MERGE.search(command):
        return True
    for match in SUBSHELL_BODY.finditer(command):
        body = match.group(1) if match.group(1) is not None else match.group(2)
        if not is_allowed(body):
            return False
    return all(segment_allowed(segment) for segment in SEGMENT_SPLIT.split(command))


def command_from(raw: str) -> str | None:
    """The Bash command, '' for other tools, or None when the input is unreadable."""
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    if data.get("tool_name") != "Bash":
        return ""
    tool_input = data.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    return command if isinstance(command, str) else None


def main() -> int:
    raw = sys.stdin.read()
    command = command_from(raw)
    if command is None:  # unreadable: fail closed if it mentions a merge at all
        return BLOCK if MERGE.search(raw) else 0
    if is_allowed(command):
        return 0
    sys.stderr.write(REASON % " ".join(command.split())[:200] + "\n")
    return BLOCK


if __name__ == "__main__":
    sys.exit(main())
