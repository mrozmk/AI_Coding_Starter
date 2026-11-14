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
  - at close (a later step adds `closed`).

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
| `acked` | runner, on a stop (`lead_stop`) | basename of the stage's last `blocked`/`failed` record the lead must resolve |
| `runs/<run>/<record>.answered` | `team-answer.sh`, after delivering the answer to that stop (step 6) | ends the wait: the stage time limit (coder 4 h, qa 3 h) is paused while `acked` names a stop without this marker, and counts again from the poll that sees it |

The team-dir root files of a lead (`teamlead.*`, `round`, `verdict-acked`, `lead-dead`,
`relaunch-lead`, `inbox-rung/`) are run-scoped: `team-next.sh` and `team-remode.sh` archive them.
Every ownership check requires `teamlead.json.run` = the current `run`, so a stale file never
switches a later run to the lead branch.

`team-lead.sh pending <team>` lists, oldest first:
- `stop` — a role/attempt whose newest record is `blocked` or `failed`;
- `attention` — attention lines after the active stage's newest record;
- `inbox` — files in `<main>/.agents/team/inbox/<team>/new/`.

## 3. Events to the Supervisor

Exactly four events reach the Supervisor, each an atomic file, then a doorbell to the Supervisor's
registered socket (`.agents/team/watch/receivers/Supervisor.json`) when one exists:

| Event | Sender | When |
|---|---|---|
| `accepted` | runner | a lead's acceptance and the wrapup are done (later step) |
| `closed` | runner | a run is closed without merge (later step) |
| `collision` | lead | another team's in-flight work collides with this run (later step) |
| `session_dead` | runner | the lead died, or a stage died with partial work (`ref` = its `.session`) |

Layout (`team-inbox.sh`): `<main>/.agents/team/inbox/<address>/{tmp,new,done}/`, files
`<UTC %Y%m%dT%H%M%SZ>-<from>-<event>.md`, written to `tmp/` and renamed into `new/`. Frontmatter
`id` (the file stem), `from`, `to`, `event`, `ticket`, `run`, `ref`, then a one-line body. A team
clone writes with `--main <teamlead.json main_root>`, never its own git root. A team address
(`inbox/<team>/`) takes any event, e.g. the Supervisor's `collision-answer`. Team-watch drops every
team signal of a run with its own lead (`lead: true` in the snapshot), so neither the global
TeamLead nor single-routing delivery sees that run's stops.
