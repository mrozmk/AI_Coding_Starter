# Quality & upkeep Tasks — the closing audits and the recurring upkeep every backlog plans

Read by `/setup:create-backlog` (Phase 4.5), `@backlog-author`, `@backlog-epic-author`,
`/update-backlog`, `/check-backlog`, `/setup:delivery-plan` and the backlog rubric. The marker
table is mirrored in code by `QUALITY_MARKERS` in `.claude/lib/backlog-check.mjs`; change both
together.

## Markers

A quality Task's `Task` cell **begins** with one marker:

| Marker | Command | Kind | Size | Planned |
|---|---|---|---|---|
| `[audit:security]` | `/audit-security` | closing | `H` | always |
| `[audit:seo-geo]` | `/seo-geo-audit` | closing | `H` | when the product has a public website — pages served without login that search engines or AI assistants should find |
| `[audit:wcag]` | `/wcag` — not in this workflow yet | closing | `H` | when the product has a user interface people operate |
| `[upkeep:architecture-review]` | `/architecture-review` | recurring | `M` | always, `n` numbered occurrences |
| `[upkeep:cleanup-workflow]` | `/maintain:cleanup-workflow` | recurring | `M` | always, `n` numbered occurrences |

Every quality Task: `Type` `tech` · `Scope` `MUST` · `Node` `—` · `Relates` `—` · `Chain` `—` ·
`Traces` `—` (an `NFR-n` the PRD states for security or accessibility may be traced; never
required). Sizes are effort budgets — 8 h per audit, 4 h per occurrence — recorded as `H` (8
points) and `M` (4 points); the forecast's duration comes from the velocity, never from the hours.

Titles: `[audit:security] Run /audit-security` · `[upkeep:architecture-review] Run
/architecture-review — occurrence 2`. A planned occurrence is always numbered (`— occurrence <k>`);
an unnumbered `[upkeep:<id>] Run <command>` Task is one an upkeep reminder added, and the cadence
rules below do not count it.

They live in one Epic, last in the Epic map: **`Quality & upkeep`** — Outcome: *the committed scope
ships audited, and its architecture and workflow stay maintained while it is built*; Key
assumption: *the audit commands run against the product as built, before release*; `Depends on`
`—`; below the map: `appetite: fixed by the workflow · cut first: a recurring occurrence, never a
closing audit`.

## Planned or ruled out

`[audit:security]` and both recurring commands are planned on every backlog. `[audit:seo-geo]`
and `[audit:wcag]` are planned when the sources (PRD, discovery, architecture) describe what the
table names; otherwise `## Consciously out of scope` gets one line naming the marker and the reason
(`[audit:seo-geo] — no public website: the product is an internal admin tool (PRD §2)`). Only these
two may be ruled out; a rule-out of a mandatory marker does not count.

## Order — `Depends on` only

Product Tasks = the live `CORE`/`MUST` Tasks without a quality marker; a product **sink** is one no
other product Task depends on.

- **Closing audit** — depends on every product sink, so it waits for all product work. The audits
  are independent of each other. A re-audit (a later Task with the same marker, added when new
  work arrives while the first audit is protected) waits for all product work too; per marker the
  live audit with the highest id (any status) is the one the checker binds — it must wait while
  `TODO` / `BLOCKED` — and a release row waits for it.
- **Cadence** — `P` = the points of the product Tasks; `n = max(2, ceil(P / 160))` occurrences of
  each recurring command.
- **Placement** — walk the product Tasks in dependency order (Task-table order, except that a Task
  is taken only after all its product prerequisites — a table may list a dependent first), summing
  their points; occurrence `k`
  (1…n) of each command depends on the sinks of the shortest prefix whose sum reaches `k · P / n`
  (the prefix's Tasks no other prefix Task depends on). Occurrence `k` of both commands depends on
  the same set; the upkeep Tasks also form one chain — review `k` → cleanup `k` → review `k+1` (each
  depends on the one before) — so no two run at once in one checkout (the cleanup edits what the
  review reads, and two reviews would write the same report names). The last occurrence waits for all product work. A threshold inside
  `CORE` lands at the join (occurrences are `MUST`). On a tiny backlog, or one whose product work
  runs fully in parallel, a threshold can coincide with the end — there is no earlier point the
  work reaches; the delivery plan's report shows the occurrence days.
- **Before the release** — a release outside row (a deploy to production) lists the planned closing
  audits in its `Starts after`; a release sign-off gets the external-blocker line
  `Release ← closing audits <ids>`. When an outside row provides the environment
  `/seo-geo-audit` audits (a reachable deployment of the release candidate), the `[audit:seo-geo]`
  Task joins its `Needed by`.

`.claude/lib/delivery-plan.mjs` runs a ready numbered occurrence before ready product Tasks, so an
occurrence starts when its prefix is done instead of drifting to the end.

## Summary lines

- **Audit:** *Run `<command>` over the committed scope as built, before release — not a
  `/brainstorm` or `/quick-change` topic. The report is the outcome; every confirmed finding becomes
  a backlog Task through `/update-backlog`, or an accepted risk recorded with its reason.*
- `[audit:seo-geo]` adds: *It audits a reachable deployment of the release candidate —
  `<the environment>`, or the outside row that provides it.*
- `[audit:wcag]` adds: *`/wcag` is not in this workflow yet — until it is, audit against WCAG 2.2 AA
  by hand or with an external tool and keep the report with the others.*
- **Upkeep occurrence:** *Run `<command>` in a person's own session — not a team run and not a
  `/brainstorm` topic: the command writes `.agents/memory/`, which team roles cannot. Act on its
  report and commit the result.* `[upkeep:architecture-review]` adds: *Each candidate chosen for
  work becomes its own Task.*

## Crediting a run

A whole-codebase run of the command closes **this** occurrence when it happens after the
occurrence's prerequisites are done, in the command's home checkout: `/architecture-review` — the
checkout the profile's `upkeep.architecture_review.repo` names when set, else this repository;
`/maintain:cleanup-workflow` — always this repository. Name the home checkout in the Task's
Summary when it is another one. An earlier run resets
the reminder's clock and closes nothing; later occurrences stay open. The person closes the Task
through its status owner (the local `Status` cell, or Jira for a synced Task).

## Detail templates (`/setup:delivery-plan` step 2, `/update-backlog` under `**Detail:** full`)

- **Audit** — Goal: *the committed scope ships with a `<command>` report on the revision that holds
  it.* In scope: *one run of `<command>` over the product as built; triage of every finding.* Out
  of scope: *fixing the findings — each becomes its own Task.* Criteria:
  - *Given every Task this audit depends on is done, when `<command>` runs, then its report names
    the revision it audited and that revision contains every one of those Tasks.*
  - *Given the report, when it is triaged, then every confirmed finding and every coverage gap it
    names is a backlog Task, a rerun of the missing part, or an accepted risk recorded with its
    reason.*
  - `[audit:wcag]`, while `/wcag` is not in this workflow, replaces "when `<command>` runs" with
    *when the product is audited against WCAG 2.2 AA (by hand or with an external tool)*.
  - `[audit:seo-geo]` replaces the first criterion's revision clause with: *it audits
    `<the environment or staging row id>`, and the report names the deployed revision (a deployment
    id or build sha the environment shows), which contains every one of those Tasks.*
- **Upkeep occurrence** — Goal: *the architecture* (or *the workflow*) *is reviewed at this point of
  the build.* In scope: *one whole-codebase run of `<command>` and acting on its report.* Out of
  scope: *the refactors or cleanups it proposes beyond its own commit — each becomes its own Task.*
  Criterion:
  - *Given this occurrence's prerequisites are done, when `<command>` runs over the whole codebase
    in `<its home checkout>`, then its result is committed.* (Fill in the checkout from Crediting a
    run, so the criterion reads on its own in a tracker.)

A quality Task needs no trace and no PRD source: this file is its source.
