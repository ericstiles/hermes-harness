#!/usr/bin/env python3
"""Claude Code PreToolUse hook: the only PR merge allowed here is `gh pr merge <N> --rebase`.

Registered in .claude/settings.json for the Bash tool. Reads the hook JSON on stdin
({"tool_name": ..., "tool_input": {"command": ...}}). Each shell segment (split on
&&, ||, ;, | and newlines; $(...) and `...` bodies are checked as commands too) that
RUNS a PR merge must be exactly `gh pr merge <N> --rebase` or `gh pr merge --rebase <N>`.
The segment is split into shell words (shlex: quotes and backslashes removed). It runs
a merge when a separate `gh` word (any path) is followed later by the words `pr merge`,
wherever it sits (after if/then/!, timeout, env, a VAR=value prefix, ...). A segment
that also invokes a shell (bash/sh/zsh/eval ...) and mentions merge is blocked, since
its merge hides inside one quoted word. Unbalanced quotes around gh + merge are blocked.
Anything other than the exact allowed form exits 2: Claude Code refuses the command and
shows the reason. A merge mentioned inside ONE quoted word (git commit -m '...',
bd note '...', echo '...') is text, not a merge; an unquoted mention counts as a merge.
Not covered: gh aliases (`gh alias set`) that expand to a merge.

The wildcard deny rules in settings.json stay as a second layer; the Main ruleset on
GitHub (rebase only, no bypass) is the last one. Unreadable hook input fails closed
when it mentions a merge, open otherwise. Python 3.9+.
"""

from __future__ import annotations

import json
import re
import shlex
import sys

BLOCK = 2
ALLOWED = (re.compile(r"gh pr merge [0-9]+ --rebase"), re.compile(r"gh pr merge --rebase [0-9]+"))
MERGE = re.compile(r"\bpr\s+merge\b")
SEGMENT_SPLIT = re.compile(r"&&|\|\||[;|\n]")
SUBSHELL_BODY = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
SHELLS = frozenset({"bash", "sh", "zsh", "dash", "ksh", "fish", "eval"})
REASON = (
    "gh_merge_guard: only `gh pr merge <N> --rebase` (or `gh pr merge --rebase <N>`) may run "
    "in this repo, as its own command. Blocked: %s"
)


def _words(segment: str) -> list[str] | None:
    """Shell words with quotes and escapes removed, or None when quoting is unbalanced."""
    try:
        words = shlex.split(segment, posix=True)
    except ValueError:
        return None
    return [word.strip("(){}") for word in words if word.strip("(){}")]


def _runs_merge(words: list[str]) -> bool:
    """True when a separate `gh` word is followed (anywhere later) by `pr` `merge`."""
    for i, word in enumerate(words):
        if word.rsplit("/", 1)[-1] == "gh":
            rest = words[i + 1 :]
            if any(rest[j : j + 2] == ["pr", "merge"] for j in range(len(rest) - 1)):
                return True
    return False


def segment_allowed(segment: str) -> bool:
    """False when this shell segment runs a PR merge other than the allowed form."""
    if "merge" not in segment or "gh" not in segment:
        return True
    words = _words(segment)
    if words is None:  # unbalanced quotes around something mentioning gh and merge
        return False
    if any(w.rsplit("/", 1)[-1] in SHELLS for w in words) and any("merge" in w for w in words):
        return False  # bash -c '...', eval "...": the merge is inside a string
    if not _runs_merge(words):
        return True  # only mentions a merge inside one quoted word (commit message, note)
    return any(pattern.fullmatch(" ".join(words)) for pattern in ALLOWED)


def is_allowed(command: str) -> bool:
    if "merge" not in command or "gh" not in command:
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
