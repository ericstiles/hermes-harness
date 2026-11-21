# Project-Specific Agent Rules

`AGENTS.md` holds the general workflow and is identical in every repository
that uses the Hermes harness (`hermes-setup` copies it; do not edit it here).
This file holds the rules and facts that only apply to this repository. Where
the two conflict, this file wins. `hermes-setup` creates this file once and
never changes it again.

## Environment

- Stack: <language and version, package manager>
- Virtualenv / toolchain: <e.g. `.venv/bin/python`; the system interpreter lacks the deps>
- Secrets and host-specific values come from the untracked `.envrc.local`; never
  commit them.

## Quality gate

Must pass before every commit:

```bash
<e.g. ruff check . && ruff format --check . && pytest -q>
```

## Conventions

- <repository-specific rules: layout, naming, migrations, dependencies>
