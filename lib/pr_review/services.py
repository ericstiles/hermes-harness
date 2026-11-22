"""GitHub (gh) and beads (bd) calls used by the reviewer agent."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass

from pr_review.fixes import FIXED_IN_PREFIX, HUMAN_LABEL, REVIEW_FIX_LABEL, is_fix_for, is_fixed_in
from pr_review.meta import BRANCH_PREFIX
from pr_review.shell import Runner, must
from pr_review.verdict import REFUSED_PREFIX

LABEL_COLOR = "d93f0b"
# Rounds of `bd epic close-eligible`: closing a child epic can make its parent eligible.
MAX_EPIC_ROUNDS = 10
log = logging.getLogger("pr_review")

REFUSED_NOTE = "**Reviewer agent: not reviewed.**"
_PR_FIELDS = "number,title,body,headRefName,headRefOid,url,isDraft"


@dataclass(frozen=True)
class PullRequest:
    number: int
    title: str
    body: str
    branch: str
    head_sha: str
    url: str


class GitHub:
    def __init__(self, run: Runner, reviewer_token: str | None = None) -> None:
        self._run = run
        self._token = reviewer_token

    def open_bead_prs(self) -> list[PullRequest]:
        """Open, non-draft PRs whose branch is bd/<id>, oldest first."""
        cmd = [
            "gh",
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "50",
            "--json",
            _PR_FIELDS,
        ]
        rows = json.loads(must(self._run(cmd), "gh pr list").out or "[]")
        prs = [
            PullRequest(
                r["number"],
                r["title"],
                r["body"] or "",
                r["headRefName"],
                r["headRefOid"],
                r["url"],
            )
            for r in rows
            if r["headRefName"].startswith(BRANCH_PREFIX) and not r.get("isDraft")
        ]
        return sorted(prs, key=lambda p: p.number)

    def has_marker(self, pr: PullRequest, marker: str) -> bool:
        """True when a comment or review on the PR contains `marker`."""
        cmd = ["gh", "pr", "view", str(pr.number), "--json", "comments,reviews"]
        data = json.loads(must(self._run(cmd), "gh pr view").out)
        bodies = [c.get("body", "") for c in data.get("comments", []) + data.get("reviews", [])]
        return any(marker in body for body in bodies)

    def refusal_at_head(self, pr: PullRequest) -> str | None:
        """The reason of the latest hermes-review refusal for the PR's CURRENT head, else None."""
        cmd = ["gh", "pr", "view", str(pr.number), "--json", "comments,reviews"]
        data = json.loads(must(self._run(cmd), "gh pr view").out)
        needle = f"{REFUSED_PREFIX}{pr.head_sha}:"
        bodies = [c.get("body", "") for c in data.get("comments", []) + data.get("reviews", [])]
        refusals = [b for b in bodies if needle in b]
        if not refusals:
            return None
        text = refusals[-1].split(REFUSED_NOTE, 1)[-1]
        return text.strip().splitlines()[0] if text.strip() else "(no reason given)"

    def post_review(self, pr: PullRequest, text: str, approve: bool) -> None:
        """Approve / request changes with the reviewer identity, else post a comment."""
        if self._token:
            flag = "--approve" if approve else "--request-changes"
            cmd = ["gh", "pr", "review", str(pr.number), flag, "--body", text]
            must(self._run(cmd, env={"GH_TOKEN": self._token}), "gh pr review")
            return
        cmd = ["gh", "pr", "comment", str(pr.number), "--body", text]
        must(self._run(cmd), "gh pr comment")

    def merge(self, pr: PullRequest) -> None:
        cmd = [
            "gh",
            "pr",
            "merge",
            str(pr.number),
            "--rebase",
            "--delete-branch",
            "--match-head-commit",
            pr.head_sha,
        ]
        must(self._run(cmd), "gh pr merge")

    def add_label(self, pr: PullRequest, label: str) -> None:
        """Label the PR, creating the label first if the repo does not have it."""
        create = ["gh", "label", "create", label, "--color", LABEL_COLOR, "--force"]
        must(self._run(create), "gh label create")
        must(
            self._run(["gh", "pr", "edit", str(pr.number), "--add-label", label]),
            "gh pr edit",
        )


class Beads:
    def __init__(self, run: Runner) -> None:
        self._run = run

    def pull(self) -> None:
        must(self._run(["bd", "dolt", "pull"]), "bd dolt pull")

    def show(self, bead: str) -> dict[str, object]:
        data = json.loads(must(self._run(["bd", "show", bead, "--json"]), "bd show").out)
        return data[0] if isinstance(data, list) else data

    def text(self, bead: str) -> str:
        return must(self._run(["bd", "show", bead]), "bd show").out

    def close(self, bead: str, pr: PullRequest) -> None:
        cmd = [
            "bd",
            "close",
            bead,
            "--force",
            "--reason",
            f"merged PR #{pr.number}",
            "--json",
        ]
        must(self._run(cmd), "bd close")

    def close_eligible_epics(self, pr: PullRequest) -> list[str]:
        """Close every epic whose children are all done, repeating for parents that become
        eligible in turn (capped). Never raises: a merged PR must not fail on this."""
        reason = f"All children completed (after merged PR #{pr.number})"
        closed: list[str] = []
        for _ in range(MAX_EPIC_ROUNDS):
            result = self._run(["bd", "epic", "close-eligible", "--json", "--reason", reason])
            try:
                data = json.loads(result.out) if result.ok else None
                ids = [str(i) for i in data["closed"]] if isinstance(data, dict) else None
            except (ValueError, KeyError, TypeError):
                ids = None
            if ids is None:
                log.warning("bd epic close-eligible failed (%s): %s", result.code,
                            (result.err or result.out).strip()[:300])  # fmt: skip
                return closed
            if not ids:
                return closed
            for epic in ids:
                log.info("closed epic %s: all its children are done", epic)
            closed += ids
        log.warning("bd epic close-eligible: stopped after %d rounds", MAX_EPIC_ROUNDS)
        return closed

    def note(self, bead: str, text: str) -> None:
        must(self._run(["bd", "update", bead, "--append-notes", text]), "bd update")

    def review_fixes(self, pr_number: int) -> list[dict[str, object]]:
        """Every review-fix issue (any status) filed for PR #pr_number."""
        cmd = [
            "bd",
            "list",
            "--all",
            "--label",
            REVIEW_FIX_LABEL,
            "--json",
            "--limit",
            "0",
        ]
        rows = json.loads(must(self._run(cmd), "bd list").out or "[]")
        return [r for r in rows if is_fix_for(str(r.get("title", "")), pr_number)]

    def fixed_in(self, pr: PullRequest) -> list[str]:
        """Open beads another review-fix solved in this PR (a `Fixed in PR <url>` note line)."""
        needle = FIXED_IN_PREFIX + pr.url
        cmd = ["bd", "list", "--notes-contains", needle, "--json", "--limit", "0"]
        rows = json.loads(must(self._run(cmd), "bd list").out or "[]")
        return [
            str(r["id"])
            for r in rows
            if r.get("status") != "closed" and is_fixed_in(str(r.get("notes") or ""), pr.url)
        ]

    def escalate(self, bead: str, text: str) -> None:
        """Block the ticket and flag it for a human (`bd human list`)."""
        cmd = ["bd", "update", bead, "--status", "blocked", "--add-label", HUMAN_LABEL,
               "--append-notes", text]  # fmt: skip
        must(self._run(cmd), "bd update")

    def create(self, args: list[str]) -> str:
        return must(self._run(["bd", *args]), "bd create").out.strip()

    def push(self) -> None:
        """Push beads; on a rejected push (someone else pushed), pull once and retry."""
        if self._run(["bd", "dolt", "push"]).ok:
            return
        self.pull()
        must(self._run(["bd", "dolt", "push"]), "bd dolt push")


def desktop_notify(run: Runner, title: str, text: str) -> None:
    """Best-effort macOS notification; a missing osascript (or Linux) is ignored."""
    script = (
        "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run"
    )
    run(["osascript", "-e", script, title, text])
