# 01 — Roles and sessions

**Contract:**
- [`supervisor-sessions.md`](../../.agents/reference/supervisor-sessions.md): the roles, profiles, launcher, preflight, auto-merge, migration and rollback.
- [`session-role.md`](../../.claude/commands/session-role.md): the bootstrap of a role window.
- [`monitor.md`](../../.claude/commands/monitor.md): the TeamLead's handling contract.

## The shape

The single-window `/monitor` splits into long-lived **role sessions**, each with one fixed role. Scripts, not models, enforce the routing, the pickup alarms, the modes, the permissions and the merge gate.

The layer is opt-in on top of the single-window flow. As long as there is no `routing.json`, routing is `single Supervisor` and one plain window runs `/monitor` as before.

| Role | Host | tmux session | Does | Never |
|---|---|---|---|---|
| **Supervisor** | Claude | `<prefix>-supervisor` | the Operator conversation, operational decisions, auto-merge within the gate, releases and the freeze, alarms, a role session's own prompts (tier 1 through `answer`) | answers or escalates a team question; switches routing on its own; clears a freeze without the Operator |
| **TeamLead** | Claude | `<prefix>-teamlead` | runs `/monitor`: team signals, tier 1, decides team questions, sends the Advisor and Operator lists through `team-escalate.sh`, writes the READY note | merges, releases, pushes; creates, advances or remodes teams; switches routing or answering |
| **Advisor** | Claude | `<prefix>-advisor` | task intake, tier 2; under `advisor: pair` it runs the Reviewer's deliver loop | receives team-watch pushes; it wakes only on its own unread mail |
| **Reviewer** | Codex | none, an agent-mail recipient | the second opinion on a tier-2 escalation (`advisor: pair` only) | exists under `advisor: solo` |

The **Operator** is the human. Operator actions (routing, `freeze off`, `here`, `rollback`, `register --takeover`, installing the kit) sit behind `ask` and are never taken by a role on its own.

Who decides what: [02 — Decision model](02-decision-model.md). What gets pushed to whom: [04 — Signals and monitoring](04-team-watch.md).

## Identity

- **`TEAM_SESSION_ROLE`** (`Supervisor` | `TeamLead` | `Advisor`) is the identity. The launcher sets it per tmux session, and each role profile sets it again under `env`. A session's memory never decides its role.
- `<prefix>` is `teams.channel.tmux_prefix`, which defaults to the repo directory slug. The mail recipient and the session's `--name` are both the role plus `teams.channel.mail_suffix`. Two projects on one machine therefore never share a tmux session, a recipient or a process name.
- The **`SessionStart` hook `session-role.sh`** (id `S`, registered by `team-setup.sh`) runs after startup, resume, `/clear` and compact. It tells the window to run `/session-role <role>` first and keeps `.agents/team/watch/sessions/<role>/session.json` on the live session id, so `team-answer.sh --session <role>` binds to the role's own transcript. It stays silent in a team clone and without a known role.
- **`/session-role <role>`** refuses when the argument differs from `TEAM_SESSION_ROLE`. Otherwise it primes, reads the role's section of the contract, registers the team-watch receiver (Supervisor and TeamLead), arms the wake loop and reconciles.

## Models

Models are config: `teams.sessions.<Role>.{model,effort}` in `.claude/project-profile.json`. Without it, every role runs `opus`: the Supervisor at effort `medium`, and the TeamLead and the Advisor at `high`, because the TeamLead decides design questions inside the AC. `/setup:teams` prints the effective table. A running window picks up a change only after `stop <role>` and `start <role>`.

## `/monitor` belongs to the TeamLead

In split routing, `/monitor` is the TeamLead's handling contract for `[team-watch #<n>]` messages. It takes only `--tiers on|off` and no longer a team list, because the daemon pushes every team's signals.

`READY` produces no summary for the Operator. The note goes to `<decisions_dir>/<date>-<team>-ready-TeamLead.md`, with its "TeamLead decisions" section, and a `turn` goes to the Supervisor on thread `ready-<team>-<run>`. The Supervisor then runs `team-automerge-check.sh`.

In the single window (no role, routing `single Supervisor`), the same `/monitor` runs everything, as before.

## Role profiles and their check

`.claude/team/sessions/Supervisor.settings.json` and `TeamLead.settings.json` are an extra `--settings` layer. The Advisor has no repo profile. Each profile:

- sets `env.TEAM_SESSION_ROLE`;
- uses `deny` and `ask` to narrow writes;
- allows **named reads** only: `Read({{CLONES}}/**)` and the agent-mail client.

Deny and ask beat allow across every layer, so a profile allow is additive and the project's deny floor holds. Never add a `* list*` or `* show*` wildcard: it also matches writes whose arguments contain the word.

| Role | Denied on top of the project and local rules |
|---|---|
| TeamLead | `git push`, the PR host's update verbs (per `teams.pr_provider`), `team-new.sh`, `team-next.sh`, `team-remode.sh`, `team-integrate.sh`, `supervisor-sessions.sh freeze\|rollback\|answer\|here`, `team-watch.sh routing`, `team-watch.sh mode answering`, `/pr-merge`, `/release` |
| Supervisor | `team-answer.sh`, `team-question.sh * answer *`, `team-escalate.sh` |

**The one committed ask entry, `Bash(cat .env*)`.** Both profiles carry this single ask rule. It gives the profile's `secrets` samples something to prove in a project whose own settings ask nothing. Provider- and cloud-specific secret verbs belong in the project's copy of the profile or in `teams.policy` examples, not in the template.

**Materialisation.** On `start` and `here`, the launcher writes `.agents/team/watch/profiles/<role>.settings.json` (mode 600 in a 700 directory). That file contains:

- the profile, plus the union of the project's and the local `deny` and `ask` rules, so the deny floor survives however `--settings` merges;
- `{{CLONES}}` expanded from `teams.clone_parent` and `teams.clone_name`;
- for the TeamLead, the PR update verbs added to `deny`;
- from the installed kit's `role-hooks.settings.json`, exactly the `Notification` and `Stop` hooks, and nothing else, because a `PreToolUse` or `PermissionRequest` hook could approve a tool call.

**The check.** `supervisor-sessions.sh check` classifies each profile's `_samples` with the same fnmatch matcher as the tier-1 prompt check:

- `forbidden` must be deny;
- `reads` must be allow;
- `secrets` must be ask or deny;
- `writes` may be anything but allow.

A `secrets` or `writes` sample that becomes allow only through `settings.local.json` is a `<role> LEAK: <cmd> allowed by local <rule>` line, exit 3. **Then `start` and `here` launch nothing**, and the preflight shows `FAIL role profiles — local allow leak`.

A materialised profile that has lost a project or local deny rule is also a FAIL (`materialised profile lost N deny rules`); `stop` and `start` the role.

The check approximates Claude Code's matcher. The live `/permissions` check in each window is a migration step.

## The launcher

```bash
bash .claude/lib/supervisor-sessions.sh start all|<role>   # materialise + check, then launch in tmux
bash .claude/lib/supervisor-sessions.sh status             # tmux, receivers (socket state), routing, freeze
bash .claude/lib/supervisor-sessions.sh stop <role>        # never `all`
bash .claude/lib/supervisor-sessions.sh up                 # after a restart; /sessions-up
bash .claude/lib/supervisor-sessions.sh preflight          # one verdict line per row, exit 1 on any FAIL
```

Each role is launched like this:

- `tmux new-session -d -s <prefix>-<role> -e TEAM_SESSION_ROLE=<role>`, under `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN`, so a launching session's identity never leaks into it;
- `claude --name <role><suffix> --session-id <uuid> --model <m> --effort <e> --settings <materialised profile>`;
- the launch prompt `/session-role <role>`.

`CODEX_HOME` and `CLAUDE_CONFIG_DIR` are forwarded per session. A changed `settings.local.json` needs `stop <role>` and `start <role>`.

Other verbs:

- `here Supervisor` runs the Supervisor in the Operator's own terminal. It refuses while `<prefix>-supervisor` runs, and it is an Operator action.
- `answer <role> --fp <fp> yes|no|pick|other` is the only tier-1 path into a role session's own prompt. It is bound to the fingerprint and refused with zero keys on any mismatch.
- `freeze on|off|status` and `rollback` are covered in the contract.
- `reviewer` reports `Reviewer: deliver ok|missing`, matched on this box's path only, or `Reviewer: none (advisor solo)`.

## `advisor: pair | solo`

`teams.channel.advisor` defaults to `pair` when the profile has `codex: true`, and to `solo` otherwise.

- **`pair`.** The Advisor answers tier 2 together with the Reviewer (Codex): it runs the Reviewer's deliver loop, and the escalation adapter's `opinion` is available.
- **`solo`.** The Reviewer does not exist: `/setup:teams` prints `reviewer: none`, `supervisor-sessions.sh reviewer` prints `Reviewer: none (advisor solo)`, and every note carries `reviewer: none`.

## Preflight

`supervisor-sessions.sh preflight` prints one `ok|WARN|FAIL <row>[ — <detail>]` line per row and exits 1 on any FAIL.

| # | Row | WARN / FAIL |
|---|---|---|
| 1 | receivers live | see below |
| 2 | team-watch loops beating | FAIL `beat or dog.beat stale — bash .claude/lib/team-watch.sh start` |
| 3 | escalations have live waiters | FAIL naming each `escalating` / `waiting-operator` q without a live `team-escalate.sh` waiter |
| 4 | mail probe and picked ping per role | FAIL on a missing `.mail` probe in `watch.local.json`, or a role whose `team-watch.sh ping` was never picked |
| 5 | team channel loads | FAIL with the loader's last error line |
| 6 | operator kit installed | FAIL on any `install.sh --verify` drift; the fix is the Operator's `install.sh --apply` ([08](08-operator-kit.md)) |
| 7 | role profiles | FAIL `local allow leak`, or any other failing `supervisor-sessions.sh check` |
| 8 | notifier | `notify.sh --check`; `none` is an ok row that prints the declared loss |
| 9 | health check scheduled | `sessions-health.sh --scheduled`; none is an ok row that prints the declared loss |
| 10 | Claude Code version | compared with the version the socket wire format was verified on; FAIL with `--permission-mode bypassPermissions` in `TEAM_SESSIONS_CLAUDE_FLAGS` and no `"crossSessionInbound": "accept"` in the user settings |

**The socket row (1).** Each registered receiver's socket is judged by `team-watch-send.py --check`, the send's own predicate and wording:

| State | Verdict |
|---|---|
| a role not started yet (no tmux session or `here` window) | **WARN** `<role> not started` |
| a running role with no active registration | **FAIL** `<role> not registered` |
| a running role whose socket is missing | **FAIL** `<role> socket <path> missing` |
| a socket that is not a 0600 socket owned by the current uid | **FAIL** `socket <path> refused mode <mode> — want mode 0600 owned by uid <uid>` |
| socket ok, but the pid is gone | **FAIL** `<role> not live (pid gone)` |

On the verified CLI the messaging token is not enforced. The 0600 mode and the owner of the socket are therefore the only boundary ([04 → wire format](04-team-watch.md#the-wire-format-and-its-boundary)).

## After a restart, and rollback

- **After a machine restart:** run `/sessions-up` (or `supervisor-sessions.sh up`). It starts the team-watch loops and every missing role, fresh, never with `--resume`, then runs `monitoring.sh start all`. Interrupted team runs are listed for `/start-team <team>`, never resumed.
- **Rollback:** run `supervisor-sessions.sh rollback` (routing `single Supervisor`, answering on), then `install.sh --rollback`. Ownership is back only when a plain `claude` window has run `/mail-role Supervisor` and `/monitor`, and `team-watch.sh status` shows the Supervisor receiver active.

The migration steps and the smoke checklist are in the contract.

## Language

Role names, preflight rows, `LEAK` and `answer` lines are English only, and no Polish form is parsed at this layer. The Operator's accepted Polish aliases live in `/monitor` ([04 → Language](04-team-watch.md#language)).

Acceptance rows: [capabilities](capabilities.md).
