---
description: Start, restore, stop or show the project's role sessions (Supervisor, Advisors, project roles) — idempotent; after a crash or reboot too, then asks which interrupted team runs to resume
argument-hint: "[up]|status|stop [<Role>|all]|here <Role>|resume <Role>|runs"
allowed-tools: Bash(bash .claude/lib/roles.sh:*), AskUserQuestion
---

# /roles — the project's role sessions

1. Run, from the main checkout:

   ```bash
   bash .claude/lib/roles.sh $ARGUMENTS
   ```

   Print its output verbatim. Do not retry, do not start or stop anything else, and do not answer a
   dialog in a role's window (a folder trust dialog is the Operator's to accept).

2. **Only when `$ARGUMENTS` is empty or `up`:** run `bash .claude/lib/roles.sh runs --json`. It
   prints a JSON array of interrupted team runs, oldest first, each `{team, run, stage, state,
   clone, resume}`.
   - `[]` → stop; ask nothing.
   - Otherwise ask **one** `AskUserQuestion`:
     - `multiSelect: true`, header `Resume runs`;
     - question `Which interrupted team runs should be resumed?`;
     - one option per run, label `<team>`, description `<run>, stage <stage>` plus `, <state>` when
       the state is not `open` (`blocked`: it waits for an answer; `failed`: it needs a fix);
     - leave every option unselected.
   - At most 4 options: ask about the first 4. Print each further run as `more interrupted runs:
     resume them with /start-team <team>`, one line per team; never drop one silently.
   - For each chosen team, in order, follow `/start-team <team>` (its RESUME path, which checks the
     lock and relaunches the runner and the TeamLead).
   - **Never resume a run that was not chosen. With no answer, resume nothing.**

- The script never asks and never calls `/start-team`; only this command asks.
- `here <Role>` is refused inside Claude Code: it prints the line to run in a new terminal.
- The ad-hoc lines (`ad-hoc sessions (gone):`) are for the Operator to paste; never run them.
- The roles, their CLI, model, contract and place: `teams.sessions` in
  `.claude/project-profile.json`; the contracts: `.agents/reference/roles/`.
