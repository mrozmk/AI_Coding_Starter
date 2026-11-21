---
description: Plan parallel sessions from .agents/backlog.md — the order per person and session, the CORE phase (Tech Lead alone or + 1) and working days / weeks / sprints at two velocities; no calendar, no money
argument-hint: "[plan]"
---

# Delivery Plan: Order per Person and Session

## Input: $ARGUMENTS

## What this produces

One generated file: `.agents/backlog/delivery-plan.md` — who builds which Task in which order, how
long CORE takes for "Tech Lead alone" and "Tech Lead + 1", the day the team scales, when the
development is done (CORE + MUST) and how long the COULD tail is, each in working days, weeks and
sprints at a pessimistic and an optimal velocity. `.claude/lib/delivery-plan.mjs` computes it;
`@delivery-analyst` writes its `## Analysis` region.

The Tech Lead runs it, after `/setup:create-backlog` and `/check-backlog`. `plan` as the argument
and an empty argument run the same steps (detailing the Epics is a later extension).

<HARD-GATE>
This command writes only `.agents/backlog/delivery-plan.md` and the `delivery` block of
`.claude/project-profile.json` — never `.agents/backlog.md`, never code. A finding about the
backlog itself goes through `/update-backlog`.
</HARD-GATE>

---

## 0. Preconditions

1. `/prime` ran and `.agents/backlog.md` exists — otherwise say which and stop.
2. `node .claude/lib/backlog-check.mjs` exits 0. Errors → print them verbatim and stop. A pre-Scope
   backlog (`Wave` / `Slice` columns, no `Scope`) is one of those errors: print the checker's
   message, which names `node .claude/lib/backlog-migrate.mjs --write`, and stop. Warnings → keep
   them for the report.
3. The backlog's `**Last check:**` line is fresh and whole. Fresh = its `backlog sha256` equals

   ```bash
   grep -v '^\*\*Last check:\*\*' .agents/backlog.md | shasum -a 256 | cut -c1-12
   ```

   (the check `/prime-ba` runs); whole = its scope is `all`. Otherwise name the state — **none**
   (no line, or `—`), **stale** (a different hash; a migrated backlog always is) or **partial**
   (scope `E<n>` or `since D-k`) — and offer `/check-backlog` first. The operator may continue; the
   plan file then carries the review state (step 2).

## 1. Team mode

Read `.claude/project-profile.json` → `delivery` (absent file or block = the script's defaults).
Ask once with `AskUserQuestion`; the recommended option is the stored `mode`, else `team`. Each
label shows the effective numbers — the stored ones, else the defaults below:

- **Team** — the Tech Lead alone builds CORE on up to 3 sessions (with one developer when that cuts
  CORE by at least 20 %); then 2 developers × 3 sessions, the Tech Lead on 2 sessions at half share.
- **Solo** — one person, 3 sessions, all phases.
- **Other numbers** — free text: mode, developers, sessions per person, velocity (points per person
  per sprint, pessimistic / optimal), sprint length in working days.

Write the answer into the profile with `jq --arg/--argjson`, merging into the existing object and
keeping `schema` and every other block (the `/setup:teams` rule). **Team** and **Solo** write only
`delivery.mode`; stored numbers stay. **Other numbers** writes `mode` plus the keys the answer
names, into their place in the block — `velocity.pessimistic`, `velocity.optimal`,
`velocity.sprint_days`, `solo.sessions`, `team.developers`, `team.developer_sessions`,
`team.tl_core_sessions`, `team.tl_scale_sessions`, `team.tl_scale_share`,
`team.core_developers` (`auto`, `0` or `1`). An answer that does not map to these keys → ask again
for that value only.

```bash
jq --arg mode team --argjson developers 3 \
  '.delivery = ((.delivery // {}) * {mode: $mode, team: {developers: $developers}})' \
  .claude/project-profile.json > "$SCRATCH/profile.json" && mv "$SCRATCH/profile.json" .claude/project-profile.json
```

No profile file → create `{"schema":1,"delivery":{…}}` with the answered keys only. `$SCRATCH` =
the session scratchpad, never `/tmp`, never the repo.

## 2. Plan

```bash
node .claude/lib/delivery-plan.mjs --write
```

Exit ≠ 0 → print its output verbatim and stop (exit 1 = the backlog has errors or is a legacy
work-package backlog; exit 2 = a profile that is not valid JSON or an invalid `delivery` value, named
in the message — fix the profile and rerun from step 1). Nothing is written in either case.

When step 0.3 found the review state **none**, **stale** or **partial**, add one line directly under
the `**Backlog:** …` header line of the plan file (Edit):

```
**Backlog review:** none | stale | partial
```

Then the analyst's input:

```bash
node .claude/lib/delivery-plan.mjs --json > "$SCRATCH/delivery-plan.json"
```

The JSON carries `config`, `summary`, `warnings`, `phases`, `schedule`, `sprints` and `outside`.

## 3. Analysis

Spawn `@delivery-analyst` (read-only) with:

```
PLAN:    $SCRATCH/delivery-plan.json
BACKLOG: .agents/backlog.md
```

Write its returned Markdown between `<!-- analysis:begin -->` and `<!-- analysis:end -->` of
`.agents/backlog/delivery-plan.md` (Edit; the markers stay, the placeholder line goes). Agent
failed, unavailable or returned something other than the four headings → the region reads
`_Analysis not written — <reason>._` and the report says so.

## 4. Report

In the project's communication language:

- mode and team (one line per phase);
- CORE duration for "Tech Lead alone" and "Tech Lead + 1", the recommendation and the rule or
  override that decided it;
- the join day;
- development done (CORE + MUST) and the COULD tail — days / weeks / sprints, pessimistic and
  optimal;
- every warning of the plan verbatim, then the checker warnings from step 0;
- the backlog review state when it is not fresh and whole;
- the three most useful points of the analysis;
- one closing line: the plan is a forecast computed from the Task sizes and the stated velocity,
  not a commitment.

Shape cap: this skeleton — unless a warning needs its Task ids, which are never compressed.

---

## Notes

- Re-run after every structural backlog change (`/update-backlog`, a resize, a Scope move). The
  plan file is generated and never hand-edited; its header carries the backlog hash, so a plan
  older than the backlog is visible.
- The script is the only scheduler of the workflow; the backlog itself holds no lanes, waves or
  durations.
- Detailing the Epics into `.agents/backlog/E<n>-<slug>.md` is a later extension of this command.
