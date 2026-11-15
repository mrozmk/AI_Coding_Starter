# Reference: parallel team pipeline — supervisor runbook

Two AI teams on two tickets at once on one Mac. Each team is a git clone (`teams.clone_name`,
default `../<repo>-<team>`); planner → coder → qa → wrapup run there as fresh Claude sessions in
tmux, driven by `team-run.sh`. You (the supervisor, in the main checkout) answer blockers, run the
merge check and merge with `/pr-merge`; the wrapup role reconciles memory in the team's PR. Role contract: [team-mode.md](team-mode.md). Why clones
and not worktrees: [parallel-orchestration.md](parallel-orchestration.md) → Step 1.

Human overview (starter repo only, not installed by `/setup:teams`): `docs/teams/03-team-pipeline.md`.

---

## Quick start

In any Claude window of the main checkout: `/start-team alfa ABC-777` (and `/start-team gamma ABC-778` in another).
`/start-team` provisions or reuses the clone and launches the runner. Herdr: the runner places each
role it launches (`TEAM_ATTACH=all`, default; `TEAM_ATTACH=planner` only the attended planner and
wrapup) as a pane in the `Teams` tab of the main checkout's Herdr space, next to the team's
TeamLead; the pane carries the role's own status and closes when the stage ends. tmux: no window
opens; the runner prints `attach: tmux attach -t …` for the planner and the wrapup, and
`bash .claude/lib/session-host.sh hint <team>-<role>` names how to look at any role. Coder and QA run alone; a macOS notification tells you when a team needs approval, has
a question, is ready for merge, or stopped. After answering: `/start-team alfa`. To look at a role:
`bash .claude/lib/session-host.sh hint alfa-coder`. Merge: ask the supervisor ("merge alfa").

- **Which mode** (`/start-team alfa ABC-801 --mode quick`, fixed per ticket, shown by `status` and
  the team snapshot):
  - `brainstorm` (default) — typical tickets: spec + plan, then coder → QA → wrapup;
  - `quick` — small, clear changes: a Codex-reviewed short plan instead of a spec, then the same
    coder → QA → wrapup;
  - `cli` — very simple changes: one unattended session (`opus[1m]` / `medium`) that guards
    eligibility, changes, runs the gates and publishes the PR itself — no QA, no wrapup.

- **Model and effort per role** come from `.claude/team/roles.json` (default: Opus [1M] for all; effort
  planner high, coder medium, qa high). The runner reads it from the main checkout, so a local edit
  applies at the next role launch; commit it to change the default. The qa role's
  `/check-implementation` still reviews inline on the role's own model: the pinned finder agents
  (`.claude/agents/correctness-reviewer.md`, `structure-reviewer.md`, checked by
  `.claude/lib/finder-model.sh`) ship ready, but spawning them in parallel is a planned step. Codex reviews inside
  `/brainstorm`, `/plan-feature` and `/check-implementation` run on the project profile, which the
  runner exports per role session (`CODEX_HOME`) from `.claude/codex-profile`; their config is
  `$CODEX_HOME/config.toml`. A role launched before that change keeps the environment it started
  with ([codex-spawn.md → Codex profile](codex-spawn.md#codex-profile)). The same holds for
  `CLAUDE_CONFIG_DIR`: an optional `.claude/claude-profile` in the main checkout names it, else the
  runner forwards its own value; it is recorded as `claude_config_dir` in the role's `session.json`,
  where the transcript readers (`team-answer`, `team-question`) take it from.
  Per ticket, without a commit: `/start-team alfa ABC-787 --roles planner=claude-fable-5-1/high`
  (or `bash .claude/lib/team-run.sh alfa roles …` on a running team) writes the clone's
  `.agents/team/roles.override.json`, merged per role and key over `roles.json`; validated at write
  and at each launch, shown by `status`, kept across resumes, archived by `team-next`, removed with
  `roles --clear`. A role already running keeps its model. Entry grammar
  `<role>=[<model>][/<effort>][/<auto|manual>]` (e.g. `coder=//manual`); roles launch in auto
  permission mode by default. `/start-team alfa ABC-900 --permission-mode manual` writes
  `coder=//manual qa=//manual` (mode cli: `cli=//manual`; planner and wrapup stay auto) —
  **mandatory for tickets editing
  `.claude/settings*.json`**, which the auto-mode classifier refuses as self-modification. A clone
  without the `guard-team-egress` hook (or an older `claude`) launches manual with a `warn:` line.
- **No window needs to stay open.** On a notification, open the waiting role
  (the line `bash .claude/lib/session-host.sh hint alfa-coder` prints), answer the
  prompt, detach with `Ctrl-b d`. In auto mode reads no longer prompt: what remains are ask-tier
  commands, egress (`guard-team-egress`), menus and questions. Role windows close by themselves when the role ends
  or when you detach (Ctrl-b d).
- **One window for all teams:** `tmux attach`, then `Ctrl-b s` lists every session — arrows + Enter
  switch. `tmux ls` / `bash .claude/lib/team-run.sh alfa status` peek without attaching.
- **Notifications are sent by `osascript`.** If none appear: System Settings → Notifications →
  Script Editor → Allow notifications.
- **The supervisor session is not notified** unless it runs `/monitor`. `/start-team` returns after
  launching; ask it for "status alfa", "show alfa coder" or "merge alfa" when you want.
- **`/tasks-status`** is the Supervisor's on-demand report: what waits for the Operator's decision
  (`waiting-operator` escalations) first, then what waits on the team (`attention[]`, PRs awaiting
  merge), then every open task with its team run and PR state. Nothing is pushed — you ask for it.
- **With a per-run TeamLead** (`teams.teamlead.enabled=true`) the runner starts one lead per run and
  you work from the Supervisor's inbox instead of `/monitor` — §5a.
- **`/monitor alfa gamma`** (global TeamLead — applies only with `teams.teamlead.enabled=false`;
  removed in the retirement step; a separate control session is handy — it is the **TeamLead**) streams
  progress every 15 s: stage changes, records, permission prompts **with the command on the role's
  screen**, questions, runner stops and ready-for-merge; a 30-minute summary on each re-arm. With
  tiers on (the default) it decides every team question outside the Advisor and Operator lists of
  team-decision-model.md §3 and prints one line each, sends only those lists to the Advisor and
  brings you only Operator actions (§11). Answer there: "approve alfa", "reject alfa —
  reason", "answer alfa: …" (accepted aliases: "zatwierdź alfa", "odrzuć alfa — powód",
  "odpowiedz alfa: …"; `team-answer.sh` / `team-question.sh`, allow-tier; they act only when the
  role's screen still shows that question); "revoke alfa q-3 — reason" (alias "cofnij alfa q-3 —
  powód") revokes a supervisor answer. `/monitor --tiers off alfa` = the old behaviour: nothing is answered without
  your explicit words.
- **On `ready`, `/monitor` prints a 5-line summary** (team · ticket · what was coded · what it
  gives · QA + PR) plus a `Supervisor decisions:` count line and a "TeamLead decisions" section,
  ending `Merge <team>?`. The summary's prose is in the developer's language (profile `language`).

## 1. One-time setup

- `brew install tmux jq`
- `chmod 600 .env` — `team-new.sh` refuses to copy a `.env` with any other mode.
- The PR provider's login for `teams.pr_provider` (`gh auth login` for `github`, `az login` for `azure-devops`), with the right to open pull requests on the repo.
- Disk: one clone ≈ the repo plus its build output after the first build.
- Install and channel order for a new machine: `docs/teams/09-setup.md` in the starter (not installed).
- The runner resolves `.claude/codex-profile` from the role clone first, matching the wrapper
  inside that clone. It falls back to the main checkout only if the clone has no declaration.
  An existing invalid/unresolvable clone declaration refuses before changing `session.json`
  or launching a session; it never falls back to a different profile.
- Never `tmux set-environment -g CODEX_HOME` — the runner sets it per session
  ([codex-spawn.md → Codex profile](codex-spawn.md#codex-profile)).

- Clone directory: `teams.clone_name` is a template (default `<repo>-{team}`; `{Team}` is the capitalized team name). The placeholder must END the template, because the clone glob is a prefix. A team name that collides with an existing directory under that prefix is rejected (APFS ignores case).
- Seed files: a tracked file whose content differs is rejected by the `team-new`/`team-next` preflight.
- Installing into an existing project: run `/setup:teams` (manifest-driven), never copy files by hand.

### One Mac, two projects with teams

Give each project its own tmux server through `env.TMUX_TMPDIR` in the project's `.claude/settings.local.json` (seeded into clones). The runner passes `CLAUDE_CONFIG_DIR` and `CODEX_HOME` per session; `session-host.sh hint <team>-<role>` names the attach command. Verify with `ps eww -p <pid>`.

## 2. Choose tickets

- Any ticket type — code, docs/harness, or operations (rollout, Azure DevOps admin). Operations run
  inside the coder's `/execute` as plan tasks; production/ADO changes are `ask`-tier, so the run
  pauses on a permission prompt until you approve it in tmux (`needs attention: tmux attach …`) —
  in auto mode too; the classifier skips only the prompts for ordinary reads and builds.
  This includes deploys: read the target instance in the prompt before approving. Merging stays the
  supervisor's (`/pr-merge` on Azure DevOps, `team-integrate.sh` on GitHub).
- Two teams at once only for disjoint code tickets: different files, no schema migration in both, no
  running app needed — the merge check catches textual and build-level breakage only.
- **Operations tickets run one at a time**, never alongside another team, and never two tickets that
  edit the same docs (e.g. ABC-777 → ABC-778 in sequence). The PR carries only the doc changes; the
  production effect happens at approval time, not at merge.
- Permissions come from `.claude/settings.json` plus your `.claude/settings.local.json`, which
  `team-new.sh` copies into the clone — change the local file before provisioning, not after.
- Target line must carry the harness: `teams.trunk` (or a maintenance line that has it).

### Prerequisite

The pipeline runs only after the team harness itself is on the target line: a clone takes its
harness from the base revision, and `team-new.sh` refuses a base without
`.claude/lib/team-record.sh`.

## 3. Provision — once per team, then reuse

Clones are permanent workstations: create `alfa`/`beta` once, then move each to its next ticket.

```bash
bash .claude/lib/team-new.sh  alfa ABC-xxx feature/ABC-xxx-slug origin/<trunk>   # first time
bash .claude/lib/team-next.sh alfa ABC-yyy feature/ABC-yyy-slug origin/<trunk>   # every next ticket
```

Both preflights list every problem at once (tools, `az` login, names, branch pattern, branch
already on origin or used by another team, `.env` mode, harness at base). `team-next.sh` also
refuses while the previous ticket is in flight — runner lock, open `session.json`, live tmux
session, dirty clone, a PR that is not `completed` (an `abandoned` one only with `--abandoned`,
which keeps the old local branch), a completed PR whose merged source is not the old branch's
local tip, or commits without a PR. The clone fetch, the base and new-branch checks and the
`git switch` to the new branch all run before the archive, so a failure leaves the previous
ticket's state in place. It then archives the previous run to
`.agents/team/archive/<ticket>-<UTC>/`, deletes the old local branch (unless abandoned) and
re-copies `.env` and `settings.local.json`.

```bash
bash .claude/lib/team-remode.sh alfa brainstorm   # quick planner failed "too big for quick"
```

After a quick planner's `failed "too big for quick: …"` record, `team-remode.sh`
restarts the same ticket in brainstorm mode. The Supervisor runs it from the main checkout (with role
sessions, the TeamLead profile denies it). It refuses any other last planner
record, another role's records, an accepted planner record, a non-quick mode, a dirty clone, and
commits or a pushed branch beyond `base_sha`. The checks run before `team-run.sh stop` and again
under the runner lock after it, so a record written during the stop is caught. Then: audit final
`archived`, `runs run acked cancel session.json` move to `archive/<ticket>-remode-<UTC>/`, a new
run starts with the notes carried over, and `team.json` mode becomes `brainstorm`; the branch,
`base_sha` and `roles.override.json` stay. Next: `/start-team alfa`.

## 4. Run

The runner blocks for hours — longer than a Claude Bash call (10 min max) — so start it in its own
tmux session from the main checkout:

```bash
tmux new-session -d -s alfa-runner "bash .claude/lib/team-run.sh alfa; read"
tmux attach -t alfa-runner        # watch; detach with Ctrl-b d
```

or from the supervisor session with `run_in_background`. Attach to the planner
(`tmux attach -t alfa-planner`), answer `/brainstorm` and `/plan-feature`, detach; the runner moves
on to coder, qa and wrapup by itself. With `/monitor` running (tiers on), the planner's questions
can also be answered by the supervisor (tier 1) or the analysts (tier 2), who answer or ask the
Operator themselves; attaching still works. Wrapup opens its window with a plain summary of the run (also
posted as a Jira comment) and asks one question only when it recommends memory or new tickets.

`bash .claude/lib/team-run.sh alfa status` prints team, run, newest record per role, live tmux
sessions, lock holder and the last attention line. All `team-*.sh` scripts are `allow` in
`settings.json`; deploy and Azure DevOps commands inside roles stay `ask`.

## 5. Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | stage(s) advanced; after qa: ready | run the merge check |
| 1 | `failed` record | read the printed reason; fix in the session or relaunch the stage |
| 2 | `blocked` record | attach, answer the question in the session, then `/start-team <team>` (it checks the runner pid, not the tmux session — that outlives the runner on `; read`) |
| 3 | stalled (coder 4 h, cli 4 h, qa 3 h) | attach and look; rerun to keep waiting |
| 4 | `done` record failed validation | read the printed check; fix in the session, rerun |
| 5 | dead session left partial work, or retry limit hit | inspect the clone; decide by hand |
| 6 | cancelled by `stop` | rerun when ready — the stopped session is gone: a stage with no trace relaunches as attempt 2; partial work or attempt 2 → exit 5 |
| 7 | orphan role session without `session.json` | attach or `stop` |
| 8 | closed without merge by the per-run TeamLead (`runs/<run>/closed.json`, event `closed`) | §5a — `closed` |

Every exit also writes the run's audit (team-mode.md §2); `warn: team audit failed` never changes the code.

`bash .claude/lib/team-run.sh alfa stop` asks a live runner to stop (up to 90 s), then ends role
sessions and removes the lock. A stale `lock/` (runner killed, `status` says `lock: stale`) →
`bash .claude/lib/team-run.sh alfa unlock`: it removes the lock only when its pid is dead and the
lock is older than 10 s; the runner never removes a lock by itself (that would race a start).

## 5a. Per-run TeamLead — the Supervisor's runbook

With `teams.teamlead.enabled=true` (not in mode cli) the runner launches one TeamLead per run before
the first stage and keeps it until the run ends; `supervisor-sessions.sh` never starts it. It gates
the spec and plan, answers the stages on an authority, accepts against the order and orders rework;
the contract is [team-lead.md](team-lead.md). Before you rely on it, read the limits in
[team-decision-model.md](team-decision-model.md) §3, "Where the trust ends". What you do:

1. **Order brief.** A NEW run needs one: `/start-team` step 4c writes it with
   `bash .claude/lib/team-brief.sh write <team> <file>` (`## Ticket`, `## Not ordered`,
   `## In-flight work`). Without it the runner exits 4 before any session (team-lead.md §1).
2. **Inbox.** Exactly four events arrive in `<main>/.agents/team/inbox/Supervisor/new/`, each with a
   doorbell to your registered socket. List them with `bash .claude/lib/team-inbox.sh list Supervisor`;
   after acting, `bash .claude/lib/team-inbox.sh done Supervisor <file>`.

   | Event | Means | Run |
   |---|---|---|
   | `accepted` | the lead accepted the delivery and the wrapup is done; the runner printed `ready:` | `bash .claude/lib/team-merge-check.sh <team>`, then (github) `bash .claude/lib/team-integrate.sh <team>` or (ADO) `/pr-merge`; the brief is the event's `ref` |
   | `closed` | the run ended without merge (exit 8); the body says `PR <id> to abandon before team-next` or `clone free` | reason `remode` → `bash .claude/lib/team-remode.sh <team> brainstorm`, then `/start-team <team>`; else abandon the named PR (if any) and free the clone with `team-next` |
   | `collision` | the lead found another team's in-flight work touching this run | answer the lead: `bash .claude/lib/team-inbox.sh write <team> collision-answer --from Supervisor --ticket <k> --run <run> --message "<line>"` |
   | `session_dead` | the lead died, or a stage died with partial work (`ref` = its `.session`) | `/start-team <team>` (it relaunches the lead, or resumes the stage) |

3. **Exit 8.** `closed.json` is written first, so a resume is refused (`run closed (<reason>)`);
   the next ticket is `team-next`, a remode is `team-remode.sh`.
4. **The log.** At merge or close the lead's notes go to `<main>/.agents/team/teamlead-log.md`, one
   block per run (team-lead.md §10): read it to tune rules and the lead's prompt.
5. **Tracker comments before the merge** (opt-in `workflow.tracker_comments: true`, tracker not
   `none`; otherwise skip). After `accepted`, before `team-merge-check.sh` and `team-integrate.sh` /
   `/pr-merge --auto`, run the freshness check of
   [tracker-comments.md](tracker-comments.md) §5 for the run's ticket. The lead is not involved
   after `ready`.
   - Fresh read and snapshot (§2–§3) into your scratchpad.
   - Baseline: the plan's snapshot. The run's `teamlead-acceptance-<n>.json` `tracker` line names
     it as `baseline <artifact>@<rev>`: that artifact's `## From tracker comments` `Read:` line
     gives the path, and `git -C <clone> show <rev>:<path>` gives the file.
   - `--reconciled`: every `<id>@<sha>` of the acceptance gate's own fresh snapshot
     (`runs/<run>[/r<n>]/tracker-acceptance-<n>.json`, newest), because the gate accepted those.
   - `node .claude/lib/tracker-snapshot.mjs compare <baseline> <fresh> --reconciled <list>`:
     exit `0` → merge as before. Exit `3` or `4` (or a failed read) → **no merge** and one Operator
     question: informational (record `- <id>@<sha>: informational — Operator <date>` under
     `## Tracker comments` in the PR description, then merge), or close and restart the ticket
     (`team-next` / a new `/start-team`), or a follow-up ticket. Reopening a ready run for one more
     round is not supported.

The Operator answers human-only decisions in the `<team>-lead` window; you are never asked for a
team question.

## 6. Merge

```bash
bash .claude/lib/team-merge-check.sh alfa
```

It checks a wrapup finished (an old run gets one on `/start-team <team>`), the PR
source is the wrapup revision, every change after QA is under `.agents/memory/`, no wrapped-up
memory file also changed on the line since the wrapup's `target_rev`, ADO's merge is current (`mergeStatus succeeded`, source
and target commits match the live tips), builds and runs `test-gate.sh` on `refs/pull/<id>/merge`,
and prints `VERDICT` plus `validated source=<sha> target=<sha>`. Right before `/pr-merge <id>`
compare that pair with `git ls-remote origin <branch> <line>`; a moved tip means rerun.
After merging the first team, rerun the check for the second — its target moved.
It holds the machine gate lock (§12) from after its local refusals until
the gate ends. Behind another clone's gate it waits up to 30 min; a timeout is exit 3 naming
the holder.

**cli mode:** the accepted cli record replaces qa + wrapup — the PR source must be the cli revision;
there are no memory checks. After `/pr-merge` the Jira ticket moves to Merged or Done (Step 6a).

`memory overlap: <files>` → read those files in the PR against the line; harmless → rerun with
`--memory-reviewed`; a real conflict → fix the memory in the clone, commit and push on the team
branch (memory files only), then rerun with `--memory-reviewed`.

**PR conflicting in memory files** — the provider reports the PR as conflicting
(`team-pr.sh readiness` → `conflict`, GitHub `CONFLICTING`) and every conflicted path is a
union-merged memory log (`git check-attr merge -- <path>` → `union`). `merge=union`
(`.gitattributes`) applies to local merges only; the PR merge on the provider does not rely on it.
The procedure:
1. in the team clone: `git fetch origin`, note the target sha (`git rev-parse origin/<line>`),
   then `git merge --no-ff --no-commit origin/<line>` into the team branch — `--no-commit` because
   with `merge=union` a clean merge would otherwise commit itself before the review in step 2;
   never rebase, never force-push;
2. keep both entries at the top of each conflicted file, the newer one (date in its heading)
   above; same date → the team branch's entry above. `merge=union` always puts the team branch's
   lines first and can drop the blank line between the two entries, so its output is right only
   when the team branch's entry is the newer one. When `origin/<line>` added a newer entry (e.g. a
   `[2026-10-23]` entry from the line must go above the branch's `[2026-10-22]` one), move it above by hand and
   restore the blank line, then `git add -- <edited files>`. Review every touched memory file
   (`rg -n '^## ' <file> | head -5` for the order, `git diff --cached -- .agents/memory/` for the
   rest): date order, a blank line between entries, no entry duplicated or spliced; `git diff`
   must be empty before the commit;
3. commit as `chore(memory): merge <line> into #<ticket> branch, keep both <topic> entries` with
   `Refs #<ticket>` in the body — the issue number, not the PR number; do not push yet;
4. `team-merge-check.sh` refuses this tip **before** its build check (the merge brings files
   outside `.agents/memory/` after wrapup — typically other teams' merged code and tests), so the merged tree is untested. Run the
   profile's build check yourself from the clone root on that commit, with a clean tree
   (`jq -r .teams.build_check .claude/project-profile.json`), then the test gate when
   `jq -r .teams.test_gate .claude/project-profile.json` is not `none`; green = both exit 0. With
   `origin/<line>` an ancestor of the commit, that tree is what the PR merge produces;
5. green → plain push, check `git ls-remote origin refs/heads/<branch>` equals the tested sha;
   the merge is then an Operator action (`team-mode.md` §10): the Operator merges the PR in the
   provider's UI after checking `git ls-remote origin refs/heads/<line>`
   still equals the target sha from step 1 (moved → repeat from step 1). Red → stop, nothing
   pushed; bring the output to the Operator.

A conflict in an excluded memory file (`git check-attr merge` → `unspecified`: `index.md`,
`architecture.md`, …) or in any path outside `.agents/memory/` is not covered —
`git merge --abort`, stop and bring it to the Operator.

## 7. Memory reconciliation

The `wrapup` role does it, inside the team's PR: role hand-offs verbatim, other learnings through
`.agents/memory/reflection-protocol.md` (default: save nothing), only after
acceptance per team-decision-model.md §3. The supervisor only reviews a memory overlap the merge
check reports (§6).

## 8. Pilot checklist

- [ ] two disjoint tickets reach published PRs
- [ ] a blocked question answered and resumed
- [ ] a killed session (`tmux kill-session -t '=beta-coder'`) recovered or stopped as designed
- [ ] a failed gate stops publication
- [ ] recorded: tokens, wall time, interventions, rejected work → `.agents/memory/domain/harness.md`
      via the reconciliation PR

## 9. Keep clones

Clones stay; `team-next.sh` reuses them. Remove one only to retire the team or to discard
unfinished work — manually (`rm-in-project.sh` does not reach outside the repo), then `team-new.sh`.

## 10. Team snapshot

`bash .claude/lib/team-snapshot.sh --out <file>` writes one read-only JSON picture of the whole
harness (`schema: 1`): the supervisor session, every team's roles, this session's sub-agents, live
Codex runs, an event log, and `attention[]` — what waits for a human. It never acts. Its readers
today are the team-watch daemon (`team-watch-lib.sh`, which turns changes into signals) and
`supervisor-sessions.sh` (interrupted runs after a restart). The snapshot lives where its caller
puts it; nothing is written inside the repo.

**Env knobs:**
- `TEAM_DASH_SESSION` — pin the supervisor transcript; unset → the newest one in the main
  checkout's project dir; set but empty → no supervisor (`unknown`). The id is the transcript file name (without `.jsonl`) under
  `~/.claude/projects/<slug>/`. `TEAM_DASH_PROJECT_DIR` overrides that dir.
- `TEAM_DASH_SECS` — the caller's refresh interval, recorded as `interval_secs` (default 3).
- `TEAM_DASH_CACHE` / `TEAM_DASH_PR_SECS` — the PR-state cache dir and the `az` time-box (below).

**What it reads:**
- the pinned supervisor transcript — model and effort of its last real reply (never `<synthetic>`),
  and its skill trail: the last 8 skill starts (`Skill` calls and typed slash commands) from a
  bounded 4 MB tail — "last invoked", never "running now" (a transcript has no skill-end event);
- its sub-agents under `<session>/subagents/` — type, model, effort, `running`/`done`/`idle`
  (`running` also covers a pending tool call — a long build writes nothing until it returns);
  `owner` = the first `/command` in `.claude/agents/<type>.md`'s description, `runs` = its
  preloaded `skills:` + a forked skill's `meta.name` + its own `Skill` calls;
- the live team role's transcript, only when unambiguous (one transcript in the clone's project
  dir started after the launch, whose first prompt names this team, role, run and attempt) — else
  `skills ?` and an `errors[]` line;
- each clone `../<repo>-<team>/.agents/team/` — `team.json`, `run`, `session.json`, records,
  `acked`, `lock/pid`, `attention`; role model/effort are the configured ones from `roles.json`
  merged with the clone's `roles.override.json` — configured values for the next launch; a role
  started before an override change still runs on the old one;
  a blocked/failed role with the runner not `up` adds `resume_hint: /start-team <team>`;
- tmux — whether the current role's session lives and whether its pane shows a permission prompt
  (the same check `team-answer.sh` uses);
- the process table — live `codex exec` runs (`ps`), their log (`lsof`) and its last `STATUS:` line.

**States:** `unknown` — the source could not be read (no transcript, tmux not on PATH, a tmux probe
error other than "no such session"); `errors[]` says why. `stopped` — the current role's tmux
session is gone. `runner stale` — `lock/` exists but its pid is dead.

**`attention[]` and finished teams.** `attention[]` lists a role waiting on a permission prompt or
a question (the pane shows a prompt, or the newest `attention` line other than `permission_prompt`
is no older than the role transcript's last write; the pane check covers prompts — its commands
follow the pane: `AskUserQuestion` menu → `pick`/`other`, prompt → `yes`/`no`, else `say`), a
`blocked`/`failed` record (its message, the `session-host.sh hint` line and the resume hint), and a PR ready to
merge (`team-merge-check.sh`, `/pr-merge <id>`); each item names the tmux window. A team whose
runner is `down` (not `stale`) and whose mode's last role is `done` gets `teams[].state`: `free`
(PR `completed`/`abandoned`), `awaiting merge` (PR `active`, also an `attention[]` item) or
`PR status ?` (ADO unreachable — no item). Only for such teams the snapshot calls
`az repos pr show`, time-boxed by `TEAM_DASH_PR_SECS` (4 s) and cached in `TEAM_DASH_CACHE` when the
caller sets one (`completed` for good, other states for 60 s — `abandoned` included, ADO can
reactivate it). After one `az` timeout the rest of that snapshot skips ADO (`PR status ?`), so a
hung ADO costs one timeout per snapshot, not one per finished team. Finished sub-agents stay listed
for 10 min after `finished_at`; the snapshot never drops a finish younger than 10 min, older ones
fill the history up to 12.

## 11. Question escalation tiers

> **global TeamLead** — applies only with `teams.teamlead.enabled=false`; removed in the retirement step.

Policy: [team-mode.md §10](team-mode.md) (matrix, rules, Operator actions). What the supervisor
does:

- **Tier 1** — TeamLead decides every team question outside the Advisor and Operator lists of
  team-decision-model.md §3 and prints `alfa q-3 (tier 1): <question> → <answer>`.
- **Tier 2 / 3** — only the Advisor list (tier 2) and the Operator list (tier 3) of §3:
  `alfa q-3 → Advisor (tier <t>)`: runs `team-escalate.sh` in the background.
  Advisor consults Reviewer and, for tier 3, asks you himself; he relays your decision with
  `decided-by: operator` + an `operator-ref`. The answer is re-checked against the matrix, then
  delivered; an analysts' answer that touches a tier-3 class goes back to Advisor with `--retier`.
- **Operator actions** — `ask`-tier / egress / production prompts, merge, deploy, your
  scripts, window recovery: `PushNotification` + the command or screen in the developer's
  language + the offer, as before. Never a decision question.
- **No reply** — `alfa q-3: Advisor no reply (<reason>) — <action>`, printed only when the
  reason changes. The supervisor re-pings Advisor (at most 2 delivered re-pings), then waits
  without a deadline; it never forwards the question to you. `status: pending-operator` from
  Advisor (you were asked) keeps the question in `waiting-operator` — the 30-minute summary lists
  it as "waiting for the Operator via the Advisor: q-<n>". You can still answer it yourself
  ("answer alfa: …").

**Where questions live:** `../<repo>-<team>/.agents/team/runs/<run>/questions/q-<n>.md` (binding,
summary, screen, `## Answer` / `## Revoked` / `## Escalation`), next to `q-<n>.payload.md` (what
Advisor received) and staged replies `q-<n>.reply-<id>.md`; tier 1/2 answers also go to the
notes' `## Supervised decisions` and from there to the PR body, the wrapup's Jira summary
(`## Supervisor decisions`) and the `/monitor` ready line. `bash .claude/lib/team-question.sh alfa list`
prints every question with its tier and state and a `total=` count line.

**Escalation adapter setup:** `/setup:teams` → channel renders the **main checkout's**
`.agents/team/escalation.local.json` (gitignored) from `.claude/team/escalation.local.json.tmpl`
with the channel config (`bash .claude/lib/team-channel.sh render`; written only once the operator
kit's adapter `<kit_dir>/escalate.sh` exists, without `opinion` under `advisor: solo`; a file
without the template's `_generated` marker is never replaced). Its operations:
- `send` — a command that sends the payload to Advisor; it gets `$1` = payload file, `$2` = team,
  `$3` = role, `$4` = q id, `$5` = thread `esc-<run>-<qid>`, `$6` = seq as positional arguments
  (never interpolated; dedup key `$5-$6`); must exit 0;
- `wait` — a command that prints one Advisor reply on the thread: an optional `mail-id: <id>`,
  `status: answer|pending-operator|withdrawn`, optional `author:`, `decided-by:
  analysts|operator`, `operator-ref: <note> sha256:<prefix>`, `eta:`, a blank line, the body. It
  stages the reply to `<dir of $1>/<qid>.reply-<mail-id>.md` **before** acking it, so a crash
  replays it. For `decided-by: operator` it verifies the `operator-ref`: a note under the
  channel's `decisions/`, whose sha256 starts with the prefix, containing the exact line
  `thread: <thread>` and an `Operator decision:` line; a failed check is published as
  `status: unverified-operator-ref`;
- `timeout_min` — 1–240, bounds each `send` and the wait for a first reply; the whole process
  group is killed past it. After `pending-operator` the wait has no deadline.

No file, invalid JSON, a failing or hanging command or an unparseable reply → `NO-REPLY` and the
re-ping behaviour above — never a question to you. No adapter yet → no file → `NO-REPLY no
config`. The channel's machine paths never appear in the repo.

**Revoke:** "revoke alfa q-3 — reason" (alias "cofnij alfa q-3 — powód") →
`team-question.sh alfa revoke q-3 --why "<reason>"`. It
records `## Revoked` and, when the role is idle on the same attempt with no prompt open, types the
revoke text (undo, treat as material, wait); otherwise it says it was not delivered — tell the role
yourself. The question is then tier 3 (you decide).

**Menu keystroke check (once, attended):** in a scratch tmux session with Claude Code, ask a
single-question `AskUserQuestion` with 3 options, run `bash .claude/lib/team-answer.sh <team>
<role> pick 2` and confirm option 2 is chosen; repeat with `other "x"` and confirm the text lands
in `Type something.`. If it misbehaves, answer menus in the window — `pick`/`other` print the
resulting screen, and a still-open menu falls back to an Operator action in the window.
Multi-question menus are always an Operator action in the window.

**Prompt binding:** a bound answer requires the same *prompt instance*, not the same
screen. The `v2:` fingerprint covers only the active prompt's content (header, description,
command lines as rendered, reason, question, options), so spinners, counters and log lines above
it never refuse; a changed argument, option or order, a re-wrapped command after a resize, a new
pane generation, `session_id`, attempt or run, or a new transcript `tool_use` for an identical
prompt (ABA) refuses with zero keys. A clipped or unknown prompt is `unreadable` and two
identical pending calls are `ambiguous` — both are Operator actions. The egress gate refuses a
`Fetch`/`WebFetch` prompt and any Bash command naming `curl`, `wget`, `ssh`, `scp`, `rsync` or `nc`
as a word, also as a path segment (`tools/curl/…`): such a false positive costs one Operator
action by design. Delivery states and `retry`: [team-questions.md](team-questions.md) item 3.

**Prompt binding check (once, attended):** in a scratch tmux session with Claude Code on a test
role, trigger a harmless `echo binding-check` permission prompt, run `team-question.sh <team> open
<role> --kind permission --anchor "echo binding-check" --summary x`, let some output change above the
prompt (a spinner or a new log line is enough), then `answer q-<n> --tier 1 --author
supervisor --why test --send yes`: it must deliver once and end `state=consumed` with
`confirmed: yes (tool_result)`; a second `answer` must say `already answered`. Team roles report
this check `SKIPPED` (team-mode §9).

**Latency:** a planner `AskUserQuestion` reaches `/monitor` only through Claude Code's
`idle_prompt` notification (an `ATTENTION` event of the 15 s poll), so the supervisor reacts when
that fires, not instantly.

## 12. Machine gate lock and run audit

**Machine gate lock.** One full gate run per machine at a time: parallel builds and test runs of
several clones starve each other. `.claude/lib/gate-lock.sh` (+ `gate_lock.py`) holds
`~/.agent-ops/locks/test-gate` (`TEAM_GATE_LOCK_DIR`): a FIFO queue of tickets, one holder
published by a rename, a stale holder reclaimed only when no process of its group still runs a
gate. `team-merge-check.sh` takes it after its local refusals and holds it to the end of the test
gate (timeout → exit 3 naming the holder); the QA and cli roles run the gate as
`bash .claude/lib/test-gate.sh`, which queues behind it and then runs the project's
`teams.test_gate` (a caller that already holds the lock passes `TEAM_GATE_LOCK_TOKEN` and is not
queued again). Waits are bounded by `TEAM_GATE_LOCK_WAIT` (1800 s) and visible: `lock waited
<n>s` and `load avg:` lines, copied into the QA report's `Load:` line. The lock is machine-wide on
purpose — two projects on one Mac queue behind each other. A project whose gate starts its own
build tools names them in `TEAM_GATE_LOCK_WORKLOAD` (a regex, e.g. `dotnet (build|test)`), so a
crashed holder's surviving build keeps the lock. Smoke: `.claude/lib/tests/gate-lock-smoke.sh`.

**Run audit.** `team-audit.sh` writes `<main checkout>/.agents/team/audit/` from the runner's exit
trap and from `team-next.sh` (team-mode.md §2); config `.claude/team/audit.json`. It is material
only — never a gate. **Retro is off by default**: only with `teams.audit.retro: true` in the
project profile does a flagged or sampled final run get one detached, report-only `/retro` in tmux
`retro-<run>` (prompt `.claude/team/prompts/retro-run.md`) — a Claude session, so a cost the
project opts into; `audit.json` keeps only its knobs (`on_flag`, `sample_every_clean`, model).

**Team supervision layer.** The question ledger, the tiers and the escalation adapter work from
one `/monitor` window. The durable signal daemon is [team-watch.md](team-watch.md): with its loops
running, it pushes `[team-watch #<n>]` batches into the registered role sessions, and `/monitor`
is the handling contract of those messages (the single window starts the daemon itself). The role
sessions — launcher, profiles, preflight — are [supervisor-sessions.md](supervisor-sessions.md);
the operator kit is a separate layer.

## 13. Tests

Starter repo only: the team layer's tests are not distributed, so a downstream has none of this.
The one gate is `.claude/lib/tests/team-suite.sh`. It runs purity, every smoke part by name
(serial parts last, alone), the standalone suites, the agent-mail unittest and the role-profile
check, and prints `ok <step> <n> checks` per step (0 checks is a FAIL). It refuses to start with
the real `HOME` or the system `TMPDIR`, and it resolves the starter root from its own path, so it
runs from any directory:

```bash
HOME=<scratch>/home TMPDIR=<scratch>/tmp/ bash .claude/lib/tests/team-suite.sh [--parallel] [--keep-going] [--out <dir>]
```

The redacted log (`<out>/suite-<utc>.log`) passes the purity deny-list and can be pasted into
evidence. Part 11 is load-sensitive, so run the suite while nothing else runs tests.
