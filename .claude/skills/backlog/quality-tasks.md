# Quality & upkeep Tasks — the closing audits and the recurring upkeep every backlog plans

Read by `/setup:create-backlog` (Phase 4.5), `@backlog-author`, `@backlog-epic-author`,
`/update-backlog`, `/check-backlog`, `/setup:delivery-plan` and the backlog rubric. The marker
table and the regression markers (`## Regression`) are mirrored in code by `QUALITY_MARKERS` in
`.claude/lib/backlog-check.mjs`; change both together.

## Markers

A quality Task's `Task` cell **begins** with one marker:

| Marker | Command | Kind | Size | Planned |
|---|---|---|---|---|
| `[audit:security]` | `/audit-security` | closing | `H` | always |
| `[audit:seo-geo]` | `/seo-geo-audit` | closing | `H` | when the product has a public website — pages served without login that search engines or AI assistants should find |
| `[audit:wcag]` | `/wcag-audit` | closing | `H` | when the product has a user interface people operate |
| `[upkeep:architecture-review]` | `/architecture-review` | recurring | `M` | always, `n` numbered occurrences |
| `[upkeep:cleanup-workflow]` | `/maintain:cleanup-workflow` | recurring | `M` | always, `n` numbered occurrences |
| `[upkeep:refresh-brief]` | `/maintain:refresh-brief` | reminder | `M` | never planned — only `/check-backlog` adds one, when the PRD changed after the brief (Reminder Tasks) |

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
- `[audit:wcag]` adds: *`/wcag-audit` scans the reachable web pages of a deployment of the release
  candidate (or a localhost build). Surfaces it cannot reach — native apps, pages behind a login (v1
  has no `--auth`), complete processes — are audited by hand or with an external tool; the Task
  names which evidence closes each part. The report's not-tested criteria and manual tasks are part
  of the outcome to triage.*
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

## Reminder Tasks

`/check-backlog` step 5a adds one when `upkeep.sh due` marks an upkeep item and the Operator
answers **Add the Task** (`refresh-brief`, `cleanup-workflow` or `architecture-review`):

- Row: `Task` `[upkeep:<id>] Run <command>` (unnumbered — the cadence never counts it) · `Type` `tech` · `Size` `M` · `Scope` `MUST` · `Depends on` `—` · `Node` `—` · `Relates` `—` · `Chain` `—` · `Traces` `—` · `Status` `TODO` · `Jira` `—`.
- Epic: `Quality & upkeep`; absent → created with the Epic fields above (Outcome, Key assumption, `Depends on` `—`, the appetite line), last in the Epic map.
- Summary: the **Upkeep occurrence** line above; `architecture-review` adds its sentence; when the item's `home` is not `.`, add *Run it from `<home>`.*
- Under `**Detail:** full` — Goal: *the brief matches the current PRD* (`refresh-brief`), *the architecture is reviewed* (`architecture-review`), *the workflow is cleaned up* (`cleanup-workflow`). In scope: *one run of `<command>` and acting on its report.* Out of scope: *the refactors or cleanups it proposes beyond its own commit — each becomes its own Task.* Criterion:
  - *Given this Task is open, when a whole-codebase run of `<command>` in `<home checkout>` finishes and prints `upkeep: recorded <id> in <path>`, where `<path>` resolved from `<home checkout>` is `<record>`, then `<record>` holds that run as the item's `last_run` and the run's result is committed.* (`<record>` is the item's `record` from `upkeep.sh due --format json`, relative to the checkout that ran `/check-backlog` — e.g. `../review-home/.agents/upkeep.json` — while the run in the home checkout prints the path relative to itself, `.agents/upkeep.json`; both name one file.)
- Crediting: a run that records itself while the Task is open closes it once the run's result is committed (the criterion above) — it has no prerequisites. A run that records nothing (a focused `/architecture-review`, a moved `HEAD`, a PRD changed during the refresh) leaves it open. The person closes it through its status owner.

## Regression

The regression Tasks and the criterion tags of `.agents/reference/regression.md`. The backlog
writers apply this section; `backlog-check.mjs` checks it (its tag and critical-flow errors start
`regression tag:`).

**When.** Only with `.claude/regression.json` (regression adopted, `/setup:regression`): plan the
Tasks below and tag the criteria. Not adopted and the profile's `app_surface` is `web` → one line
under `## Consciously out of scope`, which rules out the whole family:
`- [regression:foundation] — regression not adopted (no .claude/regression.json); run /setup:regression, then /update-backlog adds the Tasks`.
Otherwise nothing — no Task, no line, no tag. Adopted → a rule-out does not count.

| Marker | Command | Kind | Size | Planned |
|---|---|---|---|---|
| `[regression:foundation]` | `/setup:regression` (baseline stage) + the test-data adapter | regression | `H` (`XH` with a sandbox integration) | always when adopted |
| `[regression:baseline]` | — (specs by hand until the author lane ships) | regression | `H` | 1–3 when adopted: b = min(3, max(1, ceil(P / 160))) |
| `[regression:smoke]` | — | regression | `M` | optional — an early P0 smoke set |

Row fields as quality Tasks: `Type` `tech` · `Scope` `MUST` · `Node` `—` · `Traces` `—`; Epic
`Quality & upkeep`. Titles: `[regression:foundation] Set up the regression run` ·
`[regression:baseline] Write the regression baseline — part <k>` · `[regression:smoke] Write the P0
smoke set`. Unlike `[audit:` and `[upkeep:`, a regression Task is **developer work designed with
`/brainstorm` or `/quick-change`**, like a product Task.

**Order — `Depends on` only.** The foundation depends on every product sink; baseline part `k` on
the foundation and every product sink. With `[regression:smoke]` planned the foundation depends
only on the sinks of the Tasks tracing a critical flow, and the smoke Task on the foundation. The
checker does not check placement. A release outside row **never lists a regression Task** in its
`Starts after` (no gates — Operator decision).

**Tags.** With `.claude/regression.json` present every browser-observable current criterion leads
its text with `[reg P0]` (an outcome on a critical flow — `FL-n` with `**Critical:** yes`),
`[reg P1]` (another main path) or `[reg P2]` (an edge or unwanted-behaviour path); a criterion
that is not browser-observable carries no tag. Form: directly after the id separator
(`- **E1-2.AC3** — [reg P0] Given …`), followed by a space; a withdrawn criterion keeps
`(withdrawn)` first. Exactly `[reg P0]`, `[reg P1]` or `[reg P2]` — one per criterion.

- The tag is **outside the criterion fingerprint** (`qa-evidence-families.md` §7c step 4b).
- A **retag** is an edit that leaves the fingerprint unchanged: adding a valid leading tag to an
  untagged criterion, replacing one valid leading tag by another, or removing a valid leading tag.
  A retag is not a rewrite — it is allowed in place, also on a protected Task's Epic-file criterion.
- Every other tag repair — a malformed, misplaced or duplicate token — **changes the fingerprint**
  (the bad token is still text) and is a rewrite: the criterion-change and protection rules apply
  (unprotected: withdraw + a new id; protected: a proposal for `/update-backlog`).
- A spec-owned criterion is tagged only in its spec (`/brainstorm <Task id>`).
- Without `.claude/regression.json` no tag is written.
- The checker: a tag-form problem is an error naming the criterion; under `**Detail:** full` every
  live critical flow needs a `[reg P0]` criterion on the Tasks that trace it, and a backlog with
  no tag at all warns.

**Summary lines.**

- **Foundation:** *Set up the regression run for this product: `/setup:regression` baseline stage
  (runner, environments, Playwright config and fixtures) and the test-data adapter of
  `.agents/reference/regression-test-data.md` for the test environment.*
- **Baseline:** *Write the Playwright specs for the READY P0/P1 scenarios of `<areas>` and make
  them pass on the test environment.*
- **Smoke:** *Write the specs of the catalog's `smoke` priorities first, so a P0 smoke set runs
  before the full baseline.*

## Detail templates (`/setup:delivery-plan` step 2, `/update-backlog` under `**Detail:** full`)

- **Reminder Task** — an unnumbered `[upkeep:<id>] Run <command>` with `Depends on` `—` (any of the three upkeep ids): Goal, scope lines and criterion from **Reminder Tasks** above, never the occurrence template. (An unnumbered follow-up run `/update-backlog` adds after a protected occurrence has prerequisites and keeps the occurrence template.)
- **Audit** — Goal: *the committed scope ships with a `<command>` report on the revision that holds
  it.* In scope: *one run of `<command>` over the product as built; triage of every finding.* Out
  of scope: *fixing the findings — each becomes its own Task.* Criteria:
  - *Given every Task this audit depends on is done, when `<command>` runs, then its report names
    the revision it audited and that revision contains every one of those Tasks.*
  - *Given the report, when it is triaged, then every confirmed finding and every coverage gap it
    names is a backlog Task, a rerun of the missing part, or an accepted risk recorded with its
    reason.*
  - `[audit:wcag]` splits the first criterion: *when `/wcag-audit` runs on the reachable web surface
    and the remaining surfaces are audited by hand or with an external tool, then …*.
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
- **Regression foundation** — Goal: *the product's regression run is configured and its test data
  is under control on the test environment.* In scope: *the `/setup:regression` baseline stage and
  the test-data adapter (`.agents/reference/regression-test-data.md`).* Out of scope: *writing
  scenario specs — the baseline Tasks.* Criteria (`setup.mjs check` only proves that configuration
  and program files exist, so the adapter's behaviour gets its own criteria; each adapter criterion
  is proven by a test in the foundation Task itself):
  - *Given a test environment named in `.claude/regression.json`, when
    `node .claude/lib/regression/setup.mjs check` runs, then it prints `foundation complete`.*
  - *Given the test environment, when the adapter's `check` runs, then it exits 0 when every
    account and data prerequisite is in place.*
  - *IF a prerequisite is missing, THEN `check` exits 1, names it by key only and changes nothing.*
  - *Given an account key, when `session` runs, then it prints one path to a storage-state file in
    a gitignored directory and exits 0.*
  - *Given a run id, when `reset --run <id>` runs on the test environment, then only that run's
    data is reset.*
  - *IF `REGRESSION_ENV_KIND` is absent or not `test`, THEN `provision` and `reset` exit 3 and
    change nothing.*
- **Regression baseline** — Goal: *the READY P0/P1 scenarios of `<areas>` run green.* In scope:
  *one spec per READY P0/P1 scenario of `<areas>` without one.* Out of scope: *P2 scenarios and
  scenarios of other areas.* Criterion:
  - *Given the READY P0/P1 scenarios of `<areas>`, when their specs run against the test
    environment, then each passes repeated runs with zero retries on every device project of its
    scenario.*
- **Regression smoke** — the baseline template, for the scenarios of the catalog's `smoke`
  priorities.

A quality Task needs no trace and no PRD source: this file is its source.
