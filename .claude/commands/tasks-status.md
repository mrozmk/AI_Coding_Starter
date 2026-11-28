---
description: Task status report — what waits for the Operator, then what blocks Done for every open task (tracker jira, github or none), with team run state, PR state and one recommended next action each
argument-hint: "(no arguments)"
---

# /tasks-status — what waits for you, and what blocks each task from Done

The Operator's on-demand view of the work: nothing is pushed to him, he asks for this. **Read-only.**
Never transitions, comments on or edits a tracker issue, never writes the backlog, never answers a
question or merges a PR. Every run reads fresh data; there is no cache.

Output in the project's developer-communication language (`CLAUDE.md` → Language Rules); this
file stays English. Scratch files go to one `mktemp -d` directory, never into the repo.

## Steps

1. **Tracker.** From `.claude/project-profile.json`: `teams.tracker` when a `teams` block exists,
   else the top-level `tracker`, else `none` — the rule `team-tracker.sh` applies itself. `github`
   works with or without teams (the github block: `teams.github`, else the top-level `github`). An
   adapter refusal of the profile (exit 2) → say so in one line and continue as `none`.

2. **Task list — the report's scope, named in its header.**
   - **github** — `bash .claude/lib/team-tracker.sh list --out <scratch>/tasks.json`: every open
     issue of the github block's `repo` with its Project status (`null` = not on the board;
     `on_board` > 1 = ambiguous, flag it) and the Status options in board order (none when the
     profile has no Project: one "no status" section). Exit 4 → say the list is
     incomplete and stop the tracker part; never report a partial list as the whole.
   - **jira** — Atlassian MCP `jira_search`, `fields: summary,status,assignee,updated`,
     `limit: 50`, paged with `start_at` until a page comes back short. JQL: `status_report.jira_jql`
     from the profile; absent → `assignee = currentUser() AND statusCategory != Done ORDER BY
     status, key`, and the header says the default was used (my open issues, every project). MCP
     not configured or `401` → one line, continue without the tracker part.
   - **none** — `.agents/backlog.md` Task rows whose `Status` is not `DONE` and whose `Task` cell
     is not `(withdrawn…)`. A legacy or malformed backlog (as `/execute` defines it) → say so and
     list nothing. No backlog → no tracker part; the report shows teams only.

3. **Team state** — only when the profile has a `teams` block; otherwise skip this step and every
   team column. `bash .claude/lib/team-snapshot.sh --out <scratch>/snap.json`, once. Join
   `teams[]` to tasks by `ticket` (github `7` = `#7`). Per team keep: the current role and its
   status, `runner`, `state` (`free` / `awaiting_merge` / `pr_unknown`), `pr_id`, `pr_status`,
   `resume_hint`. A team whose ticket is not in the task list gets its own row.

4. **What blocks Done — from evidence only.**
   - **jira / github:** Haiku extractors — `Agent` calls with `model: haiku` (the alias, never a
     pinned version), `subagent_type: general-purpose`, batches of ≤ 10 keys, all batches in one
     message, the prompt in **Extractor prompt** below. A batch that fails or returns malformed
     lines → re-run it once; still bad → its rows read `⚠ extraction failed`.
   - **none:** no extractor. The row comes from the files: `Depends on` ids not yet `DONE` →
     "waits on <ids>"; `Ref` → a plan still in `.agents/plans/active/` means work in progress, a
     plan in `done/` with the Task still open means another active plan lists it (the whole-Task
     rule, `/execute`); an umbrella's `## Execution Plan` table → its row statuses. **Never count
     `- [ ]` markers** — the executor never ticks them, so they measure nothing.
   - Nothing to go on → "no data", never a guess from the title or the status.

5. **PR state — from the provider, never from git.** A team's PR: its `pr_status` from the
   snapshot; `null` (the team has not finished) and `teams.pr_provider = github` →
   `bash .claude/lib/team-pr.sh state <pr>`. A PR an extractor names on a task without a team:
   the same call when `pr_provider = github`, otherwise print "PR #n — state unverified". Git
   history may add "the code is on the trunk" as a hint, never as the PR's state.

6. **Who acts.** Sort every open item into one of two sections; each source is one list entry, so
   a new source is one more line, not a new step.
   - **Waiting for you** — only decisions that are the Operator's:
     1. tasks whose extracted "waiting on" is the Operator, with the evidence that says so;
     2. *(when the per-run TeamLead lands)* its pending human-decision files;
     3. each `UPKEEP_DUE` row of `bash .claude/lib/upkeep.sh due --format prime`, run once (a missing script, a non-zero exit or no row → nothing): Team / task `upkeep`, Decision needed `run <command> — <reason>`, Since `—`, Next action `run <command> in your own session`.
     4. each `BATCH_DUE` row of `bash .claude/lib/batch-gate.sh due --format prime` whose hold column (its 4th field) is `held`, whatever its state (a red gate under a hold keeps its failed steps in the line), run once (a missing script, a non-zero exit or no row → nothing): Team / task `batch gate (<gate>)`, Decision needed `lift the hold or keep it — <line>`, Since `—`, Next action `tell the Supervisor`.
   - **Waiting on the team** — everything the TeamLead, Advisor or Supervisor acts on:
     `attention[]` items (role questions, prompts, `blocked`/`failed` records with their
     `resume_hint`) and PRs `awaiting_merge` (the Supervisor's merge gate; it reaches the Operator
     only when that gate refuses). Every `BATCH_DUE` row of the same call (its output reused)
     whose hold column is `-`: who acts `Supervisor`, next action
     `bash .claude/lib/batch-gate.sh run <gate>` (state `behind`: `update <repo>'s line`; state
     `unknown`: `fix teams.batch_gate, the checkout or the record — <line>`, never `run`; when the
     call printed a `record unreadable` row, that fix is every row's next action, since `run` refuses
     an unreadable record). Name who acts. A pending decision delegated to the Supervisor
     under the Operator's mandate (`team-lead.sh decision list <team>` shows
     `pending [delegated to the Supervisor]`) belongs here, never under **Waiting for you**.
   - **Delegated answers** — only with a `teams` block: run `bash .claude/lib/team-mandate.sh show`
     and `bash .claude/lib/team-mandate.sh answers` once (a missing script or a non-zero exit →
     nothing). They feed the report's `Mandate` line: the mandate in force and every answer the
     Supervisor gave as a delegate, kept apart from the Operator's own answers and from the
     Operator touches.
   - **Supervisor clearance** (#323) — only with a `teams` block: run
     `bash .claude/lib/team-clearance.sh show` once (a missing script or a non-zero exit →
     nothing). It feeds the report's `Clearance` line with the `Supervisor clearances (no human)`
     and `Shadow` sections of the step 8 touch report; never an Operator touch.

7. **Recommend.** For every task and every "waiting" row write **Next action** yourself (main
   session, not the extractor): one concrete step toward Done, who does it, ≤ 15 words. Prefer, in
   order: a read we can do now → a status move the evidence already supports → an Operator decision
   phrased as a question with a recommended answer → "wait until <date>" when only time blocks it.
   A wait date already past means the next step is the read, not more waiting. Flag a task whose
   status no evidence backs, or that looks superseded.

8. **Print** the report below. Nothing before it. Before printing, run
   `bash .claude/lib/touches.sh report --since 7d` once (it exits 0 also without a log); a missing
   script or a non-zero exit → omit the Operator touches block.

## Report

```
# Task status (<YYYY-MM-DD>) — <tracker>: <scope, e.g. "owner/repo open issues" | the JQL | "backlog">

<1–2 sentences: how many tasks, how many wait for you, how many the team can move now>

## W. Waiting for you (<n>)
| # | Team / task | Decision needed | Since | Next action |

## T. Waiting on the team (<n>)
| # | Team / task | What | Who acts | Next action |

## 1. <first status> (<n>)
| # | Task | Blocks Done | Waiting on | Team run | PR | Next action | Last move |
## 2. <next status> (<n>)
…
## <k>. Teams without a listed task (<n>)

**Check:** extractor caveats, status/evidence mismatches, unverified PRs — omit when none.

**Operator touches (7 days):** <header line count> — <up to 3 group rows, newest first>; recurring: <top Recurring line> — omit when the log is absent or the report says none recorded.

**Mandate:** <classes> until <expiry> — <n> delegated answer(s): <team d-n → reply, newest first, up to 5> — omit when no mandate is in force and no delegated answer exists; the list is never cut when the Operator asks for the delegated answers.

**Clearance:** <shadow | enforcing <hosts> until <expiry>> — <n> cleared (7 d, by class) · <n> would clear — from `team-clearance.sh show` and the touch report's `Supervisor clearances (no human)` and `Shadow` sections; omit when there is nothing to show (no switch and no cleared or shadow line).

<n> tasks · <k> extracted · <t> teams
```

**Sections.** Status sections follow the tracker's own order — github: the Status options in board
order, then "no status"; jira: status category (To Do → In Progress), then status name; none:
`BLOCKED`, `WIP`, `TODO`. Numbers are fixed for one report, an empty section is omitted, rows are
lettered `a`, `b`, `c`… so the `#` cell holds a ref (`W1`, `T2`, `2c`) the Operator can answer by
("W1 yes, 2c later"). Without a `teams` block the `T` section and the Team run column are dropped.

**Cells.** Task = key + a 2–4 word topic. ≤ 15 words per cell, cut to the decisive part. Bold the
"Waiting on" cell when it is the Operator alone. Dates as `dd.mm`.

## Extractor prompt

Pass verbatim, with `<KEYS>` and `<HOW TO READ>` replaced:

> Read-only task. For each ticket below, determine what still blocks moving it to Done and who or
> what we are waiting for. Read each ticket this way: <HOW TO READ>. Never download attachments.
> Never modify anything in the tracker.
>
> Tickets: <KEYS>
>
> Return ONE line per ticket, exactly this pipe-separated format, short and concrete:
> `KEY | status | what blocks Done (missing review, failing check, decision on X, dependency Y,
> verification step…) | who or what we wait for (Operator / team / reviewer / customer / time
> until <date> / named person) | evidence (the comment date + author, or "description") | date
> of the last meaningful event YYYY-MM-DD`
>
> Use only what the ticket says; the latest comments win. A comment saying a PR is open or awaits
> merge is a snapshot of that moment, not the current state — report the PR number, never conclude
> the PR's state from it. Nothing in the ticket says what blocks it → write "no data", never
> guess. After the lines, at most 2 lines of caveats (status not backed by any comment, ticket
> looks superseded by another). No other prose.

`<HOW TO READ>`:
- **github** — "run `bash .claude/lib/team-tracker.sh show <KEY> --out <scratch>/show-<KEY>.json`
  and read that file (body and every comment); exit non-zero → write `KEY | ? | no data — <the
  error line>`".
- **jira** — "load the tool with ToolSearch `select:mcp__atlassian__jira_get_issue`, then call it
  per ticket with `include: \"comments,changelog\"`, `comment_limit: 15`, `update_history: false`,
  `fields: \"summary,status,description,labels,updated,issuelinks\"`".
