# 03 — Team pipeline: clones, runner, roles, records, merge

**Contract:**
- [`team-mode.md`](../../.agents/reference/team-mode.md): detection, state files, roles, decision policy, notes, records, the QA report.
- [`team-pipeline.md`](../../.agents/reference/team-pipeline.md): the runbook — setup, provisioning, run, exit codes, merge, team snapshot, gate lock.

## The shape

Each **team** is a permanent git clone of the project, a workstation reused ticket after ticket. Where clones live and what they are called is configuration: `teams.clone_parent`, and `teams.clone_name` (default `<repo dir>-{team}`, next to the main checkout).

Before a clone takes a new ticket, the start claims the ticket in the tracker: a check (closed, already started, an open PR or a remote branch for its key, another holder), a claim comment, and a confirm — the first claim wins and only the winner moves the status. A second machine or team starting the same ticket is refused with the holder's team and machine, and a start that fails before the clone names the ticket gives it back. Details: [`team-pipeline.md` → Claim at the start](../../.agents/reference/team-pipeline.md#claim-at-the-start).

Clones are used rather than worktrees because a worktree shares one git database with the main checkout — branches, stash, config, hooks and `.git/info/exclude` — and a clone has its own:

- **Blast radius.** Roles work unattended. In a worktree a wrong `git branch -D`, `git stash` or `git gc` hits every team and the Operator's checkout; in a clone it stays in the clone, and the only way out is a push and a PR, where the gates stand.
- **The trunk.** One branch can be checked out in one worktree only, so team scripts that switch to and merge the trunk would not work as they are.
- **Per-clone files.** `project-profile.json` and `harness-version.json` are kept out of git through `.git/info/exclude`, which worktrees share.
- **Same path as a developer.** Branch, push, PR, merge — and the clone may live on another machine.

A worktree would save disk and a few seconds at provisioning, nothing else: the folder trust dialog, the copy of the Operator's `settings.local.json` and the build output are per directory either way. The roles of one ticket run **one after another in the same clone**, and two teams never share a working tree.

A ticket runs in one of three modes. Without `--mode` the run's TeamLead chooses it before any stage (rules: [`team-lead.md` → Mode choice](../../.agents/reference/team-lead.md)); the Operator fixes one with `/start-team <team> <KEY> --mode …`:

| Mode | Stages | For |
|---|---|---|
| `brainstorm` | planner (`/brainstorm` → `/plan-feature`), coder (`/execute`), qa (`/check-implementation` + gates), wrapup | typical tickets |
| `quick` | planner runs `/quick-change` and commits a short reviewed plan, then the same coder → qa (no wrapup; the ticket moves on merge) | small, clear changes |
| `cli` | the TeamLead itself, in its own conversation (on its model): checks eligibility, changes, runs the gates and `/codex-review`, publishes the PR | very simple changes |

A quick ticket whose planner finds it too big is restarted in `brainstorm` mode by the Supervisor (`team-remode.sh`). The branch, base and notes are kept.

## The runner

`team-run.sh <team>` runs in its own session (tmux or Herdr, through the session-host driver) because it blocks for hours. It:

- launches each role as a fresh Claude session;
- watches the role's **record**;
- validates a `done` against git and the PR host;
- advances the stage;
- ends the session.

Its exit codes are the vocabulary of everything above it, and [`team-pipeline.md` §5](../../.agents/reference/team-pipeline.md#5-exit-codes) says what to do for each. `blocked` (2) means a role is waiting for an answer. `stalled` (3) means no progress within the stage's budget. A dead session with partial work (5) is always a human's call.

Roles never exit their own session. In a run with a per-run TeamLead every stop of a stage — a question (several in one call are fine), a plan approval, a permission prompt, a blocked record, a plain-text stop — is handed by a Claude Code hook to the run's ask channel and answered by the TeamLead; nothing reads a screen or types into a stage. Material decisions are never guessed: changing scope or AC, a public contract, an unplanned schema change, or a deviation from the plan beyond file placement. The coder, qa and cli roles write a `blocked` record and wait. Routine choices are decided and logged in the run's notes.

**Auto mode.** Roles run with `--permission-mode auto`: the classifier approves ordinary reads, builds and tests. What still prompts is ask-tier rules, team egress (the `guard-team-egress` hook) and settings edits. Tickets that edit `.claude/settings*.json` must run in manual mode. A classifier denial is a material question, never a reason to retry the same action under another spelling.

## Per-run TeamLead (pilot)

In every mode except a cli the Operator fixed with `--mode cli` the runner launches a TeamLead before the first stage (a cli the TeamLead chose resumes its conversation as the worker) and waits in place on a stop instead of exiting. It gates the plan against the order (there is no spec gate: the planner approves its own spec), accepts the qa result against the order brief, and may order **rework rounds**. A round n ≥ 2 keeps its records in `runs/<run>/r<n>/` and continues on the same branch and PR. The runner exits 8 when the lead closes a run without merge. The Supervisor reads four inbox events (`accepted`, `closed`, `collision`, `session_dead`) — [`team-pipeline.md` §5a](../../.agents/reference/team-pipeline.md). Contract: [`team-lead.md`](../../.agents/reference/team-lead.md).

## Records and notes

Every hand-off is a JSON **record** (`team-record.sh --verdict done|blocked|failed`) with the input and output revision, the PR, artefacts and evidence. Nothing is overwritten: each call writes a new sequence number.

The run's `notes.md` is append-only and has four sections:
- *Unattended decisions*;
- *Learnings*, which replace every memory write a command would make;
- *Follow-ups*;
- *Blockers*.

The TeamLead's answers to a role's prompts land in `runs/<run>/answers.md`, not in the notes.

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
