# Upgrade notes — team layer

Changes that need an action, or a second look, in a project that already runs the team layer.
Newest first.

## The `/roles` pointers and the old-name bridge are gone (#33, after v3.2.0)

**Before (v3.2.0):** `/session-role`, `/sessions-up`, `/mail-role`, `/monitoring` and `/team-watch`
were one-release pointers to `/roles`; `supervisor-sessions.sh start|stop|status|up|here` printed a
deprecation line and ran `roles.sh`; the session-host driver still reached a session under the name
it had before session prefixes (`TEAM_HOST_LEGACY_NAMES`).

**Now:**
- The five command files are gone. The manifest lists them as `retired` with the blob ids of the
  versions the starter shipped (v3.1.0, v3.2.0): `/setup:teams` deletes a project's copy only when
  it is byte for byte one of those (`removed retired <path>`); a copy the project changed is a
  `conflict (retired — …)` and stays for a hand decision. A project that syncs instead reads the
  dropped `own` lines from the base manifest, as for any upstream deletion.
- `supervisor-sessions.sh start|stop|status|up|here` print the usage and exit 2. The verbs are
  `roles.sh up|stop|status|here`. `/setup:teams` drops the exact allow/ask rules it once added for
  them; a rule worded any other way stays.
- `sh_target` resolves a session by its record, else its prefixed name; `TEAM_HOST_LEGACY_NAMES` is
  read by nothing.
- The TeamLead profile denies `roles.sh here` (was `supervisor-sessions.sh here`).
- Unchanged here: the team-watch daemon, `team-watch.sh mode`, `monitoring.sh`, `session-wake.sh`,
  `/monitor` and `supervisor-sessions.sh answer` (later steps).

**Action:**
- Upgrade to v3.2.0 first if the project is older: its sessions get prefixed names there, and this
  release no longer finds a session under an old name. A role or stage still running under its
  pre-prefix tmux name: stop it by that name (`tmux kill-session -t <old name>`) and start it again
  with `/roles` or `/start-team <team>`.
- Run `/setup:teams` (it deletes the unchanged pointers); delete or keep any `conflict (retired — …)`
  file by hand.
- Replace `/session-role`, `/sessions-up`, `/mail-role`, `/monitoring`, `/team-watch` and
  `supervisor-sessions.sh start|stop|status|up|here` in your own notes, scripts and `settings.local.json`
  with `/roles` / `roles.sh` (the listening switch is `bash .claude/lib/monitoring.sh`, until it is
  retired too).
- Restart the TeamLead session so it loads the new deny rule.

## The Herdr strip is docked only by `install.sh --dock <layout>`

**Before:** the mod's `mod.json` said `"place": "bottom"`, so Herdr docked the strip itself the first
time it saw the mod: it wrapped the shown layout's root in a new column and moved the root's keys
(`titlebar`, `traffic_lights`, the look) into the inner node, which brought back the system title
bar as a band over the window.

**Now:** `mod.json` says `"place": "none"`, so Herdr docks nothing by itself and a plain install
changes no layout. `install.sh --dock <layout>` docks the strip into exactly that layout file
(validated, backed up, rewritten atomically, the root keys kept on the root); `--undock <layout>`
and `--rollback` remove exactly what it added. Herdr's own layouts (`main`, `terminals`, `win98`)
are refused: clone one first.

**Action:**
- Re-run `bash .claude/team/herdr-mod/install.sh --dock <your layout>` (an Operator action).
- A layout Herdr auto-docked before keeps that strip and its title band: restore it from its own
  backup, or delete Herdr's wrapper by hand (the node whose children are the old root and a
  `harness-notify` block, with the root keys moved back up). For Herdr's own `main`, Herdr restores
  it on its next start.

## `/check-implementation` spawns two parallel finders

**Before:** Step 1 ran `/code-review high --fix` and `/deep-review` inline, one after the other,
on the session's model; the qa role's run reviewed on the qa model. The finder agents
`correctness-reviewer` / `structure-reviewer` were team-installed files the command did not use.

**Now:** Step 1ab spawns both finders in parallel, read-only, on the models and efforts pinned in
their agent files; the session applies their reports (bugs first, then structure) and stays the
only mutator. `tree-fingerprint.sh` proves the finders wrote nothing, `finder-model.sh` proves the
model and effort. A finder whose pinned model fails twice on a rate or usage limit, or is
unavailable, re-runs once as its `-fallback` agent on the session's model; the report, the QA
report's `Warnings:` and the PR description name it. The agents, their fallbacks and
`tree-fingerprint.sh` are core now, not team-installed.

**Cost:** two subagents per iteration (Opus 5.5 `xhigh` and Fable 5.1 `high`, up to 3 iterations)
instead of one inline pass of each skill: faster wall-clock, more tokens.

**Action:**
- Sync `.claude/agents/{correctness,structure}-reviewer{,-fallback}.md`,
  `.claude/lib/finder-model.sh`, `.claude/lib/tree-fingerprint.sh` and
  `.claude/commands/check-implementation.md` (a `shared` file: merge by hand).
- **Start a new session** before the first `/check-implementation` after the sync: a session keeps
  the agent definitions it loaded, and the command stops with `Reviewer agents not loaded`
  otherwise. Restart the role sessions for the same reason.
- Optional: `workflow.finder_fallback: "off"` in `.claude/project-profile.json` makes a limited or
  unavailable pinned model a STOP instead of the session-model fallback (absent = `session`).

## Session host, `/roles` and restore (#27–#36)

**Before:** role sessions and team stages ran in tmux only. `supervisor-sessions.sh` (and
`/sessions-up`, `/session-role`, `/mail-role`, `/monitoring`, `/team-watch`) started the roles, the
runner opened a Terminal.app window per role through `team-attach.sh`, and role messages were
pushed by the team-watch daemon and woken by wake loops. agent-mail was part of every install.

**Now:**
- **One driver.** Every session goes through `.claude/lib/session-host.sh`, on tmux or Herdr
  (`teams.session_host: auto | tmux | herdr`). **`auto` is tmux today**: Herdr runs only when
  chosen explicitly, until the owner switches `auto` to it. A running session stays on the
  backend it started on. Contract: `.agents/reference/session-host.md`.
- **Prefixed names.** Every session name carries the project prefix (`teams.session_prefix`, else
  `teams.channel.tmux_prefix`, else the repo slug, cut to 12): `<prefix>-<team>-<role>`,
  `<prefix>-<role>`. A run started before the update keeps its old name for one release.
- **`/roles` replaces five commands.** `/roles` (`roles.sh up|status|stop|here|resume|runs`)
  starts, restores, stops and lists the role sessions; after a crash or reboot it also asks which
  interrupted team runs to resume and prints resume lines for gone ad-hoc conversations. Roles are
  `teams.sessions` (one key per role: `cli`, `model`, `effort`, `settings`, `contract`, `standing`,
  `enabled`, `place`); the shipped defaults are Supervisor, Fable (Claude) and Astra (Codex). The
  old key `Advisor` is read as Fable. `/sessions-up`, `/session-role`, `/mail-role`, `/monitoring`,
  `/team-watch` and `supervisor-sessions.sh start|stop|status|up|here` are deprecated pointers to
  `/roles` and go in the next release.
- **Role messages** are inbox files rung by the doorbell (`session-host.sh send`); `/roles` starts
  no team-watch daemon and no wake loop. `/monitor` users start the daemon by hand:
  `bash .claude/lib/team-watch.sh start`.
- **tmux: no role windows open any more.** The runner no longer opens a Terminal.app window per
  role, and `team-attach.sh` is gone. Nothing replaces the window under tmux: run the command
  `bash .claude/lib/session-host.sh hint <team>-<role>` prints, and detach with `Ctrl-b d`. The
  planner and the wrapup print `attach: <hint>`; a role that waits on you prints
  `needs attention: <hint>`. `TEAM_ATTACH` does nothing under tmux (under Herdr it decides which
  stages get a pane in the team's tab). `team-status.sh` no longer writes the OSC 7501 status to
  attached tmux clients. A runner running during the update prints
  `warn: no preview window for <name>` and goes on.
- **Hints.** A tmux hint carries `TMUX_TMPDIR=<dir>` when the process that prints it has the
  variable (a per-project tmux server). With no session found, the Operator notification's hint
  says so (`no Supervisor session found — bash .claude/lib/roles.sh status`, and for a decision
  `no <team>-lead session found — bash .claude/lib/session-host.sh status <team>-lead`) instead of
  a guessed tmux name.
- **Startup dialogs are reported, never answered.** A role at the folder trust dialog prints
  `started (needs trust — pick Yes; Enter alone exits)`: under Herdr the dialog's first option is
  `No, exit`. The MCP servers dialog prints `started (startup dialog open)`.
- **Herdr:** roles go to the `Lead` tab; each team gets its own tab, named after the team, with its
  TeamLead on the left and the running stage on the right. A team named like a roles tab (`lead`,
  case-insensitive) is refused. A role's pane title is set to its address before the CLI starts;
  Claude Code then shows its own title (`Claude Code`), so the address is visible only at a startup
  dialog or after the program exits.
- **agent-mail is an optional kit.** `/setup:teams` installs it only when the profile has
  `teams.channel`, the kit is already installed (`.agents/team/channel.local.json`) or you pick it;
  `sqlite3` is required only then. A project that uses the kit today sees no change. The warning
  "operator kit role-hooks.settings.json not installed — <role> without the mail Stop guard" is gone.
- **Worker artifacts** of a new install live in `~/.agent-ops/worker/<id>` (mode 0700). An existing
  `~/.agent-mail/worker` stays the artifacts root.

**Action:**
- Run `/setup:teams` to update the layer, then start the roles with `/roles` (stop the old windows
  first, or let `/roles` find them under their old names).
- Optional: set `teams.session_host` and `teams.session_prefix`; give each project its own tmux
  server through `env.TMUX_TMPDIR` in `.claude/settings.local.json`.
- A Worker to move out of the mail home: release its active assignment, move the directory to
  `~/.agent-ops/worker`, give the Worker's Codex host write access to the new path and drop the old
  one — or set `WORKER_ARTIFACTS` to a path you choose.
- Replace `/sessions-up` and the other four commands in your own notes and scripts with `/roles`.
- A team named `lead` (the roles' Herdr tab) no longer starts: provision it under another name.


## `notify.sh` is the only path to the Operator

**Before:** the Operator was reached by several sinks: the operator kit's platform notifier
(`osascript` / `notify-send`, `teams.channel.notifier`), the role sessions' `Notification` hook
`supervisor-notify.sh`, team-watch alarms, the runner's `TEAM_NOTIFY=1` notices, the health
check's alarm and `PushNotification` in `/monitor`.

**Now:** only `.claude/lib/notify.sh` notifies, for four events (`human_decision`,
`abandon_decision`, `unrepaired_failure`, `release`), on the channels switched on in
`~/.agent-comms/notify.json` (Herdr, iMessage; both off by default). Prompts, waits, "ready",
stops and team-watch alarms notify nobody; what waits for you shows in `/tasks-status`.
`TEAM_NOTIFY` is ignored. `teams.channel.notifier` is ignored with one `warn:` line.

**Action:**
- Re-run `bash .claude/team/sessions/operator-kit/install.sh --apply` (an Operator action): the
  installed `hooks/role-hooks.settings.json` still wires the removed hook, so `--verify` and the
  preflight's `operator kit installed` row report it as `differs` until then. Restart the role
  sessions afterwards.
- Delete by hand, when convenient: `<kit_dir>/notify.sh` and `<kit_dir>/notify.sh.bak-team-kit`
  (nothing calls them; the installer no longer manages them), `.claude/hooks/supervisor-notify.sh`
  if your sync left it, the `notifier` key in `teams.channel`, and any `TEAM_NOTIFY` export.
- To be notified, write `~/.agent-comms/notify.json` (`.claude/team/notify-kit/README.md`; the
  Herdr mod: `.claude/team/herdr-mod/harness-notify/README.md`).

## The agent-mail tool's default project label is `default`

**Before:** the vendored tool kept the upstream's own project name as its default label (the
CLI's `--project` default, the `messages.project` schema default, the store's `project=`
defaults).

**Now:** the default is `default`. The tool's content changed, so `check` reports `tool behind
checkout` for an entry whose `agent_mail-<sha>` copy predates it.

**Action:** none required. The team client passes the entry's `project_label` on every forwarded
call, so no row depends on the default. A box keeps the schema default it was created with.
Re-sync the copy when convenient (`team-mail-setup.sh <repo> --key <KEY> --resync-tool`, an
Operator action).

## The egress guard arms in role sessions and covers more forms

**Before:** `guard-team-egress.sh` armed only inside a team run (`.agents/team/session.json` or
`TEAM_RUN_TEAM`), so the Supervisor, TeamLead and Advisor sessions, which are launched with only
`TEAM_SESSION_ROLE`, ran without it.

**Now:** a set `TEAM_SESSION_ROLE` also arms it. The classifier also asks on `python -m <module>`
(the local test modules pytest/unittest/doctest/py_compile/compileall/json.tool pass), `python -`,
`node -`, a bare `python3 <<EOF`, `npx`/`pipx`/`uvx`, and on git config that points a remote at a
host outside the WebFetch allowlist (`git config remote.<n>.url|pushurl`, `git -c …url=…`,
`url.<base>.insteadOf`, `git push --repo=`). It stays a best-effort guard, not an allowlist.

**Action:** none beyond the starter sync. The settings entry calls `bash
.claude/hooks/guard-team-egress.sh` by path, so the updated file takes effect without re-running
`/setup:teams`. Role sessions now see an egress prompt where they did not before; a host the
roles need goes on the WebFetch allowlist as usual.

## The escalation adapter points at the Advisor's contract

**Before:** the operator kit's `escalate.sh` sent the reply protocol without saying where the
Advisor's rules live, and the starter had no Advisor-facing contract.

**Now:** the protocol header carries one more line, `Contract: .agents/reference/team-advisor.md
(main checkout).`, and `/setup:teams` installs that file (the reply format, tier 3 through the
Operator, the policy-log promotion exception, the solo mode).

**Action:** `bash .claude/team/sessions/operator-kit/install.sh --verify` reports
`differs <kit_dir>/escalate.sh` until the Operator re-applies the kit (`install.sh --apply`).
Until then escalations still work; the Advisor just does not see the pointer.

## The fallback conditions text is English

**Before:** a Reviewer-conditioned fallback typed `<text> — Warunki Reviewer (#<id>): …`.

**Now:** `<text> — Reviewer conditions (#<id>): …`. The payload's `## Reviewer` section names
generic critical grounds (a public contract, a schema or data migration, a sensitive path from
the profile) instead of one project's examples.

**Action:** none. A ledger with the old text stays valid: the `TeamLead-fallback` guard compares
the delivered text with the recorded one, never with a fixed wording, so an undelivered old
fallback is still delivered as recorded.

## The agent-mail tool copy is named by its content

**Before:** the channel step named the copy under `~/.agent-mail/tools/` after the vendored
tool's commit (`agent_mail-<7 hex>`), refused an uncommitted tool, and gave a second project a
second copy of identical content. A `~/…` value in `.claude/codex-profile` was stored as
`$HOME/~/…`.

**Now:** the copy is `agent_mail-<12 hex>`, a hash of the runtime files' names and bytes. A fresh
install finishes in one run, and identical tools share one copy. `~/…` is stored under `$HOME`.

**Action:**

- `bash .claude/lib/team-mail.sh --here check` reports `tool behind checkout (<old> → <new>)` once
  for an entry that still points at a commit-named copy, even when the content is the same. The
  re-sync is an Operator action, as before: run the command the line prints (`--resync-tool`).
  It repoints the entry to the content-named copy; the old directory stays until you remove it.
- An entry or `channel.local.json` whose `codex_home` contains `/~/`: re-run the channel step
  (`/setup:teams`) or correct the path by hand to the real directory.

## Permission classes are off until the profile enables them

**Before:** every deterministic class (`merge-line`, `allow-offline`, `add-ask`, `prod-diagnose`)
was **on** unless the Operator switched it off. `prod-diagnose` existed as soon as its `dir` and
`privileged` were set.

**Now:** a class is active only when `.claude/project-profile.json → teams.policy.classes.<name>.enabled`
is exactly `true` **and** its runtime switch is not off. `team_prompt_classes.py switches <main>`
prints `disabled` for a class the profile does not enable.

**Action:** if your TeamLead relied on a class, enable it in the profile:

```json
"teams": { "policy": { "classes": {
  "merge_line":    {"enabled": true},
  "allow_offline": {"enabled": true},
  "add_ask":       {"enabled": true},
  "prod_diagnose": {"enabled": true, "dir": "scripts/ops/", "privileged": "<regex>"}
} } }
```

What you will see otherwise: ask-tier prompts that used to be answered at tier 1 become Operator actions (`class <name> not enabled`), and the auto-merge gate refuses a PR that adds offline allow entries.

## Protocol headings are English

The headings one file writes and another reads are now fixed English. Prose under them follows the profile's `language` (`pl` | `en`). A run whose wrapup was written before the upgrade keeps the old headings. Read them with this map:

| Old (Polish) | New |
|---|---|
| `## Planowanie` | `## Planning` |
| `## Co ważne dla Ciebie` | `## What matters for you` |
| `## Decyzje nadzorcy` | `## Supervisor decisions` |
| `## Pamięć odłożona (B)` | `## Deferred memory (B)` |
| „Decyzje TeamLead” (READY note section) | "TeamLead decisions" |
| `Decyzje nadzorcy: <n> …` (READY count line) | the same line, in the developer's language |
| `Mergować <team>?` | `Merge <team>?` |
| `Advisor bez odpowiedzi (<reason>)` | `Advisor no reply (<reason>)` |
| dashboard `czeka na odpowiedź` | `waiting for an answer` |

The Operator's words are English (`approve`, `reject`, `answer`, `revoke`). The Polish forms (`zatwierdź`, `odrzuć`, `odpowiedz`, `cofnij`) stay accepted as aliases.
