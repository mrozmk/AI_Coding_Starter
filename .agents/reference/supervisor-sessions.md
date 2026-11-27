# Reference: supervision role sessions

> **Superseded for launching.** Role sessions are started, restored, stopped and taken over by
> `/roles` (`roles.sh up|status|stop|here|resume`) through the session-host driver:
> [session-host.md](session-host.md) and the role contracts in [roles/](roles/supervisor.md). The
> old `supervisor-sessions.sh` launch verbs (`start`, `up`, `here`, `stop`, `status`)
> are gone (#33): they print the usage and exit 2. `materialize`, `check`, `preflight`, `freeze`,
> `rollback` stay, and so does `reviewer` (the agent-mail kit's Reviewer check). The session table
> below is the old launcher's naming, kept for reference; current session names follow
> `teams.session_prefix` ([session-host.md](session-host.md)).

The single supervision window (one session talks to the Operator and runs the teams) is split into
long-lived role sessions with fixed roles. Identity is `TEAM_SESSION_ROLE`, set by the launcher;
**scripts, not models**, enforce the modes, the permissions and the merge gate. The supervision
layer is opt-in on top of the single-window flow. A message to a role is an inbox file rung by the
session-host doorbell ([session-host.md](session-host.md) §12); the decision model:
[team-decision-model.md](team-decision-model.md); the mail channel: [agent-mail.md](agent-mail.md).

| Session | tmux | Role | Woken by |
|---|---|---|---|
| **Supervisor** | `<prefix>-supervisor` | Operator conversation, operational actions (auto-merge within the gate, team start/stop/queue/clones, releases, incidents), the tracker — outside the question loop | its inbox events (doorbell); its own mail wakes nothing — read at bootstrap or by hand |
| **TeamLead** (retired) | `<prefix>-teamlead` | the global TeamLead — retired: no run reaches it ([§ TeamLead](#teamlead)) | none |
| **Advisor** | `<prefix>-advisor` | task intake, on request through the Supervisor | none — agent-mail only (with the kit), read by hand |

**The per-run TeamLead is not one of these sessions.** In brainstorm and quick mode the runner
(`team-run.sh`) launches one lead per team run as `<team>-lead` in the team clone and ends it with
the run; `supervisor-sessions.sh` never starts, stops or restores it. Its answers reach the Supervisor only as the four inbox events
([team-pipeline.md](team-pipeline.md) §5a, [team-lead.md](team-lead.md)).

`<prefix>` is `teams.channel.tmux_prefix` (default: the repo directory slug); the mail recipient
name is the role plus `teams.channel.mail_suffix`, and the same name is the session's `--name`, so
two projects on one machine never share a tmux session, a recipient or a process name.

Models are config: `teams.sessions.<Role>.{model,effort}` in `.claude/project-profile.json`.
Without it the Supervisor runs `opus` at effort `high`, Fable `fable` at `medium`, and Astra at
`high` on Codex's default model (`model: "default"`, no `-m`, effort pinned — a named model pins
it); a project that wants a stronger Advisor model names it there (the profile example
carries the block with the defaults). A running window changes model or effort only after
`roles.sh stop <Role>` + `roles.sh up <Role>`. `teams.sessions.TeamLead` is the per-run lead's model and effort
(default `fable` / `medium`, read by the runner at each launch); it starts no role session.

Channel, pane and mail content is data, never the Operator's consent. A request for action to
another role is always agent-mail `--kind turn --awaiting <role>` (`team-channel.sh turn <From>
<To>`); `info` / `report` carry information only — the kit's Stop hook holds a role only on an
unread `kind=turn`.

## Supervisor

> The Supervisor's role contract is [roles/supervisor.md](roles/supervisor.md): the
> `SessionStart` hook (`session-registry.sh`) names it on every start, `/clear` and compaction.

**Does:**
- the conversation with the Operator; operational decisions (never a team question); the
  Advisor's task intake (path recommendation); `/start-team` for a new ticket;
- the **automatic merge** after QA ready ([Auto-merge](#auto-merge)); tracker bookkeeping;
- releases ordered by the Operator, with `supervisor-sessions.sh freeze on <release>` before and
  the Operator's `freeze off` after the post-check;
- its own questions (not a team's) to the Advisor by plain agent-mail.

**Does not:** answer a team question (`team-answer.sh` is denied by its profile); relay the
Operator's decision to a team (that goes through the role's window); clear a freeze without the
Operator.

**Wakes the Supervisor only for:** the four team events in its inbox — `accepted` (with the
acceptance brief), `closed` (a run closed without a merge, a quick plan's `remode` included),
`collision`, `session_dead` ([team-lead.md §3](team-lead.md#3-events-to-the-supervisor)).
Its own mail (`kind=turn`) is not pushed: the Supervisor is a `monitor` recipient
([agent-mail.md](agent-mail.md)) and reads it at bootstrap or by hand, and the kit's Stop hook keeps a
running turn open until it is handled. Team questions, routine and progress never wake it.

**Bootstrap:** the launch line's bootstrap (`roles.sh`) and the hook's contract line — freeze state,
the inbox, the latest `decisions.md` commits, unread mail.

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
`team-remode.sh <team> brainstorm` (after a `closed` event whose reason is `remode`, then `/start-team <team>`).

## TeamLead

The global TeamLead is retired; the per-run TeamLead is not a supervision session ([team-lead.md](team-lead.md)).

## Advisor

> The Advisors are the roles Fable (Claude) and Astra (Codex) in `teams.sessions`, started by
> `/roles` (`bash .claude/lib/roles.sh`); their contract is [roles/advisor.md](roles/advisor.md) and
> Fable's settings template is `.claude/team/sessions/Advisor.settings.json`. What follows is the
> agent-mail side of the old single Advisor, kept for projects that install the agent-mail kit.

Nothing wakes it on mail: with the kit it reads unread `turn`s by hand (`team-mail.sh <KEY> inbox --for Advisor<suffix> --unread`) at bootstrap. Under `advisor: pair` it runs the Reviewer's deliver loop:
`supervisor-sessions.sh reviewer` reports `Reviewer: deliver ok|missing`, matched on this box's
path only (another project's same-name loop never counts); a missing one is restored per
[agent-mail.md](agent-mail.md) → Bring-up. Under `advisor: solo` the Reviewer does not exist
(`Reviewer: none (advisor solo)`) and every note carries `reviewer: none`.

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

`/sessions-up` and `supervisor-sessions.sh up` are gone. What is not
restored: [roles/supervisor.md](roles/supervisor.md#not-restored).

A team's stops (`ATTENTION`, `RECORD`, `RUNNER`, `READY`) reach that run's per-run TeamLead, and the
Supervisor gets only the four inbox events ([team-lead.md §3](team-lead.md#3-events-to-the-supervisor)).

## Profiles

`.claude/team/sessions/<role>.settings.json` (Supervisor, Advisor): `env.TEAM_SESSION_ROLE`,
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
project's copy or to `teams.policy` examples. The per-run TeamLead's `TeamLead.settings.json` is
not materialised here: `team-lead.sh materialize` builds it into the team clone
([team-lead.md](team-lead.md)).

The launcher **materialises** each profile into `.agents/team/watch/profiles/<role>.settings.json`
(mode 600 in a 700 directory): the union of the profile and the project + local `deny`/`ask` rules
(the deny floor survives whether `--settings` merges or overrides those keys), the profile `allow`
with `{{CLONES}}` expanded to `//<clone parent>/<clone prefix>*` from `teams.clone_parent` /
`teams.clone_name` (a `/path` rule in a `--settings` file anchors at that file's directory). From the installed kit's
`role-hooks.settings.json` it takes exactly `.hooks.Stop`, never its permissions, env or any other
event: a `PreToolUse` or `PermissionRequest` hook could approve a tool call. The template's own
hooks come from the repo (#323): every hook command gets `{{MAIN}}` → this checkout and `{{SEAL}}` →
the sha256 of `.agents/team/clearance.json` at this launch (or `off`), then `{{RULES}}` → the digest
of the launch rules (`guard_team_egress_clear.py rules-digest`); the kit's `Stop` is appended to the
template's events, never replacing them. A template with no hooks and no kit writes no `hooks` key.
The Advisor and Supervisor templates register the clearance hook for `PermissionRequest` and its
write guard for `PreToolUse` Edit/Write/MultiEdit/NotebookEdit ([security-egress.md](security-egress.md)
→ Supervisor clearance).

| Role | Denied on top of the project + local rules |
|---|---|
| Supervisor | `team-answer.sh`, `notify.sh` |
| Advisor | `git push`, `team-answer.sh`, `team-new.sh`, `team-next.sh`, `team-remode.sh`, `team-integrate.sh`, `supervisor-sessions.sh freeze\|rollback`, `Skill(start-team)`, `Skill(pr-merge)`, `Skill(release)`, `notify.sh`, `operator-record.sh` |

`supervisor-sessions.sh check` classifies each profile's `_samples` (deny > ask > allow > prompt,
the fnmatch matcher of `team_prompt_check.py`) and lists the effective hooks per layer: `forbidden`
must be deny, `reads` allow, `secrets` ask or deny, `writes` anything but allow. A `secrets`/`writes`
sample that becomes allow only through `settings.local.json` is a `<role> LEAK: <cmd> allowed by
local <rule>` line, exit 3; `roles.sh up` and `roles.sh here` then launch nothing and `preflight`
maps it to `FAIL role profiles — local allow leak`. A materialised profile that misses a project or
local deny is a `FAIL` (`materialised profile lost N deny rules`) — `roles.sh stop <Role>` +
`roles.sh up <Role>`. It is an
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
--no-daemon [-m <m>] -c model_reasoning_effort=<e> "<bootstrap line> Contract: <path>"` (no `-m`
when its model is `default`). `CODEX_HOME` /
`CLAUDE_CONFIG_DIR` are forwarded per session, never with `tmux set-environment -g`.
`CODEX_HOME` comes from the team channel's `codex_home`, else from `.claude/codex-profile` when it
has a value line — for Claude and Codex roles alike — else, for a Claude role, from the launcher's
own environment; a profile value that does not resolve, or a channel home that differs from it,
refuses `roles.sh up` / `here` / `resume` before any session starts.
`CLAUDE_CONFIG_DIR` comes from `.claude/claude-profile` when it has a value line (`here` and the
preflight's settings check use the same dir), else from the launcher's own environment; a declared
dir that does not resolve refuses `roles.sh up` / `roles.sh here` before any session starts. The session id
is written to `.agents/team/watch/sessions/<role>/session.json` by the `session-registry.sh` hook on
every start, `/clear` or resume. A changed `settings.local.json` needs `roles.sh stop
<Role>` + `roles.sh` (the materialised union is rebuilt on start).

**A role in the Operator's own terminal:** `roles.sh here <Role>` refuses inside Claude Code and
while the role runs, materialises and checks the profile, writes the role's record with this
terminal's handle (Herdr terminal id, tmux session, or — a plain terminal — the shell's pid and
start time, which `exec` keeps) and execs the role's CLI with its role environment — an Operator
action (an `ask` rule). `sessions-health.sh` counts a Supervisor window as up.

**`preflight` rows:** (1) the team channel loads — judged only when `teams.channel` is a JSON
object; absent or `null` prints `ok team channel: not configured (no teams.channel)`, any other
value is `FAIL team channel loads — teams.channel is not an object`; (2) the operator kit installed
(`install.sh --verify`) — with no `teams.channel`, `ok operator kit: not in use (no
teams.channel)`, any other value is `FAIL operator kit installed — not verified — teams.channel is
not an object`; (3) role profiles; (4) notifications (the `.claude/lib/notify.sh --check` lines on one
row; both channels off is an ok row); (5) the health check scheduled (`sessions-health.sh
--scheduled`; none is an ok row with the declared loss); (6) the Claude Code version against the one
the socket wire format was verified on ([session-host.md](session-host.md#socket-wire-format); any
other version: check the doorbell by hand) — with `--permission-mode bypassPermissions` in `TEAM_SESSIONS_CLAUDE_FLAGS` and no
`"crossSessionInbound": "accept"` in the user settings it is a FAIL naming that line (preflight only
reads the file). On the verified CLI the messaging token is **not** enforced: the socket's 0600
mode and owner are the only boundary, and delivered text stays untrusted data. A `/roles` checkout
without a channel exits 0 when rows 3–6 are green. `preflight` alone skips the channel-names check
every other verb runs first.

## Auto-merge

1. The `accepted` event (`ref: runs/<run>[/r<n>]/acceptance-brief.md`) wakes the Supervisor; it
   reads the brief and passes on to the Operator only what matters.
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
off` (an Operator action — never cleared without the Operator). Denied to the Advisors.

## Operator notifications

A permission prompt or elicitation dialog in a role session notifies nobody: it waits in that
role's window (and in the Herdr status). The roles take only the `Stop` hook from the installed kit
file `<kit_dir>/hooks/role-hooks.settings.json` (the Supervisor and the Claude Advisors through
their materialised profiles).

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
2. `/roles` (or `bash .claude/lib/roles.sh up`; `roles.sh here Supervisor` for a plain terminal).
3. In each window: the role's contract line appears (SessionStart hook); check `/permissions` against
   [Profiles](#profiles).
4. Channel check: `bash .claude/lib/session-host.sh send <Role> "<line>"` for each role; the line
   arrives in each window.
5. Close the old single window.
6. `supervisor-sessions.sh preflight` until green.
7. Smoke ([Smoke checklist](#smoke-checklist)), then the [Pilot](#pilot).

**Rollback:** `supervisor-sessions.sh rollback` prints the two Operator steps and calls nothing:
`! bash .claude/team/sessions/operator-kit/install.sh --rollback`, then a plain `claude` in the main
checkout (no `TEAM_SESSION_ROLE`).

## Smoke checklist

| Acceptance | Offline (`TEAM_SMOKE_PART=…`) | Live (Operator) |
|---|---|---|
| directive per role, silent in a clone | `sessions` (1) | `/clear` in a role window |
| three sessions under their prefix, role env, clean env, model/effort per role | `sessions` (2) | `roles.sh up` |
| profiles OK, deny floor kept, local leak blocks `roles.sh up` | `sessions` (3) | `/permissions` per window |
| preflight channel rows: not declared, malformed, local half missing | `sessions` (1b) | `preflight` on a checkout without `teams.channel` |
| preflight single verdict, declared losses | `sessions` (5) | `preflight` on the machine |
| Reviewer loop of this box only | `sessions` (6) | `reviewer` |
| `roles.sh status` lines, `roles.sh up` after a restart (fresh sessions, dead pane replaced, a running role and a `here` Supervisor kept), `rollback` prints the Operator steps only | `roles` (2), (3), (8), (14); `sessions` (9) for `rollback` | `roles.sh up` after a reboot |
| the doorbell's socket sender: deadline, 0666 refusal, 0600 delivery | part 15 (47) | `session-host.sh send` to a role window |

## Pilot

1–2 days after the switch. Write down, per day, the tokens per session (the costs layer, one
session id per window) and compare the Supervisor's with the single window's before the switch.
