# Reference: parallel team pipeline — supervisor runbook (TT-781)

Two AI teams on two Jira tickets at once on one Mac. Each team is a git clone
(`../TakeTask.DN-<team>`); planner → coder → qa → wrapup run there as fresh Claude sessions in
tmux, driven by `team-run.sh`. You (the supervisor, in the main checkout) answer blockers, run the
merge check and merge with `/pr-merge`; the wrapup role reconciles memory in the team's PR. Role contract: [team-mode.md](team-mode.md). Why clones
and not worktrees: [parallel-orchestration.md](parallel-orchestration.md) → Step 1.

---

## Quick start

In any Claude window of the main checkout: `/start-team alfa TT-777` (and `/start-team gamma TT-778` in another).
`/start-team` provisions or reuses the clone and launches the runner in tmux; the runner opens a Terminal
preview window on each role it launches (`TEAM_ATTACH=all`, default; `TEAM_ATTACH=planner` opens only the
attended roles' — planner and wrapup). Coder and QA run alone; a macOS notification tells you when a team needs approval, has
a question, is ready for merge, or stopped. After answering: `/start-team alfa`. To look at a role:
`bash .claude/lib/team-attach.sh alfa coder`. Merge: ask the supervisor ("merge alfa").

- **Which mode** (`/start-team alfa TT-801 --mode quick`, fixed per ticket, shown by `status` and
  the dashboard):
  - `brainstorm` (default) — typical tickets: spec + plan, then coder → QA → wrapup;
  - `quick` — small, clear changes: a Codex-reviewed short plan instead of a spec, then the same
    coder → QA → wrapup;
  - `cli` — very simple changes: one unattended session (`opus[1m]` / `medium`) that guards
    eligibility, changes, runs the gates and publishes the PR itself — no QA, no wrapup.

- **Model and effort per role** come from `.claude/team/roles.json` (default: Opus [1M] for all; effort
  planner high, coder medium, qa high). The runner reads it from the main checkout, so a local edit
  applies at the next role launch; commit it to change the default. The qa role's
  `/check-implementation` spawns its two finders on the model and effort pinned in
  `.claude/agents/correctness-reviewer.md` and `.claude/agents/structure-reviewer.md` —
  `roles.json` does not reach them, and a QA stage takes ≈15 min longer per iteration for it. Codex reviews inside
  `/brainstorm`, `/plan-feature` and `/check-implementation` run on the project profile, which the
  runner exports per role session (`CODEX_HOME`) from `.claude/codex-profile`; their config is
  `$CODEX_HOME/config.toml`. A role launched before that change keeps the environment it started
  with ([codex-spawn.md → Codex profile](codex-spawn.md#codex-profile-tt-912)).
  Per ticket, without a commit: `/start-team alfa TT-787 --roles planner=claude-fable-5-1/high`
  (or `bash .claude/lib/team-run.sh alfa roles …` on a running team) writes the clone's
  `.agents/team/roles.override.json`, merged per role and key over `roles.json`; validated at write
  and at each launch, shown by `status`, kept across resumes, archived by `team-next`, removed with
  `roles --clear`. A role already running keeps its model.
- **No window needs to stay open.** On a notification, open the waiting role
  (`bash .claude/lib/team-attach.sh alfa coder` or `tmux attach -t alfa-coder`), answer the
  permission prompt, detach with `Ctrl-b d`. Role windows close by themselves when the role ends
  or when you detach (Ctrl-b d).
- **One window for all teams:** `tmux attach`, then `Ctrl-b s` lists every session — arrows + Enter
  switch. `tmux ls` / `bash .claude/lib/team-run.sh alfa status` peek without attaching.
- **Notifications are sent by `osascript`.** If none appear: System Settings → Notifications →
  Script Editor → Allow notifications.
- **The supervisor session is not notified** unless it runs `/monitor`. `/start-team` returns after
  launching; ask it for "status alfa", "show alfa coder" or "merge alfa" when you want.
- **`/monitor alfa gamma`** (a separate control session is handy) streams progress every 15 s:
  stage changes, records, permission prompts **with the command on the role's screen**, questions,
  runner stops and ready-for-merge; a 30-minute summary on each re-arm. With tiers on (the
  default, TT-799) it answers tier-1 questions itself and prints one line each, sends tier 2 and 3
  to FableTT (who asks you when needed) and brings you only Operator actions (§11). Answer there: "zatwierdź alfa", "odrzuć alfa —
  powód", "odpowiedz alfa: …" (`team-answer.sh` / `team-question.sh`, allow-tier; they act only
  when the role's screen still shows that question); "cofnij alfa q-3 — powód" revokes a
  supervisor answer. `/monitor --tiers off alfa` = the old behaviour: nothing is answered without
  your explicit words.
- **On `ready`, `/monitor` prints a 5-line summary** (team · ticket · what was coded · what it
  gives · QA + PR) plus a `Decyzje nadzorcy:` count line, ending `Mergować <team>?`.
- **Live dashboard in the browser:** `/dashboard` — teams, this session's sub-agents and Codex runs
  on one page (read-only), opened in the default browser. See §10.

## 1. One-time setup

- `brew install tmux jq`
- `chmod 600 .env` — `team-new.sh` refuses to copy a `.env` with any other mode.
- `az login` (the account with Contribute to pull requests on the repo).
- Disk: one clone ≈ the repo plus its `bin/obj` after the first build.
- The runner resolves `.claude/codex-profile` from the role clone first, matching the wrapper
  inside that clone. It falls back to the main checkout only if the clone has no declaration.
  An existing invalid/unresolvable clone declaration refuses before changing `session.json`
  or launching a session; it never falls back to a different profile.
- Never `tmux set-environment -g CODEX_HOME` — the runner sets it per session
  ([codex-spawn.md → Codex profile](codex-spawn.md#codex-profile-tt-912)).

- Clone directory: `teams.clone_name` is a template (default `<repo>-{team}`; `{Team}` is the capitalized team name). The placeholder must END the template, because the clone glob is a prefix. A team name that collides with an existing directory under that prefix is rejected (APFS ignores case).
- Seed files: a tracked file whose content differs is rejected by the `team-new`/`team-next` preflight.
- Installing into an existing project: run `/setup:teams` (manifest-driven), never copy files by hand.

### One Mac, two projects with teams

Give each project its own tmux server through `env.TMUX_TMPDIR` in the project's `.claude/settings.local.json` (seeded into clones). The runner passes `CLAUDE_CONFIG_DIR` and `CODEX_HOME` per session; `team-attach.sh` attaches through the session's socket. Verify with `ps eww -p <pid>`.

## 2. Choose tickets

- Any ticket type — code, docs/harness, or operations (rollout, Azure DevOps admin). Operations run
  inside the coder's `/execute` as plan tasks; production/ADO changes are `ask`-tier, so the run
  pauses on a permission prompt until you approve it in tmux (`needs attention: tmux attach …`).
  This includes deploys (`az webapp deploy`, `az pipelines release create`): read the target
  instance in the prompt before approving. Merging stays the supervisor's `/pr-merge` (no review
  required on `develop-netcore7`; a merge triggers no deploy).
- Two teams at once only for disjoint code tickets: different files, no EF migration in both, no
  runtime (`dotnet run`) needed — the merge check catches textual and build-level breakage only.
- **Operations tickets run one at a time**, never alongside another team, and never two tickets that
  edit the same docs (e.g. TT-777 → TT-778 in sequence). The PR carries only the doc changes; the
  production effect happens at approval time, not at merge.
- Permissions come from `.claude/settings.json` plus your `.claude/settings.local.json`, which
  `team-new.sh` copies into the clone — change the local file before provisioning, not after.
- Target line must carry the harness: `develop-netcore7`. `rc/rc` tickets stay manual;
  `feature/mongodb_implementation` is retired (TT-777).

### Prerequisite

The pipeline runs only after TT-781 itself is merged into `develop-netcore7`: a clone takes its
harness from the base revision, and `team-new.sh` refuses a base without
`.claude/lib/team-record.sh`.

## 3. Provision — once per team, then reuse

Clones are permanent workstations: create `alfa`/`beta` once, then move each to its next ticket.

```bash
bash .claude/lib/team-new.sh  alfa TT-xxx feature/TT-xxx-slug origin/develop-netcore7   # first time
bash .claude/lib/team-next.sh alfa TT-yyy feature/TT-yyy-slug origin/develop-netcore7   # every next ticket
```

Both preflights list every problem at once (tools, `az` login, names, branch pattern, branch
already on origin or used by another team, `.env` mode, harness at base). `team-next.sh` also
refuses while the previous ticket is in flight — runner lock, open `session.json`, live tmux
session, dirty clone, a PR that is not `completed`/`abandoned`, or commits without a PR. It archives
the previous run to `.agents/team/archive/<ticket>-<UTC>/`, cuts the new branch from a fresh
`origin/<line>`, deletes the old local branch and re-copies `.env` and `settings.local.json`.

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
`settings.json` (TT-790); deploy and Azure DevOps commands inside roles stay `ask`.

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

`bash .claude/lib/team-run.sh alfa stop` asks a live runner to stop (up to 90 s), then ends role
sessions and removes the lock. A stale `lock/` (runner killed, `status` says `lock: stale`) →
`bash .claude/lib/team-run.sh alfa unlock`: it removes the lock only when its pid is dead and the
lock is older than 10 s; the runner never removes a lock by itself (that would race a start).

## 6. Merge

```bash
bash .claude/lib/team-merge-check.sh alfa
```

It checks a wrapup finished (a run started before TT-784 gets one on `/start-team <team>`), the PR
source is the wrapup revision, every change after QA is under `.agents/memory/`, no wrapped-up
memory file also changed on the line since the wrapup's `target_rev`, ADO's merge is current (`mergeStatus succeeded`, source
and target commits match the live tips), builds and runs `test-gate.sh` on `refs/pull/<id>/merge`,
and prints `VERDICT` plus `validated source=<sha> target=<sha>`. Right before `/pr-merge <id>`
compare that pair with `git ls-remote origin <branch> develop-netcore7`; a moved tip means rerun.
After merging the first team, rerun the check for the second — its target moved.

**cli mode:** the accepted cli record replaces qa + wrapup — the PR source must be the cli revision;
there are no memory checks. After `/pr-merge` the Jira ticket moves to Done (Step 6a).

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
`.agents/memory/reflection-protocol.md` (default: save nothing), only after the developer accepts.
The supervisor only reviews a memory overlap the merge check reports (§6).

## 8. Pilot checklist (TT-781 acceptance)

- [ ] two disjoint tickets reach published PRs
- [ ] a blocked question answered and resumed
- [ ] a killed session (`tmux kill-session -t '=beta-coder'`) recovered or stopped as designed
- [ ] a failed gate stops publication
- [ ] recorded: tokens, wall time, interventions, rejected work → `.agents/memory/domain/harness.md`
      via the reconciliation PR

## 9. Keep clones

Clones stay; `team-next.sh` reuses them. Remove one only to retire the team or to discard
unfinished work — manually (`rm-in-project.sh` does not reach outside the repo), then `team-new.sh`.

## 10. Dashboard

A local, read-only web page of the whole harness: supervisor session, every team's roles, this
session's sub-agents and live Codex runs, plus an event log. It shows prompts, questions and the
commands to answer them; it cannot act.

**Start:** `/dashboard` in the Claude window of the main checkout whose session the page should
show. It pins that session, starts `serve.sh` in the detached tmux session `dashboard` (it survives
the Claude session), waits until the page answers and opens it in the default browser. Run again →
it only reopens the page; from another session → it restarts pinned to that one. `/dashboard stop`
ends it. Without Claude: `bash .claude/dashboard/dashboard.sh [stop]`, or `bash
.claude/dashboard/serve.sh` in the foreground (`Ctrl-C` stops it and removes its temp dir).

**Env knobs:**
- `TEAM_DASH_PORT` — port (default 8787); a taken port exits with this hint.
- `TEAM_DASH_SECS` — refresh interval (default 3 s).
- `TEAM_DASH_SESSION` — pin the supervisor transcript. Without it `serve.sh` pins the newest one at
  start; set it when several Claude windows run in the main checkout. The id is the transcript file
  name (without `.jsonl`) under `~/.claude/projects/<slug>/`, printed by `serve.sh` at start.

**What it reads** (`.claude/lib/team-snapshot.sh`, one JSON per cycle, `schema: 1`):
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

**Local and read-only:** `server.py` binds 127.0.0.1, serves only `/` and `/snapshot.json`, and
answers 403 to any `Host` other than `127.0.0.1:<port>` / `localhost:<port>` (pane output must not
leak through DNS rebinding). The snapshot lives in a temp dir; nothing is written inside the repo.

**States:** `unknown` — the source could not be read (no transcript, tmux not on PATH, a tmux probe
error other than "no such session"); the footer's `errors` list says why. When `serve.sh` started
with no transcript it pins none, so the supervisor stays `unknown` until you restart it. `stale` (red badge) — the last snapshot is older than 3 × the interval or
the fetch failed (`serve.sh` stopped); the page keeps the last render. `stopped` — the current
role's tmux session is gone. `runner stale` — `lock/` exists but its pid is dead.

**Folding and the "czeka na Ciebie" bar (TT-823).** The bar above the columns lists the snapshot's
`attention[]`, hidden when empty: a role waiting on a permission prompt or a question (the pane
shows a prompt, or the newest `attention` line other than `permission_prompt` is no older than the
role transcript's last write; the pane check covers prompts. Its card's commands follow the pane:
`AskUserQuestion` menu → `pick`/`other`, prompt → `yes`/`no`, else `say`),
a `blocked`/`failed` record (its message, `team-attach.sh` and the resume hint), and a PR ready to
merge (`team-merge-check.sh`, `/pr-merge <id>`); each item names the tmux window. A team whose
runner is `down` (not `stale`) and whose mode's last role is `done` folds into one card from
`teams[].state`: `wolna` (PR `completed`/`abandoned`), `czeka na merge` (PR `active`, highlighted,
also a bar item) or `PR status ?` (ADO unreachable — no bar item). Only for such teams the snapshot
calls `az repos pr show`, time-boxed by `TEAM_DASH_PR_SECS` (4 s) and cached in the server's temp
dir (`TEAM_DASH_CACHE`, exported by `serve.sh`; `completed` for good, other states for 60 s —
`abandoned` included, ADO can reactivate it). After one `az` timeout the rest of that snapshot
skips ADO (`PR status ?`), so a hung ADO costs one timeout per snapshot, not one per finished team.
Finished sub-agents stay cards for 10 min after `finished_at`, then fold into one
`✓ N zakończone` line; the snapshot never drops a finish younger than 10 min, older ones fill the
history up to 12. Which folds are open is kept per browser in `localStorage` (`tt-dash-open`) —
view state only, nothing is written inside the repo.

**Manual live smoke:** with one team on a ticket and a sub-agent spawned in this session, both
appear within one refresh; `tmux kill-session -t '=<team>-coder'` turns that role `stopped` within one
cycle.

## 11. Question escalation tiers (TT-799, TT-852)

Policy: [team-mode.md §10](team-mode.md) (matrix, rules, Operator actions). What the supervisor
does:

- **Tier 1** — answers alone (implementation choices inside the spec/plan, a plan-matching
  permission prompt with no `ask`/`deny` rule) and prints `alfa q-3 (tier 1): <question> → <answer>`.
- **Tier 2 / 3** — `alfa q-3 → FableTT (tier <t>)`: runs `team-escalate.sh` in the background.
  FableTT consults AstraTT and, for tier 3, asks you himself; he relays your decision with
  `decided-by: operator` + an `operator-ref`. The answer is re-checked against the matrix, then
  delivered; an analysts' answer that touches a tier-3 class goes back to FableTT with `--retier`.
- **Operator actions** — `ask`-tier / egress / production prompts, merge, deploy, memory
  acceptance, your scripts, window recovery: `PushNotification` + the command or screen in Polish
  + the offer, as before. Never a decision question.
- **No reply** — `alfa q-3: FableTT bez odpowiedzi (<reason>) — <action>`, printed only when the
  reason changes. The supervisor re-pings FableTT (at most 2 delivered re-pings), then waits
  without a deadline; it never forwards the question to you. `status: pending-operator` from
  FableTT (you were asked) keeps the question in `waiting-operator` — the 30-minute summary lists
  it as "czeka na Operatora u Fable: q-<n>". You can still answer it yourself ("odpowiedz alfa: …").

**Where questions live:** `../<repo>-<team>/.agents/team/runs/<run>/questions/q-<n>.md` (binding,
summary, screen, `## Answer` / `## Revoked` / `## Escalation`), next to `q-<n>.payload.md` (what
FableTT received) and staged replies `q-<n>.reply-<id>.md`; tier 1/2 answers also go to the
notes' `## Supervised decisions` and from there to the PR body, the wrapup's Jira summary
(`## Decyzje nadzorcy`) and the `/monitor` ready line. `bash .claude/lib/team-question.sh alfa list`
prints every question with its tier and state and a `total=` count line.

**Escalation adapter setup:** copy `.claude/team/escalation.local.json.example` to the **main
checkout's** `.agents/team/escalation.local.json` (gitignored) and set:
- `send` — a command that sends the payload to FableTT; it gets `$1` = payload file, `$2` = team,
  `$3` = role, `$4` = q id, `$5` = thread `esc-<run>-<qid>`, `$6` = seq as positional arguments
  (never interpolated; dedup key `$5-$6`); must exit 0;
- `wait` — a command that prints one FableTT reply on the thread: an optional `mail-id: <id>`,
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
re-ping behaviour above — never a question to you. The example's `wait` exits 1 on purpose, so an
unedited copy ends in `NO-REPLY`. The channel itself never appears in the repo.

**Revoke:** "cofnij alfa q-3 — powód" → `team-question.sh alfa revoke q-3 --why "<powód>"`. It
records `## Revoked` and, when the role is idle on the same attempt with no prompt open, types the
revoke text (undo, treat as material, wait); otherwise it says it was not delivered — tell the role
yourself. The question is then tier 3 (you decide).

**Menu keystroke check (once, attended):** in a scratch tmux session with Claude Code, ask a
single-question `AskUserQuestion` with 3 options, run `bash .claude/lib/team-answer.sh <team>
<role> pick 2` and confirm option 2 is chosen; repeat with `other "x"` and confirm the text lands
in `Type something.`. If it misbehaves, answer menus in the window — `pick`/`other` print the
resulting screen, and a still-open menu falls back to an Operator action in the window.
Multi-question menus are always an Operator action in the window.

**Fingerprint stability:** a bound answer requires the role's pane to be unchanged since `open`.
If a dynamic footer (a clock, a spinner) changes the last 40 lines while the role waits, every
bound answer falls back to an Operator action in the window with `stale: screen changed since
open`.

**Latency:** a planner `AskUserQuestion` reaches `/monitor` only through Claude Code's
`idle_prompt` notification, so the supervisor reacts when that fires, not instantly.
