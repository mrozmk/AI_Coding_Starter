# 03 — Team pipeline: clones, runner, roles, records, merge

**Contract:**
- [`team-mode.md`](../../.agents/reference/team-mode.md): detection, state files, roles, decision policy, notes, records, the QA report.
- [`team-pipeline.md`](../../.agents/reference/team-pipeline.md): the runbook — setup, provisioning, run, exit codes, merge, dashboard, gate lock.

## The shape

Each **team** is a permanent git clone of the project, a workstation reused ticket after ticket. Where clones live and what they are called is configuration: `teams.clone_parent`, and `teams.clone_name` (default `<repo dir>-{team}`, next to the main checkout).

Clones are used rather than worktrees because each team needs its own `.claude/`, `.agents/`, build output and a copy of the Operator's `settings.local.json`. The roles of one ticket run **one after another in the same clone**, and two teams never share a working tree.

A ticket runs in one of three modes, fixed when the team is provisioned (`/start-team <team> <KEY> --mode …`):

| Mode | Stages | For |
|---|---|---|
| `brainstorm` (default) | planner (`/brainstorm` → `/plan-feature`), coder (`/execute`), qa (`/check-implementation` + gates), wrapup | typical tickets |
| `quick` | planner runs `/quick-change` and commits a short reviewed plan, then the same coder → qa → wrapup | small, clear changes |
| `cli` | one unattended session that checks eligibility, changes, runs the gates and publishes the PR itself | very simple changes |

A quick ticket whose planner finds it too big is restarted in `brainstorm` mode by the Supervisor (`team-remode.sh`). The branch, base and notes are kept.

## The runner

`team-run.sh <team>` runs in its own tmux session because it blocks for hours. It:

- launches each role as a fresh Claude session;
- watches the role's **record**;
- validates a `done` against git and the PR host;
- advances the stage;
- ends the session.

Its exit codes are the vocabulary of everything above it, and [`team-pipeline.md` §5](../../.agents/reference/team-pipeline.md#5-exit-codes) says what to do for each. `blocked` (2) means a role is waiting for an answer. `stalled` (3) means no progress within the stage's budget. A dead session with partial work (5) is always a human's call.

Roles never exit their own session and never ask more than one question per call (a hook enforces it). Material decisions are never guessed: changing scope or AC, a public contract, an unplanned schema change, or a deviation from the plan beyond file placement. The coder, qa and cli roles write a `blocked` record and wait. Routine choices are decided and logged in the run's notes.

**Auto mode.** Roles run with `--permission-mode auto`: the classifier approves ordinary reads, builds and tests. What still prompts is ask-tier rules, team egress (the `guard-team-egress` hook) and settings edits. Tickets that edit `.claude/settings*.json` must run in manual mode. A classifier denial is a material question, never a reason to retry the same action under another spelling.

## Records and notes

Every hand-off is a JSON **record** (`team-record.sh --verdict done|blocked|failed`) with the input and output revision, the PR, artefacts and evidence. Nothing is overwritten: each call writes a new sequence number.

The run's `notes.md` is append-only and has five sections:
- *Unattended decisions*;
- *Learnings*, which replace every memory write a command would make;
- *Follow-ups*;
- *Supervised decisions*, written only by the question ledger;
- *Blockers*.

Memory is written only by the wrapup role, after acceptance, inside the team's PR.

## Merge

`team-merge-check.sh <team>` is the gate. It checks:
- the wrapup finished;
- the PR's source is the wrapup revision;
- after QA, only memory files changed;
- no memory file the wrapup touched also changed on the line;
- the host's merge is current.

It then builds and runs the project's test gate on the merge ref. It holds the **machine gate lock**: one build gate at a time across every clone on the machine, by design. A wait is visible and bounded at 30 minutes.

**Auto-merge.** After a READY, the Supervisor runs `team-automerge-check.sh <team>`. It refuses when:
- a release freeze is set (`.agents/team/release-freeze`);
- the QA record is not accepted;
- the QA report lacks `Verdict: ready|ready-with-warnings` or `Gate final-build: passed`;
- the merge check failed;
- the PR changes settings beyond added offline allow entries.

`AUTOMERGE: yes` → `/pr-merge <id> --auto <team>`, which re-checks immediately before completing. `AUTOMERGE: no — <reason>` → the Operator decides, with the reason.

**Freeze.** Set before a release and cleared after its post-check, never cleared without the Operator. While it is on, nothing merges.

## Choosing tickets

Run two teams at once only on disjoint code tickets: different files, no migration in both, no runtime needed. The merge check catches textual and build-level breakage only. Run operations tickets one at a time. Permissions come from the project's `settings.json` plus the Operator's `settings.local.json`, copied into each clone when it is provisioned, so change the local file before provisioning.
