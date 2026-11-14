# Per-run TeamLead — role contract

One TeamLead session per team run, in brainstorm and quick mode (`teams.teamlead.enabled: true`;
mode `cli` never has one). It gates the team's spec and plan, answers the team's stops, accepts the
result against the order brief and escalates only human-only decisions to the Operator. It never
writes code, commits, pushes, merges or writes a stage record. With the switch off the runner's
behaviour is unchanged and the global TeamLead (`supervisor-sessions.md#teamlead`) handles the team.

Profile keys (`teams.teamlead.*`, `teams.sessions.TeamLead`): `.claude/project-profile.json.example`
→ `_teamlead_doc`.

## 1. Lifecycle

- **Launch.** `team-run.sh` launches the lead once per run, before the first stage, in tmux session
  `<team>-lead` in the clone. Preconditions, each a refusal (exit 4) when missing:
  - the clone base has the lead's files (`team_lead_base_ok` in `team-run-lead.sh`; an older base
    → `team-next` onto a current line);
  - a valid `order-brief.md` (`team-brief.sh check`; `/start-team` step 4c writes it).

  The launch copies the brief into `runs/<run>/order-brief.md` (frozen for the run), materialises
  the profile (`team-lead.sh materialize`) and starts
  `claude --settings <clone>/.agents/team/teamlead.settings.json --model <TEAM_LEAD_MODEL>
  --effort <TEAM_LEAD_EFFORT> --disallowedTools AskUserQuestion` with the prompt rendered from the
  **main checkout's** `.claude/team/prompts/teamlead.md`.
- **Reuse.** A runner that restarts within the same run reuses a live lead whose
  `teamlead.json.run` is the current run; a dead one is launched again.
- **Wait in place.** A stage's `blocked` / `failed` record no longer ends the runner: the runner
  acks it, rings the lead (`stop <role> <attempt>: <record> — <message>`), prints
  `waiting for TeamLead: <record>` and keeps waiting for the stage's next record. Time spent waiting
  does not count toward the stage limit.
- **Doorbell.** `team_session_doorbell` (`team-lead-lib.sh`) is the one transport. First Claude's
  messaging socket from the lead's own `teamlead.reg.json` (draft- and dialog-safe). Otherwise
  `send-keys` on a recognised empty idle input under the send lock. Otherwise skip and log
  `doorbell-skipped` to `send-lead.log`. Pending work is derived from files, so a lost doorbell
  only delays. The runner rings on a stop, a new attention line (`prompt <role>: needs a
  decision`) and once per new file in the team's inbox (`inbox: <file>`).
- **Identity.** `team_lead_caller` (`team-lead-lib.sh`): role env `TeamLead` + `teamlead.json` of the
  current run (+ the hook's session id). The SessionStart hook `teamlead-register.sh` moves
  `teamlead.json.session_id` to the live id after `/clear`, but only for the lead's own process, then
  writes the registration and prints `team-lead.sh pending`.
- **Death and relaunch.** A dead lead is reported once (`session_dead`, marker `lead-dead`) and the
  runner prints `TeamLead died — /start-team <team> relaunches it`. `/start-team <team>` on a live
  runner with `teamlead: dead` runs `team-lead.sh relaunch <team>` (writes `relaunch-lead`), and
  the runner relaunches at its next poll and rings `relaunched: reconcile from files`.
- **End.** The lead ends with its run:
  - at merge: `team-integrate.sh` after `integrated:` / `already integrated:`, or `/pr-merge` step 6b,
    both through `team-lead.sh finalize <team> merged` (idempotent, marks `runs/<run>/finalized`);
  - at `team-next.sh` and `team-remode.sh`, through `team-lead.sh end <team>`;
  - at close: `close_run` (§4) runs `team-lead.sh end <team>`.

  A missing session is not an error.

## 2. Files

| File | Writer | Content |
|---|---|---|
| `order-brief.md` | `team-brief.sh write` | the order (team-mode.md §2) |
| `runs/<run>/order-brief.md` | runner at launch | the frozen copy the lead reads |
| `teamlead.json` | runner at launch; `teamlead-register.sh` (session id) | `team, run, session_id, launched_at, launch, model, effort, permission_mode, main_root` |
| `teamlead.settings.json` | `team-lead.sh materialize` (mode 600) | the lead's permission layer and its write guard |
| `teamlead.reg.json` | `teamlead-register.sh` (mode 600) | `socket, token, pid, session_id, registered_at` — the doorbell's target |
| `runs/<run>/lead-<n>.prompt.md`, `lead-<n>.session` | runner, per launch (relaunches count) | the rendered prompt and session id; `cost.py bind --team-run` pairs them |
| `lead-dead`, `relaunch-lead`, `inbox-rung/<file>`, `send-lead.log` | runner | death reported once, relaunch request, inbox ring markers, skipped doorbells |
| `acked` | runner, on a stop (`lead_stop`) or a gate (`lead_gate_ring`) | basename of the stage record the lead must resolve: a `blocked`/`failed` stop, a planner `review` (spec gate) or `done` (plan gate) |
| `runs/<run>/teamlead-<gate>-<seq>.json` | `team-verdict.sh` (lead only) | a gate verdict, §4 |
| `runs/<run>/gate-<gate>-<n>.md` | the lead | gate findings; a verdict's `ref` |
| `runs/<run>/digest.md` | the lead (its digest sub-agent's answer, verbatim) | `scope: <paths>`, `made_at: <UTC>`, then the cited constraints — §5 |
| `verdict-acked` | runner | the verdict files already acted on, one per line |
| `runs/<run>/closed.json` | runner (`close_run`) | `reason, ref, closed_at, pr_id` — a closed run; the runner and `/start-team` refuse to resume it |
| `runs/<run>/<record>.answered` | `team-answer.sh`, after delivering the answer to that stop (step 6) | ends the wait: the stage time limit (coder 4 h, qa 3 h) is paused while `acked` names a stop without this marker, and counts again from the poll that sees it |

The team-dir root files of a lead (`teamlead.*`, `round`, `verdict-acked`, `lead-dead`,
`relaunch-lead`, `inbox-rung/`) are run-scoped: `team-next.sh` and `team-remode.sh` archive them.
Every ownership check requires `teamlead.json.run` = the current `run`, so a stale file never
switches a later run to the lead branch.

`team-lead.sh pending <team>` lists, oldest first:
- `stop` — a role/attempt whose newest record is `blocked` or `failed`;
- `gate` — a planner `review` (spec gate) or unaccepted `done` (plan gate) that no verdict other
  than `escalate` names yet;
- `attention` — attention lines after the active stage's newest record;
- `inbox` — files in `<main>/.agents/team/inbox/<team>/new/`.

## 3. Events to the Supervisor

Exactly four events reach the Supervisor, each an atomic file, then a doorbell to the Supervisor's
registered socket (`.agents/team/watch/receivers/Supervisor.json`) when one exists:

| Event | Sender | When |
|---|---|---|
| `accepted` | runner | a lead's acceptance and the wrapup are done (later step) |
| `closed` | runner | a run is closed without merge (`close_run`, §4); the body names the reason and what is left (`PR <id> to abandon before team-next` or `clone free`) |
| `collision` | lead | another team's in-flight work collides with this run (`team-verdict.sh event collision`) |
| `session_dead` | runner | the lead died, or a stage died with partial work (`ref` = its `.session`) |

Layout (`team-inbox.sh`): `<main>/.agents/team/inbox/<address>/{tmp,new,done}/`, files
`<UTC %Y%m%dT%H%M%SZ>-<from>-<event>.md`, written to `tmp/` and renamed into `new/`. Frontmatter
`id` (the file stem), `from`, `to`, `event`, `ticket`, `run`, `ref`, then a one-line body and an
optional `--message` line. A team
clone writes with `--main <teamlead.json main_root>`, never its own git root. A team address
(`inbox/<team>/`) takes any event, e.g. the Supervisor's `collision-answer`. Team-watch drops every
team signal of a run with its own lead (`lead: true` in the snapshot), so neither the global
TeamLead nor single-routing delivery sees that run's stops.

## 4. Gates

The lead gates the planner's spec (brainstorm) and plan (both modes) with verdict records the
runner acts on. Writer: `team-verdict.sh <gate> <verdict> --for <record> --message "<line>"
[--ref <findings>] [--notify human_decision|abandon_decision] [--decision d-<n>]`, lead only
(`team_lead_caller`), into `runs/<run>/teamlead-<gate>-<seq>.json` (`team, ticket, run, gate, seq,
for, verdict, ref, notify, message, spec_digest, written_at, session_id`).

| Gate | Input (`--for`) | Verdicts | Runner |
|---|---|---|---|
| `spec` (brainstorm) | the planner's `review` record (`/brainstorm` Step 9) | `approve` · `revise` · `escalate` | approve → `[team-run] TeamLead approved the spec …`, the planner sets `Approved (TeamLead, <date>)` and plans; revise → `[team-run] TeamLead: revise the spec — findings in <ref>…`; escalate → keeps waiting |
| `plan` | the planner's `done` record, before validation | `approve` · `revise` · `escalate` · `remode` (quick) | approve → validate + accept, the next stage launches; revise → `[team-run] TeamLead: amend the plan …`; remode → `close_run remode`; escalate → keeps waiting |

- **Refusals** (exit): `3` not the lead; `4` an unknown gate (`acceptance`/`decision` come later),
  a verdict outside the gate's set, `--for` that is not the planner's newest record or not in the
  gate's verdict, `revise` without `--ref`; `5` revise limit; `6` spec changed after approval;
  `7` constraint digest missing (§5).
- **Caller guard.** The script's own check (role env + `teamlead.json`) can be forged by a stage
  that prefixes `TEAM_SESSION_ROLE=TeamLead`. `guard-team-verdict.sh` (PreToolUse `Bash`, project
  settings, `/setup:teams` id `V`) refuses an invocation of `team-verdict.sh` (and of
  `team-answer.sh … --authority`, §6) in a team clone
  unless `team_lead_caller` holds for the hook payload's `session_id` (empty → refused). The guard
  sees the command text only: a stage writing a `teamlead-*.json` file by other means is not
  covered by it.
- **Revise limit.** At most `teams.teamlead.revise_limit` (default 3) `revise` per gate per run.
  Past it: `escalate` with a pending decision, `approve`, or (quick plan) `remode`. An answered
  decision `runs/<run>/decisions/d-<n>.md` with frontmatter `outcome: more-revise` and
  `gate: <gate>`, passed as `--decision d-<n>`, grants one more round and is marked `consumed`.
- **Spec digest.** A spec `approve` stores the SHA-256 of the spec at the record's `output_rev`
  without its `**Status:**` line. A brainstorm plan `approve` recomputes it at the `done` record's
  `output_rev`; a body change refuses (exit 6) and the spec gate runs again (it counts against the
  spec gate's limit), while setting `Approved (TeamLead, …)` passes.
- **Planner messages** go through `team_session_doorbell <team dir> planner` (idle input, send
  lock). A skipped message leaves its verdict unacted, and the next poll retries it.
- **Close.** `close_run <reason> <ref>` writes `closed.json`, the `closed` event, ends the lead and
  the stage session, removes `session.json` and exits **8** (closed without merge; audit
  `--final closed`). `team-remode.sh <team> brainstorm` accepts a quick run closed by a plan-gate
  `remode`: the new brainstorm run starts from the current `HEAD` (the committed quick plan stays in
  history) and keeps the order brief.
- **Collision.** `team-verdict.sh event collision --ref <file> --message "<line>"` writes the
  Supervisor event; the lead then either sends the spec back (`revise`) or holds the gate until the
  Supervisor answers through `inbox/<team>/`.

## 5. Project context

The lead loads project knowledge in three layers:

1. **Always:** `/prime` quick at bootstrap — nothing wholesale beyond it.
2. **Per task: the constraint digest.** At the first gate one distillation sub-agent reads
   `.agents/memory/decisions.md` and the domain files `index.md` routes for the paths the spec or
   plan touches (`.claude/memory-domains.json` rules, the same lookup as `guard-memory.sh`:
   `.claude/hooks/lib/memory-domain.sh`). It returns only the constraints bearing on this task,
   each cited (`- <constraint> — <file>#<heading or line>`), at most 60 lines, `none` when nothing
   applies. The lead saves it verbatim as `runs/<run>/digest.md` (`scope:` and `made_at:` header)
   and uses it for the rest of the run: gates, answers, acceptance. The brief is in the role prompt
   (`teamlead.md` → Constraint digest).
3. **Never:** `/prime full` or the whole `domain/*`.

When it is required: always in brainstorm (decisions.md alone is input); in quick only when a path
the plan names maps to a routed domain. A project without `memory-domains.json` has no routed
domains, so quick never needs one. `team-lead.sh digest-check <team> <spec|plan path>` decides;
`team-verdict.sh` runs it before a brainstorm spec `approve` or a quick plan `approve` and refuses
with exit 7 (`constraint digest missing — see the Digest section of the TeamLead prompt`).

## 6. Answering on an authority

`team-answer.sh <team> <role> <action> … --authority class|teamlead|operator --why "<line>"
[--decision <answered runs/<run>/decisions/d-<n>.md>]` (`team-answer-lead.sh`). The checker
(`team_prompt_check.py --authority`, rules in `team_prompt_authority.py`) runs the **human-only
check first**, before any waiver.

| | class | teamlead | operator |
|---|---|---|---|
| Caller | the runner, or the lead | the lead only (own team) | the lead, relaying an answered decision |
| Prompt with no ask/deny match, no human-only cause | sent | sent | sent |
| Baseline ask match (a `Bash(…)` rule meeting the command, or an `Edit(…)`/`Write(…)` rule meeting the edited path, that is in `.claude/team/baseline-ask.json`) | only in an enabled class | sent | sent |
| **Human-only** → exit 9 below operator: an Edit/Write or Bash naming `.claude/settings*.json` or `.claude/team/sessions/*.settings.json`; a project-added ask rule, Bash or Edit/Write (not in the baseline; no readable baseline → every ask); egress (WebFetch, curl/wget/ssh/scp/rsync/nc, `git remote add`/`set-url`); a recursive `rm` (`-rf`, `-fr`, `-r -f`, `--recursive`, behind wrappers) with a target outside the clone and the temp roots (`/tmp`, `/private/tmp`, the system temp dir, `$TMPDIR` — the scratchpad is under `/tmp`), or one that cannot be resolved (`$VAR`, a glob with no match, a relative path after a `cd`) | refused (9) | refused (9) | sent |
| **Never**: a deny match, the SQL guard, an unreadable or unbound prompt (no transcript, no unique pending tool_use, screen differs from it), an edit or path outside the clone; a recursive `rm` of the clone root or its `.git`; and, when anything needs a waiver, a recovered prompt (header off screen) or no live session | refused | refused | refused |

- Waivable by the lead on its own, from the baseline: `git merge --no-ff`/`--squash`,
  `git branch -d`/`-D`, `git rm`, `Edit(**/.env.*)`, and `rm -rf` whose every target is inside the
  clone (not its root or `.git`) or a temp root.
- The legacy path stays for runs without a lead: `--tier`/`--classes` behave as before (a class
  may still waive a settings edit there). In a **lead-owned run** (`teamlead.json.run` = the
  clone's run) `--tier` is refused with exit 8, so the human-only check cannot be bypassed.
- Without a ledger the identity checks run on every authority call: the stage transcript from
  `session.json`, a readable and unambiguous live event (equal to `--expect-event` when given), the
  dispatch journalled in `send-<role>.log` as `q=authority:<a>`.
- Every delivered authority answer appends `- <utc> [<role> <attempt>] <question> → <answer> —
  <why> [authority <a>] [decision <id>]` to `runs/<run>/answers.md`. A delivered `say` (or yes/no
  on an authority) to the role/attempt named by `acked` writes `runs/<run>/<record>.answered`, which
  restarts the stage clock (§2).
- Exit codes beyond the sender's usual ones: 7 caller or decision rule, 8 `--tier` in a lead-owned
  run, 9 human-only (open a pending decision; the decision flow is the next step).
