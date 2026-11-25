# Upgrade notes — team layer

Changes that need an action, or a second look, in a project that already runs the team layer.
Newest first.

## The TeamLead runs without your plugin directories (#316)

`team-lead.sh materialize` now writes `env.CLAUDE_CODE_PLUGIN_DIRS = ""` into
`teamlead.settings.json`. The lead therefore loads no mod that you load through
`CLAUDE_CODE_PLUGIN_DIRS`, whether it comes from your settings `env` or from your environment. Since
#311 such a mod (hooks registered in code) refused every lead start; now it keeps working in your
own sessions and the lead starts clean. No action needed. A mod you want inside the lead as well is
not supported. The ASK provenance guard cannot vet code-registered hooks.

## The TeamLead picks the mode; cli is the TeamLead; quick has no wrapup

**Before:** `/start-team` without `--mode` started `brainstorm`; the cli role was a separate
session on `opus[1m]` / `medium` (`teams.roles.cli`, `--roles cli=…` could change it); a quick run
ended with a wrapup. Fable-pinned agents named an older Fable; the correctness finder ran at `xhigh`; the
Step 1.5 Codex review ran on the CLI's default model.

**Now:**
- `/start-team` without `--mode` writes mode `lead`: the run's TeamLead reads the ticket and chooses
  `brainstorm`, `quick` or `cli` before any stage (`team-lead.md` → Mode choice); `status` shows
  `mode: <m> (TeamLead: <reason>)`. `--mode` stays the Operator's override.
- **cli is the TeamLead.** A cli the TeamLead chose resumes its own conversation as the worker
  (`claude --resume`, same Claude config dir); a fixed `--mode cli` starts a fresh session. Both
  run on `teams.sessions.TeamLead` (model/effort) and run `/codex-review` before the PR.
  `teams.roles.cli` and `cli=` set only the permission: a `cli=` model/effort is refused, a
  leftover one in a file is ignored with `warn: cli model/effort override ignored …`.
- **quick has no wrapup:** planner → coder → qa. No memory writes, no follow-up ticket, no tracker
  writes at the end — the ticket moves on merge; the qa copies `## Follow-ups` into the PR. The
  lead's acceptance refuses a `→ follow-up` disposition in quick. A quick run on a clone provisioned
  before this change keeps its wrapup.
- Models: the Fable-pinned agents and skills run Fable 5.2 (`claude-fable-5-2`); the correctness
  finder runs at `high`; `/plan-feature` runs at `effort: medium` (frontmatter); the Step 1.5
  Codex review of `/check-implementation` runs on `gpt-6.2-sol` (`CODEX_MODEL` in `codex-bg.sh`).
- A new ticket needs a base with the new prompts: `team-new` / `team-next` refuse an old base ref
  for mode `lead`, `quick` or `cli` ("pick a current base ref").

**Action:**
1. Remove `model`/`effort` from `teams.roles.cli` in `.claude/project-profile.json` and from any
   `--roles cli=…` habit; set the cli path's model through `teams.sessions.TeamLead`.
2. Make sure the Codex account can use `gpt-6.2-sol` (Step 1.5 of `/check-implementation` fails
   otherwise).
3. Start new tickets from a current line (`origin/<trunk>` after this change has landed).

## Preflight judges the channel only when it is declared (#181)

**Before:** `supervisor-sessions.sh preflight` always ran the team-channel loader and
`operator-kit/install.sh --verify`, so a `/roles` checkout without `teams.channel` printed
`FAIL team channel loads` and `FAIL operator kit installed` and exited 1; a channel value that
failed the names check (a string, an array) made it exit 3 before printing any row.

**Now:** without `teams.channel` (absent or `null`) the two rows read
`ok team channel: not configured (no teams.channel)` and `ok operator kit: not in use (no teams.channel)`,
and preflight exits 0 when the other four rows are green. A `teams.channel` object is judged as
before (the loader, then `install.sh --verify`). A value that is neither an object nor `null`
is `FAIL team channel loads — teams.channel is not an object`, with all six rows printed. An
object whose names do not validate (e.g. a bad `tmux_prefix`) used to stop preflight with exit 3
and no rows; it is now the loader's error in the `team channel loads` row, six rows, exit 1.
Every other `supervisor-sessions.sh` verb keeps refusing invalid channel names (exit 3).

**Action:** none for a healthy setup. A script that read preflight's exit 3 as "invalid channel
names" reads exit 1 and the `FAIL team channel loads` row instead.

## The team-watch daemon is removed (#286)

**Before:** the team-watch daemon (`team-watch.sh` loops and its watchdog in the tmux sessions
`<prefix>-team-watch` and `<prefix>-team-watch-dog`), its SessionStart hook `team-watch-session.sh`,
the pause script `monitoring.sh` with `.claude/team/sessions/monitoring.json`, and the probe template
`.claude/team/watch.local.json.tmpl` rendered by `team-channel.sh render` into
`.agents/team/watch.local.json`. `/setup:teams` installed the Operator `ask` rules for
`team-watch.sh routing|stop|register --takeover|mode answering|mode class` and an allow rule for
`monitoring.sh`; `supervisor-sessions.sh preflight` printed the rows `receivers live`,
`team-watch loops beating` and `mail probe and picked ping per role`.

**Now:** role messages are inbox files rung by the session-host doorbell. `team-watch-send.py`
stays — it is the doorbell's socket sender. `preflight` prints six rows (channel, kit, profiles,
notifications, health check, Claude Code). The class runtime switch is a hand edit:
`classes.<name>: "off"` in `.agents/team/watch/state.json`, keyed by the hyphenated class name
(`{"classes": {"merge-line": "off"}}`, not `merge_line`). `team-channel.sh` has no `render`
verb, and `supervisor-sessions.sh rollback` only prints the Operator steps.

**Action:**
1. A running daemon: `bash .claude/lib/team-watch.sh stop` **before** syncing; kill a leftover
   `<prefix>-team-watch` / `<prefix>-team-watch-dog` session by hand.
2. Rerun `/setup:teams`: it removes the SessionStart hook, the six rules and every unchanged retired
   file; a changed one is reported as a `conflict` — delete it by hand.
3. An installed operator kit: `! bash .claude/team/sessions/operator-kit/install.sh --dry-run`,
   then `--apply`, then `--verify` (its Stop hook no longer asks the daemon, and its health check
   no longer expects the daemon's sessions).
4. Optional: delete `.agents/team/watch.local.json` and the daemon state in `.agents/team/watch/`
   (`events.jsonl`, `deliveries.jsonl`, `acks.jsonl`, `open.*`, `cursor.*`, `receivers/`, `beat`,
   `dog.beat`) — keep `profiles/`, `sessions/`, `automerge/` and `state.json`.

## The roles' Herdr tab is named Supervisor

**Before:** `/roles` put the shipped roles (Supervisor, Fable, Astra) into a Herdr tab named `Lead`.

**Now:** the shipped `place.tab` is `Supervisor`. A team still may not be named `lead` (older
windows keep a `Lead` tab) nor like a role (`supervisor`, `fable` …). `TeamLead` is unchanged: each
team's tab keeps its TeamLead on the left.

**Action:**
1. A profile whose `teams.sessions` roles declare `"place": {"tab": "Lead", …}` keeps its `Lead`
   tab — change those entries to `"Supervisor"` to follow the default (or drop `place` to take it).
2. A Herdr window still open with a `Lead` tab: the next `/roles` puts the roles into a new
   `Supervisor` tab; rename the old tab to `Supervisor` first (or close it once empty).

## A Codex role starts on the CLI's default model

**Before:** `/roles` always launched a Codex role with `-m <model>`. The shipped Astra default,
`"model": "astra"`, is no Codex model: `codex -m astra` fails (`The 'astra' model is not
supported…`), so the role did not start.

**Now:** on a `cli: "codex"` role, `"model": "default"` — or no `model` at all — launches Codex
without `-m`, on the Codex default model of the role's environment (`model` in
`$CODEX_HOME/config.toml`); `-c model_reasoning_effort=<effort>` is always passed. A named model
starts with `-m <model>` as before. Claude roles are unchanged. The start line prints the model:
`Astra: started — model: CLI default · effort high`, or the pinned name; `/status` in the role's
window names the model it runs on.

**Action:**
1. A profile with `"model": "astra"` on a Codex role → change it to `"default"`, or to a current
   versioned name to pin it.
2. Restart the role: `/roles stop Astra`, then `/roles`.

## The TeamLead runs the team tools from the main checkout; follow-ups land on the board

**Before:** the per-run TeamLead called `bash .claude/lib/team-answer.sh|team-lead.sh|team-verdict.sh`
in its clone, so a ticket that changed those files changed how its own lead answered, and a clone
cut before the ask channel was refused at runner start ("clone base lacks the ask channel"). An
operator-tier permission ask was withdrawn at the stage hook's deadline, so an Operator answer that
came later was spent; `decision answer` judged the Operator's reply with its own parser and the
hook with another, so a recorded answer could be refused at delivery; after a lead relaunch the
previous lead's answer no longer verified. Wrapup follow-ups and `/github-sync` issues were created
off the Project board.

**Now:** the lead's prompt and materialised profile name every team tool by the main checkout's
path (the clone spelling is denied), both lead guards are registered from the main checkout, and
the lead's SessionStart `pending` runs the main checkout's `team-lead.sh`. An operator-tier
permission ask whose inputs the checker can pin (its `retry:` key) times out instead of being
withdrawn and is claimed by the stage's retry of the same call; `ask_parse_reply` parses the
Operator's reply on both sides; the runner records every lead session of a run in the main
checkout's anchor (`lead_sessions`) and the answer check reads only those. `create-followup` and
`create-issue` add the issue to the Project; a failed add is a `warning:` line, not an error.
The frontmatter setters keep backslashes and quotes verbatim.

**Action:**
1. Take the change with `/maintain:sync-from-starter` first — `team-tracker.sh` is a core file, not
   in the team manifest, and `/setup:teams` refuses a stale core in its preflight — then run
   `/setup:teams` for the team layer and resolve the conflicts it reports.
2. Pull with no team run active. For an active run, from the main checkout: `bash
   .claude/lib/team-run.sh <team> stop`, then `bash .claude/lib/team-lead.sh end <team>` (the
   runner stop leaves the lead alive and a resume would reuse it with its old profile), update,
   then `/start-team <team>`. Never `team-lead.sh relaunch` on a live lead.
3. A clone on an old base no longer needs a refusal for its sender. It keeps its own SessionStart
   registry hook (which prints the clone's `pending`) until it takes this change; the lead's prompt
   runs the main checkout's `pending` first anyway.
4. Wrapup follow-ups and `/github-sync` issues are added to the Project. A failed add is a warning
   in the wrapup's record and summary, repaired on the wrapup's resume (`project_add: "failed"` →
   `team-tracker.sh project-add <issue>`).

## The TeamLead answers every stop through hooks; the screen sender is retired

**Before:** the per-run TeamLead answered a stage by having `team-answer.sh <team> <role>
yes|no|say|pick|other|picks` capture its pane, parse it, bind it to the transcript and type keys
(a Herdr helper under Herdr); the runner tried a permission prompt at `--authority class` from the
pane and wrote a request file for a human-only one, which the Operator answered in the stage's
window. A tall menu, a sub-agent's prompt or several questions in one call fell back to the
Operator.

**Now:** in a lead run the runner passes each stage `--settings
<clone>/.agents/team/stage-hooks.settings.json` (materialised from the main checkout's
`.claude/team/stage-hooks.json`): `.claude/hooks/team-ask-hook.sh` files every stop as
`runs/<run>/asks/a-<n>.json` and returns the lead's answer as hook JSON. The lead answers with
`team-answer.sh <team> a-<n> --answers|--pick|--text|--allow|--deny … --authority teamlead|operator`;
an operator-tier ask goes through a decision (`decision open --ask a-<n>`) the Operator answers in
the lead's window. Coder and qa may ask in a lead run; planner and wrapup are answered by the lead.
`guard-team-question.sh` is a no-op. The lead can close a run that loses nothing (`team-verdict.sh
run close`). Each run reports `Operator touches: <n>`. The Herdr sender helper is `retired` in the
manifest.

**Action:**
1. Run `/setup:teams` to take the new and changed files (`team-ask.sh`, `team-ask-hook.sh`,
   `stage-hooks.json`, the sender, the runner).
2. A lead run whose clone was cut before this change is refused at its next runner start (exit 4,
   "clone base lacks the ask channel"): finish it on a main checkout from before the change, or
   restart the ticket on a fresh clone (`team-new.sh`). Land the change when no such run needs a
   runner restart.
3. Mode cli and runs without a TeamLead lose the screen sender too: `team-answer.sh <team> <role>
   yes|no|say|pick|other|picks` no longer exists for any caller, and the team snapshot's role card
   offers the stage's window hint (`session-host.sh hint <team>-<role>`) and `/start-team <team>`
   instead of sender commands. Nothing answers such a stage from outside: a prompt or question
   there is answered in the stage's own window. Its stages get no ask hooks, and coder and qa keep
   `AskUserQuestion` disabled.

## `auto` picks Herdr when it answers; a machine without tmux can start sessions

**Before:** `teams.session_host: "auto"` (the default) always meant tmux; Herdr ran only when the
profile said `herdr`. On a machine without tmux, a role or team session that had no registry record
yet failed its liveness probe (`<Role>: failed: liveness probe (exit 1)`), so `/roles` could not
start it even with `session_host: "herdr"`.

**Now:** `auto` starts a session on Herdr when its core answers `hc server status`, else on tmux
(exit 6 with neither). `herdr` and `tmux` still pin one host and never fall back. Without a tmux
binary the tmux liveness probe answers "gone", so a session with no record starts on the configured
host. `/roles status` shows `-` as the backend of a role that has no record.

**Action:**
1. A project on the default `auto` whose operator runs Herdr now gets new sessions in Herdr. To
   keep tmux, set `teams.session_host: "tmux"`. Running sessions keep their host.
2. To get "Herdr, else tmux", set `teams.session_host: "auto"` (or remove the key). `herdr` stays
   strict: a start stops with exit 6 while the core does not answer.

## The session profiles drop the global TeamLead; `TeamLead-run` is renamed (#22, slice 4)

**Before:** `Supervisor.settings.json` and `Advisor.settings.json` denied and sampled
`team-question.sh`, `team-escalate.sh` and `supervisor-sessions.sh answer`;
`TeamLead.settings.json` was the global TeamLead's role profile; the per-run lead's profile was
`TeamLead-run.settings.json`; `/setup:teams` allowed `supervisor-sessions.sh answer *`.

**Now:** the dead rules and samples are gone; `TeamLead.settings.json` is the per-run lead's
profile (the old global file is replaced); `team-lead.sh materialize` refuses a
`TeamLead.settings.json` that is not the per-run profile (env role `TeamLead`, deny `git commit*`
and `team-record.sh*`); `TeamLead-run.settings.json` is `retired`; `/setup:teams` removes the exact
`supervisor-sessions.sh answer *` allow.

**Action:**
1. Sync the changed runtime files and `.claude/team/sessions/` together
   (`/maintain:sync-from-starter`) — a new `team-lead.sh` with the old sessions files refuses to
   materialise, so the next team run stops before its lead starts.
2. Re-run `/setup:teams`: it deletes an unmodified `TeamLead-run.settings.json` (a modified one is
   a conflict — move any project-specific rule into `TeamLead.settings.json`, then delete it) and
   the allow rule.
3. A project that kept its own copy of the global `TeamLead.settings.json` resolves the sync
   conflict to the starter's per-run file.
4. A per-run lead running during the sync keeps its materialised profile; the next launch reads
   the new name.

## The question ledger, `/monitor` and the answer verb are removed (#22, slice 3)

**Before:** the global TeamLead's tier ledger (`team-question.sh` with its parser
`team-question-lib.sh`) recorded team questions and drove the sender through
`team-answer.sh --tier --q --attempt --journal --send --session` and the action `finish`.
`/monitor` was the receiver's handling contract, and `supervisor-sessions.sh answer` answered a
role session's own prompt. No run reached any of it since the global TeamLead's retirement.

**Now:** the per-run TeamLead answers through `team-answer.sh … --authority class|teamlead|operator`
(answers land in `runs/<run>/answers.md`); a TeamLead session's bare call (no `--authority`) is
refused. The Operator's direct call stays. `--expect-event` binds every action, not only `say`. A
stale send lock is removed by hand: the refusal prints its directory; remove it once its pid is
dead. `team-question.sh`, `team-question-lib.sh`, `.claude/commands/monitor.md` and
`.agents/reference/team-questions.md` are `retired` in the manifest.

**Action:**
1. Sync the changed runtime files first (`/maintain:sync-from-starter`), then re-run
   `/setup:teams`: it deletes unmodified copies of the four retired files and reports a locally
   modified one as a conflict.
2. Close any open `/monitor` window.
3. If the team-watch daemon runs, run `bash .claude/lib/team-watch.sh start` in a Claude session
   in the main checkout (single routing) or in the Supervisor role session (split routing):
   `TW_VERSION` is now 3, so `start` replaces the loops still pushing the `/monitor` contract
   (never `stop` first — it deactivates every receiver).
4. The session profiles' entries for `team-question.sh` and `supervisor-sessions.sh answer` went
   in slice 4 (above).

## The role wake loop is retired (#52)

**Before:** `/setup:teams` registered a `Stop` hook (`monitoring-rearm.sh`) that refused to end a
role session's turn while its wake loop (`session-wake.sh`) was not armed, and allowed
`session-wake.sh`. `monitoring.sh` had `ensure` and `armed`; `monitoring.json` declared `wake`
sources and `remind_secs`; the kit's `watch.local.json` carried a `wake_mail` probe.

**Now:** role messages are inbox files rung by the session host's doorbell (`session-host.md`
§12); no loop runs. Both scripts are gone; `monitoring.sh` keeps `start|stop|status|paused`.
With the agent-mail kit, an Advisor reads its mail by hand; the Reviewer's deliver loop is
unchanged.

**Action:**
- Re-run `/setup:teams`: it deletes the two scripts when unchanged (a locally changed copy is a
  conflict to resolve by hand), retires the `Stop` hook and the `session-wake.sh` allow rule.
  Until then, a `settings.json` still naming `monitoring-rearm.sh` shows a hook error at each
  turn end once the file is gone.
- End any armed `session-wake.sh` background task in a running role session.
- Optional: drop `wake` / `remind_secs` from a project-edited `monitoring.json` (ignored now).

## The Advisor escalation path is removed (#22, slice 2)

**Before:** `team-escalate.sh` (with its parser `team-escalate-lib.sh`) sent tier-2/3 questions to
the Advisor through the operator kit's adapter `escalate.sh`, configured by
`.agents/team/escalation.local.json` (rendered from `escalation.local.json.tmpl`). The question
ledger had escalation states and an `orphans` verb, the team snapshot carried `esc_unsent` and
`escalations`, and `supervisor-sessions.sh preflight` had an `escalations have live waiters` row.
Since the global TeamLead's retirement nothing reached that path, but `/setup:teams` still
installed it.

**Now:** the six files are `retired` in the manifest: `team-escalate.sh`, `team-escalate-lib.sh`,
`escalation.local.json.tmpl`, the kit's `escalate.sh`, `escalation-fallback.md` and
`team-advisor.md`. The ledger reads only `## Answer` / `## Revoked` (an old `## Escalation`
section is ignored), `team-question.sh list` prints no escalation counters, the snapshot has no
`esc_unsent`/`escalations`, `team-channel.sh render` writes only `watch.local.json`, the kit
installer no longer copies `escalate.sh`, and the preflight has no waiter row. The question
ledger, `/monitor`, the `answer` verb, the tier tables and the session permission profiles stay
until the next step.

**Action — order first.** `/setup:teams` keeps a differing `own` file as a `conflict` while it
deletes an unmodified `retired` one in the same pass, and an installation's old runtime files still
name the retired ones (`team-question.sh` and `team-snapshot.sh` source `team-escalate-lib.sh`,
`operator-kit/install.sh` copies `escalate.sh`, `team-channel.sh` renders
`escalation.local.json.tmpl`). So:
1. First update every runtime file this release changed: `team-lib.sh`, `team-question.sh`,
   `team-snapshot.sh`, `team-snapshot-teams.sh`, `team-channel.sh`, `team-mail-setup.sh`,
   `supervisor-sessions.sh`, `operator-kit/install.sh` — with `/maintain:sync-from-starter`, or by
   hand-merging each `--check` conflict.
2. Only then run `/setup:teams`: it deletes an unmodified shipped copy of the six removed files and
   reports a modified one as `conflict` (delete or keep it by hand).
3. Check: `bash .claude/lib/team-snapshot.sh >/dev/null`; `bash .claude/lib/team-question.sh
   <team> list` on a live team; with the kit installed, `install.sh --apply` followed by
   `install.sh --verify`.
4. Re-run the kit's `install.sh --apply` (it no longer copies `escalate.sh`), then delete
   `<kit_dir>/escalate.sh` and `.agents/team/escalation.local.json` by hand.

## The global TeamLead is retired: the switch and the team routes (#22)

**Before:** `teams.teamlead.enabled` (default `false`) picked the model. Off, the global TeamLead
session ran `/monitor`, team-watch pushed it the team signals (`ATTENTION <team> …`, `RECORD`,
`RUNNER`, `READY`, `ESCALATION`) and the Advisor's escalation replies, and the wrapup asked its (B)
memory questions through the Advisor.

**Now:** every brainstorm and quick run has its own per-run TeamLead; mode `cli` has none. The
profile key is gone: `true` is accepted as a no-op, `false` is refused by every command that loads
the profile. team-watch has one receiver, the Supervisor (`TW_ROLES`), produces no team or Advisor
signal, and drops unsent any event of those kinds queued before the upgrade and any event addressed
to the TeamLead. A `TEAM_SESSION_ROLE=TeamLead` window is refused as a receiver, a `routing.json`
saying `single TeamLead` reads as `single Supervisor`, the mail guard holds only the Supervisor, and
`supervisor-sessions.sh` neither materializes nor answers a TeamLead. The escalation scripts, the
tier ledger, `/monitor` and the permission profiles stay until a later step.

**Action:**
- Delete `teams.teamlead.enabled` from `.claude/project-profile.json` (`false` is refused).
- End any global TeamLead window and its armed `session-wake.sh` loop.
- If the daemon is used, run `bash .claude/lib/team-watch.sh start` once (the version bump
  restarts it); `team-watch.sh status` names a stale `single TeamLead` routing and its repair.
- Re-run the operator kit's `install.sh --apply` (`--verify` only compares).
- Optional: re-render with `/setup:teams` to drop `mail.TeamLead` / `esc_mail` from
  `watch.local.json` (they are ignored).

## A run end resolves its notifications; the Supervisor closes operator records (#98)

**Before:** a pending decision of a run that was closed or merged stayed on the Herdr strip and in
the overnight batch. An operator record (`release`, `unrepaired_failure`) stayed open until someone
closed it by hand.

**Now:** the runner's `close_run` and `team-lead.sh finalize` run `notify.sh resolve --team <t>
--run <r> --all`, which resolves every event of that run. `--all` is the new form; a bare `--team
--run` is still usage. The Supervisor contract closes each operator record by id
(`operator-record.sh close <id>`) as soon as the Operator has acted on it, and its bootstrap closes
the open records whose step is already done.

**Action:** none.

## The TeamLead decides the wrapup's proposals; the wrapup asks nothing (#104)

**Before:** with a per-run TeamLead the wrapup still asked its ticket and memory menus in its window.
The lead answered through the screen parser, which could not read a checkbox question under Herdr,
so the menu (and two egress prompts of the wrapup's own steps) reached the Operator.

**Now:** with a lead the wrapup writes `wrapup_proposals-<attempt>_<k>.json` and stops with
`team-record.sh --verdict blocked --proposals <file>`. That record carries a `proposals` field. The
lead decides each item in `wrapup-decision-<n>.md` (default no, a cap of one ticket and one memory
entry per run, an optional one-line correction) through `team-verdict.sh wrapup decide`, and every item,
declined ones included, is logged under the new `## Wrapup decisions` heading of its notes. The
runner refuses the wrapup's `done` when it applied an item the lead did not accept. The audit counts
the stop under `records: proposals` (and leaves the wait for the lead out of the wrapup's minutes),
and the team snapshot, `team-watch` and `/roles`' interrupted-runs list show `proposals`, not
`blocked`. The wrapup reads the tracker through `team-tracker.sh` and edits files with the file tools
and `jq`, so its own steps raise no egress prompt. Without a lead nothing changes.

**Action:** none. A script of your own that reads stage records and treats every `blocked` as a
block should skip a record with a `proposals` field.
## The runner reports a session held at a startup dialog

**Before:** a TeamLead or stage started in a new clone directory sat at Claude's folder trust dialog
with no sign from the runner: `team-run.sh <team> status` said `tmux: <session> alive` (also under
Herdr), no `warn:` line, no Operator event, and the stage's execution-time limit kept running.

**Now:** the runner reads a session that reports no status yet against the driver's dialog screens
(`session-host.md` §11). At the folder trust dialog or the MCP servers dialog it prints one `warn:`
line with the hint (Herdr: also the team's tab), `status` shows `<backend>: <session> waiting at …`
and `teamlead: waiting at …`, and one `human_decision` event goes out through `notify.sh` (decision
`dialog-<role>-<attempt>` or `dialog-lead-<launch>`), resolved once the dialog is gone. While a
stage's own dialog is open its limit pauses and no attempt is spent. The dialog is still never
answered by code. The status label names the session's backend (`herdr:` or `tmux:`).

**Action:** none. A script that read the `tmux: <session> alive` status line under Herdr now sees
`herdr: <session> alive`.

## An answer seen elsewhere resolves its notification (#97)

**Before:** the Herdr strip kept an item until it was clicked, cleared or 24 hours old, and an event
held for quiet hours went out in the morning batch even when the Operator had already answered it.

**Now:** `notify.sh resolve (--team <t> --run <r> --decision <d> | --key <k>) [--project <p>]`
marks an event answered elsewhere. It is called by the runner (a human-only prompt answered or
withdrawn in the stage window), by `team-lead.sh decision answer|withdraw` and by
`operator-record.sh close`; a failed resolve never stops them. A resolved event is delivered no
further (`skipped resolved`: a held overnight message leaves the batch; a sent message stays sent).
For a Herdr event it writes `<id>.resolve` into the spool's `new/`, and the strip drops the item.
`notify.sh list` adds `resolved` to such a line.

**Action:** update the Herdr mod (`bash .claude/team/herdr-mod/install.sh`). An older mod ignores
the `.resolve` files, and `notify.sh` removes them after a day.

## The Herdr strip can be cleared, and `--rollback` removes its list (#39)

**Before:** the strip's waiting list lived in Herdr's store, `~/.config/herdr-app/data/harness-notify/store.json`,
outside the mod folder. `install.sh --rollback` left it, so a reinstall showed items from before
(for up to 24 hours), and an item answered elsewhere could only be clicked away one by one.

**Now:** **clear**, at the strip's right end, drops every item. `--rollback` removes
`data/harness-notify/store.json` (and the folder when nothing else is in it), also when the mod
folder is already gone. The 24-hour expiry is unchanged.

**Action:** none. To drop a list left by an earlier rollback, run `install.sh --rollback` once more.

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
  (`teams.session_host: auto | tmux | herdr`). **`auto` was tmux then**: Herdr ran only when
  chosen explicitly (since switched — see the note at the top). A running session stays on the
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
