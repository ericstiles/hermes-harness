#!/usr/bin/env python3
"""Claude Code PreToolUse hook: the only PR merge allowed here is `gh pr merge <N> --rebase`.

Registered in .claude/settings.json for the Bash tool. Reads the hook JSON on stdin
({"tool_name": ..., "tool_input": {"command": ...}}).

The command is tokenized once, quote-aware (shlex with shell punctuation): quotes and
backslashes are removed, and `;`, `&&`, `||`, `|`, `&`, newlines, `(`, `)` outside quotes
become separators, so a `|` or newline inside a quoted string stays part of its word.
Each segment between separators that RUNS a PR merge must be exactly
`gh pr merge <N> --rebase` or `gh pr merge --rebase <N>`. A segment runs a merge when a
separate `gh` word (any path) is followed later by the words `pr` `merge`, wherever it
sits (after if/then/!, timeout, env, a VAR=value prefix, inside $(...) or backticks).
A segment that invokes a shell (bash/sh/zsh/eval ...) and has a word containing the
whole word `merge` is blocked, since its merge hides inside one quoted word. Unbalanced
quotes in a command that mentions gh and the word merge are blocked. shlex does not
expand `$x`, `$'...'`, `$(...)` or backticks, so in a command that mentions gh and the
whole word merge, a segment that runs gh (or starts with an expansion such as `$G`) and
contains any `$` or backtick is blocked without trying to work out what it expands to.
Anything else exits 2: Claude Code refuses the command and shows the reason.

Allowed: a merge mentioned inside ONE quoted word (git commit -m '...', bd note '...',
python3 -c '...'), and words like `mergeable` (`gh pr view --json mergeable`).
Blocked: an unquoted mention (`echo gh pr merge -s 0`).
Not covered: gh aliases (`gh alias set`) that expand to a merge.

This hook is BEST-EFFORT: matching text cannot fully model the shell (e.g. a merge
built from pieces that never spell `merge`, or a gh alias). The real enforcement is the
Main ruleset on GitHub (rebase only, no bypass); the wildcard deny rules in settings.json
are a second layer. Python 3.9+.
"""

from __future__ import annotations

import json
import re
import shlex
import sys

BLOCK = 2
ALLOWED = (re.compile(r"gh pr merge [0-9]+ --rebase"), re.compile(r"gh pr merge --rebase [0-9]+"))
MERGE_WORD = re.compile(r"\bmerge\b")
PUNCTUATION = "();<>|&\n"
SEPARATOR_CHARS = frozenset("();|&\n")
SHELLS = frozenset({"bash", "sh", "zsh", "dash", "ksh", "fish", "eval"})
REASON = (
    "gh_merge_guard: only `gh pr merge <N> --rebase` (or `gh pr merge --rebase <N>`) may run "
    "in this repo, as its own command. Blocked: %s"
)


def _tokens(command: str) -> list[str] | None:
    """Shell tokens (words and punctuation runs), or None when quoting is unbalanced."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=PUNCTUATION)
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""  # bash starts a comment only at a word start; `a#b` is one word
    try:
        return list(lexer)
    except ValueError:
        return None


def _segments(tokens: list[str]) -> list[list[str]]:
    """Words between separators, with grouping braces and backticks stripped."""
    segments: list[list[str]] = [[]]
    for token in tokens:
        if token and set(token) <= SEPARATOR_CHARS:
            segments.append([])
            continue
        word = token.strip("{}`")
        if word:
            segments[-1].append(word)
    return [segment for segment in segments if segment]


def _is_gh(word: str) -> bool:
    """`gh`, any path to it, or `$'gh'` (shlex keeps the `$` of ANSI-C quoting)."""
    return word.lstrip("$").rsplit("/", 1)[-1] == "gh"


def _has_expansion(word: str) -> bool:
    return "$" in word or "`" in word


def _runs_merge(words: list[str]) -> bool:
    """True when a separate `gh` word is followed (anywhere later) by `pr` `merge`."""
    for i, word in enumerate(words):
        if _is_gh(word):
            rest = words[i + 1 :]
            if any(rest[j : j + 2] == ["pr", "merge"] for j in range(len(rest) - 1)):
                return True
    return False


def segment_allowed(words: list[str]) -> bool:
    """False when this segment runs a PR merge other than the allowed form.

    Only called for commands that mention gh and the whole word merge."""
    invokes_shell = any(word.rsplit("/", 1)[-1] in SHELLS for word in words)
    if invokes_shell and any(MERGE_WORD.search(word) for word in words):
        return False  # bash -c '...', eval "...": the merge is inside a string
    runs_gh = any(_is_gh(word) for word in words) or _has_expansion(words[0])
    if runs_gh and any(_has_expansion(word) for word in words):
        return False  # $x, $'...', $(...), `...`: shlex cannot see what the shell expands
    if not _runs_merge(words):
        return True
    return any(pattern.fullmatch(" ".join(words)) for pattern in ALLOWED)


def is_allowed(command: str) -> bool:
    if not MERGE_WORD.search(command) or "gh" not in command:
        return True
    tokens = _tokens(command)
    if tokens is None:  # unbalanced quotes in a command mentioning gh and merge
        return False
    return all(segment_allowed(words) for words in _segments(tokens))


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
    if command is None:  # unreadable: fail closed if it mentions gh and the word merge
        return BLOCK if MERGE_WORD.search(raw) and "gh" in raw else 0
    if is_allowed(command):
        return 0
    sys.stderr.write(REASON % " ".join(command.split())[:200] + "\n")
    return BLOCK


if __name__ == "__main__":
    sys.exit(main())
