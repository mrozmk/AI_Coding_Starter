---
description: Start, restore, stop or show the project's role sessions (Supervisor, Advisors, project roles) — idempotent; after a crash or reboot too
argument-hint: "[up]|status|stop [<Role>|all]|here <Role>"
allowed-tools: Bash(bash .claude/lib/roles.sh:*)
---

# /roles — the project's role sessions

Run, from the main checkout:

```bash
bash .claude/lib/roles.sh $ARGUMENTS
```

Print its output verbatim and stop. Do not retry, do not start or stop anything else, and do not
answer a dialog in a role's window (a folder trust dialog is the Operator's to accept).

- No argument (`up`): every standing role in `teams.sessions` that is not running is started; a
  running one is left alone. One line per role, then how to look at each.
- `here <Role>` is refused inside Claude Code: it prints the line to run in a new terminal.
- The roles, their CLI, model, contract and place: `teams.sessions` in
  `.claude/project-profile.json`; the contracts: `.agents/reference/roles/`.
