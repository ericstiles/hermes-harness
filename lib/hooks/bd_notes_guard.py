#!/usr/bin/env python3
"""Hermes pre_tool_call hook: guard `bd update` notes writes in terminal commands.

1. Block `bd update ... --notes`: it replaces a bead's whole notes field and takes a literal
   string (it does not read @file). On 2026-11-19 Hermes ran `bd update <id> --notes @/tmp/f`,
   which wiped the PR link hermes-review needs, and the queue stalled.
2. Block `bd update <id> --append-notes` on a bead this run has not claimed. On 2026-11-24
   Hermes appended the PR link to organize_music-b8p.25 instead of organize_music-225. Claims
   (`bd update <id> --claim`) are recorded in the file named by HERMES_HARNESS_CLAIMS, which
   bin/hermes-run exports and empties per loop iteration; a claim earlier in the same command
   counts. Without HERMES_HARNESS_CLAIMS this check is off.
   A claim is recorded when the command is allowed, before bd runs, so a claim bd refuses
   (bead already claimed by another actor, unknown id) still counts for the rest of the
   iteration. A pre_tool_call hook cannot see bd's answer. That is acceptable: the check
   catches a mistyped id on --append-notes, and a refused claim names the id the agent chose
   to claim, not a retyped one. An unknown id also makes the append fail in bd, and
   lib/notes_check.sh still reports any bead that wrongly carries the PR URL after the run.

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
UNCLAIMED = (
    "Blocked: `bd update {ids} --append-notes`: this run has not claimed {ids} "
    "(claimed: {claimed}). Copy the full bead id from the claim or `gh pr view`, never retype "
    "it. A side bead must be claimed first (`bd update <id> --claim`)."
)
NO_ID = "Blocked: `bd update --append-notes` without a bead id. Name the full id you claimed."
GATE_VAR = "HERMES_HARNESS_RUN"  # set to 1 by bin/hermes-run; otherwise the hook allows all
CLAIMS_VAR = "HERMES_HARNESS_CLAIMS"  # file of ids claimed this run, one per line
_OPERATORS = {";", "&&", "||", "|", "&", "\n"}
_NOTES = re.compile(r"--notes(=|$)")
_ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
_PREFIXES = {"command", "env", "exec", "sudo", "nohup", "time"}
# Fallback when the command cannot be tokenized (unbalanced quotes).
_FALLBACK = re.compile(r"\bbd\s[^;&|\n]*\bupdate\b[^;&|\n]*(?<![\w-])--notes(?=[\s=]|$)")
# bd update flags that take a value (`bd update --help`: string, strings, stringArray, int);
# the value is never a bead id. tests/notes_guard_tests.sh compares this with the real bd.
_VALUE_FLAGS = {
    "--append-notes", "--notes", "--status", "-s", "--assignee", "-a", "--title",
    "--description", "-d", "--design", "--acceptance", "--priority", "-p", "--type", "-t",
    "--add-label", "--remove-label", "--set-labels", "-l", "--parent", "--if-assignee",
    "--if-status", "--estimate", "-e", "--external-ref", "--due", "--defer", "--body-file",
    "--description-file", "--metadata", "--spec-id", "--actor", "--db", "--await-id",
    "--design-file", "--session", "--set-metadata", "--unset-metadata", "--database", "-C",
    "--directory", "--dolt-auto-commit", "--mem-profile",
}  # fmt: skip


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


class Guard:
    """Walks a command's `bd update` calls in order; `reason` is set when one must be blocked."""

    def __init__(self, claimed: set[str] | None) -> None:
        self.claimed = claimed  # None: the claim check is off
        self.new_claims: list[str] = []
        self.reason: str | None = None

    def command(self, command: str) -> None:
        try:
            tokens = _tokens(command)
        except ValueError:
            if _FALLBACK.search(command):
                self.reason = REASON
            return
        for seg in _segments(tokens):
            if self.reason is None:
                self._segment(seg)

    def _segment(self, seg: list[str]) -> None:
        start = _program(seg)
        is_bd = os.path.basename(seg[start]) == "bd"
        args = seg[start + 1 :]
        if not is_bd:  # bash -c '...': guard the inner command too (never a bd flag's value)
            for tok in args:
                if any(c.isspace() for c in tok) and self.reason is None:
                    self.command(tok)
            return
        if "update" not in args:
            return
        ids, flags = _parse_update(args[args.index("update") + 1 :])
        if "--notes" in flags:
            self.reason = REASON
            return
        if "--claim" in flags:
            self.new_claims.extend(ids)
        if "--append-notes" in flags and self.claimed is not None:
            self._check_append(ids)

    def _check_append(self, ids: list[str]) -> None:
        if not ids:
            self.reason = NO_ID
            return
        known = self.claimed | set(self.new_claims)
        missing = [i for i in ids if i not in known]
        if missing:
            self.reason = UNCLAIMED.format(
                ids=" ".join(missing), claimed=", ".join(sorted(known)) or "none"
            )


def _parse_update(args: list[str]) -> tuple[list[str], set[str]]:
    """The bead ids and the flag names of `bd update <args>`."""
    ids: list[str] = []
    flags: set[str] = set()
    skip_next = False
    for tok in args:
        if skip_next:  # a flag's value, whatever it says (e.g. "--notes" as appended text)
            skip_next = False
            continue
        if tok.startswith("-"):
            name = tok.split("=", 1)[0]
            flags.add("--notes" if _NOTES.match(tok) else name)
            skip_next = "=" not in tok and name in _VALUE_FLAGS
        else:
            ids.append(tok)
    return ids, flags


def blocked(command: str) -> bool:
    """True when the shell command runs `bd update` with `--notes` / `--notes=`."""
    guard = Guard(None)
    guard.command(command)
    return guard.reason is not None


def _read_claims(path: str) -> set[str]:
    try:
        with open(path, encoding="utf-8") as fh:
            return {line.strip() for line in fh if line.strip()}
    except OSError:
        return set()


def _record_claims(path: str, ids: list[str]) -> None:
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.writelines(i + "\n" for i in ids)
    except OSError as exc:
        print(f"bd_notes_guard: cannot record claims in {path}: {exc}", file=sys.stderr)


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
        if not isinstance(command, str):
            return 0
        claims_path = os.environ.get(CLAIMS_VAR) or ""
        guard = Guard(_read_claims(claims_path) if claims_path else None)
        guard.command(command)
        if guard.reason is not None:
            print(json.dumps({"decision": "block", "reason": guard.reason}))
        elif claims_path and guard.new_claims:
            _record_claims(claims_path, guard.new_claims)
    except Exception as exc:  # fail open: a broken hook must never stop the agent
        print(f"bd_notes_guard: ignoring malformed payload: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
