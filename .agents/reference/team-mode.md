# Reference: team mode (parallel team pipeline contract)

The contract between the team scripts (`.claude/lib/team-*.sh`), the team hooks and six
commands. Every role reads this file first. Runbook for the supervisor:
[team-pipeline.md](team-pipeline.md).

Human overview (starter repo only, not installed by `/setup:teams`): `docs/teams/03-team-pipeline.md`.
Sessions (start, liveness, screen, keys, doorbell, stop, attach hints) go through the session-host
driver, on tmux or Herdr: [session-host.md](session-host.md).

---

## 1. Detection

Team mode ⇔ `.agents/team/session.json` exists; role: `jq -r .role .agents/team/session.json`.

| Field | Meaning |
|---|---|
| `team` | team name (`alfa`, `beta`) |
| `role` | `planner` \| `coder` \| `qa` \| `wrapup` \| `cli` |
| `mode` | `brainstorm` \| `quick` \| `cli` — copied from `team.json` at launch (`team.json` may also hold `lead` while the TeamLead chooses; no stage runs then) |
| `run` | run id (`<team>-<UTC timestamp>`) |
| `attempt` | attempt number of this role in this run (1 or 2) |
| `ticket` | tracker key — `ABC-123` (jira) \| `7` (github) \| `L3` (none) |
| `cost_key` | the same ticket, project-qualified, for costs (§2a) |
| `input_rev` | revision the role starts from (previous accepted `output_rev`; planner: `base_sha`) |
| `launched_at` | UTC launch time |
| `session_id` | the role's Claude session UUID (`claude --session-id`) |
| `permission_mode` | the effective `--permission-mode` of the launch: `auto` \| `manual` (`default` when no flag was passed — an old `roles.json`) |

Written only by `team-run.sh` before a launch; removed by it when the role's record is accepted.
`stop` keeps it (it is the recovery input of the next run). The runner also sets
`TEAM_RUN_TEAM`, `TEAM_RUN_ROLE`, `TEAM_RUN_ID`, `TEAM_RUN_ATTEMPT` on its session (set by the runner at launch) — informational;
`session.json` is authoritative because hook processes are not documented to inherit the session
environment. `session.json` also carries `round` (1, or n in a rework round — team-lead.md §9).

**Second identity — the per-run TeamLead** (modes lead, brainstorm and quick; never in a cli run the
Operator fixed — in a cli run it chose, its conversation becomes the cli stage): one
lead session per run, launched by the runner before the first stage. Its identity is
`.agents/team/teamlead.json` (`run`, `session_id`, `main_root`, …) plus `TEAM_SESSION_ROLE=TeamLead`
in its session's environment; it never has a `session.json` and never writes a stage record. Contract:
[team-lead.md](team-lead.md).

## 2. State files

All under `.agents/team/` (git-ignored, local to the clone):

| Path | Written by | Content |
|---|---|---|
| `team.json` | `team-new.sh` (once) | `team, ticket, branch, line, base_ref, base_sha, mode, tracker, cost_key, origin_url, created_at` (no `mode` in an old clone = `brainstorm`; no `tracker`/`cost_key` before 2b = `jira` / `ticket`); the runner adds `mode_choice` (`by: teamlead`, reason, verdict, at, session_id, claude_config_dir) when it applies the TeamLead's mode verdict (team-lead.md §1a) |
| `ticket.json`, `ticket.md` | `team-new.sh`/`team-next.sh`, from the supervisor's `--ticket-file` | the ticket the tracker read (§2a); `jira` has neither |
| `session.json` | `team-run.sh` | §1 |
| `run` | `team-run.sh` | current run id |
| `acked` | `team-run.sh` | the last acknowledged record, relative to `runs/<run>/` (`r<n>/<record>` in a rework round): a `blocked`/`failed` stop, or with a TeamLead a gate input |
| `teamlead.*`, `round`, `verdict-acked`; `runs/<run>/teamlead-<gate>-<seq>.json`, `decisions/`, `answers.md`, `teamlead-notes.md`, `rework-<n>.md` | runner, TeamLead scripts | the per-run TeamLead's identity, verdicts, pending decisions, authority answers, notes and rework orders — team-lead.md §2, §9, §10 |
| `runs/<run>/r<n>/` | runner, roles | rework round n ≥ 2: the same record, prompt, session, notes and report names as round 1 (team-lead.md §9) |
| `<main checkout>/.agents/team/inbox/Supervisor/new/` | `team-inbox.sh` (runner, `team-verdict.sh event`) | the Supervisor's four events: `accepted`, `closed`, `collision`, `session_dead` (team-lead.md §3) |
| `lock/` (`lock/pid`) | `team-run.sh` | runner mutex |
| `cancel` | `team-run.sh stop` | stop request for a live runner |
| `roles.override.json` | `team-run.sh roles` | per-ticket model/effort override, merged over `.claude/team/roles.json` at each launch |
| `order-brief.md` | `team-brief.sh write` (Supervisor, `/start-team` step 4c) | the order: `## Ticket`, `## Not ordered`, `## In-flight work`, under a `ticket:` / `written_at:` header; per-run TeamLead only, kept by a remode |
| `archive/<ticket>-<UTC>/` | `team-next.sh` | the previous ticket's `runs/`, `run`, `acked`, `team.json`, `roles.override.json`, `ticket.json`, `ticket.md`, `order-brief.md` |
| `runs/<run>/<role>-<attempt>-<seq>.json` | `team-record.sh` | handoff record (§6) |
| `runs/<run>/<record>.accepted` | `team-run.sh` | record passed validation |
| `runs/<run>/<role>-<attempt>.prompt.md` | `team-run.sh` | rendered role prompt |
| `runs/<run>/<role>-<attempt>.session` | `team-run.sh` | role session UUID; read by `cost.py bind --team-run` |
| `runs/<run>/notes.md` | roles, `team-record.sh` | §5 |
| `runs/<run>/order-brief.md` | `team-run.sh` at TeamLead launch | the frozen copy of `order-brief.md` the per-run TeamLead reads |
| `runs/<run>/qa-report-<attempt>.md` | qa | §7 |
| `runs/<run>/pr-description.md` | qa, wrapup | PR body before publication |
| `runs/<run>/wrapup-<attempt>.md` | wrapup | `target_rev: <sha>` + the plain-Polish summary |
| `runs/<run>/cli-<attempt>.md` | cli | plain summary for the Supervisor |
| `<main checkout>/.agents/team/anchors/<team>.json` | team-new/next, team-run (main checkout only) | ticket/branch/line/base_sha, run/role/attempt/session_id, `planner` on acceptance; trusted by the classes, a differing clone `team.json` → `mismatch` (no class) |
| `runs/<run>/wrapup-state.json` | wrapup | tracker intents (`op`, `marker`, `state`, id/key) — makes retries safe (§2a) |
| `runs/<run>/attention` | `team-attention.sh` hook | one line per `Notification` |
| `runs/<run>/asks/a-<n>.json`, `a-<n>.answer.json` | the stage hook (`team-ask-hook.sh`); `team-answer.sh` (the lead) | every stop of a stage in a lead run and its one answer — the ask channel, team-lead.md §6 |
| `stage-hooks.settings.json` | `team-run.sh launch` (lead runs) | the stage's `--settings` layer: the ask hooks, materialised from `<main>/.claude/team/stage-hooks.json` |
| `runs/<run>/operator-touches` | `team-lead.sh decision answer`, the runner's dialog watch | one line per human action the run needed (team-lead.md §10) |
| `<main checkout>/.agents/touches/<yyyy-mm>.jsonl` | `touches.sh` (decision answer, the runner's dialog watch, the Notification hook, the egress guard, by hand) | one JSON line per human intervention, per project and machine ([operator-touches.md](operator-touches.md)) |
| `send-<role>.lock/` (`pid`, `owner`) | the session-host driver (`sh_send`, `sh_kill`), `team-run.sh end_session` | per-target send lock: one writer of keys into the role's pane (the doorbell, `/exit`); never reclaimed automatically (remove a stale lock once its pid is dead) |
| `send-<role>.log` | the driver, `team-run.sh` | append-only: `doorbell-skipped …`; `stop-during-send <utc> <owner>` when a stop found the lock held |

**Run audit, outside the clone.** `<main checkout>/.agents/team/audit/` holds
`<YYYYMMDD>-<team>-<ticket>-<run>.{md,json}`, `index.jsonl` (one line per run) and `*.retro.md/log`.
`team-audit.sh` writes it from the runner's EXIT trap (snapshot; `ready` makes it final) and from
`team-next.sh` (final `archived`); config `.claude/team/audit.json`. Material only: it never changes
a verdict or blocks merge/next. A flagged or sampled final run gets one detached, report-only
`/retro` over all role transcripts in its own session `helper:retro-<run>`.

## 2a. Tracker

`teams.tracker` in `.claude/project-profile.json` picks who owns the ticket:

| Tracker | Key | Ticket read by | Writes |
|---|---|---|---|
| `jira` | `ABC-123` | the role's own MCP session (no `ticket.json`) | the wrapup prompt, over MCP |
| `github` | `7` (`#7` normalized) | `team-tracker.sh read <key>` → `gh` | `team-tracker.sh` only |
| `none` | `L3`, allocated by the adapter (`.agents/team/local-ids`, `mkdir` lock) | `read --brief <text>`/`--brief-file <path>` | nothing (every op is a no-op) |

`.claude/lib/team-tracker.sh` is the **only** place the harness calls `gh`. Ops:
`read … --out <dir>` (writes `<dir>/ticket.json` + `ticket.md`, prints `key=<k> type=<t>`, `type`
a `teams.branch_types` entry — the first synonym of the label's kind, else the first entry and a
`warning:` — and `title=<t>`), `comment`, `set-status <key> started|delivered`, `create-followup`. Writes are idempotent by a marker on the body's
**last** line, matched over a full enumeration. Exit codes: 0 ok · 1 ticket unusable · 2
usage/profile · 3 `tracker=jira` · 4 recoverable (permissions, no project item, unknown logical
status, failed or partial enumeration) — never the conclusion "not there".

`/start-team` reads the ticket into `<main checkout>/.agents/team/incoming/<TEAM>/` and hands it to
`team-new.sh`/`team-next.sh` as `--ticket-file`; those copy both files into the clone. "Never Done"
is the runner's: `team-validate.sh` rejects a `done` wrapup record whose `github` intents
(`comment`, `set-status delivered`, any accepted follow-up) are not all `done`, or whose
`wrapup-state.json` `target` (`{run, ticket, repo, project_id}`, written before any external op) is
not this run's — so a previous run's or another ticket's finished state cannot carry a run to Done.

**Single writer of tracker intents: the wrapup role.** Every other role only reads the tracker. No
new lock is needed, because the runner already serialises roles: `team-run.sh:296` takes the per-team
runner lock (`$TD/lock`, `mkdir` + pid; removed only by its own pid at `team-run.sh:416`), so a
second runner for the same team refuses to start; inside it `cmd_advance` launches exactly one role
per iteration (`team-run.sh:312`) and `check_orphans` (defined `team-run.sh:286-291`, called at
`team-run.sh:304` and `:306`) aborts with `die 7 "orphan session …"` when any other role's session
is still alive. One runner × one live role = one wrapup = one writer, and that is what
makes the adapter's read-then-create idempotent. The single exception is the start's claim
(`/start-team` step 3b, `/start-task` step 6b, `team-claim.sh`): a claim comment and the `started`
move, writing no intent; a failure stops the start before any clone or branch, and a start failing
after it releases the claim (team-pipeline.md → Claim at the start). Costs bind to
`cost_key` — `<owner>/<repo>#<n>` · `<repo-dir>:L<n>` · the key itself — so the same short key in
two projects stays two bindings. At wrapup the adapter runs **inside the clone** and reads its
**committed** profile: the github block (`teams.github`, else the top-level `github`) must be on the
branch's base and equal to the supervisor's, or the start is refused.

## 3. Roles

| Role | Questions | Memory | Material decision | End |
|---|---|---|---|---|
| planner | asked normally — with a per-run TeamLead the lead answers through the ask channel, without one the developer in the window (attended); `/brainstorm` approves the spec itself (`Approved (auto — team mode)`) with or without a TeamLead; with a per-run TeamLead its `done` waits for the plan gate (team-lead.md §4) | → notes `## Learnings` | asked normally | `/commit` spec+plan, `team-record --verdict done` |
| coder | with a per-run TeamLead: may ask, the lead answers (ask channel); without one never — `--disallowedTools AskUserQuestion` | → notes | `team-record --verdict blocked`, stay idle | draft PR via `team-pr.sh create --draft`, `team-record --verdict done --pr <id>` |
| qa | with a per-run TeamLead: may ask, the lead answers (ask channel); without one never — `--disallowedTools AskUserQuestion` | → notes | `team-record --verdict blocked`, stay idle | QA report, PR description, publish, `team-record --verdict done` |
| wrapup | asked normally (attended), only when it has recommendations; with a per-run TeamLead never — a proposals stop instead | writes `.agents/memory/**` after acceptance per team-decision-model.md §3 (TeamLead or Advisor; with a per-run TeamLead the wrapup asks nothing: it stops with a proposals file and the lead decides every item, team-lead.md §10); also `docs/coding-standards.md`, only an accepted standards item, via `team-standards.sh add` | asked normally | summary (Jira comment + PR `## Wrap-up`), accepted memory commit, `team-record --verdict done --pr <id>` |
| cli (the TeamLead's cli path: its resumed conversation when it chose cli, a fresh session when the Operator fixed it) | never — `--disallowedTools AskUserQuestion`; a stop goes to the Operator | → notes, copied into the PR (no wrapup) | `team-record --verdict blocked` (also on an eligibility-guard hit), stay idle | published PR via `team-pr.sh create --ready`, `team-record --verdict done --pr <id>` |

'Asked normally (attended)' means, with a per-run TeamLead, that the run's lead answers on an
authority ([team-lead.md](team-lead.md) §6; the wrapup's proposals §10) and only human-only items reach
the Operator as pending decisions.

**Questions in a lead run.** Every stage stop — an `AskUserQuestion` with one or several questions,
a plan approval, a permission prompt of the stage or a sub-agent, a blocked record, a plain-text
stop — is filed by the stage hook as an ask and answered by the run's TeamLead (team-lead.md §6);
`guard-team-question.sh` is a no-op kept for its settings entry. Mode cli and a run without a lead
keep `--disallowedTools AskUserQuestion` for coder, qa and cli.

No role exits its session — the runner ends it after accepting the record. Each role runs with the
`--model` / `--effort` / `--permission-mode` set for it in `.claude/team/roles.json` (the shipped
default), then by the project profile's optional `teams.roles.<role>` (same fields, committed), then
per ticket by `.agents/team/roles.override.json` (entry `<role>=[<model>][/<effort>][/<permission>]`).
The cli role has no `roles.json` entry: it runs on the TeamLead's model and effort
(`teams.sessions.TeamLead`, default `fable` / `medium`); `teams.roles.cli` and the override set only
its permission (`cli=//<auto|manual>` — a `cli=` model or effort is refused, a leftover one in a file
is ignored with a `warn:`); in mode cli the override takes only `cli=…` entries.

**Permission mode.** `permission` ∈ `auto|manual` only; `roles.json` sets `auto` for every
role, the cli role defaults to `auto` (`TEAM_CLI_PERMISSION`). `/start-team … --permission-mode manual` writes `coder=//manual qa=//manual` (cli:
`cli=//manual`; mode lead: `coder=//manual qa=//manual cli=//manual`) — mandatory for tickets editing `.claude/settings*.json` (the classifier
refuses that as self-modification). `auto` is honoured only when the clone has the
`guard-team-egress` hook (both files, registered under `WebFetch` and `Bash` with `"onFailure":
"block"` — `/setup:teams` (`team-setup.sh`) registers both; the template's shared settings do not) and `claude --version` ≥ 2.1.295; otherwise the runner launches `manual`, prints `warn:
<role> launches in manual mode — <why>` and records `permission_mode: "manual"`.

**Modes.** `team.json` `mode`, written per ticket by `team-new.sh` / `team-next.sh`, decides the
stages. The default is `lead`: the run's TeamLead chooses the mode before any stage (team-lead.md
§1a); the Operator fixes one with `/start-team --mode`. `brainstorm` runs planner → coder → qa →
wrapup; `quick` runs planner → coder → qa (a quick clone whose `qa.md` predates #296 keeps its
wrapup); `cli` runs one `cli` role alone. A `quick` planner runs `/quick-change` Phases 0–2 and
commits only a Codex-reviewed plan — no spec (`planner-quick.md`). The `cli` role runs on the
TeamLead's model and effort, ignoring `roles.json` and any model/effort override; it guards
eligibility, changes, gates, runs `/codex-review`, commits, pushes and publishes its own PR. The
runner refuses a record from a role the mode does not run.

Base role keys follow the main checkout's schema; override keys follow the clone's runnable roles.
Both configurations allow only known role keys and `model`/`effort` string fields. Effort must be
`low`, `medium`, `high`, `xhigh`, or `max`; model names retain the safe-token format. Invalid launch
configuration is rejected before an attempt is recorded. `roles` validates the merged candidate
once, so overwriting a bad value may repair an override; remaining invalid data requires a fix or
`roles --clear`. Input refusals preserve the old file and send no stopped notification. `status`
shows invalid overrides as `invalid — <message>`.

## 4. Decision policy

**Material — never guessed.** The coder/qa writes a `blocked` record with the question and waits:

- changing scope or acceptance criteria;
- changing a public contract (route, DTO, byte enum, a transport endpoint, a queue message);
- a schema migration the plan does not name;
- a deviation from the plan beyond file-level placement;
- a `fundamental` review finding;
- a gate escalation;

**Routine — everything else.** Decide, then log it under `## Unattended decisions`.

**Auto mode: what still prompts.** In auto mode the classifier approves ordinary commands (reads,
builds, tests) without a prompt. Only `ask`-tier rules, team egress (the PreToolUse hook
`guard-team-egress`, best-effort: a `WebFetch` host outside the allowlist, an egress-capable verb in
command position, a network `git` command to an unlisted host — list in `security-egress.md`; a
loopback `nc -z` is not) and other forced prompts appear. A
**classifier denial** is a material question: coder/qa/cli write `blocked`, planner/wrapup ask,
nobody works around it — never turn a denial into an alternative spelling of the same action.

**Permission prompts are the human gate, not a blocker.** Operations on production or Azure
DevOps (deploy, release creation, App Service config, branch lock, policy change) are `ask`-tier:
nothing a ticket legitimately needs is `deny`, and every such command waits for approval. Merging
to the line triggers no deploy and stays the supervisor's `/pr-merge`. The
session shows a permission prompt, the `Notification` hook flags it, the runner prints
`needs attention`, and the developer approves or rejects in that session's window (`session-host.sh hint <team>-<role>`) — in a lead run the prompt is an ask of tier `operator` instead, answered through the lead's decision (team-lead.md §6–§7). Keep waiting; never write a
`blocked` record for a prompt and never work around a rejected one — a rejection is a material
question (`blocked`). Secrets stay `deny` for every role: read setting **names** only
(`--query "[].name"`), never values, keys or connection strings.

**Routing with a per-run TeamLead:** stage → the run's TeamLead → Operator. Every stop of a stage
(a question, a plan approval, a permission prompt, a blocked record, a plain-text stop) is filed by
the stage hook as an ask and rung to the lead; the runner rings gates. The stage hook answers a
class-tier permission itself; the lead answers an ask at `teamlead` and opens a pending decision
for an operator-tier ask (allow or deny), which notifies the Operator once — the Operator answers
in the lead's window, never in a stage's
([team-decision-model.md](team-decision-model.md) §3, [team-lead.md](team-lead.md) §6–§7). The roles'
behaviour below is the same.

## 5. Notes

`.agents/team/runs/<run>/notes.md`, append-only, these four sections:

```markdown
## Unattended decisions
- <decision> — <reason> — <file>

## Learnings
- <lesson> — <where it bit>

## Follow-ups
- [<role> <attempt>] <noticed but not done> — <where>

## Blockers
- [<role> <attempt>] <question>
```

`## Learnings` replaces every memory write a command would make (reflection, `patterns.md` rule,
grill memory update). The `wrapup` role reconciles them into `.agents/memory/` in the team's PR
after acceptance per team-decision-model.md §3 — the only role `guard-team-memory.sh` lets write
there. Every role puts what it noticed but did not do under `## Follow-ups`; wrapup turns the
worthwhile ones into tickets. `team-record.sh` creates the file with the four headings when absent and appends
`## Blockers`.
A github or jira follow-up ticket's body ends with the line `Follow-up of <ticket> · origin <origin>`;
the third follow-up of one origin waits for the Operator's consent (a terminal, or the phrase
`consent <ticket>` typed in the Supervisor window) before `/start-team` starts it (`team-lineage.sh`;
`.agents/reference/roles/supervisor.md` → Follow-up chains).

Wrapup follow-up tickets: fetch the run ticket's parent, then verify that parent's issue type is
`Epic`; an ordinary Task is never a parent substitute. If no valid Epic exists, ask for and
verify one in wrapup step 7 before offering the ticket for acceptance. Save the complete field
table, description, parent, queued files/defaults, marker and acceptance under a stable create
intent id in run-scoped `wrapup-state.json`; copy the draft to `wrapup-<attempt>.md` for reporting.
Show the complete draft once before the selection question. Each ticket choice shows its title
and parent Epic key/summary (including
the question text for one or more than four recommendations). Selection accepts that exact
draft and its listed uploads and assignee/active-sprint defaults.
TeamLead makes this wrapup selection by default; the developer may make it in the window;
either counts as acceptance. A memory entry for `decisions.md`, `patterns.md` or `index.md` is the
Advisor+Reviewer class and is asked as its own question (`prompts/wrapup.md` step 7), unless it
comes as a hand-off with a ref the wrapup can check (step 6). Each created
ticket carries the recommendation line and, only when the profile sets them, the labels of
`teams.policy.tickets` (team-decision-model.md §3 → Tickets from recommendations). On another attempt reuse accepted drafts, markers and ids verbatim, never
regenerate or renumber them. Only new/unaccepted recommendations return to selection; finish
saved accepted operations even if there are no new recommendations.

For `.agents/team/session.json` with `role: "wrapup"`, this acceptance replaces `/jira create`'s
`y`: no second dry-run or `Tworzę? [y/n/edit]`. Other Jira contexts retain their full confirmation;
changed drafts return to step 7. Required fields, preflight and parent verification still apply.
Every write has a pending intent in `wrapup-state.json`: create/comment use the textual marker;
search results are candidates, confirmed read-only by the exact final marker line in the fetched
description/comment before marking done;
assign/sprint/upload use separate issue-key/expected-result intents recovered by read-only issue
inspection. Unknown outcomes block instead of blindly retrying; a done create is never repeated
to finish its post-create operations. Assignee and the currently active sprint come from
`.agents/memory/domain/jira.md`; never hardcode the sprint or choose a future one.

## 6. Record

`bash .claude/lib/team-record.sh --verdict done|blocked|failed [--artifacts a,b] [--pr <id>]
[--evidence a,b] [--message "<one line>"]` → prints the path it wrote.

```json
{ "team": "alfa", "ticket": "ABC-790", "run": "alfa-20261002-091500", "role": "coder",
  "attempt": 1, "seq": 1, "branch": "feature/ABC-790-x", "input_rev": "<sha>",
  "output_rev": "<HEAD>", "verdict": "done", "pr_id": 8371,
  "artifacts": [".agents/plans/done/x.md"], "evidence": [],
  "notes": ".agents/team/runs/<run>/notes.md", "message": "", "written_at": "<UTC>" }
```

- `done` — the role's work is committed (tree clean, `HEAD` = `output_rev`) and, for coder/qa,
  pushed. The runner validates it against git and ADO. A cli `done` is pushed with its PR
  **published** (`isDraft false`) and carries no plan artifact. With a TeamLead the planner's
  `done` waits for the plan gate before validation (team-lead.md §4).
- `blocked` — a material question; `--message` required. **Stay idle in the session — do not
  exit.** The supervisor attaches and answers; continue, then write a new record.
- `failed` — the role cannot finish (e.g. empty QA delta); `--message` required.

**wrapup `done`:** `--pr` = the coder's PR; `output_rev` is the QA revision or a memory-only commit
on top of it (`git diff --name-only <qa rev> <output_rev>` lists only `.agents/memory/**`, plus
`docs/coding-standards.md` changed by exactly the TeamLead's accepted standards item — the runner
re-renders it and compares bytes);
`runs/<run>/wrapup-<attempt>.md` exists with a `target_rev:` line. `team-merge-check` then expects
the PR source to be this revision and refuses a memory overlap with the target line unless rerun
with `--memory-reviewed`.

Each call writes a new `<seq>`; nothing is overwritten. Every record carries `round` (from
`session.json`); a rework round n ≥ 2 writes into `runs/<run>/r<n>/` (team-lead.md §9).

## 7. QA report

`.agents/team/runs/<run>/qa-report-<attempt>.md` — machine-checked by the runner, one fact per line,
exact keys:

```
run: <run>
attempt: <n>
output_rev: <sha>
Verdict: ready | ready-with-warnings | escalated
Gate code: <outcome>[ — <reason>]
Gate design: <outcome>[ — <reason>]
Gate cross-model: <outcome>[ — <reason>]
Gate final-build: <outcome>[ — <reason>]
Tests: passed=<n> failed=<n> skipped=<n> baseline=<n>
AC: total=<n> met=<n> unconfirmed=<n> deferred=<n>
Warnings: none | <list>
Rethink signals: none | <list>
```

`<outcome>` ∈ `passed|warn|skipped|substituted|not-verified`; a reason (` — <reason>`) is required
for the last three. `Gate final-build` is the clean-tree `teams.build_check` + test gate rerun;
anything but `passed` means no publication. `Tests: passed=0` is accepted only when the main
checkout's `teams.test_gate` is `none`. `Verdict: escalated` or any rethink signal means a `blocked`
record, not `done`. Free text may follow; it records `Load: start … end … (waited …s)` per gate run.

**Acceptance criteria — the optional `AC:` line.** QA writes it from the `Acceptance criteria:`
status of `/check-implementation`'s final report and the last gate pass's `### Acceptance Criteria`
block (`/gates:verify-implementation` §6). It counts the active criteria and has no `unmet` count:
an `unmet` row, like an `unconfirmed` one with effect `BLOCK`, stays in QA's fix loop and never
reaches a `done` record. Each `unconfirmed` criterion is one `Warnings:` item `AC <id> unconfirmed`
(the id only — the line is split at every comma), and `unconfirmed > 0` requires
`Verdict: ready-with-warnings`; with no `unconfirmed` criterion the verdict stays what the other
gates made it. A `deferred` criterion is no warning. The line is absent on an escalated attempt
(`Verdict: escalated` — that rule wins over every other here, and covers an attempt a rethink
signal sends to a `blocked` record, which keeps the verdict the gates made), when the gate printed
no ledger (a clone on an older base: the runner's validator comes from the main checkout, the QA
prompt and the gate from the clone), and when the status is `n/a (…)` or `not evaluated — …` (on
an attempt QA publishes, the latter adds the `Warnings:` item `AC not evaluated` and sets
`Verdict: ready-with-warnings`). When it is present,
`team-validate.sh` refuses a second `AC:` line, a line off this shape, a count longer than 9
digits once its leading zeros are dropped, counts whose `met + unconfirmed + deferred` is not
`total`, and `unconfirmed > 0` unless the report's first `Verdict:` line — the one the acceptance
gate reads — is `ready-with-warnings`; it does not cross-check the `Warnings:` items.

The complete ledger follows the keyed lines as free text, opened by the line
`Acceptance criteria ledger:` — the gate's completeness notice verbatim when it printed one, then
one line per active criterion in the gate's order, `- <id> — <verdict> — <criterion text> —
<evidence>`. The criterion text comes from the plan by id; a gate-numbered duplicate `<id> (k)`
takes the k-th active criterion with that id in plan order and keeps its decorated id in the
ledger, `Warnings:` and the PR. A `deferred` row ends `manual check:
<the plan's what-and-where, or its Proof: none reason>`; on a plan without `Proof:` lines,
`manual check: no procedure in the plan — <the gate's evidence>`. Every ledger line starts with
`- `, so none reads as a keyed line. An escalated attempt copies the final gate pass's rows
verbatim with their effect; when that pass stopped before §6 it copies the final
`not evaluated — …` status instead, never an earlier pass's rows.

## 8. What team mode changes per command

| Command | Team mode |
|---|---|
| `/brainstorm` | Step 8.8 rule → notes `## Learnings`, not `patterns.md`; Step 9 approves the spec itself (`Approved (auto — team mode)`) unless a rethink signal and continues in the same turn |
| `/plan-feature` | grill memory update and Step 7.9 → notes `## Learnings` |
| `/execute` | Step 7 skipped (→ notes); routine deviation → `## Unattended decisions`; each `red before green: <test> — yes \| n/a — <why>` line → `## Unattended decisions`; material → `TEAM-BLOCKED: <question>` before `/commit` |
| `/check-implementation` | base from `team.json` `base_sha` for qa (`--base`); Step 2 → notes; Step 3 never asks; a finder `FALLBACK` line → `Warnings:` (§7) and the PR's `## QA`, verbatim; its `Acceptance criteria` status and ledger → the `AC:` line, the `AC <id> unconfirmed` items of `Warnings:` and the ledger (§7) |
| `/commit` | Step 9 memory checkpoint skipped |
| `/quick-change` | quick planner: Phases 0–2, then the plan file, no code |
| `/pr-create` | not used by the team roles — Step 7a stops in team mode; the coder (draft) and cli (published) create the PR with `team-pr.sh create` against `team.json` `line` on both providers (§8a) |

## 8a. PR provider

`teams.pr_provider` (`azure-devops` | `github` | `none`) selects the PR layer; `none` turns it off, and
team runs, PRs and merges refuse with a message naming the setting. ADO keeps `az` in `team-lib.sh`;
github goes only through `.claude/lib/team-pr.sh` (needs `gh`, `teams.github.repo` — or the top-level
`github.repo` when `teams.github` is absent — and `origin` matching it).

- `team-pr.sh` ops: `coords`, `state`, `identity`, `readiness`, `create --draft|--ready`, `publish`,
  `body-get`, `body-set`. Exit: 0 ok · 2 usage/profile/provider · 3 refusal · 4 recoverable (network,
  merge ref not ready). It never merges and never forces. With `azure-devops` only `create` and
  `publish` exist (`team-pr-ado.sh`: the same before/after lookup, draft rules, a body ≤ 4000
  characters); state and validation stay on the `team-lib.sh` helpers.
- Prompt blocks per provider: `.claude/team/pr/<provider>-<block>.md`.
- Merge (github): the supervisor runs `team-merge-check.sh <TEAM>` (holds the team runner lock, writes
  `.agents/team/merge-check.json`: target/merge/source SHAs, `records_digest`), asks the Operator, then
  `team-integrate.sh <TEAM> [--base <line>]`. Merge (ADO): `/pr-merge <id>` as before.
- A merge ref GitHub has not rebuilt since the line moved (`readiness` → `stale-base`) is not
  waited out. Eligibility builds `M = merge(T, S)` in the clone (`refs/team-pr/<pr>/local-merge`,
  reused while its parents are still T and S), the gates run on it, and integrate pushes that sha.
  It refuses a conflict on the current base, and a union-merged memory log changed on both sides
  (the provider would report it as conflicting; `team-pipeline.md` → PR conflicting in memory files).
- `team-integrate.sh` steps: lock the base (`team-integrate-lock.sh`, shared with the solo worker) ->
  recover an earlier intent read-only -> read `merge-check.json` -> base still the validated target ->
  re-check eligibility -> write the intent (`<main root>/.agents/team/integrate/<team>-<run>.json`) ->
  plain non-force push of the tested merge commit M -> verify base == M and PR `MERGED` ->
  delete the team's remote branch (only at the validated S, never a long-lived branch or another
  open PR's head; one line, never changes the exit).
  Exit: 0 integrated · 2 usage/ADO · 3 refused, no effect · 4 partial/unknown effect (inspect the
  intent, then rerun: recovery is state-dependent).
- Integration contract: after a successful push the base equals the tested M. This is weaker than a
  CAS T -> M (the window between the last `ls-remote` and the push), and consciously accepted.
- Branch protection that rejects the push -> rc 4, stop. There is no `gh pr merge` fallback and no
  admin override; the Operator decides.
- The ticket status `Merged` is set by the supervisor by hand after the `integrated:` line.

## 9. Never in team mode

- write `.agents/memory/` — except the `wrapup` role after acceptance per team-decision-model.md §3
  (the hook `guard-team-memory.sh` enforces both); the same holds for `docs/coding-standards.md`,
  which the wrapup writes only through `team-standards.sh add` for an accepted standards item;
- start the app — runtime smoke reports `SKIPPED`;
- merge a PR (`/pr-merge` or `team-integrate.sh` is the supervisor's) or run the trunk writers `team-merge-check.sh`, `team-integrate.sh`, `team-integrate-lock.sh` or `team-automerge-check.sh` — `guard-team-verdict.sh` refuses them in a role session, whatever `workflow.team_merge` says;
- push to a protected branch;
- delete the clone or `.agents/team/`.
