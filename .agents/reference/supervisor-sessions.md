# Reference: supervision role sessions

> **Superseded for launching.** Role sessions are started, restored, stopped and taken over by
> `/roles` (`roles.sh up|status|stop|here|resume`) through the session-host driver:
> [session-host.md](session-host.md) and the role contracts in [roles/](roles/supervisor.md). The
> `supervisor-sessions.sh` launch verbs (`start`, `up`, `here`, `stop`, `status`) are deprecated
> pointers to `roles.sh` and go in the next release. `materialize`, `check`, `preflight`, `freeze`,
> `rollback` stay, and so does `reviewer` (the agent-mail kit's Reviewer check). The tmux tables below describe the
> old launcher.

The single supervision window (one session receives every team signal, talks to the Operator, runs
the teams) is split into long-lived role sessions with fixed roles. Identity is
`TEAM_SESSION_ROLE`, set by the launcher; **scripts, not models**, enforce the routing, the pickup
alarms, the modes, the permissions and the merge gate. The supervision layer is opt-in on top of
the single-window flow (routing `single Supervisor`). Mechanics of the push channel:
[team-watch.md](team-watch.md); the decision model:
[team-decision-model.md](team-decision-model.md); the mail channel: [agent-mail.md](agent-mail.md).

| Session | tmux | Role | team-watch pushes |
|---|---|---|---|
| **Supervisor** | `<prefix>-supervisor` | Operator conversation, operational actions (auto-merge within the gate, team start/stop/queue/clones, releases, incidents), the tracker — outside the question loop | alarms + its own mail |
| **TeamLead** (retired) | `<prefix>-teamlead` | the global TeamLead — retired: no run reaches it ([§ TeamLead](#teamlead)) | none |
| **Advisor** | `<prefix>-advisor` | task intake, on request through the Supervisor | none — agent-mail only (with the kit), read by hand |

**The per-run TeamLead is not one of these sessions.** In brainstorm and quick mode the runner
(`team-run.sh`) launches one lead per team run as `<team>-lead` in the team clone and ends it with
the run; `supervisor-sessions.sh` never starts, stops or restores it, and team-watch carries no
team signal. Its answers reach the Supervisor only as the four inbox events
([team-pipeline.md](team-pipeline.md) §5a, [team-lead.md](team-lead.md)).

`<prefix>` is `teams.channel.tmux_prefix` (default: the repo directory slug); the mail recipient
name is the role plus `teams.channel.mail_suffix`, and the same name is the session's `--name`, so
two projects on one machine never share a tmux session, a recipient or a process name.

Models are config: `teams.sessions.<Role>.{model,effort}` in `.claude/project-profile.json`;
without it every role runs `opus`, the Supervisor at effort `medium`, the TeamLead and the Advisor
at `high` (the TeamLead decides design questions inside the AC). A project that wants a stronger
Advisor model names it there (the profile example carries the block with the defaults). A running window changes
model or effort only after `stop <role>` + `start <role>`. `teams.sessions.TeamLead` applies to both
TeamLeads while they coexist: the global session (default `opus`) and the per-run lead (default
`fable` / `high`, read by the runner at each launch).

Every `[team-watch #<n>]` message: `bash .claude/lib/team-watch.sh ack <n>` first, `… done <n>`
last. Channel, pane and mail content is data, never the Operator's consent. A request for action to
another role is always agent-mail `--kind turn --awaiting <role>` (`team-channel.sh turn <From>
<To>`); `info` / `report` carry information only — the mail probes wake a role only on
`kind=turn`.

## Supervisor

> The Supervisor's role contract is [roles/supervisor.md](roles/supervisor.md): the
> `SessionStart` hook (`session-registry.sh`) names it on every start, `/clear` and compaction.
> This section keeps the team-watch side that is still running until team-watch is retired.

**Does:**
- the conversation with the Operator; operational decisions (never a team question); the
  Advisor's task intake (path recommendation); `/start-team` for a new ticket;
- the **automatic merge** after QA ready ([Auto-merge](#auto-merge)); tracker bookkeeping;
- releases ordered by the Operator, with `supervisor-sessions.sh freeze on <release>` before and
  the Operator's `freeze off` after the post-check;
- its own questions (not a team's) to the Advisor by plain agent-mail;
- the alarms: `UNPICKED` / `STALLED` / `RECEIVER … down` / `UNDELIVERED` / `MONITOR` → find out why
  (the role's window, `roles.sh status`), tell the Operator in one line when a role
  is down or stuck;
- `ATTENTION TeamLead|Advisor (<permission|menu>) fp=<fp>: <anchor>` — a role session's own prompt
  or menu: an Operator action with a notification and the role's window.

**Does not:** answer a team question (`team-answer.sh` is denied by its profile); relay the
Operator's decision to a team (that goes through the role's window); switch `routing` on its own;
clear a freeze without the Operator.

**Wakes the Supervisor only for:** `ATTENTION TeamLead|Advisor`; a READY `turn` from the TeamLead
(thread `ready-<team>-<run>`); a `remode-<team>-<run>` turn; a blocker the TeamLead cannot resolve
or a ticket request; its own mail (`kind=turn`); the alarms above. Routine and progress never wake
it.

**Bootstrap:** the launch line's bootstrap (`roles.sh`) and the hook's contract line — freeze state,
`team-watch.sh pending Supervisor`, the latest `decisions.md` commits, unread mail.

**Operator records** — the Supervisor's only path to a notification:
`bash .claude/lib/operator-record.sh failure --summary "<line>" [--team <t>] [--ref <file>]` for a
failure it tried and could not repair (a stage or TeamLead that will not restart, a broken main it
cannot fix), `… release --summary "<line>"` for a release step that waits for the Operator, and
`… close <id>` itself as soon as the Operator has acted on that record — answered it, finished the
release step, or the failure is repaired. One record per step, closed by id; the Operator never
closes one, and the end of a release (`freeze off`) closes nothing. The script writes
`.agents/team/operator/<id>.md` and calls `notify.sh` itself; an open record with the same event,
team and summary is reused, not sent again. `notify.sh` is denied to every role profile.

**Commands:** `roles.sh status`, `supervisor-sessions.sh freeze on …|freeze status|preflight|reviewer`,
`team-automerge-check.sh <team> [--recheck <id>]`, `/pr-merge <id> --auto <team>`,
`team-remode.sh <team> brainstorm` (on the TeamLead's `remode` turn, then `/start-team <team>`),
`team-watch.sh status|stats|pending|mode tiers …`.

## TeamLead

The global TeamLead is retired; the per-run TeamLead is not a supervision session ([team-lead.md](team-lead.md)).

## Advisor

> The Advisors are the roles Fable (Claude) and Astra (Codex) in `teams.sessions`, started by
> `/roles` (`bash .claude/lib/roles.sh`); their contract is [roles/advisor.md](roles/advisor.md) and
> Fable's settings template is `.claude/team/sessions/Advisor.settings.json`. What follows is the
> agent-mail side of the old single Advisor, kept for projects that install the agent-mail kit.

It is no team-watch receiver and nothing wakes it on mail: with the kit it reads unread `turn`s by hand (`team-mail.sh <KEY> inbox --for Advisor<suffix> --unread`) at bootstrap. Under `advisor: pair` it runs the Reviewer's deliver loop:
`supervisor-sessions.sh reviewer` reports `Reviewer: deliver ok|missing`, matched on this box's
path only (another project's same-name loop never counts); a missing one is restored per
[agent-mail.md](agent-mail.md) → Bring-up. Under `advisor: solo` the Reviewer does not exist
(`Reviewer: none (advisor solo)`) and every note carries `reviewer: none`.

## Monitoring

**Declaration:** `.claude/team/sessions/monitoring.json` — per role `team_watch`,
`pause.pass`, `start` steps (allow-list: `mode tiers on`).
**Commands:** `bash .claude/lib/monitoring.sh start|stop|status [all]` (`all` only from the
Supervisor or a role-less caller; the `/monitoring` command is gone, the script stays until the
team-watch side is retired); [team-watch.md § Supervisor](team-watch.md#supervisor) is the
handling contract of `[team-watch #<n>]` messages.

**Pause:** one durable flag per role in `.agents/team/watch/state.json` `.paused[<role>] = {since,
by}`; an unreadable flag counts as a pause. A pause holds the team-watch push (routine not sent,
`pause.pass` sent) and the kit's Stop hook; it **never** acks,
supersedes, marks `done` or moves a cursor, and never silences alarms or incident threads. A
bootstrap (start, `/clear`, compact) keeps the pause. Details:
[team-watch.md](team-watch.md) → Pause.

**Start:** idempotent — only a paused role is rebased (unsent routine retired, alarms re-queued,
the open set replayed as `(current state)`); it prints `readiness: running | degraded (<why>) |
missing (<why>)`.

## Morning / after a restart

**After a crash or a machine restart:** run `/roles` in any session in the main checkout (or
`bash .claude/lib/roles.sh` in a terminal):
- every missing standing role starts fresh (a dead `; read` pane is replaced; a running role, also
  one taken with `roles.sh here`, is left alone), one line per role, then the `tmux attach -t …`
  lines;
- every interrupted team run is listed (`interrupted run <team> (<run>, stage <s>[, blocked|failed])
  — resume: /start-team <team>`). The command form asks which to resume and runs `/start-team` only
  for the chosen ones; with no answer it resumes nothing. `roles.sh runs` lists them on their own;
- every ad-hoc Claude session whose conversation is gone gets a paste-ready line
  (`<tab or tmux name> — cd '<cwd>' && claude --resume <session id>`); one that ended normally does
  not;
- `bash .claude/lib/roles.sh resume <Role>` continues a gone Claude role's previous conversation
  instead of a fresh one; plain `/roles` never resumes.

It starts no team-watch: while that still runs, start it with `bash .claude/lib/team-watch.sh start`
(`/sessions-up` and `supervisor-sessions.sh up` are gone). What is not
restored: [roles/supervisor.md](roles/supervisor.md#not-restored).

**Overnight:** `bash .claude/lib/monitoring.sh stop all` in the Supervisor at night, `… start all` in
the morning; each role then gets its `(current state)`.

## Routing

`bash .claude/lib/team-watch.sh routing split|single <role>` — an Operator action (an `ask` rule;
denied to the TeamLead). No `routing.json` = `single Supervisor`: the Supervisor's window receives everything.

| Event | split | single `<r>` |
|---|---|---|
| `ATTENTION`, `RECORD blocked/failed`, `RUNNER`, `READY`, team `ERROR` | TeamLead | `<r>` |
| `MAIL` from probe `<role>` | `<role>` | `<r>` |
| `MONITOR`, `UNDELIVERED`, `UNPICKED`, `STALLED`, `RECEIVER … down` | Supervisor | `<r>` |
| `ATTENTION <role>` — a prompt or menu in `<prefix>-teamlead` / `<prefix>-advisor` | Supervisor | `<r>`; the Supervisor when `<r>` is the subject |

A switch is an atomic handover: open batches become `transferred` (the old receiver's `ack` is
refused), and the next tick re-delivers every open signal as `(current state)` to the new
receivers. The dedup identity is unchanged, so a signal handled on the old side is refused as
`(existing …)` / `already answered`.

## Profiles

`.claude/team/sessions/<role>.settings.json` (Supervisor, TeamLead): `env.TEAM_SESSION_ROLE`,
`permissions.deny`/`ask` that narrow writes, and an `allow` of **named reads** only:
`Read({{CLONES}}/**)` and the agent-mail client (`team-mail.sh * inbox|recipients` are reads,
`ack|send` communication writes). Project-specific named reads (a cloud CLI's `list`/`show` by
name, local infrastructure) go into the project's own copy of the profile, each with a matching
`_samples.reads` line — `check` enforces the pairing. Never a `* list*` / `* show*` wildcard: it
also matches writes whose arguments contain the word. Arrays merge across `--settings`, local and
project, and deny/ask beat allow, so a profile allow is additive and the deny floor holds. The
committed ask floor is two rules, in both committed profiles: `Bash(cat .env*)` and
`Read(**/.env*)` (the Read tool would otherwise open a `.env` the Bash rule never sees). They are
there so the `_samples.secrets` lines (`cat .env`, `cat .env.local`, `Read(.env)`,
`Read(services/api/.env.local)`; a `Read(<path>)` sample is matched against Read rules) do
not depend on the project's settings: `check` requires every secrets sample to be ask or deny, and
a project whose own `settings.json` carries no `.env` rule would otherwise fail `check` (and leave
the secret read to a bare prompt). Provider- and cloud-specific secret verbs belong to the
project's copy or to `teams.policy` examples.

The launcher **materialises** each profile into `.agents/team/watch/profiles/<role>.settings.json`
(mode 600 in a 700 directory): the union of the profile and the project + local `deny`/`ask` rules
(the deny floor survives whether `--settings` merges or overrides those keys), the profile `allow`
with `{{CLONES}}` expanded to `//<clone parent>/<clone prefix>*` from `teams.clone_parent` /
`teams.clone_name` (a `/path` rule in a `--settings` file anchors at that file's directory), and —
TeamLead only — the PR host's update verbs for `teams.pr_provider` (github: `gh pr merge*`,
`gh pr edit*`; azure-devops: `az repos pr update*`; none: nothing). From the installed kit's
`role-hooks.settings.json` it takes exactly `.hooks.Notification` and `.hooks.Stop`, never its
permissions, env or any other event: a `PreToolUse` or `PermissionRequest` hook could approve a
tool call.

| Role | Denied on top of the project + local rules |
|---|---|
| TeamLead | `git push`, the PR update verbs (by provider), `team-new.sh`, `team-next.sh`, `team-remode.sh`, `team-integrate.sh`, `supervisor-sessions.sh freeze\|rollback\|here`, `team-watch.sh routing`, `team-watch.sh mode answering`, `Skill(pr-merge)`, `Skill(release)` |
| Supervisor | `team-answer.sh` |

`supervisor-sessions.sh check` classifies each profile's `_samples` (deny > ask > allow > prompt,
the fnmatch matcher of `team_prompt_check.py`) and lists the effective hooks per layer: `forbidden`
must be deny, `reads` allow, `secrets` ask or deny, `writes` anything but allow. A `secrets`/`writes`
sample that becomes allow only through `settings.local.json` is a `<role> LEAK: <cmd> allowed by
local <rule>` line, exit 3; `start` and `here` then launch nothing and `preflight` maps it to `FAIL
role profiles — local allow leak`. A materialised profile that misses a project or local deny is a
`FAIL` (`materialised profile lost N deny rules`) — `stop` + `start` the role. It is an
approximation of Claude Code's matcher: the live `/permissions` check in each window is a
migration step.

## Launcher

```bash
bash .claude/lib/roles.sh                          # up: every missing role; materialises + checks first
bash .claude/lib/roles.sh status                   # backend, alive|gone, state, inbox, session id
bash .claude/lib/roles.sh stop <Role>|all          # /exit, then a kill after 15 s; the record stays
bash .claude/lib/roles.sh here <Role>              # this plain terminal becomes <Role> (Operator)
bash .claude/lib/supervisor-sessions.sh preflight  # one verdict line per row, exit 1 on any FAIL
```

The old `supervisor-sessions.sh start|stop|status|up|here` are gone (`start all` is `roles.sh up`,
`start <Role>` is `roles.sh up <Role>`). What follows describes `roles.sh` through the session-host
driver (`session-host.sh start`).

Every launch runs under `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u
CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN`: a tmux server started from a Claude
session would otherwise hand `CLAUDECODE=1` to every later session. `up` runs, per role,
`tmux new-session -d -s <prefix>-<role lc> -e TEAM_SESSION_ROLE=<Role> -e HARNESS_ADDRESS=<Role> …`
with `claude --name <Role><suffix> --session-id <uuid> --model <m> --effort <e> --settings
<materialised profile>` (plus `TEAM_SESSIONS_CLAUDE_FLAGS`) and the bootstrap line "You are <Role>.
Follow the role contract the session context names and reconcile now …"; a Codex role gets `codex
--no-daemon -m <m> -c model_reasoning_effort=<e> "<bootstrap line> Contract: <path>"`. `CODEX_HOME` /
`CLAUDE_CONFIG_DIR` are forwarded per session, never with `tmux set-environment -g`.
`CLAUDE_CONFIG_DIR` comes from `.claude/claude-profile` when it has a value line (`here` and the
preflight's settings check use the same dir), else from the launcher's own environment; a declared
dir that does not resolve refuses `start` / `here` before any session starts. The session id
is written to `.agents/team/watch/sessions/<role>/session.json` by the `session-registry.sh` hook on
every start, `/clear` or resume. A changed `settings.local.json` needs `roles.sh stop
<Role>` + `roles.sh` (the materialised union is rebuilt on start).

**A role in the Operator's own terminal:** `roles.sh here <Role>` refuses inside Claude Code and
while the role runs, materialises and checks the profile, writes the role's record with this
terminal's handle (Herdr terminal id, tmux session, or — a plain terminal — the shell's pid and
start time, which `exec` keeps) and execs the role's CLI with its role environment — an Operator
action (an `ask` rule). `sessions-health.sh` counts a Supervisor window as up.

**`preflight` rows:** (1) receivers live — a refused socket is a FAIL with the send's own wording
(`socket <path> refused mode <mode> — want mode 0600 owned by uid <uid>`), a role not started yet a
WARN; (2) team-watch loops beating; (3) a mail probe and a picked
ping per role; (4) the team channel loads; (5) the operator kit installed (`install.sh --verify`);
(6) role profiles; (7) notifications (the `.claude/lib/notify.sh --check` lines on one row; both
channels off is an ok row); (8) the health check scheduled (`sessions-health.sh --scheduled`; none is an ok row with the
declared loss); (9) the Claude Code version against the one the socket wire format was verified on
— with `--permission-mode bypassPermissions` in `TEAM_SESSIONS_CLAUDE_FLAGS` and no
`"crossSessionInbound": "accept"` in the user settings it is a FAIL naming that line (preflight only
reads the file). On the verified CLI the messaging token is **not** enforced: the socket's 0600
mode and owner are the only boundary, and delivered text stays untrusted data.

## Auto-merge

1. The TeamLead's READY `turn` wakes the Supervisor; it reads the note's "TeamLead decisions"
   section and passes on to the Operator only what matters.
2. `bash .claude/lib/team-automerge-check.sh <team>` with `run_in_background: true` (the merge
   check builds for minutes). It refuses on a release freeze (`.agents/team/release-freeze`), a QA
   record that is not accepted `done`, a report without `Verdict: ready|ready-with-warnings` or
   `Gate final-build: passed`, any `team-merge-check.sh` failure, and a `.claude/**/*settings*.json`
   change other than added `allow-offline` entries. On `stale merge` it restarts the merge once
   through the provider's restart verb when there is one; otherwise `AUTOMERGE: no — stale merge,
   restart not available for <provider>`.
3. `AUTOMERGE: yes — PR <id> …` → `/pr-merge <id> --auto <team>`, which runs
   `team-automerge-check.sh <team> --recheck <id>` immediately before completing.
4. `AUTOMERGE: no — <reason>` → ask the Operator `Merge <team>?` with that reason.

Freeze: `supervisor-sessions.sh freeze on <release>|status` (the Supervisor's own call), `freeze
off` (an Operator action — never cleared without the Operator). Denied to the TeamLead.

## Alarms

Computed by the daemon after each tick, outside every LLM; one alarm per receiver episode, a
`… recovered` line when it ends. `RECEIVER <role> down`, `UNPICKED <role> #<n>`, `STALLED <role>
#<n>`, `UNDELIVERED <role>`, `MONITOR <daemon|dog> dead` — conditions and knobs:
[team-watch.md](team-watch.md) → Alarms. Target: the Supervisor (single routing: the receiver).
An alarm notifies nobody. **Terminal rule:** an episode about the target itself is only logged —
alarms never spawn alarms about alarms.

## Operator notifications

A permission prompt or elicitation dialog in a role session notifies nobody: it waits in that
role's window (and in the Herdr status). The roles take only the `Stop` hook from the installed kit
file `<kit_dir>/hooks/role-hooks.settings.json` (Supervisor and TeamLead through the materialised
profile, the Advisor as its `--settings`).

The single sender `.claude/lib/notify.sh` (notification model, epic E2) writes every Operator event
— `human_decision`, `abandon_decision` (runner, from TeamLead verdicts), `unrepaired_failure`,
`release` (`operator-record.sh`) — once into `~/.agent-comms/outbox/` and fans it out to the
channels switched on in `~/.agent-comms/notify.json`. The Herdr channel (#39) writes a spool entry
for the opt-in `harness-notify` mod (`.claude/team/herdr-mod/`) when the answering session's registry
record says `herdr`; the mod shows it once as a toast that jumps to that session, and keeps it in a
strip until clicked. The iMessage channel (#40, any backend, macOS) sends one message per event,
holds events during quiet hours and sends them as one message after `quiet.end`; the opt-in
`.claude/team/notify-kit/` installs the launchd job that runs that flush. `notify.sh --check` shows
the switches, whether the mod was seen and the flush job's state; `notify.sh list` shows the events. It is the only path to the Operator.
When the answer is seen elsewhere, the caller runs `notify.sh resolve` (#97): the runner for a
human-only prompt answered or withdrawn in the stage window, `team-lead.sh decision answer|withdraw`,
and `operator-record.sh close`. Nothing more is delivered for the event (a held overnight message
leaves the batch; a sent one stays sent), and the strip drops it. A failed resolve never stops the
caller. When a run ends (the runner's `close_run`, `team-lead.sh finalize`), `notify.sh resolve --team
<t> --run <r> --all` resolves every event of that run.

## Migration

Operator actions, in order; each step's rollback is `supervisor-sessions.sh rollback` +
`install.sh --rollback`.

1. `/setup:teams` with the channel step; `! bash .claude/team/sessions/operator-kit/install.sh
   --dry-run`, then `--apply`.
2. `/roles` (or `bash .claude/lib/roles.sh up`; `roles.sh here Supervisor` for a plain terminal);
   then `bash .claude/lib/team-watch.sh mode answering off` while the old
   single window is still running.
3. In each window: the role's contract line appears (SessionStart hook); check `/permissions` against
   [Profiles](#profiles). Each registers as `standby` while routing is single.
4. Channel check: `team-watch.sh ping <role>` for each role; each window acks; `team-watch.sh stats`
   shows `picked` for the ping batches.
5. Stop the old single window from handling team signals and close it. **Never** `team-watch.sh
   stop` — it stops the shared daemon for every role.
6. `supervisor-sessions.sh preflight` until green.
7. The switch: `bash .claude/lib/team-watch.sh routing split` + `mode answering on`.
8. Smoke ([Smoke checklist](#smoke-checklist)), then the [Pilot](#pilot).

**Rollback:** `supervisor-sessions.sh rollback` (routing `single Supervisor`, answering on, the
Operator steps printed) and `! bash .claude/team/sessions/operator-kit/install.sh --rollback`.
Ownership is back only when a plain `claude` window has run `bash .claude/lib/team-watch.sh start` and
`team-watch.sh status` shows `receiver Supervisor: … active`.

## Smoke checklist

| Acceptance | Offline (`TEAM_SMOKE_PART=…`) | Live (Operator) |
|---|---|---|
| directive per role, silent in a clone | `sessions` (1) | `/clear` in a role window |
| three sessions under their prefix, role env, clean env, model/effort per role | `sessions` (2) | `start all` |
| profiles OK, deny floor kept, local leak blocks `start` | `sessions` (3) | `/permissions` per window |
| role prompt reaches the Supervisor once and notifies nobody | part 17 (78) | a prompt in the Advisor window |
| preflight single verdict, declared losses | `sessions` (5) | `preflight` on the machine |
| Reviewer loop of this box only | `sessions` (6) | `reviewer` |
| `status` lines, `up` after a restart (fresh sessions, dead pane replaced, a running role and a `here` Supervisor kept), `rollback` switches routing and answering | `sessions` (9) | `up` after a reboot |
| a delivered signal handled exactly once, duplicates counted | part 17 (68) | a menu in a test team |
| `/clear`, a pid restart, alarms outside the LLM, rollback handover | the team-watch parts 15–19 | `/clear` in the TeamLead, kill a test receiver, rollback after the smoke |

## Pilot

1–2 days after the switch. Write down, per day: `bash .claude/lib/team-watch.sh stats --since
<UTC>` (delivered = wake-ups, pickup p50/max, unpicked/stalled alarms, duplicates per role) and the
tokens per session (the costs layer, one session id per window). Compare the Supervisor's
wake-ups with the single window's before the switch; an `UNPICKED TeamLead` on a READY is the
signal to route READY straight to the Supervisor. The TeamLead's tokens at effort high stay
informational: no threshold and no automatic return to medium.
