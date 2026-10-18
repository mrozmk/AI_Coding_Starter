---
description: Start (or resume) a parallel AI team on a ticket — provision or reuse its clone, launch the runner in tmux (it opens a Terminal preview window per role)
argument-hint: "<team> [key] [branch] [--mode brainstorm|quick|cli] [--brief \"<text>\" | --brief-file <path>] [--roles <role>=<model>[/<effort>] …]  (e.g. alfa TT-777 · alfa 7 --mode quick · alfa --brief \"Fix X\" · alfa — resume · alfa TT-787 --roles planner=claude-fable-5-1/high)"
allowed-tools: Bash(bash -c source .claude/lib/team-profile.sh:*), Bash(bash .claude/lib/team-tracker.sh:*), Bash(bash .claude/lib/team-new.sh:*), Bash(bash .claude/lib/team-next.sh:*), Bash(bash .claude/lib/team-run.sh:*), Bash(bash .claude/lib/team-attach.sh:*), Bash(tmux has-session:*), Bash(tmux new-session:*), Bash(tmux kill-session:*), Bash(git rev-parse:*), Bash(test:*), mcp__atlassian__jira_get_issue, Bash(bash .claude/lib/costs/runtime-mark.sh:*)
---

# /start-team — run a team on a ticket

Arguments: **$ARGUMENTS** — `<team> [key] [branch] [--mode <mode>] [--brief <text>|--brief-file <path>] [--roles <entries…>]`. Supervisor command: run it in the **main
checkout** (`TakeTask.DN`), from any Claude window. Runbook: `.agents/reference/team-pipeline.md`.

## Guardrails

- Refuse inside a team clone (`.agents/team/team.json` at the repo root) — teams never start teams.
- Never delete a clone, never touch another team, never answer a team's questions for the user.
- A refusal from `team-new.sh` / `team-next.sh` is printed verbatim — fix nothing on your own.

## Steps

0a. **Profile preflight** — before the clone and before `tmux`:
   `bash -c 'source .claude/lib/team-profile.sh; team_profile_load; team_profile_require_supported;
   echo "trunk: $TEAM_TRUNK"; echo "tracker: $TEAM_TRACKER"'`. Non-zero exit → print its `error:`
   line verbatim and stop (no clone, no branch, no tmux session). `TEAM_TRUNK` is the trunk used in
   step 4; `TRACKER` (the `tracker:` line, one of `jira`, `github`, `none`) decides steps 1, 3 and 4.

1. **Parse.** `TEAM` = first argument (`[a-z0-9-]+`), `KEY` = second (optional, shape per `TRACKER`:
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
   `/start-team alfa TT-791 --roles planner=claude-fable-5-1/high chore/TT-791-team-next-retry-guard`
   keeps `chore/TT-791-team-next-retry-guard` as `BRANCH`. Map the user's wording to roles:
   brainstorm/spec/plan = `planner`,
   implementation = `coder`, review/QA = `qa`, summary = `wrapup`. Entry forms:
   `<role>=<model>/<effort>`, `<role>=<model>`, `<role>=/<effort>`.
   `MODE` = the word after `--mode`, also taken out before the positional parse; default
   `brainstorm`. A value outside `brainstorm|quick|cli`, or `--mode` with no value → stop and say
   the allowed values. Which mode: brainstorm = typical tickets; quick = small clear changes (a
   Codex-reviewed short plan, then coder → QA → wrapup); cli = very simple changes (one session,
   Opus/medium, no QA).
   `--brief "<text>"` / `--brief-file <path>` are taken out the same way, before the positional
   parse — for `TRACKER=none` they *are* the ticket (there is no key to name).
   **This run is NEW** when `KEY` is given, or (only `none`) when `--brief`/`--brief-file` is given;
   otherwise it is a **RESUME** (step 2). Refuse:
   - `--brief`/`--brief-file` with `TRACKER` = `jira` or `github` → "`--brief` is for tracker=none —
     name the ticket key instead";
   - `--mode` on a RESUME → "mode is fixed per ticket — `/start-team <team> <KEY> --mode …`
     (tracker=none: `--brief …`) starts a new one". `/start-team alfa --brief "Fix X" --mode quick`
     is NEW, so it is allowed;
   - `--mode cli` with `--roles` → "cli always runs opus[1m]/medium; drop --roles".

2. **RESUME** (no `KEY`, and for `none` no `--brief*` either). `CLONE` must exist. Never call
   `team-tracker.sh read` here: a resume allocates nothing, and the ticket it continues is already in
   `<CLONE>/.agents/team/ticket.json` (`github`/`none`) or in Jira. With `ROLES` → step 4a first, then run
   `bash .claude/lib/team-run.sh <TEAM> status`:
   - a line `lock: runner <pid> alive` → say "runner already running — watch:
     `bash .claude/lib/team-attach.sh <TEAM> runner`" and stop;
   - a line `lock: stale (pid … dead)` → `bash .claude/lib/team-run.sh <TEAM> unlock` (deliberate;
     the runner never removes a lock by itself);
   - then, if `tmux has-session -t "=<TEAM>-runner"` — only an idle shell on `; read`, since the
     runner is dead — `tmux kill-session -t "=<TEAM>-runner"`. A live tmux session alone never
     means a live runner: it outlives the runner after a `blocked` record.

   Then go to step 5 (launch the runner) and report which stage it resumed.

3. **Ticket + branch name.**

   **`TRACKER=jira`** (only when `BRANCH` is not given). `mcp__atlassian__jira_get_issue(KEY,
   fields="summary,issuetype,labels")`. Type: `Bug` → `bugfix`; labels `harness`, `deploy`,
   `consolidation` or a docs/config-only summary → `chore`; otherwise `feature`. Slug: the summary
   in **English**, kebab-case, 3–6 words, `[a-z0-9-]` only. `BRANCH` = `<type>/<KEY>-<slug>`.
   Jira unreachable → stop and ask for the branch as the third argument.

   **`TRACKER=github` / `none`** — read the ticket **unconditionally** on every NEW run, also when
   `BRANCH` was given (step 4 needs the file either way); only the slug is conditional:
   `bash .claude/lib/team-tracker.sh read <KEY> --out .agents/team/incoming/<TEAM>`
   (`none`: `bash .claude/lib/team-tracker.sh read --brief "<text>"|--brief-file <path>
   --out .agents/team/incoming/<TEAM>`). Non-zero exit → print its `error:` line verbatim and stop,
   **before** the clone. From its output take `KEY` (`key=`, for `none` the allocated `L<n>`), `type`
   and `title`; then, only when `BRANCH` is not given, slug = the title in **English**, kebab-case,
   3–6 words, `[a-z0-9-]` only, and `BRANCH` = `<type>/<KEY>-<slug>`.

4. **Clone.** `CLONE` absent → `bash .claude/lib/team-new.sh <TEAM> <KEY> <BRANCH>
   origin/<TEAM_TRUNK> <MODE>` (the base-ref is `origin/` plus the trunk from step 0a); present →
   `bash .claude/lib/team-next.sh …` with the same arguments. For `github`/`none` append
   `--ticket-file .agents/team/incoming/<TEAM>/ticket.json` (the file from step 3; `jira` passes none).
   Non-zero exit → print its errors and stop.

4b. **Ticket status** (`TRACKER=github` only, NEW runs only, after step 4 succeeded).
   `bash .claude/lib/team-tracker.sh set-status <KEY> started`. Non-zero exit → record it DURABLY
   first: `bash .claude/lib/team-warn.sh <TEAM> "status started not set — <error>"` (appends to
   `warnings[]` in the clone's `team.json`; `bash .claude/lib/team-run.sh <TEAM> status` prints every
   entry). Continue **only after that command succeeded**, with one line
   `warn: status started not set — <error>` in the report; the run then starts regardless, because
   the failure is recoverable from the clone.
   `team-warn.sh` itself exiting non-zero → **stop the start**: do not run step 4a and do not launch
   the runner, print its error verbatim, and report that the ticket status was not set *and* the
   warning could not be stored. This is the one failure that must not be walked past — it would
   leave a run going with a ticket that silently never left its old status and no record of why.

4a. **Roles override** (only with `ROLES`). `bash .claude/lib/team-run.sh <TEAM> roles <ROLES…>`.
   New ticket: after step 4, so `team-next.sh` has archived the previous ticket's override first.
   Resume: right after confirming `CLONE` exists, before the status check; with a live runner it
   applies at its next role launch. Non-zero exit → print its error verbatim and stop without
   launching the runner. For a new ticket, step 4 has already provisioned its clone: after a
   failure in step 4a,
   correct the roles and retry as `/start-team <TEAM> --roles <corrected entries…>` (resume),
   without `KEY` or `BRANCH`. If no override is needed, resume with `/start-team <TEAM>`.
   Do not repeat the new-ticket invocation or run `team-next` for the same ticket.
   The override lives until `team-next` (the next ticket); undo with
   `bash .claude/lib/team-run.sh <TEAM> roles --clear`. A role already running keeps its model.

5. **Runner.** `tmux new-session -d -s <TEAM>-runner -c "<ROOT>" "bash .claude/lib/team-run.sh
   <TEAM>; read"`. It survives this Claude session; it does not survive a Mac restart. The user
   asked for the planner window only → run `TEAM_ATTACH=planner bash .claude/lib/team-run.sh <TEAM>`
   in that command instead.

5a. **Token usage.** Run
   `bash .claude/lib/costs/runtime-mark.sh session --provider claude --source start-team --team <TEAM> --team-json <CLONE>/.agents/team/team.json`
   — the clone's `team.json` is the one source of the ticket identity for costs (`cost_key`, or
   `ticket` on a pre-2b clone), so it is right for a new ticket and for a resume alike.
   It registers this supervisor session for labels only — never a ticket binding (spec TT-821); a
   non-zero exit is impossible, nothing to check.

6. **Role windows.** Do not open one yourself: the runner opens a Terminal preview window for every
   role it launches (`TEAM_ATTACH=all`, the default), or only for the attended roles, planner and wrapup (`TEAM_ATTACH=planner`).
   A `warn: no preview window` line in the runner's output means the window failed; the role still runs.

7. **Report** (Polish, short): clone path, ticket (for `none` the key the adapter allocated),
   `tracker: <TRACKER>`, any `warn:` line from step 4b, branch and `mode: <MODE>`, "a Terminal window opens on each role
   as it starts — talk to the planner there, detach with Ctrl-b d", and that coder/QA run alone and a
   macOS notification appears when a team needs approval, has a question, is ready for merge, or
   stopped. After QA a `wrapup` window opens with a plain summary of the run and, only if it has
   recommendations (memory, new tickets), one question. Resume after answering:
   `/start-team <TEAM>`. Merge when ready: ask the supervisor ("merge <TEAM>"). With an active
   override, include the `roles override:` line from `team-run.sh <TEAM> status`. For `cli`: one
   session runs alone, with no window questions, and publishes the PR itself (no QA, no wrapup).
