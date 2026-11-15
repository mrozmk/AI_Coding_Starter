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
| `acked` | runner, on a stop (`lead_stop`) or a gate (`lead_gate_ring`) | the stage record the lead must resolve, relative to `runs/<run>/` (`r<n>/<record>` in a rework round): a `blocked`/`failed` stop, a planner `review` (spec gate) or `done` (plan gate), a qa `done` (acceptance gate) |
| `round`, `round-transition` | runner (§9) | the durable rework round `{run, round, verdict, pr_published}`; the transition intent `{run, from, to, verdict, pr_published}` |
| `runs/<run>/rework-<n>.md`, `runs/<run>/r<n>/` | the lead; runner + stages | the round's rework order; round n's records, prompts, sessions, reports and acceptance files |
| `runs/<run>/teamlead-<gate>-<seq>.json` | `team-verdict.sh` (lead only) | a gate verdict, §4 |
| `runs/<run>/gate-<gate>-<n>.md` | the lead | gate findings; a verdict's `ref` |
| `runs/<run>/answers.md` | `team-answer.sh` (every authority answer) | `- <utc> [<role> <attempt>] <question> → <answer> — <why> [authority <a>] [decision <id>]` |
| `runs/<run>/decisions/d-<n>.md` | `team-lead.sh decision` | a human decision, §7 |
| `runs/<run>/decisions/req-<n>.json` | runner (`lead_attention`) | a human-only prompt the lead opens a decision from: source, tool, command, binding |
| `runs/<run>/.notified` | runner (`lead_notify`) | verdict files already notified to the Operator |
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
  run, 9 human-only (open a pending decision, §7).
- **The runner answers first:** a new `permission_prompt` attention line is tried at `--authority
  class` (no model wakes). Exit 0 → answered (`answers.md`); exit 9 → `decisions/req-<n>.json` and
  the doorbell `human-only <role>: <tool> <command> — open a decision for req-<n>`; any other refusal
  → `prompt <role>: <tool> <command> — team-answer.sh … --authority teamlead`. The tool and command
  come from the transcript-bound parse; an unreadable one rings `prompt <role>: unreadable`. Other
  attention kinds ring `prompt <role>: <kind> — <message>`.

## 7. Human decisions

The lead never waits on the Operator (`AskUserQuestion` is disabled for it); a decision only it
cannot make becomes a file, and the stop that needs it waits while everything else goes on.

- **Open** (lead only): `team-lead.sh decision open <team> --source <run file|attention:<n>>
  --question "<line>" [--options "a|b"] [--recommend "<line>"] [--notify human_decision|abandon_decision]
  [--gate spec|plan]`, or `--request req-<n>` (the runner's request: source, question and the prompt
  binding `bind_session_id, bind_run, bind_attempt, bind_fp, bind_event, bind_pane` are copied). It
  writes `decisions/d-<n>.md` (frontmatter `id, status: pending, stage, attempt, source, created_at,
  notify`; body `## Question`, `## Options`, `## Recommendation`) and the verdict
  `team-verdict.sh decision escalate --for <source> --ref <file> --notify <event>`.
- **Notify:** the runner sends each verdict with `notify` set once (`.notified`) through
  `team_channel_notify --alarm` — `<ticket> <id>: <question> — answer in tmux attach -t <team>-lead` —
  whatever `TEAM_NOTIFY` says.
- **Answer:** `team-lead.sh decision answer <team> d-<n> --text "<Operator's words>"
  [--outcome continue|close|more-revise|approve]` → `status: answered`, `answered_at`,
  `answered_via`, `## Answer`. It asks for a human: from a **terminal** (stdin is a TTY and the id
  is typed to confirm — `answered_via: terminal`), or from the **lead window**, where the lead's own
  transcript must hold a typed user message after `created_at`, not a doorbell or `[team-run]` line,
  that contains the answer text (`answered_via: teamlead-window <message uuid>`); else exit 7. One
  message is evidence for one decision, unless it names the other decision's id too
  (`d-8 yes, d-9 no`). A non-pending decision refuses with exit 4 (a late answer to a withdrawn
  decision is never applied).
- **Relay:** `team-answer.sh … --authority operator --decision <d-n.md>` requires `status: answered`,
  checks the bound prompt instance (`--expect-*` from `bind_*`: a successor prompt refuses with 6) and,
  under the send lock before the first key, sets `status: dispatched` + `dispatched_at` — one relay
  per decision.
- **Decision gate** (`team-verdict.sh decision <verdict> --for <run file|attention:<n>>`):
  `escalate` (needs `--ref`), `continue` / `close` (need `--decision d-<n>` answered with that
  `answer_outcome`; the decision becomes `status: consumed`, once), `resolved` (closes a pending or
  answered decision without changing the run). The revise allowance of §4 counts consumed
  `more-revise` grants; the rework budget of §9 counts consumed `continue` grants of abandon
  decisions.
- **Close is not limited to acceptance.** The runner acts on `decision close` whose `--for` is the
  acked record at **any** gate or stop — a spec, plan or acceptance gate, a coder or qa `blocked`
  stop: the Operator said close, so the run closes there (`close_run abandon`, exit 8). A `continue`
  only means something at the acceptance gate (§9); elsewhere it changes nothing in the runner.
- **Withdraw / list:** `decision withdraw <team> d-<n> --why "<line>"` (`status: withdrawn`, lead
  only), `decision list <team> [--pending]`; `team-lead.sh pending` lists pending decisions first.
- **Guard:** `guard-team-verdict.sh` refuses `team-lead.sh decision open|answer|withdraw` from any
  session but the lead's (payload session id), like the verdict and authority calls.
- **Limit of the human binding.** Both paths raise the bar; neither is proof that a human answered.
  A lead in auto mode can still create a pty (`script`, a tmux window it types into) to satisfy the
  terminal path, or append a user line to its own transcript for the window path. Both are
  deliberate acts, visible in the lead's tool log, not something it does by accident. A hard
  guarantee is an owner decision, outside these files.

## 8. Acceptance

After qa `done`, before the runner accepts it: the runner validates the record (published PR,
report — a rejection is `die 4` as before), acks it and rings `gate acceptance: <record>`. The qa
stage clock is paused while the gate waits (`lead_waiting`).

- **Blind check:** `team-lead.sh diff <team>` writes `runs/<run>/acceptance-diff.patch` and
  `.stat` — `git diff <base_sha>..<qa output_rev>` in the clone, excluding the spec and plan named in
  the accepted planner record (and the plan's `plans/done/` counterpart). One sub-agent gets only
  the order brief and the patch path; the lead saves its answer as `blind-check.md` and never opens
  the patch.
- **Brief:** `acceptance-brief.md` with `## Ordered vs delivered`, `## Scope delta`, `## Fit risks`,
  `## Open defects`, `## Warnings`, `## Recommendation`.
- **Verdict** (`team-verdict.sh acceptance <v> --for <qa record>`):
  - `accept` — needs `blind-check.md`, then the brief (not older than the blind check) with the six
    headings, and for a QA `Verdict: ready-with-warnings` one `- <warning> → keep|fix|follow-up —
    <why>` line under `## Warnings` per comma-separated item of the report's `Warnings:` line;
    otherwise exit 8 naming the missing piece. The runner accepts the qa record and launches the
    wrapup.
  - `rework` — opens the next round (§9).
  - `abandon-recommended` — needs `--decision d-<n>`, a pending decision opened with
    `--notify abandon_decision` (its escalate verdict is the one notification); the runner waits.
- **Decision verdicts the runner acts on:** on the acked record, `decision close` →
  `close_run abandon` (exit 8, event `closed`); `decision continue` → rings the lead
  `continue granted — order the rework` (§9). Decisions about prompts (`attention:<n>`) and
  `escalate` / `resolved` change nothing in the runner.
- **Ready:** `ready:` is printed only when every stage is accepted — so after `accept` **and** a done
  wrapup. With the lead on, the runner first writes the Supervisor event `accepted`
  (`ref: runs/<run>[/r<n>]/acceptance-brief.md`) once, guarded by `runs/<run>/accepted.sent`; a
  resume after `ready` sends no second one. The event needs an `acceptance accept` verdict naming
  the accepted qa record: a lead switched on after the qa was accepted wrote no brief, so the
  runner skips the event and says so. Without the lead nothing changes.
- **Per round:** the patch, `blind-check.md`, `acceptance-brief.md` and the qa report of round n
  live in the round's directory (`runs/<run>/` for round 1, `runs/<run>/r<n>/` after); the gate
  reads only those, so a round-2 accept never passes on round 1's files.

## 9. Rework rounds

The lead may order rework after an acceptance gate or a qa `blocked` stop. Each rework is a new
round: the coder continues on the **same branch and the same PR**, then qa (and later the wrapup)
runs again.

- **Order:** the lead writes `runs/<run>/rework-<n>.md` (n = the next round; each item tied to an
  order line or a QA defect), then `team-verdict.sh acceptance rework --for <qa record> --ref
  runs/<run>/rework-<n>.md`. `--for` is the qa's newest record of the current round, `done` or
  `blocked`.
- **Budget:** rounds the lead may order alone = `teams.teamlead.rework_budget.<mode>` (defaults
  brainstorm 2, quick 1) + the consumed Operator `continue` grants of decisions opened with
  `--notify abandon_decision` — one grant, one round. The count is derived from files (rework
  verdicts, consumed decisions), so a restarted runner or lead cannot reset it. Past it the verdict
  script exits 9: the lead opens an abandon decision (`--notify abandon_decision`, the one
  notification), writes `acceptance abandon-recommended --decision d-<n>`, and the Operator answers
  `continue` (→ `decision continue`, then the round is ordered) or `close` (→ `decision close`, the
  run closes). In quick mode the first rework needs `--quick-call continue`; the alternative is
  `abandon-recommended` — a remode once code exists is not offered.
- **Storage:** round 1 stays in `runs/<run>/`; round n ≥ 2 lives in `runs/<run>/r<n>/` (records,
  prompts, `.session` files, `notes.md`, `qa-report-<a>.md`, `pr-description.md`, `wrapup-<a>.md`,
  `wrapup-state.json`, acceptance files). No round-1 path changes. The run root keeps `attention`,
  `answers.md`, `decisions/`, `questions/`, verdicts, the rework orders and the lead's files.
  Records and `session.json` carry `round`; `run` stays the logical run id everywhere (records, QA
  report header, tracker markers). Prompts get `{{RUN_DIR}}` (the round's dir), `{{ROUND}}` and
  `{{REWORK}}` (the order, or `none`). Readers resolve the dir through `team_run_ref` (merge-check,
  integrate, automerge, validation, `pending`, `diff`); the records digest and the audit include
  every round. The `r<n>` directory never matches a record glob (`*-*-*.json`); team-watch and the
  snapshot also read `r*/` and take the newest record by time, so a round-2 stop is seen.
- **Transition** (runner, on the rework verdict): the order file must exist and the PR state is read
  live (`pr_published`); the intent `round-transition` is written first, then the qa session is
  ended, `runs/<run>/r<n+1>/` created, `session.json`, `acked` and `verdict-acked` cleared, `round`
  written atomically and the intent removed; the lead is rung `round <n+1> started`, and the coder
  launches with `input_rev` = the qa `output_rev` the rework was ordered for. A start with an intent
  present completes it from its first undone step; a `session.json` of an earlier round is ended and
  removed.
- **Validation of a rework coder:** its `pr_id` is round 1's, its `output_rev` descends from the
  previous qa `output_rev` (`git merge-base --is-ancestor`), and the PR is in the state it had at
  the rework order — a draft after a qa `blocked` before publishing, else published (both providers
  through `check_pr`). The plan check of round 1 does not apply. The coder prompt in round ≥ 2 fixes
  exactly the order's items, pushes to the same branch and records `done --pr <round 1's PR>`; the
  qa's publish step is a no-op on a published PR.
