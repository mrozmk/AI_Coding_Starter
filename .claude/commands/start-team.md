---
description: Start (or resume) a parallel AI team on a ticket — provision or reuse its clone, launch the runner (Herdr: a tab per team, its TeamLead and the working stage; tmux: an attach hint line)
argument-hint: "<team> [key] [branch] [--mode brainstorm|quick|cli] [--brief \"<text>\" | --brief-file <path>] [--roles <role>=<model>[/<effort>][/<permission>] …] [--permission-mode manual] [--follow-up-of <key>] [--takeover]  (e.g. alfa AB-777 · alfa 7 --mode quick · alfa --brief \"Fix X\" · alfa — resume · alfa AB-787 --roles planner=claude-fable-5-2/high · alfa AB-900 --permission-mode manual)"
allowed-tools: Bash(bash -c source .claude/lib/team-profile.sh:*), Bash(bash .claude/lib/team-tracker.sh:*), Bash(bash .claude/lib/team-new.sh:*), Bash(bash .claude/lib/team-next.sh:*), Bash(bash .claude/lib/team-lineage.sh:*), Bash(bash .claude/lib/team-brief.sh:*), Bash(bash .claude/lib/team-lead.sh:*), Bash(bash .claude/lib/team-run.sh:*), Bash(bash .claude/lib/session-host.sh:*), Bash(git rev-parse:*), Bash(test:*), mcp__atlassian__jira_get_issue, Bash(bash .claude/lib/costs/runtime-mark.sh:*), Bash(bash .claude/lib/team-claim.sh:*), mcp__atlassian__jira_get_transitions, mcp__atlassian__jira_add_comment, mcp__atlassian__jira_transition_issue, AskUserQuestion, Bash(jq:*), Bash(mv:*), Bash(node .claude/lib/tracker-snapshot.mjs:*)
---

# /start-team — run a team on a ticket

Arguments: **$ARGUMENTS** — `<team> [key] [branch] [--mode <mode>] [--brief <text>|--brief-file <path>] [--roles <entries…>] [--permission-mode manual] [--follow-up-of <key>] [--takeover]`. Supervisor command: run it in the **main
checkout**, from any Claude window. Runbook: `.agents/reference/team-pipeline.md`.

## Guardrails

- Refuse inside a team clone (`.agents/team/team.json` at the repo root) — teams never start teams.
- Never delete a clone, never touch another team, never answer a team's questions for the user.
- A refusal from `team-new.sh` / `team-next.sh` is printed verbatim — fix nothing on your own.
  An exit 9 (the follow-up cap) is never retried under another key, another team or without
  `--follow-up-of`. `team-lineage.sh` stays callable from this session: its `consent` needs a
  terminal or the Operator's own typed message in this window, so it is not a deny-list entry.
  Never run `consent` on your own words or on a message without the phrase `consent <KEY>`.
- A claim refusal or a lost race (step 3b) is printed verbatim and never retried under another
  key, team or branch. `--takeover` only when the Operator wrote it in this invocation — never
  added on your own.

## Steps

0a. **Profile preflight** — before the clone and before `tmux`:
   `bash -c 'source .claude/lib/team-profile.sh; team_profile_load; team_profile_require_supported;
   echo "trunk: $TEAM_TRUNK"; echo "tracker: $TEAM_TRACKER"'`.
   Non-zero exit → print its `error:` line verbatim and stop (no clone, no branch, no tmux session).
   `TEAM_TRUNK` is the trunk used in step 4; `TRACKER` (the `tracker:` line, one of `jira`,
   `github`, `none`) decides steps 1, 3, 3b and 4. The ticket's mode decides step 4c and the brief
   check in step 2: a per-run TeamLead in every mode except a `cli` the Operator fixed with
   `--mode cli` (a cli the TeamLead chose resumes the lead's own conversation).

1. **Parse.** `TEAM` = first argument (`[a-z0-9-]+`). A `TEAM` equal to a roles tab (`lead`, or
   any `teams.sessions` `place.tab`, case-insensitive) → STOP before any side effect: "team name
   `<TEAM>` is the roles' Herdr tab — each team gets a tab named after it; pick another name"
   (`team-new.sh` and the runner refuse it too). `KEY` = second (optional, shape per `TRACKER`:
   `jira` → `[A-Z]+-[0-9]+`; `github` → `[0-9]+`, a leading `#` dropped (`#7` = `7`); `none` → no
   `KEY` at all, the ticket comes from `--brief`),
   `BRANCH` = the next positional after `KEY` (optional): third for `jira`/`github`, second for
   `none` (`<team> [branch]`). `ROOT` = `git rev-parse --show-toplevel`;
   `CLONE` = the single resolver's answer:
   `bash -c 'source .claude/lib/team-profile.sh; team_profile_load; team_clone_dir <TEAM>'`
   (it honours `teams.clone_parent`; never build the path by hand).
   Before the positional parse, remove `--roles` and only its consecutive `role=value` tokens
   into `ROLES`. The first token without `=` ends that list and remains a positional argument
   (including a trailing `BRANCH`); do not consume all words after `--roles`. Keep invalid role
   names and values in `ROLES` for the existing `team-run.sh … roles` validation in step 4a.
   `--roles` with no entry → stop and ask. For example,
   `/start-team alfa ABC-791 --roles planner=claude-fable-5-2/high chore/ABC-791-team-next-retry-guard`
   keeps `chore/ABC-791-team-next-retry-guard` as `BRANCH`. Map the user's wording to roles:
   brainstorm/spec/plan = `planner`,
   implementation = `coder`, review/QA = `qa`, summary = `wrapup`. Entry forms:
   `<role>=<model>/<effort>`, `<role>=<model>`, `<role>=/<effort>`, and a third segment
   `<role>=[<model>][/<effort>]/<auto|manual>` for the permission mode (e.g. `coder=//manual`).
   `--permission-mode manual` is taken out before the positional parse too (like `--mode`) and
   expands to `coder=//manual qa=//manual` for modes `brainstorm`/`quick` (`cli=//manual` for mode
   `cli`; `coder=//manual qa=//manual cli=//manual` in mode `lead`, whose choice is not known yet), merged into `ROLES` after the explicit entries; planner and wrapup stay auto (they write
   only spec/plan and memory), a ticket whose planner must edit settings uses `--roles
   planner=//manual`. Any other value, or no value →
   stop and say "only `manual` (auto is the default)". Roles launch in auto mode by default
   (`roles.json`); **`--permission-mode manual` is mandatory for tickets editing
   `.claude/settings*.json`** — the auto-mode classifier refuses that as self-modification.
   `MODE` = the word after `--mode`, also taken out before the positional parse; default `lead`
   (the TeamLead chooses — never classify here). A value outside `brainstorm|quick|cli`, or
   `--mode` with no value → stop and say the allowed values. `--mode` is the Operator's override;
   the TeamLead's criteria are in `.agents/reference/team-lead.md` → Mode choice.
   `--brief "<text>"` / `--brief-file <path>` are taken out the same way, before the positional
   parse — for `TRACKER=none` they *are* the ticket (there is no key to name).
   `FOLLOW` = the key after `--follow-up-of` (the ticket this one follows up; a leading `#`
   dropped), taken out the same way; no value → stop and ask.
   `TAKEOVER` = `--takeover` present, taken out the same way (a flag, no value); with
   `TRACKER=none` say "no claim with tracker none — `--takeover` ignored".
   **This run is NEW** when `KEY` is given, or (only `none`) when `--brief`/`--brief-file` is given;
   otherwise it is a **RESUME** (step 2). Refuse:
   - `--brief`/`--brief-file` with `TRACKER` = `jira` or `github` → "`--brief` is for tracker=none —
     name the ticket key instead";
   - `--mode` on a RESUME → "mode is fixed per ticket — `/start-team <team> <KEY> --mode …`
     (tracker=none: `--brief …`) starts a new one". `/start-team alfa --brief "Fix X" --mode quick`
     is NEW, so it is allowed;
   - `--follow-up-of` on a RESUME → "the lineage is fixed at the start — the clone's `team.json`
     carries it";
   - `--takeover` on a RESUME → "`--takeover` is for a new start";
   - a `--roles` `cli=` entry with a model or effort → "the cli path runs on the TeamLead's model
     (`teams.sessions.TeamLead`); drop it from --roles" (`cli=//manual` from `--permission-mode
     manual` is allowed).

1a. **ASK provenance preflight** — for every start whose run has a per-run TeamLead: a NEW
   start with `MODE` ≠ `cli`, and a RESUME whose ticket's `mode` in
   `<CLONE>/.agents/team/team.json` is not `cli` (fixed or chosen by a lead: the runner launches
   no lead for either).
   Before the claim, the clone and the runner: `bash .claude/lib/team-lead.sh preflight <TEAM>`.
   Exit 3 → print its `error:` and `fix:` lines verbatim and stop — no claim, no clone, no
   runner: a lead launched now could not take the Operator's dialog answers, and the runner
   would refuse to launch it. Never work around it (no `--mode cli` on your own, no settings or
   plugin edit): the Operator makes the fix and starts again. Exit 0 prints
   `ask provenance: clean` (`.agents/reference/team-lead.md` §7 → Provenance guard).

2. **RESUME** (no `KEY`, and for `none` no `--brief*` either). `CLONE` must exist. Never call
   `team-tracker.sh read` here: a resume allocates nothing, and the ticket it continues is already in
   `<CLONE>/.agents/team/ticket.json` (`github`/`none`) or in Jira. With `ROLES` → step 4a first, then run
   `bash .claude/lib/team-run.sh <TEAM> status`:
   - a line `closed: <reason>` → refuse "run closed (<reason>) — team-next for the next ticket,
     team-remode for remode" and stop (the runner refuses it too, `runs/<run>/closed.json`);
   - a line `lock: runner <pid> alive` → if the status also shows `teamlead: dead`, run
     `bash .claude/lib/team-lead.sh relaunch <TEAM>` (it writes `<CLONE>/.agents/team/relaunch-lead`;
     the live runner relaunches the lead at its next poll), report "TeamLead relaunch requested"
     and stop; otherwise say "runner already running — watch:
     `bash .claude/lib/session-host.sh hint <TEAM>-runner`" and stop;
   - a line `lock: stale (pid … dead)` → `bash .claude/lib/team-run.sh <TEAM> unlock` (deliberate;
     the runner never removes a lock by itself);
   - then, if `bash .claude/lib/session-host.sh alive <TEAM>-runner` exits 0 — only an idle shell
     on `; read`, since the runner is dead — `bash .claude/lib/session-host.sh kill <TEAM>-runner`.
     A live session alone never
     means a live runner: it outlives the runner after a `blocked` record.

   With the ticket's mode not a fixed `cli` (`mode` in `<CLONE>/.agents/team/team.json`; a cli
   with `mode_choice` was chosen by a lead and has its brief): `bash .claude/lib/team-brief.sh check <TEAM>` must pass;
   otherwise write the brief first as in step 4c (`write`, never `--replace`).

   Record the start, before the runner: `bash .claude/lib/team-lineage.sh record <ticket> <TEAM>`
   plus `--follow-up-of <parent_ticket>` when that field of `<CLONE>/.agents/team/team.json` is set
   and `--ticket-file <CLONE>/.agents/team/ticket.md` when that file exists (its body line carries
   the origin; without it the start is counted under the parent) (`<ticket>` = its `ticket`). It prints `already recorded` (exit 0) for a counted start and
   records one whose record failed at step 4. Exit 9 → as in step 4; any other non-zero → print it
   and stop.

   Then go to step 5 (launch the runner) and report which stage it resumed.

3. **Ticket + branch name.**

   **`TRACKER=jira`** (only when `BRANCH` is not given). `mcp__atlassian__jira_get_issue(KEY,
   fields="summary,issuetype,labels,description")`; read it this way on every NEW run, also with
   `BRANCH` given, for the follow-up line below. Kind: `Bug` → `bugfix`; labels `harness`, `deploy`,
   `consolidation` or a config-only summary → `chore`; a docs-only summary → `docs`; otherwise
   `feature`. `type` = the kind as one of `teams.branch_types`, by the adapter's rule (the first
   synonym the list holds — `feature`: feature, feat · `bugfix`: bugfix, fix, bug · `docs`: docs,
   doc, documentation, chore · `chore`: chore; none → the list's first entry, and say so). Slug: the summary
   in **English**, kebab-case, 3–6 words, `[a-z0-9-]` only. `BRANCH` = `<type>/<KEY>-<slug>`.
   Jira unreachable → stop and ask for the branch as the third argument.
   A description line `Follow-up of <parent> · origin <origin>` → `FOLLOW` = `<parent>`; a
   `--follow-up-of` that names another key → stop and ask the Operator which. Jira has no
   `ticket.md`, so the line's `origin` part is not checked against the ledger (the origin comes
   from the ledger's record of the parent, or is the parent itself).

   **`TRACKER=github` / `none`** — read the ticket **unconditionally** on every NEW run, also when
   `BRANCH` was given (step 4 needs the file either way); only the slug is conditional:
   `bash .claude/lib/team-tracker.sh read <KEY> --out .agents/team/incoming/<TEAM>`
   (`none`: `bash .claude/lib/team-tracker.sh read --brief "<text>"|--brief-file <path>
   --out .agents/team/incoming/<TEAM>`). Non-zero exit → print its `error:` line verbatim and stop,
   **before** the clone. From its output take `KEY` (`key=`, for `none` the allocated `L<n>`), `type`
   (already one of `teams.branch_types`; a `warning:` line means no synonym matched and the list's
   first entry was used — show it) and `title`; then, only when `BRANCH` is not given, slug = the title in **English**, kebab-case,
   3–6 words, `[a-z0-9-]` only, and `BRANCH` = `<type>/<KEY>-<slug>`.

3b. **Claim the ticket** (NEW runs only; after step 3, before step 4 — no clone and no branch
   names the ticket until this passes). Another machine or team may be starting the same ticket:
   the first unreleased claim comment wins, and only the winner moves the status. Keep `CLAIM_ID`
   and the printed `previous` for step 4. First: `<CLONE>/.agents/team/team.json` already names
   `KEY` → stop before any claim: "this clone already runs `KEY` — resume with `/start-team
   <TEAM>`" (`team-next.sh` would refuse the same ticket anyway). `TRACKER=none` → one line
   "tracker none: no shared signal, the start continues as before" and skip this step. The
   protocol, the grammar and the release order: `.agents/reference/team-pipeline.md` → Claim at the
   start.
   - **Check.** github: done by the one `team-claim.sh claim` call under Claim (it checks first).
     jira: read `mcp__atlassian__jira_get_issue(issue_key=KEY,
     fields="summary,issuetype,labels,description,status", include="comments", comment_limit=100)`,
     save the result to a scratchpad file and judge it with the existing predicate —
     `node .claude/lib/tracker-snapshot.mjs snapshot --jira <result> --limit 100 --out
     <scratch>/snap.json` → its `.status` (`.agents/reference/tracker-comments.md` §3):
     `possibly-truncated` → stop: "claim history may be truncated"; `unknown` (no comments) is
     accepted only here in Check (a fresh ticket), never in Confirm or the release, which need
     `complete`. Then `bash .claude/lib/team-claim.sh refs <KEY>` (remote branches and open PRs
     carrying the key), and the claim records — one tab-separated line `<created>\t<id>\t<last
     line>` per comment whose last non-empty line contains `team:claim`, nothing else of the
     comment — into a scratchpad file → `bash .claude/lib/team-claim.sh holder --lines <f> --who
     <TEAM>`. Refuse with one line naming the status, the PRs, the branches and the holder when
     the status category is `In Progress` or `Done` (unless the holder is ours or `TAKEOVER`), a
     foreign holder exists (unless `TAKEOVER`), or `refs` printed a `branch` or `pr` line (unless
     the holder is ours — an own claim's pushed refs do not refuse; with `TAKEOVER` only a branch
     equal to `BRANCH` still refuses). **Held** (`self=yes`): reuse that
     claim's `id` and its marker's `previous` as `CLAIM_ID` / `previous` (the marker stores it
     percent-encoded: decode it, `To%20Do` → `To Do`, before any comparison or transition — here
     and in step 4's release), post nothing in Claim,
     confirm that exact id, and skip the transition when the status already is
     `jira.started_status` — the crash-recovery path, never a second claim; a status that is
     neither that `previous` nor `jira.started_status` (e.g. Done) → refuse "held here but the
     status moved on", nothing written.
   - **Claim.** github: `bash .claude/lib/team-claim.sh claim <KEY> --who <TEAM> --branch <BRANCH>
     [--takeover]` (checks, posts the claim comment, confirms, then moves the winner's status;
     an own unreleased claim prints `held` and posts nothing). Exit 3 → print the `refused:` line
     verbatim and stop before step 4; exit 4 → print it and stop (the script has posted the
     release itself); exit 2 → print it and stop. jira (skipped when Check found our own claim —
     **Held**): `jira.started_status` missing from `.claude/project-profile.json` → ask once
     (`AskUserQuestion`, the target statuses of `mcp__atlassian__jira_get_transitions(KEY)` as
     options), write it with `jq` (temp file in `.claude/`, then `mv`, every other key kept) and
     append `## <date> — jira.started_status` with one `**Decision:**` line to
     `.agents/memory/decisions.md` (as `/qa-verify` Step 0.2 does for its pool status); then
     `bash .claude/lib/team-claim.sh body claim --who <TEAM> --branch <BRANCH> --previous "<status
     name>" --format jira [--superseded <id|status>]` → `mcp__atlassian__jira_add_comment` with
     that body; `CLAIM_ID` = the marker's `id`. A failed comment → post `bash
     .claude/lib/team-claim.sh body release --id <CLAIM_ID> --reason post-failed --format jira`
     the same way, stop. The Jira writes stay `ask`-tier: the Operator's prompt is the gate.
   - **Confirm.** github: inside the same call — its `claimed`/`held` line and `status:` line.
     jira: re-read as in Check (the snapshot `.status` must be `complete`, else post the release
     body and stop) → `holder`; holder id ≠ `CLAIM_ID` → post the release body for `CLAIM_ID`
     (`--reason lost-race`) and stop naming the holder — never transition; holder id = `CLAIM_ID`
     → status already `jira.started_status` → no transition (unchanged); else
     `mcp__atlassian__jira_get_transitions(KEY)` → the transition whose target is
     `jira.started_status` → `mcp__atlassian__jira_transition_issue` with `comment="Started —
     claim <CLAIM_ID>"` (`guard-jira-transition.sh` rules apply). No such transition, a guard
     refusal or a declined prompt → post the release body (`--reason status-failed`) and stop,
     naming the status and the available transitions.

4. **Clone.** `CLONE` absent → `bash .claude/lib/team-new.sh <TEAM> <KEY> <BRANCH>
   origin/<TEAM_TRUNK> <MODE>` (the base-ref is `origin/` plus the trunk from step 0a); present →
   `bash .claude/lib/team-next.sh …` with the same arguments. For `github`/`none` append
   `--ticket-file .agents/team/incoming/<TEAM>/ticket.json` (the file from step 3; `jira` passes none),
   and `--follow-up-of <FOLLOW>` when set (for `github`/`none` the script also reads the follow-up
   line of the `ticket.md` next to the ticket file). Non-zero exit → print its errors and stop.
   **Release the claim first** when step 3b won or held one and `<CLONE>/.agents/team/team.json`
   is absent or its `ticket` ≠ `KEY` (nothing names the ticket yet): github `bash
   .claude/lib/team-claim.sh release <KEY> --id <CLAIM_ID> --reason start-failed`; jira the MCP
   release — re-read as in step 3b (snapshot `.status` must be `complete`, else stop and report
   that nothing was restored) → `holder` still `CLAIM_ID`? → status still `jira.started_status`?
   → transition back to the marker's `previous` with a one-line comment, or say "status left at
   <started> — no transition back to <previous>" → the release body (`--reason start-failed`) via
   `mcp__atlassian__jira_add_comment`. Name each failed call as a partial cleanup. The exit-9 case
   whose clone already names `KEY` keeps the claim (the resume path below).
   Exit **9** is the follow-up cap: this ticket would be the third follow-up of one origin. Print the
   refusal verbatim, add one Polish line for the Operator — the origin, the follow-ups already
   started, and how to consent: in their own terminal
   (`bash .claude/lib/team-lineage.sh consent <KEY> --text "<their words>"`) or by typing to you a
   message with the exact phrase `consent <KEY>` (e.g. `consent AB-793`; a mention of the ticket is
   not enough; the paths are in `.agents/reference/roles/supervisor.md` → Follow-up chains) — and
   stop. After the consent the
   same `/start-team` invocation passes. When the clone's `team.json` already names `KEY` (the
   start lost a race in the ledger after provisioning), the clone stays: after the consent, resume
   with `/start-team <TEAM>`, which records it.

4a. **Roles override** (only with `ROLES`). `bash .claude/lib/team-run.sh <TEAM> roles <ROLES…>`.
   New ticket: after step 4, so `team-next.sh` has archived the previous ticket's override first.
   Resume: right after confirming `CLONE` exists, before the status check; with a live runner it
   applies at its next role launch. Non-zero exit → print its error verbatim and stop without
   launching the runner. For a new ticket, step 4 has already provisioned its clone: after a
   failure in step 4a,
   correct the roles and retry as `/start-team <TEAM> --roles <corrected entries…>` (resume),
   without `KEY` or `BRANCH`. If no override is needed, resume with `/start-team <TEAM>`.
   Do not repeat the new-ticket invocation or run `team-next` for the same ticket. The claim from
   step 3b stays: the clone names the ticket, so the resume continues under it.
   The override lives until `team-next` (the next ticket); undo with
   `bash .claude/lib/team-run.sh <TEAM> roles --clear`. A role already running keeps its model.

4c. **Order brief** (NEW runs only, only when `MODE` ≠ `cli`; after step 4). The per-run
   TeamLead judges every gate and the acceptance against this file. A failure here keeps the claim
   (the clone names the ticket — resume).
   - Run `bash .claude/lib/team-brief.sh inflight <TEAM>`.
   - Write a draft in your scratchpad with exactly these three sections:
     - `## Ticket` — the ticket body copied verbatim, never paraphrased: `ticket.md` from step 3
       for `github`/`none`; for `jira` the summary, description and comment ledger read in step 3.
       Headings inside the ticket text are fine (they stay part of the section), except the three
       reserved ones named here;
     - `## Not ordered` — what this ticket explicitly does not ask for, and adjacent work you know
       is not wanted; `none stated` when nothing applies;
     - `## In-flight work` — the `inflight` list, each line extended with one clause on what that
       team touches (`- none` stays as is).
   - Run `bash .claude/lib/team-brief.sh write <TEAM> <draft>`. Non-zero exit → print its error
     and stop before step 5.

   Your judgement goes only into `## Not ordered` and the in-flight clauses.

5. **Runner.**
   `bash .claude/lib/session-host.sh start <TEAM>-runner --kind team --cwd "<ROOT>" --cli script --env "AGENT_COSTS_HOME=${AGENT_COSTS_HOME:-}" -- "bash .claude/lib/team-run.sh <TEAM>; read"`.
   It survives this Claude session; it does not survive a Mac restart. The `--env` carries the
   token-usage home into the runner, which forwards it to every role; an empty value means the
   default `~/.agent-costs`. The user asked for the planner window only → run
   `TEAM_ATTACH=planner bash .claude/lib/team-run.sh <TEAM>` in that command instead (same `--env`).

5a. **Token usage.** Run
   `bash .claude/lib/costs/runtime-mark.sh session --provider claude --source start-team --team <TEAM> --team-json <CLONE>/.agents/team/team.json`
   — the clone's `team.json` is the one source of the ticket identity for costs (`cost_key`, or
   `ticket` on a pre-2b clone), so it is right for a new ticket and for a resume alike.
   It registers this supervisor session for labels only — never a ticket binding; a
   non-zero exit is impossible, nothing to check.

6. **Role windows.** Do not open one yourself. Herdr: the runner places each stage it launches
   (`TEAM_ATTACH=all`, the default), or only the attended planner and wrapup (`TEAM_ATTACH=planner`),
   as a pane in the team's own tab of the main checkout's Herdr space (the tab is named `<TEAM>`): the
   TeamLead on the left, the working stage on the right; the pane shows the role's own status and closes when the stage ends. A `warn: placement …` line means
   the pane failed; the role still runs. tmux: no window opens — the runner prints
   `attach: tmux attach -t …` for the planner and the wrapup, and
   `bash .claude/lib/session-host.sh hint <TEAM>-<role>` names how to look at any role.

7. **Report** (Polish, short): clone path, ticket (for `none` the key the adapter allocated),
   `tracker: <TRACKER>`, the claim result from step 3b (`claimed`/`held` + `status:`, or
   `tracker none: no shared signal`), branch and the mode line: `mode: the TeamLead chooses
   (status shows it once chosen)` | `mode: <MODE> — set by the Operator (--mode)` | on a RESUME
   `mode: <the status line's mode> — fixed per ticket`, "Herdr: the team has its own tab `<TEAM>` (TeamLead left, the working stage right) — talk to the planner there; tmux: the
   runner's `attach:` line says how to reach the planner (detach with Ctrl-b d)", and that coder/QA run alone, the
   team's TeamLead answers what it may, and only a decision that needs the Operator notifies them
   (`notify.sh`, when a channel is on in `~/.agent-comms/notify.json`; otherwise it waits in
   `/tasks-status`). When step 4 ran `team-new.sh` (a new clone directory): the first sessions there —
   the TeamLead and the planner — stop at Claude's folder trust dialog; the Operator accepts it once
   in each, in the team's tab `<TEAM>` (Herdr) or through the runner's `attach:` / `warn:` hint (tmux),
   by picking `Yes, I trust this folder` (Enter alone exits). The runner prints a `warn:` line and
   notifies the Operator for each, and its stage clock waits meanwhile. After QA a `wrapup` window opens with a plain summary of the run and, only if it has
   recommendations (memory, new tickets), one question. Resume after answering:
   `/start-team <TEAM>`. Merge when ready: ask the supervisor ("merge <TEAM>"). For `pr_provider: github` the supervisor runs
   `team-merge-check.sh <TEAM>`, asks the Operator, then `team-integrate.sh <TEAM>`; for azure-devops it
   is `/pr-merge` as before. With an active
   override, include the `roles override:` line from `team-run.sh <TEAM> status`. For `cli`: one
   session runs alone, with no window questions, and publishes the PR itself (no QA, no wrapup).
