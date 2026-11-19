# 01 — Roles and sessions

**Contract:**
- [`supervisor-sessions.md`](../../.agents/reference/supervisor-sessions.md): the roles, profiles, launcher, preflight, auto-merge, migration and rollback.
- [`roles.md`](../../.claude/commands/roles.md) (`/roles`, script `roles.sh`): starts, stops, lists and takes the role sessions declared in `teams.sessions`; the role contracts are in [`.agents/reference/roles/`](../../.agents/reference/roles/).

> **`/roles` replaces the old launcher.** The old `supervisor-sessions.sh start|stop|status|up|here`, `/sessions-up`, `/session-role`, `/mail-role`, `/monitoring` and `/team-watch` are gone (they were pointers to it for one release, v3.2.0). The `SessionStart` hook `session-registry.sh` now names the role's contract on every start, `/clear` and compaction, and the bootstrap line is on the launch line. The sections below still describe the team-watch side until it is retired.

## Per-run TeamLead (pilot)

In brainstorm and quick mode the TeamLead is not a role session. The runner starts one lead per team run, as `<team>-lead` in the team clone, and ends it with the run. `supervisor-sessions.sh` never starts it, and team-watch carries no team signal. The Supervisor and the Advisor stay as below. Contract: [`team-lead.md`](../../.agents/reference/team-lead.md); the Supervisor's side: [`team-pipeline.md` §5a](../../.agents/reference/team-pipeline.md).

## The shape

Supervision runs as long-lived **role sessions**, each with one fixed role. Scripts, not models, enforce the routing, the pickup alarms, the modes, the permissions and the merge gate.

The layer is opt-in on top of the single-window flow. As long as there is no `routing.json`, routing is `single Supervisor` and one plain window receives everything.

| Role | Host | Session (tmux name / Herdr terminal) | Does | Never |
|---|---|---|---|---|
| **Supervisor** | Claude | `<prefix>-supervisor` | the Operator conversation, operational decisions, auto-merge within the gate, releases and the freeze, alarms | answers a team question; switches routing on its own; clears a freeze without the Operator |
| **Advisor** | Claude | `<prefix>-advisor` | task intake, on request through the Supervisor; under `advisor: pair` it runs the Reviewer's deliver loop | receives team-watch pushes; it reads its agent-mail by hand (with the kit) |
| **Reviewer** | Codex | none, an agent-mail recipient | the second opinion the Advisor asks for (`advisor: pair` only) | exists under `advisor: solo` |

The **Operator** is the human. Operator actions (routing, `freeze off`, `here`, `rollback`, `register --takeover`, installing the kit) sit behind `ask` and are never taken by a role on its own.

Who decides what: [02 — Decision model](02-decision-model.md). What gets pushed to whom: [04 — Signals and monitoring](04-team-watch.md).

## Identity

- **`TEAM_SESSION_ROLE`** (`Supervisor` | `TeamLead` | `Advisor`) is the identity. `/roles` sets it in each role session's launch environment, and each role profile sets it again under `env`. A session's memory never decides its role.
- `<prefix>` is `teams.session_prefix`, else `teams.channel.tmux_prefix`, else the repo directory slug, cut to 12 characters ([session-host.md](../../.agents/reference/session-host.md) §2). The session's `--name` is the role plus `teams.channel.mail_suffix`. Two projects on one machine therefore never share a session or a process name.
- The **`SessionStart` hook `session-registry.sh`** (id `L`, registered by `team-setup.sh`; it absorbed `session-role.sh`, which `team-setup.sh` now retires) runs after startup, resume, `/clear` and compact. It names the role's contract (`teams.sessions.<Role>.contract`) and keeps `.agents/team/watch/sessions/<role>/session.json` on the live session id. It stays silent in a team clone and without a known role.
- The bootstrap line is on the launch line itself (`You are <Role>. Follow the role contract …`): a hook adds context but starts no turn.

## Models

Models are config: `teams.sessions.<Role>.{model,effort}` in `.claude/project-profile.json`. Without it, every role runs `opus`: the Supervisor at effort `medium`, and the TeamLead and the Advisor at `high`, because the TeamLead decides design questions inside the AC. The profile example carries the block with these defaults, and an invalid value stops the launch with an error naming the key. A running window picks up a change only after `roles.sh stop <Role>` and `roles.sh up <Role>`.

## Role profiles and their check

`.claude/team/sessions/Supervisor.settings.json` and `TeamLead.settings.json` are an extra `--settings` layer. The Advisor has no repo profile. Each profile:

- sets `env.TEAM_SESSION_ROLE`;
- uses `deny` and `ask` to narrow writes;
- allows **named reads** only: `Read({{CLONES}}/**)` and the agent-mail client.

Deny and ask beat allow across every layer, so a profile allow is additive and the project's deny floor holds. Never add a `* list*` or `* show*` wildcard: it also matches writes whose arguments contain the word.

| Role | Denied on top of the project and local rules |
|---|---|
| TeamLead | `git push`, the PR host's update verbs (per `teams.pr_provider`), `team-new.sh`, `team-next.sh`, `team-remode.sh`, `team-integrate.sh`, `supervisor-sessions.sh freeze\|rollback\|here`, `team-watch.sh routing`, `team-watch.sh mode answering`, `/pr-merge`, `/release` |
| Supervisor | `team-answer.sh` |

**The committed ask entries, `Bash(cat .env*)` and `Read(**/.env*)`.** Both profiles carry these two ask rules; the second keeps the Read tool from opening a `.env` the Bash rule never sees. They give the profile's `secrets` samples something to prove in a project whose own settings ask nothing. Provider- and cloud-specific secret verbs belong in the project's copy of the profile or in `teams.policy` examples, not in the template.

**Materialisation.** On `start` and `here`, the launcher writes `.agents/team/watch/profiles/<role>.settings.json` (mode 600 in a 700 directory). That file contains:

- the profile, plus the union of the project's and the local `deny` and `ask` rules, so the deny floor survives however `--settings` merges;
- `{{CLONES}}` expanded from `teams.clone_parent` and `teams.clone_name`;
- for the TeamLead, the PR update verbs added to `deny`;
- from the installed kit's `role-hooks.settings.json`, exactly the `Stop` hook, and nothing else, because a `PreToolUse` or `PermissionRequest` hook could approve a tool call.

**The check.** `supervisor-sessions.sh check` classifies each profile's `_samples` with the same fnmatch matcher as the prompt check ([06](06-permissions.md#the-prompt-check)):

- `forbidden` must be deny;
- `reads` must be allow;
- `secrets` must be ask or deny;
- `writes` may be anything but allow.

A `secrets` or `writes` sample that becomes allow only through `settings.local.json` is a `<role> LEAK: <cmd> allowed by local <rule>` line, exit 3. **Then `start` and `here` launch nothing**, and the preflight shows `FAIL role profiles — local allow leak`.

A materialised profile that has lost a project or local deny rule is also a FAIL (`materialised profile lost N deny rules`); `stop` and `start` the role.

The check approximates Claude Code's matcher. The live `/permissions` check in each window is a migration step.

## Starting, restoring and stopping roles

Roles are started by `/roles`, on tmux or Herdr through the session-host driver
([session-host.md](../../.agents/reference/session-host.md)):

```bash
bash .claude/lib/roles.sh                 # = up: start every standing role that is not running (idempotent)
bash .claude/lib/roles.sh status          # backend, alive|gone|stopped, state, inbox, session id, last seen
bash .claude/lib/roles.sh stop <Role>|all # /exit, then a kill after 15 s; the record stays, marked stopped
bash .claude/lib/roles.sh resume <Role>   # a gone Claude role on its previous conversation
bash .claude/lib/roles.sh here <Role>     # this plain terminal becomes <Role> (an Operator action)
bash .claude/lib/supervisor-sessions.sh preflight   # one verdict line per row, exit 1 on any FAIL
```

After a crash or reboot, `/roles` also lists the interrupted team runs (resuming one is optional,
`/start-team <team>`) and prints a resume line for each gone ad-hoc conversation. Under Herdr the
roles land in the `Lead` tab of the checkout's space. A role that waits at the folder trust dialog
is reported as `started (needs trust — pick Yes; Enter alone exits)`: accept it in that window. No
wake loop and no team-watch daemon start; role messages are inbox files rung by the doorbell.

Each Claude role runs as `claude --name <role><suffix> --session-id <uuid> --model <m> --effort <e>
--settings <materialised profile> -- <bootstrap line>; read`, with the caller's `CLAUDECODE*` and
messaging variables dropped. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are set per session. A changed
`settings.local.json` needs `roles.sh stop <Role>` and `roles.sh up <Role>`.

Other verbs:

- `freeze on|off|status` and `rollback` are covered in the contract.
- `reviewer` reports `Reviewer: deliver ok|missing`, matched on this box's path only, or `Reviewer: none (advisor solo)`.

## `advisor: pair | solo`

`teams.channel.advisor` defaults to `pair` when the profile has `codex: true`, and to `solo` otherwise.

- **`pair`.** The Advisor works with the Reviewer (Codex): it runs the Reviewer's deliver loop.
- **`solo`.** The Reviewer does not exist: `/setup:teams` prints `reviewer: none`, `supervisor-sessions.sh reviewer` prints `Reviewer: none (advisor solo)`, and every note carries `reviewer: none`.

`solo` removes the Reviewer from the channel and nothing else. **The Codex CLI is still required by the team pipeline today:** `/setup:teams` stops without `codex` on `PATH`, the profile example lists it in `required_tools`, and the runner refuses to launch any team role while `.claude/codex-profile` does not resolve to an existing directory. Making it conditional is follow-up F32.

## Preflight

`supervisor-sessions.sh preflight` prints one `ok|WARN|FAIL <row>[ — <detail>]` line per row and exits 1 on any FAIL.

| # | Row | WARN / FAIL |
|---|---|---|
| 1 | receivers live | see below |
| 2 | team-watch loops beating | FAIL `beat or dog.beat stale — bash .claude/lib/team-watch.sh start` |
| 3 | mail probe and picked ping per role | FAIL on a missing `.mail` probe in `watch.local.json`, or a role whose `team-watch.sh ping` was never picked |
| 4 | team channel loads | FAIL with the loader's last error line |
| 5 | operator kit installed | FAIL on any `install.sh --verify` drift; the fix is the Operator's `install.sh --apply` ([08](08-operator-kit.md)) |
| 6 | role profiles | FAIL `local allow leak`, or any other failing `supervisor-sessions.sh check` |
| 7 | notifications | the `.claude/lib/notify.sh --check` lines on one row; both channels off is an ok row |
| 8 | health check | `sessions-health.sh --scheduled`; none is an ok row that prints the declared loss |
| 9 | Claude Code version | compared with the version the socket wire format was verified on (2.1.318); any other version prints `unverified: run team-watch.sh ping <role>`; FAIL with `--permission-mode bypassPermissions` in `TEAM_SESSIONS_CLAUDE_FLAGS` and no `"crossSessionInbound": "accept"` in the user settings |

**The socket row (1).** Each registered receiver's socket is judged by `team-watch-send.py --check`, the send's own predicate and wording:

| State | Verdict |
|---|---|
| a role not started yet (no session or `here` window) | **WARN** `<role> not started` |
| a running role with no active registration | **FAIL** `<role> not registered` |
| a running role whose socket is missing | **FAIL** `<role> socket <path> missing` |
| a socket that is not a 0600 socket owned by the current uid | **FAIL** `socket <path> refused mode <mode> — want mode 0600 owned by uid <uid>` |
| socket ok, but the pid is gone | **FAIL** `<role> not live (pid gone)` |

On the verified CLI the messaging token is not enforced. The 0600 mode and the owner of the socket are therefore the only boundary ([04 → wire format](04-team-watch.md#the-wire-format-and-its-boundary)).

## After a restart, and rollback

- **After a machine restart:** run `/roles`. It starts every missing standing role fresh (`roles.sh resume <Role>` continues a Claude role's previous conversation on request), asks which interrupted team runs to resume (`/start-team <team>`, optional), and prints resume lines for gone ad-hoc conversations. It starts no team-watch loop; a single Supervisor window starts it by hand (`bash .claude/lib/team-watch.sh start`).
- **Rollback:** run `supervisor-sessions.sh rollback` (routing `single Supervisor`, answering on), then `install.sh --rollback`. Ownership is back only when a plain `claude` window has run `team-watch.sh start`, and `team-watch.sh status` shows the Supervisor receiver active.

The migration steps (for a machine that already runs a single Supervisor window) and the smoke checklist are in the contract.

## Language

Role names, preflight rows and `LEAK` lines are English only, and no Polish form is parsed at this layer ([04 → Language](04-team-watch.md#language)).

Acceptance rows: [capabilities](capabilities.md).
